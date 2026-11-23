//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatrixRustSDK

/// Inputs of the chat/call credit gate for one room. Mirrors the Android `MessageComposerState`
/// fields used by `MessageComposerPresenter` (final MVP state, 93b7510204 + fc38a7a6a0).
struct ChatGateState: Equatable {
    /// The other active (joined/invited) member of a 1:1 DM. nil for groups or while members load.
    var peerID: String?
    /// The local user's role. nil = unknown.
    var isConsultant: Bool?
    /// The local user's spendable balance (`current_hold`).
    var credits: Int?
    /// The partner's chat rate (their `max_credits`).
    var recipientRate: Int?
    /// Whether a 24 h hold is active for (me, peer). nil = not checked yet or errored.
    var holdExists: Bool?

    /// Fail open: only a known client, with no active hold, whose known balance is strictly below
    /// the known partner rate is restricted. Unknown never restricts (the server still bills).
    var isRestricted: Bool {
        guard peerID != nil,
              isConsultant == false,
              holdExists == false,
              let credits,
              let recipientRate else {
            return false
        }
        return credits < recipientRate
    }
}

enum ChatGatePreSendDecision {
    /// Send right away.
    case send
    /// Show the "Start a new session?" warning first.
    case warn
    /// The hold state is unknown; resolve it with `resolvePreSendDecision()`.
    case needsCheck
}

/// Per-room wallet gate (Android `MessageComposerPresenter` gate). Owned by `RoomScreenCoordinator`,
/// which calls `start()` / `stop()`. It drives the restricted composer, the call button visibility
/// and the "Start a new session?" warning.
///
/// - The first paint is seeded synchronously from the `WalletService` caches (instant gate).
/// - The balance, hold state and partner rate are then revalidated concurrently, and again
///   whenever the partner or the role changes.
/// - Confirmed clients (`isConsultant == false`) in a DM are polled every 60 s.
/// - Any hold started elsewhere (text/voice send, call billing) is picked up through
///   `WalletService.holdStateDidChange`.
@MainActor
final class ChatWalletGate {
    private static let pollInterval: Duration = .seconds(60)

    private let roomProxy: JoinedRoomProxyProtocol
    private let wallet: WalletService?
    private let ownUserID: String

    private let stateSubject = CurrentValueSubject<ChatGateState, Never>(.init())
    var statePublisher: CurrentValuePublisher<ChatGateState, Never> {
        stateSubject.asCurrentValuePublisher()
    }

    var state: ChatGateState {
        stateSubject.value
    }

    private var cancellables = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var recheckTask: Task<Void, Never>?
    private var isRunning = false

    /// `wallet` is nil in previews and tests (nothing registered in the `ServiceLocator`); the gate
    /// then stays open.
    init(roomProxy: JoinedRoomProxyProtocol, wallet: WalletService?) {
        self.roomProxy = roomProxy
        self.wallet = wallet
        ownUserID = roomProxy.ownUserID
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        guard let wallet else { return }

        // Instant gate: everything known locally is applied before the first network call.
        var initialState = ChatGateState()
        initialState.peerID = roomProxy.walletPartnerUserID
        initialState.isConsultant = wallet.isCurrentUserConsultant
        initialState.credits = wallet.credits
        stateSubject.send(initialState)
        restartLoadAndPoll()

        wallet.$credits
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] credits in
                guard let self, credits != state.credits else { return }
                update { $0.credits = credits }
            }
            .store(in: &cancellables)

        wallet.$isCurrentUserConsultant
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConsultant in
                guard let self, isConsultant != state.isConsultant else { return }
                update { $0.isConsultant = isConsultant }
                restartLoadAndPoll()
            }
            .store(in: &cancellables)

        let ownUserID = self.ownUserID
        Publishers.CombineLatest(roomProxy.membersPublisher, roomProxy.infoPublisher)
            .map { members, roomInfo in
                WalletPartnerResolver.partnerUserID(roomInfo: roomInfo, members: members, ownUserID: ownUserID)
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peerID in
                guard let self, peerID != state.peerID else { return }
                update { state in
                    state.peerID = peerID
                    state.holdExists = nil
                    state.recipientRate = nil
                }
                restartLoadAndPoll()
            }
            .store(in: &cancellables)

        wallet.holdStateDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] key in
                self?.handleHoldStateChange(key: key)
            }
            .store(in: &cancellables)
    }

    /// Called from `RoomScreenCoordinator.stop()` (not `deinit`, which a running task would delay).
    func stop() {
        isRunning = false
        cancellables.removeAll()
        loadTask?.cancel()
        loadTask = nil
        pollTask?.cancel()
        pollTask = nil
        recheckTask?.cancel()
        recheckTask = nil
    }

    // MARK: - New session warning (Android 165e2616fd)

    /// Synchronous decision used on Send. `.needsCheck` means the hold state is unknown.
    func preSendDecision() -> ChatGatePreSendDecision {
        let state = self.state
        // Note: an unknown role is treated as a client here, like Android (`isClient = role != true`).
        guard wallet != nil,
              let peerID = state.peerID,
              state.isConsultant != true,
              !NewSessionWarningOptOutStore.isOptedOut(consultantID: peerID, accountID: ownUserID) else {
            return .send
        }

        switch state.holdExists {
        case .some(true):
            return .send
        case .some(false):
            return .warn
        case .none:
            return .needsCheck
        }
    }

    /// Resolves an unknown hold state at send time. Errors fail open (send).
    func resolvePreSendDecision() async -> ChatGatePreSendDecision {
        let decision = preSendDecision()
        guard decision == .needsCheck else { return decision }
        guard let wallet, let peerID = state.peerID else { return .send }

        let exists = await wallet.checkHoldExists(clientId: ownUserID, consultantId: peerID)
        if state.peerID == peerID {
            update { $0.holdExists = exists }
        }
        return exists == false ? .warn : .send
    }

    /// "Never remind me again for this consultant".
    func optOutOfNewSessionWarning() {
        guard let peerID = state.peerID else { return }
        NewSessionWarningOptOutStore.optOut(consultantID: peerID, accountID: ownUserID)
    }

    // MARK: - Loading

    private func update(_ change: (inout ChatGateState) -> Void) {
        var newState = stateSubject.value
        change(&newState)
        if newState != stateSubject.value {
            stateSubject.send(newState)
        }
    }

    /// Android `LaunchedEffect(otherUserId, isCurrentUserConsultant)` + the separate poll effect.
    private func restartLoadAndPoll() {
        loadTask?.cancel()
        loadTask = nil
        pollTask?.cancel()
        pollTask = nil

        guard isRunning, let wallet else { return }

        let state = self.state
        if state.isConsultant != true, let peerID = state.peerID {
            // Instant gate (fc38a7a6a0): synchronous seeds before any network call.
            let cachedHoldExists = wallet.cachedHoldExists(clientId: ownUserID, consultantId: peerID)
            let cachedRate = wallet.cachedMaxCredits(userId: peerID)
            update { state in
                state.holdExists = cachedHoldExists
                if state.recipientRate == nil {
                    state.recipientRate = cachedRate
                }
            }
        }

        loadTask = Task { [weak self] in
            await self?.revalidate()
        }

        // Only confirmed clients in a DM are polled; consultants and unknown roles never are.
        guard state.isConsultant == false, state.peerID != nil else { return }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)

                // Re-bind `self` on each tick so the sleep never keeps the gate alive.
                do {
                    guard !Task.isCancelled, let self else { return }
                    guard self.state.isConsultant == false, self.state.peerID != nil else { return }
                    await self.revalidate()
                }
            }
        }
    }

    /// Refreshes the balance (always) and, for a non-consultant in a DM, the hold state and partner
    /// rate — all three concurrently. The hold result is assigned directly (an error clears a stale
    /// cached `false` back to unknown); the rate only overwrites on a value.
    private func revalidate() async {
        guard let wallet else { return }
        let ownUserID = self.ownUserID
        let state = self.state

        guard state.isConsultant != true, let peerID = state.peerID else {
            await wallet.refreshBalance(userId: ownUserID)
            return
        }

        async let balanceRefresh: Void = wallet.refreshBalance(userId: ownUserID)
        async let holdExists = wallet.checkHoldExists(clientId: ownUserID, consultantId: peerID)
        async let rate = wallet.getMaxCredits(userId: peerID)
        let (_, holdResult, rateResult) = await (balanceRefresh, holdExists, rate)

        guard !Task.isCancelled, self.state.peerID == peerID else { return }
        update { state in
            state.holdExists = holdResult
            if let rateResult {
                state.recipientRate = rateResult
            }
        }
    }

    /// A hold was started (or failed) somewhere for this pair: paint the cached value right away,
    /// then re-check the hold and the rate like Android does after a send.
    private func handleHoldStateChange(key: String) {
        guard isRunning,
              let wallet,
              let peerID = state.peerID,
              key == "\(ownUserID)|\(peerID)" else {
            return
        }

        let cachedHoldExists = wallet.cachedHoldExists(clientId: ownUserID, consultantId: peerID)
        update { $0.holdExists = cachedHoldExists }

        guard state.isConsultant != true else { return }

        recheckTask?.cancel()
        let ownUserID = self.ownUserID
        recheckTask = Task { [weak self] in
            async let holdExists = wallet.checkHoldExists(clientId: ownUserID, consultantId: peerID)
            async let rate = wallet.getMaxCredits(userId: peerID)
            let (holdResult, rateResult) = await (holdExists, rate)

            guard !Task.isCancelled, let self, self.state.peerID == peerID else { return }
            self.update { state in
                state.holdExists = holdResult
                if let rateResult {
                    state.recipientRate = rateResult
                }
            }
        }
    }
}

// MARK: - DM partner

enum WalletPartnerResolver {
    /// The other active (joined or invited) member of a 1:1 DM, or nil when the room isn't one or
    /// its members haven't loaded yet. Android: `roomInfo.isDm` + `membership.isActive`.
    static func partnerUserID(roomInfo: RoomInfoProxyProtocol,
                              members: [RoomMemberProxyProtocol],
                              ownUserID: String) -> String? {
        guard roomInfo.isDirect, roomInfo.activeMembersCount <= 2 else {
            return nil
        }
        return members.first { member in
            member.userID != ownUserID && (member.membership == .join || member.membership == .invite)
        }?.userID
    }
}

extension JoinedRoomProxyProtocol {
    /// The wallet counterparty of this room: the other active member of a 1:1 DM, else nil.
    var walletPartnerUserID: String? {
        WalletPartnerResolver.partnerUserID(roomInfo: infoPublisher.value,
                                            members: membersPublisher.value,
                                            ownUserID: ownUserID)
    }
}

// MARK: - "Never remind me again" persistence

/// Per-account set of consultant Matrix IDs for which the "Start a new session?" warning is
/// disabled. Android: DataStore string set `newSessionWarningDismissedConsultants`, session-scoped.
enum NewSessionWarningOptOutStore {
    private static func key(accountID: String) -> String {
        "newSessionWarningDismissedConsultants.\(accountID)"
    }

    static func isOptedOut(consultantID: String, accountID: String) -> Bool {
        let consultants = UserDefaults.standard.stringArray(forKey: key(accountID: accountID)) ?? []
        return consultants.contains(consultantID)
    }

    static func optOut(consultantID: String, accountID: String) {
        var consultants = UserDefaults.standard.stringArray(forKey: key(accountID: accountID)) ?? []
        guard !consultants.contains(consultantID) else { return }
        consultants.append(consultantID)
        UserDefaults.standard.set(consultants, forKey: key(accountID: accountID))
    }
}
