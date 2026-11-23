//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatrixRustSDK
import OrderedCollections
import SwiftUI

typealias RoomScreenViewModelType = StateStoreViewModel<RoomScreenViewState, RoomScreenViewAction>

class RoomScreenViewModel: RoomScreenViewModelType, RoomScreenViewModelProtocol {
    private let clientProxy: ClientProxyProtocol
    private let roomProxy: JoinedRoomProxyProtocol
    private let appSettings: AppSettings
    private let analyticsService: AnalyticsService
    private let userIndicatorController: UserIndicatorControllerProtocol
    
    private var initialSelectedPinnedEventID: String?
    private let pinnedEventStringBuilder: RoomEventStringBuilder
    
    private var identityPinningViolations = [String: RoomMemberProxyProtocol]()
    private var identityVerificationViolations = [String: RoomMemberProxyProtocol]()
    
    /// Clariva DM header status (designation badge, presence) and the consultant ↔ consultant rule.
    /// nil in previews and unit tests, where no profile service is registered.
    private let peerStatusController: DMPeerStatusController?
    
    private let actionsSubject: PassthroughSubject<RoomScreenViewModelAction, Never> = .init()
    var actions: AnyPublisher<RoomScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    private var pinnedEventsTimelineItemProvider: TimelineItemProviderProtocol? {
        didSet {
            guard let pinnedEventsTimelineItemProvider else {
                return
            }
            
            buildPinnedEventContents(timelineItems: pinnedEventsTimelineItemProvider.itemProxies)
            pinnedEventsTimelineItemProvider.updatePublisher
                // When pinning or unpinning an item, the timeline might return empty for a short while, so we need to debounce it to prevent weird UI behaviours like the banner disappearing
                .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
                .sink { [weak self] updatedItems, _ in
                    guard let self else { return }
                    buildPinnedEventContents(timelineItems: updatedItems)
                }
                .store(in: &cancellables)
        }
    }
    
    init(userSession: UserSessionProtocol,
         roomProxy: JoinedRoomProxyProtocol,
         initialSelectedPinnedEventID: String?,
         ongoingCallRoomIDPublisher: CurrentValuePublisher<String?, Never>,
         appSettings: AppSettings,
         appHooks: AppHooks,
         analyticsService: AnalyticsService,
         userIndicatorController: UserIndicatorControllerProtocol,
         chatGateStatePublisher: CurrentValuePublisher<ChatGateState, Never>? = nil) {
        clientProxy = userSession.clientProxy
        self.roomProxy = roomProxy
        self.appSettings = appSettings
        self.analyticsService = analyticsService
        self.userIndicatorController = userIndicatorController
        
        self.initialSelectedPinnedEventID = initialSelectedPinnedEventID
        pinnedEventStringBuilder = .pinnedEventStringBuilder(userID: roomProxy.ownUserID)
        if let profiles = ServiceLocator.shared.clarivaProfile {
            peerStatusController = DMPeerStatusController(ownUserID: roomProxy.ownUserID, profiles: profiles, appSettings: appSettings)
        } else {
            peerStatusController = nil
        }

        let viewState = RoomScreenViewState(roomTitle: roomProxy.infoPublisher.value.displayName ?? roomProxy.id,
                                            roomAvatar: roomProxy.infoPublisher.value.avatar,
                                            hasOngoingCall: roomProxy.infoPublisher.value.hasRoomCall,
                                            hasSuccessor: roomProxy.infoPublisher.value.successor != nil)
        super.init(initialViewState: appHooks.roomScreenHook.update(viewState),
                   mediaProvider: userSession.mediaProvider)
        
        updateRoomInfo(roomProxy.infoPublisher.value)
        setupSubscriptions(ongoingCallRoomIDPublisher: ongoingCallRoomIDPublisher)
        setupWalletSubscriptions(chatGateStatePublisher: chatGateStatePublisher)
        setupPeerStatusSubscriptions()

        Task {
            await updateVerificationBadge()
        }
    }

    deinit {
        refundPollTask?.cancel()
    }

    /// The 15 s pending-hold status loop (Android `MessagesPresenter` LaunchedEffect). Restarted
    /// whenever the DM partner changes and cancelled in `stop()`.
    private var refundPollTask: Task<Void, Never>?
    /// Local dedupe of the auto-approval notices already claimed (or tried) during this session.
    /// Mirrors Android `notifiedRefundRequestIds` — keeps us from pounding the
    /// auto-approval claim endpoint on every 15s tick.
    private var notifiedRefundRequestIds: Set<String> = []
    /// Fetches the recorded call type whenever a call becomes ongoing (Join icon).
    private var ongoingCallTypeTask: Task<Void, Never>?
    private var lastKnownHasRoomCall = false
    /// Guards the chooser while the call type is being recorded (≤ 2 s).
    private var isStartingCall = false
    /// Set by `stop()`; the refund poll is never restarted afterwards.
    private var isStopped = false
    
    /// nil in previews and unit tests, where no wallet is registered.
    private var wallet: WalletService? {
        ServiceLocator.shared.wallet
    }

    override func process(viewAction: RoomScreenViewAction) {
        switch viewAction {
        case .tappedPinnedEventsBanner:
            handleTappedPinnedEventsBanner()
        case .viewAllPins:
            analyticsService.trackInteraction(name: .PinnedMessageBannerViewAllButton)
            actionsSubject.send(.displayPinnedEventsTimeline)
        case .displayRoomDetails:
            actionsSubject.send(.displayRoomDetails)
        case .displayCall:
            // Join an ongoing call, or start one directly in a non-DM room: no media choice is
            // recorded (the call screen resolves Join from the server record).
            CallBillingWatcher.shared.arm(roomProxy: roomProxy)
            actionsSubject.send(.displayCall)
            actionsSubject.send(.removeComposerFocus)
            analyticsService.trackInteraction(name: .MobileRoomCallButton)
        case .startCall(let isVoice):
            startCall(isVoice: isVoice)
        case .footerViewAction(let action):
            switch action {
            case .resolvePinViolation(let userID):
                Task { await resolveIdentityPinningViolation(userID) }
            case .resolveVerificationViolation(let userID):
                Task { await resolveIdentityVerificationViolation(userID) }
            case .dismissHistoryVisibleAlert:
                appSettings.acknowledgedHistoryVisibleRooms.insert(roomProxy.id)
                state.historyVisibleDetails = nil
            }
        case .acceptKnock(let eventID):
            Task { await acceptKnock(eventID: eventID) }
        case .dismissKnockRequests:
            Task { await markAllKnocksAsSeen() }
        case .viewKnockRequests:
            actionsSubject.send(.displayKnockRequests)
        case .displaySuccessorRoom:
            guard let successorID = roomProxy.infoPublisher.value.successor?.roomId else { return }
            let serverNames = roomProxy.knownServerNames(maxCount: 50) // Limit to the same number used by ClientProxy.resolveRoomAlias(_:)
            actionsSubject.send(.displayRoom(roomID: successorID, via: Array(serverNames)))
        case .requestRefundTapped:
            guard !state.isRefundRequestInProgress else { return }
            state.bindings.alertInfo = AlertInfo(id: .requestRefund,
                                                 title: "Request Refund",
                                                 message: "Are you sure you want to request a refund?",
                                                 primaryButton: .init(title: "Cancel", role: .cancel, action: nil),
                                                 secondaryButton: .init(title: "Request") { [weak self] in
                                                     self?.handleRequestRefund()
                                                 })
        case .approveRefundTapped:
            guard !state.isRefundRequestInProgress else { return }
            state.bindings.approveRefundSheet = ApproveRefundSheetModel(heldAmount: state.refundHeldAmount)
        case .approveRefund(let amount):
            state.bindings.approveRefundSheet = nil
            handleApproveRefund(amount: amount)
        case .rejectRefundTapped:
            guard !state.isRefundRequestInProgress else { return }
            state.bindings.alertInfo = AlertInfo(id: .rejectRefund,
                                                 title: "Reject Refund",
                                                 message: "The held amount will transfer to your wallet at the end of the hold window.",
                                                 primaryButton: .init(title: "Cancel", role: .cancel, action: nil),
                                                 secondaryButton: .init(title: "Reject") { [weak self] in
                                                     self?.handleRejectRefund()
                                                 })
        case .clearRefundSnackbar:
            state.refundSnackbar = nil
        }
    }
    
    // MARK: - Calls
    
    /// DM chooser choice. Records the type server-side first (≤ 2 s, like Android) so the receiver
    /// rings as voice/video, then hands the choice to the call screen and starts the call.
    private func startCall(isVoice: Bool) {
        guard !isStartingCall else { return }
        isStartingCall = true
        
        actionsSubject.send(.removeComposerFocus)
        analyticsService.trackInteraction(name: .MobileRoomCallButton)
        CallBillingWatcher.shared.arm(roomProxy: roomProxy)
        
        let roomID = roomProxy.id
        let ownUserID = roomProxy.ownUserID
        let wallet = self.wallet
        Task { [weak self] in
            await wallet?.setRoomCallType(roomId: roomID, isVideo: !isVoice, callerId: ownUserID)
            
            guard let self else { return }
            isStartingCall = false
            // Set right before presenting so an abandoned start never leaves a stale choice behind.
            CallMediaChoiceStore.shared.setStartWithVideoMuted(isVoice, for: roomID)
            actionsSubject.send(.displayCall)
        }
    }
    
    /// Android `LaunchedEffect(hasOngoingCall)`: re-read the recorded type each time a call
    /// becomes ongoing. Unknown → voice icon.
    private func refreshOngoingCallType() {
        guard let wallet else { return }
        
        let roomID = roomProxy.id
        ongoingCallTypeTask?.cancel()
        ongoingCallTypeTask = Task { [weak self] in
            let callType = await wallet.getRoomCallType(roomId: roomID)
            guard !Task.isCancelled else { return }
            self?.state.ongoingCallIsVideo = callType == "video"
        }
    }
    
    // MARK: - New session warning
    
    func presentNewSessionWarning(onContinue: @escaping (_ neverRemindAgain: Bool) -> Void) {
        state.bindings.alertInfo = AlertInfo(id: .newSessionWarning,
                                             title: "Start a new session?",
                                             message: "Your previous session has ended. Sending this message starts a new billable session and places a fresh hold on your credits.",
                                             primaryButton: .init(title: "Cancel", role: .cancel, action: nil),
                                             verticalButtons: [
                                                 .init(title: "Continue") { onContinue(false) },
                                                 .init(title: "Never remind me again for this consultant") { onContinue(true) }
                                             ])
    }

    // MARK: - Refund

    /// Exact mirror of Android's `do_not_translate.xml` refund bodies (165e2616fd removed the emoji).
    /// Plain `m.text` bodies: shown in the chat history and as the push preview.
    private static let refundRequestNotificationBody = "Refund requested for the held credits"
    private static let refundApprovedNotificationBody = "Your refund was approved — credits returned to your wallet"
    private static let refundRejectedNotificationBody = "Your refund was rejected by the consultant"
    private static let refundAutoApprovedNotificationBody = "Refund auto-approved after 24h with no response — credits returned to the client"
    
    /// Partial approval body: the amount actually returned to the client.
    private static func refundPartiallyApprovedNotificationBody(amount: Double) -> String {
        "Your refund was approved — \(RefundAmountFormatter.format(amount)) credits returned to your wallet"
    }
    
    private static let refundPollInterval: Duration = .seconds(15)

    /// (Re)starts the 15 s poll for the current DM partner, polling immediately. Called whenever the
    /// partner changes, so a partner that resolves after the room opened is picked up right away.
    private func restartRefundPolling(partnerID: String?) {
        refundPollTask?.cancel()
        refundPollTask = nil

        // A member update after `stop()` must not resurrect the poll on a dismissed room.
        guard !isStopped else { return }

        guard let partnerID, wallet != nil else {
            clearRefundState()
            return
        }
        
        refundPollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Only hold `self` for the poll itself, never across the sleep, so the loop can't
                // keep a dismissed room alive.
                do {
                    guard let self else { return }
                    await self.pollPendingHoldStatusOnce(partnerID: partnerID)
                }
                try? await Task.sleep(for: Self.refundPollInterval)
            }
        }
    }
    
    private func clearRefundState() {
        state.isRefundButtonVisible = false
        state.refundStatus = nil
        state.refundPendingHoldId = nil
        state.refundRequestId = nil
        state.refundHeldAmount = nil
    }

    private func partnerUserID() -> String? {
        roomProxy.walletPartnerUserID
    }

    private func pollPendingHoldStatusOnce(partnerID: String) async {
        guard let wallet else { return }
        let myUserId = roomProxy.ownUserID
        // Errors leave the state untouched (Android `catch: log`).
        guard let status = await wallet.getPendingHoldStatus(clientId: myUserId, consultantId: partnerID),
              !Task.isCancelled else {
            return
        }
        // Server bidirectional lookup: my role is determined by whether the hold's consultantId == me.
        let amConsultant = status.consultantId != nil && status.consultantId == myUserId
        state.isConsultantInThisRoom = amConsultant
        if status.exists, status.isRefundActive == 1 {
            state.refundStatus = status.refundStatus
            state.refundPendingHoldId = status.holdIdString
            state.refundRequestId = status.refundRequestIdString
            state.refundHeldAmount = status.amount
            state.isRefundButtonVisible = true
            // Android also records "requested" ids here, but they are the same ids as the auto-approval
            // notices below, so a consultant who saw the request would never announce its auto-approval.
        } else {
            clearRefundState()
        }
        // Auto-approval push-notification pickup. First app to observe the
        // pendingAutoApprovalNotification + win the atomic claim posts the in-room
        // m.room.message; the other party (likely app-closed) gets the push via the
        // standard homeserver → Sygnal → APNs pipeline. Best-effort: claim or send
        // failure does NOT roll back the refund — credits are already returned.
        if let pending = status.pendingAutoApprovalNotification {
            let idString = pending.refundRequestId
            if !notifiedRefundRequestIds.contains(idString) {
                notifiedRefundRequestIds.insert(idString)
                let claimed = await wallet.claimAutoApprovalNotification(refundRequestId: idString,
                                                                          callerUserId: myUserId)
                if claimed {
                    await sendRefundNotification(Self.refundAutoApprovedNotificationBody)
                    MXLog.info("[Refund] Posted auto-approval Matrix message for refund \(idString)")
                } else {
                    MXLog.info("[Refund] Auto-approval claim lost for refund \(idString) (other side announced)")
                }
            }
        }
    }
    
    /// Plain-text push message on the live timeline. It bypasses the composer, so it never starts a
    /// hold. Failures are logged and never roll anything back.
    private func sendRefundNotification(_ body: String) async {
        if case .failure(let error) = await roomProxy.timeline.sendMessage(body,
                                                                         html: nil,
                                                                         inReplyToEventID: nil,
                                                                         intentionalMentions: .empty) {
            MXLog.error("[Refund] Failed sending refund message: \(error)")
        }
    }

    private func handleRequestRefund() {
        if state.isRefundRequestInProgress { return }
        guard let wallet, let holdId = state.refundPendingHoldId, let partnerId = partnerUserID() else {
            MXLog.warning("[Refund] Cannot request refund: holdId=\(state.refundPendingHoldId ?? "nil"), partner=\(partnerUserID() ?? "nil")")
            return
        }
        state.isRefundRequestInProgress = true
        let myId = roomProxy.ownUserID
        Task { [weak self] in
            let result = await wallet.requestRefund(clientId: myId, consultantId: partnerId, pendingHoldId: holdId)
            guard let self else { return }
            switch result {
            case .success:
                state.refundStatus = "requested"
                state.refundSnackbar = "Refund request sent"
                await sendRefundNotification(Self.refundRequestNotificationBody)
            case .failure(let error):
                MXLog.error("[Refund] requestRefund failed: \(error)")
                state.refundSnackbar = L10n.commonError
            }
            state.isRefundRequestInProgress = false
        }
    }

    /// `amount == nil` ⇒ full refund.
    private func handleApproveRefund(amount: Double?) {
        if state.isRefundRequestInProgress { return }
        guard let wallet, let reqId = state.refundRequestId, let holdId = state.refundPendingHoldId else {
            MXLog.warning("[Refund] Cannot approve: reqId=\(state.refundRequestId ?? "nil") holdId=\(state.refundPendingHoldId ?? "nil")")
            return
        }
        state.isRefundRequestInProgress = true
        let myId = roomProxy.ownUserID
        Task { [weak self] in
            let result = await wallet.approveRefund(refundRequestId: reqId, pendingHoldId: holdId, refundAmount: amount)
            guard let self else { return }
            switch result {
            case .success(let response):
                state.refundStatus = "approved"
                state.isRefundButtonVisible = false
                state.refundSnackbar = "Refund approved"
                // Drop the chat-list pending-refund badge for this client. Mirrors Android.
                await wallet.refreshPendingRefundRequests(consultantUserId: myId)
                // The amount actually returned, falling back to the requested partial amount.
                let returnedAmount = response.amount ?? amount
                if amount != nil, let returnedAmount {
                    await sendRefundNotification(Self.refundPartiallyApprovedNotificationBody(amount: returnedAmount))
                } else {
                    await sendRefundNotification(Self.refundApprovedNotificationBody)
                }
            case .failure(let error):
                MXLog.error("[Refund] approveRefund failed: \(error)")
                state.refundSnackbar = L10n.commonError
            }
            state.isRefundRequestInProgress = false
        }
    }

    private func handleRejectRefund() {
        if state.isRefundRequestInProgress { return }
        guard let wallet, let reqId = state.refundRequestId else {
            MXLog.warning("[Refund] Cannot reject: reqId is nil")
            return
        }
        state.isRefundRequestInProgress = true
        let myId = roomProxy.ownUserID
        Task { [weak self] in
            let result = await wallet.rejectRefund(refundRequestId: reqId)
            guard let self else { return }
            switch result {
            case .success:
                state.refundStatus = "rejected"
                state.refundSnackbar = "Refund rejected"
                await wallet.refreshPendingRefundRequests(consultantUserId: myId)
                await sendRefundNotification(Self.refundRejectedNotificationBody)
            case .failure(let error):
                MXLog.error("[Refund] rejectRefund failed: \(error)")
                state.refundSnackbar = L10n.commonError
            }
            state.isRefundRequestInProgress = false
        }
    }
    
    func stop() {
        // When navigating away from the room, we need to mark the room as fully read.
        // This does not affect the read receipts only the notification count.
        Task { await roomProxy.markAsRead(receiptType: .fullyRead) }
        // Work around QLPreviewController dismissal issues, see the InteractiveQuickLookModifier.
        state.bindings.mediaPreviewViewModel = nil
        // Stop the refund poll (it must not outlive the room screen) and pending lookups.
        isStopped = true
        refundPollTask?.cancel()
        refundPollTask = nil
        ongoingCallTypeTask?.cancel()
        ongoingCallTypeTask = nil
        peerStatusController?.stop()
    }
    
    func timelineHasScrolled(direction: ScrollDirection) {
        state.lastScrollDirection = direction
    }
    
    func setSelectedPinnedEventID(_ eventID: String) {
        state.pinnedEventsBannerState.setSelectedPinnedEventID(eventID)
    }
    
    func displayMediaPreview(_ mediaPreviewViewModel: TimelineMediaPreviewViewModel) {
        mediaPreviewViewModel.actions.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .dismiss:
                state.bindings.mediaPreviewViewModel = nil
            case .displayMessageForwarding(let forwardingItem):
                state.bindings.mediaPreviewViewModel = nil
                // We need a small delay because we need to wait for the media preview to be fully dismissed.
                DispatchQueue.main.asyncAfter(deadline: .now() + TimelineMediaPreviewViewModel.displayMessageForwardingDelay) {
                    self.actionsSubject.send(.displayMessageForwarding(forwardingItem))
                }
            case .viewInRoomTimeline:
                fatalError("\(action) should not be visible on a room preview.")
            }
        }
        .store(in: &cancellables)
        
        state.bindings.mediaPreviewViewModel = mediaPreviewViewModel
    }
    
    // MARK: - Private
    
    private func setupSubscriptions(ongoingCallRoomIDPublisher: CurrentValuePublisher<String?, Never>) {
        appSettings.$knockingEnabled
            .weakAssign(to: \.state.isKnockingEnabled, on: self)
            .store(in: &cancellables)
                
        roomProxy.infoPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] roomInfo in
                self?.updateRoomInfo(roomInfo)
            }
            .store(in: &cancellables)
        
        let identityStatusChangesPublisher = roomProxy.identityStatusChangesPublisher.receive(on: DispatchQueue.main)
        
        Task { [weak self] in
            for await changes in identityStatusChangesPublisher.values {
                guard !Task.isCancelled else {
                    return
                }
                
                await self?.processIdentityStatusChanges(changes)
                await self?.updateVerificationBadge()
            }
        }
        .store(in: &cancellables)
        
        clientProxy.homeserverReachabilityPublisher
            .filter { $0 == .reachable }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setupPinnedEventsTimelineItemProviderIfNeeded()
            }
            .store(in: &cancellables)
        
        ongoingCallRoomIDPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ongoingCallRoomID in
                guard let self else { return }
                state.isParticipatingInOngoingCall = ongoingCallRoomID == roomProxy.id
            }
            .store(in: &cancellables)
        
        roomProxy.knockRequestsStatePublisher
            // We only care about unseen requests
            .map { knockRequestsState in
                guard case let .loaded(requests) = knockRequestsState else {
                    return []
                }
                
                return requests
                    .filter { !$0.isSeen }
                    .map(KnockRequestInfo.init)
            }
            // If the requests have the same event ids we can discard the output
            .removeDuplicates { Set($0.map(\.eventID)) == Set($1.map(\.eventID)) }
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .weakAssign(to: \.state.unseenKnockRequests, on: self)
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.roomProxy.timeline.retryDecryption(sessionIDs: nil)
            }
            .store(in: &cancellables)
    }
    
    private func setupWalletSubscriptions(chatGateStatePublisher: CurrentValuePublisher<ChatGateState, Never>?) {
        if let chatGateStatePublisher {
            // The gate publishes on the main actor; assign synchronously so the instant (cached)
            // gate is in place for the first paint.
            state.chatGate = chatGateStatePublisher.value
            chatGateStatePublisher
                .removeDuplicates()
                .weakAssign(to: \.state.chatGate, on: self)
                .store(in: &cancellables)
        }
        
        // Restart the refund poll whenever the DM partner resolves or changes (Android restarts its
        // LaunchedEffect keyed on the member), instead of waiting for the next 15 s tick.
        let ownUserID = roomProxy.ownUserID
        Publishers.CombineLatest(roomProxy.membersPublisher, roomProxy.infoPublisher)
            .map { members, roomInfo in
                WalletPartnerResolver.partnerUserID(roomInfo: roomInfo, members: members, ownUserID: ownUserID)
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] partnerID in
                self?.restartRefundPolling(partnerID: partnerID)
            }
            .store(in: &cancellables)
    }
    
    /// Android ee053dc156: the DM header shows the partner's designation and presence, and a
    /// consultant ↔ consultant DM is read-only (composer replaced, calls hidden).
    private func setupPeerStatusSubscriptions() {
        guard let peerStatusController else { return }

        let ownUserID = roomProxy.ownUserID

        // Seeded synchronously from the caches (the chat list usually looked the partner up already)
        // so the badge and a read-only composer are there at first paint.
        let initialPeerID = roomProxy.walletPartnerUserID
        let isInitialPeerJoined = initialPeerID.map { peerID in roomProxy.membersPublisher.value.contains { $0.userID == peerID && $0.membership == .join } } ?? false
        peerStatusController.update(peerID: initialPeerID, isPeerJoined: isInitialPeerJoined)
        let initialStatus = peerStatusController.statusPublisher.value
        state.dmPeerStatus = initialStatus
        state.isConsultantPeerBlocked = wallet?.isCurrentUserConsultant == true && initialStatus.isPeerConsultant == true && initialPeerID != nil

        Publishers.CombineLatest(roomProxy.membersPublisher, roomProxy.infoPublisher)
            .map { members, roomInfo -> DMPeerKey in
                let peerID = WalletPartnerResolver.partnerUserID(roomInfo: roomInfo, members: members, ownUserID: ownUserID)
                let isPeerJoined = peerID.map { peerID in members.contains { $0.userID == peerID && $0.membership == .join } } ?? false
                return DMPeerKey(peerID: peerID, isPeerJoined: isPeerJoined)
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] key in
                guard let self, !isStopped else { return }
                peerStatusController.update(peerID: key.peerID, isPeerJoined: key.isPeerJoined)
            }
            .store(in: &cancellables)
        
        // Consultants may only chat with clients. Both roles must be CONFIRMED to block: an unknown
        // role fails open, like the wallet gate.
        let isCurrentUserConsultant = wallet?.$isCurrentUserConsultant.eraseToAnyPublisher() ?? Just<Bool?>(nil).eraseToAnyPublisher()
        peerStatusController.statusPublisher
            .combineLatest(isCurrentUserConsultant.removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status, isCurrentUserConsultant in
                guard let self else { return }
                if state.dmPeerStatus != status {
                    state.dmPeerStatus = status
                }
                let isBlocked = isCurrentUserConsultant == true && status.isPeerConsultant == true && roomProxy.walletPartnerUserID != nil
                if state.isConsultantPeerBlocked != isBlocked {
                    state.isConsultantPeerBlocked = isBlocked
                }
            }
            .store(in: &cancellables)
    }
    
    private func processIdentityStatusChanges(_ changes: [IdentityStatusChange]) async {
        for change in changes {
            switch change.changedTo {
            case .pinViolation:
                guard case let .success(member) = await roomProxy.getMember(userID: change.userId) else {
                    MXLog.error("Failed retrieving room member for identity status change: \(change)")
                    continue
                }
                
                identityPinningViolations[change.userId] = member
            case .verificationViolation:
                guard case let .success(member) = await roomProxy.getMember(userID: change.userId) else {
                    MXLog.error("Failed retrieving room member for identity status change: \(change)")
                    continue
                }

                identityVerificationViolations[change.userId] = member
            default:
                identityVerificationViolations[change.userId] = nil
                identityPinningViolations[change.userId] = nil
            }
        }
        
        if let member = identityVerificationViolations.values.first {
            state.identityViolationDetails = .verificationViolation(member: member,
                                                                    learnMoreURL: appSettings.identityPinningViolationDetailsURL)
        } else if let member = identityPinningViolations.values.first {
            state.identityViolationDetails = .pinViolation(member: member,
                                                           learnMoreURL: appSettings.identityPinningViolationDetailsURL)
        } else {
            state.identityViolationDetails = nil
        }
    }
    
    private func updateVerificationBadge() async {
        guard roomProxy.isDirectOneToOneRoom,
              let dmRecipient = roomProxy.membersPublisher.value.first(where: { $0.userID != roomProxy.ownUserID }),
              case let .success(userIdentity) = await clientProxy.userIdentity(for: dmRecipient.userID, fallBackToServer: true) else {
            state.dmRecipientVerificationState = .notVerified
            return
        }
        
        guard let userIdentity else {
            MXLog.failure("User identity should be known at this point")
            state.dmRecipientVerificationState = .notVerified
            return
        }
        
        state.dmRecipientVerificationState = userIdentity.verificationState
    }
    
    private func resolveIdentityPinningViolation(_ userID: String) async {
        defer {
            hideLoadingIndicator()
        }
        
        showLoadingIndicator()
        
        if case .failure = await clientProxy.pinUserIdentity(userID) {
            userIndicatorController.alertInfo = .init(id: .init(), title: L10n.commonError)
        }
    }
    
    private func resolveIdentityVerificationViolation(_ userID: String) async {
        defer {
            hideLoadingIndicator()
        }

        showLoadingIndicator()

        if case .failure = await clientProxy.withdrawUserIdentityVerification(userID) {
            userIndicatorController.alertInfo = .init(id: .init(), title: L10n.commonError)
        }
    }
    
    private func buildPinnedEventContents(timelineItems: [TimelineItemProxy]) {
        var pinnedEventContents = OrderedDictionary<String, AttributedString>()
        
        for item in timelineItems {
            // Only remote events are pinned
            if case let .event(event) = item,
               let eventID = event.id.eventID {
                pinnedEventContents.updateValue(pinnedEventStringBuilder.buildAttributedString(for: event) ?? AttributedString(L10n.commonUnsupportedEvent),
                                                forKey: eventID)
            }
        }
        
        state.pinnedEventsBannerState.setPinnedEventContents(pinnedEventContents)
        
        // If it's the first time we are setting the pinned events, we should select the initial event if available.
        if let initialSelectedPinnedEventID {
            state.pinnedEventsBannerState.setSelectedPinnedEventID(initialSelectedPinnedEventID)
            self.initialSelectedPinnedEventID = nil
        }
    }
    
    private func updateRoomInfo(_ roomInfo: RoomInfoProxyProtocol) {
        state.roomTitle = roomInfo.displayName ?? roomProxy.id
        state.roomAvatar = roomInfo.avatar
        state.hasOngoingCall = roomInfo.hasRoomCall
        state.hasSuccessor = roomInfo.successor != nil
        state.isDirectOneToOneRoom = roomInfo.isDirect && roomInfo.activeMembersCount <= 2
        
        if roomInfo.hasRoomCall, !lastKnownHasRoomCall {
            refreshOngoingCallType()
        }
        lastKnownHasRoomCall = roomInfo.hasRoomCall
        
        let pinnedEventIDs = roomInfo.pinnedEventIDs
        // Only update the loading state of the banner
        if state.pinnedEventsBannerState.isLoading {
            state.pinnedEventsBannerState = .loading(numbersOfEvents: pinnedEventIDs.count)
        }
        
        switch (roomProxy.isDirectOneToOneRoom, roomInfo.joinRule) {
        case (false, .knock), (false, .knockRestricted):
            state.isKnockableRoom = true
        default:
            state.isKnockableRoom = false
        }

        if let powerLevels = roomInfo.powerLevels {
            state.canSendMessage = powerLevels.canOwnUser(sendMessage: .roomMessage)
            state.canJoinCall = powerLevels.canOwnUserJoinCall()
            state.canAcceptKnocks = powerLevels.canOwnUserInvite()
            state.canDeclineKnocks = powerLevels.canOwnUserKick()
            state.canBan = powerLevels.canOwnUserBan()
        }
        
        let isHistoryVisible = roomInfo.historyVisibility == .shared || roomInfo.historyVisibility == .worldReadable
        let isHistoryVisibleBannerAcknowledged = appSettings.acknowledgedHistoryVisibleRooms.contains(roomInfo.id)

        if appSettings.enableKeyShareOnInvite, roomInfo.isEncrypted {
            if isHistoryVisible, !isHistoryVisibleBannerAcknowledged {
                // Whenever the user opens an encrypted room with shared/world-readable history visbility, we show them a warning banner if they have not already dismissed it.
                state.historyVisibleDetails = .historyVisible(learnMoreURL: appSettings.historySharingDetailsURL)
            } else if !isHistoryVisible, isHistoryVisibleBannerAcknowledged {
                // Whenever the user opens a room with non-shared history visibility, we clear the dismiss flag to ensure that the banner is displayed again if the history is made visible in the future.
                appSettings.acknowledgedHistoryVisibleRooms.remove(roomInfo.id)
                state.historyVisibleDetails = nil
            }
        }
    }
    
    private func setupPinnedEventsTimelineItemProviderIfNeeded() {
        guard pinnedEventsTimelineItemProvider == nil else {
            return
        }
        
        Task {
            guard case let .success(pinnedEventsTimeline) = await roomProxy.pinnedEventsTimeline() else {
                return
            }
            
            if pinnedEventsTimelineItemProvider == nil {
                pinnedEventsTimelineItemProvider = pinnedEventsTimeline.timelineItemProvider
            }
        }
    }
        
    private func acceptKnock(eventID: String) async {
        guard case let .loaded(requests) = roomProxy.knockRequestsStatePublisher.value,
              let request = requests.first(where: { $0.eventID == eventID }) else {
            return
        }
        
        state.handledEventIDs.insert(eventID)
        switch await request.accept() {
        case .success:
            break
        case .failure:
            userIndicatorController.submitIndicator(.init(id: Self.errorIndicatorIdentifier, type: .toast, title: L10n.errorUnknown))
            state.handledEventIDs.remove(eventID)
        }
    }
    
    private func markAllKnocksAsSeen() async {
        guard case let .loaded(requests) = roomProxy.knockRequestsStatePublisher.value else {
            return
        }
        state.handledEventIDs.formUnion(Set(requests.map(\.eventID)))
        
        let failedIDs = await withTaskGroup(of: (String, Result<Void, KnockRequestProxyError>).self) { group in
            for request in requests {
                group.addTask {
                    await (request.eventID, request.markAsSeen())
                }
            }
            
            var failedIDs = [String]()
            for await result in group where result.1.isFailure {
                failedIDs.append(result.0)
            }
            return failedIDs
        }
        state.handledEventIDs.subtract(failedIDs)
    }
    
    private func handleTappedPinnedEventsBanner() {
        analyticsService.trackInteraction(name: .PinnedMessageBannerClick)
        if let eventID = state.pinnedEventsBannerState.selectedPinnedEventID {
            Task {
                switch await roomProxy.loadOrFetchEventDetails(for: eventID) {
                case .success(let event):
                    if appSettings.threadsEnabled,
                       let threadRootEventID = event.threadRootEventId() {
                        actionsSubject.send(.focusEvent(eventID: threadRootEventID))
                        actionsSubject.send(.displayThread(threadRootEventID: threadRootEventID, focussedEventID: eventID))
                    } else {
                        actionsSubject.send(.focusEvent(eventID: eventID))
                    }
                case .failure:
                    userIndicatorController.submitIndicator(.init(title: L10n.errorUnknown))
                }
            }
        }
        state.pinnedEventsBannerState.previousPin()
    }
    
    // MARK: Loading indicators
    
    private static let loadingIndicatorIdentifier = "\(RoomScreenViewModel.self)-Loading"
    private static let errorIndicatorIdentifier = "\(RoomScreenViewModel.self)-Error"
    
    private func showLoadingIndicator() {
        userIndicatorController.submitIndicator(.init(id: Self.loadingIndicatorIdentifier, type: .toast, title: L10n.commonLoading))
    }
    
    private func hideLoadingIndicator() {
        userIndicatorController.retractIndicatorWithId(Self.loadingIndicatorIdentifier)
    }
}

extension RoomScreenViewModel {
    static func mock(roomProxyMock: JoinedRoomProxyMock,
                     clientProxyMock: ClientProxyMock = ClientProxyMock(.init()),
                     appHooks: AppHooks = AppHooks(),
                     chatGateState: ChatGateState = ChatGateState()) -> RoomScreenViewModel {
        RoomScreenViewModel(userSession: UserSessionMock(.init(clientProxy: clientProxyMock)),
                            roomProxy: roomProxyMock,
                            initialSelectedPinnedEventID: nil,
                            ongoingCallRoomIDPublisher: .init(.init(nil)),
                            appSettings: ServiceLocator.shared.settings,
                            appHooks: appHooks,
                            analyticsService: ServiceLocator.shared.analytics,
                            userIndicatorController: ServiceLocator.shared.userIndicatorController,
                            chatGateStatePublisher: CurrentValuePublisher<ChatGateState, Never>(chatGateState))
    }
}

/// The DM partner and whether they joined (a "contact" for last-seen privacy).
private struct DMPeerKey: Equatable {
    let peerID: String?
    let isPeerJoined: Bool
}

private extension KnockRequestInfo {
    init(from proxy: KnockRequestProxyProtocol) {
        self.init(displayName: proxy.displayName,
                  avatarURL: proxy.avatarURL,
                  userID: proxy.userID,
                  reason: proxy.reason,
                  eventID: proxy.eventID)
    }
}
