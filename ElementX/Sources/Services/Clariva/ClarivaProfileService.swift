//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import UIKit

enum ClarivaProfileError: Error, LocalizedError {
    case designationTooLong

    var errorDescription: String? {
        switch self {
        case .designationTooLong:
            "Designation must be at most \(ClarivaDesignation.maxLength) characters"
        }
    }
}

/// Clariva profile data kept in the Wallet-API user record: every user's role, a consultant's
/// designation and the "Last seen and online" privacy choice (Android ee053dc156 `WalletService`
/// designation / presence-privacy additions). Peer values are cached per user, filled by lookups.
///
/// Identity: like `WalletService`, the Matrix user ID is the wallet `Webuddy_name`.
@MainActor
final class ClarivaProfileService: ObservableObject {
    /// Stand-in for views when nothing is registered (tests and previews). Its host never resolves.
    static let offline = ClarivaProfileService(baseURL: URL(string: "https://wallet.invalid/")!,
                                               presenceService: MatrixPresenceService { _ in nil })

    let presenceService: MatrixPresenceService
    private let api: WalletAPIClient

    /// The current user's designation (consultants only); nil = none set, so "Consultant" shows.
    @Published private(set) var currentUserDesignation: String?
    /// The current user's "Last seen and online" choice; nil = not loaded yet.
    @Published private(set) var currentUserPresencePrivacy: PresencePrivacy?

    /// Emits a user ID whenever that user's cached role, designation or privacy choice was refreshed.
    let profileDidChange = PassthroughSubject<String, Never>()

    private var isConsultantCache: [String: Bool] = [:]
    /// "" = looked up, none set.
    private var designationCache: [String: String] = [:]
    private var presencePrivacyCache: [String: PresencePrivacy] = [:]
    /// Concurrent lookups of the same user (e.g. chat-list rows) share one request.
    private var lookupTasks: [String: Task<Bool, Never>] = [:]
    /// The account whose state is held; a different one flushes everything.
    private var currentUserID: String?

    init(baseURL: URL = ClarivaConfig.apiBaseURL, presenceService: MatrixPresenceService = .keychainBacked()) {
        api = WalletAPIClient(baseURL: baseURL)
        self.presenceService = presenceService
    }

    // MARK: - Current user

    /// (Re)loads the current user's designation and privacy choice. A failure keeps known values.
    func refreshCurrentUser(userID: String) async {
        switchUser(to: userID)
        guard await lookUpUser(userID), currentUserID == userID else { return }
        setIfChanged(\.currentUserDesignation, cachedDesignation(userID: userID))
        setIfChanged(\.currentUserPresencePrivacy, presencePrivacyCache[userID] ?? PresencePrivacy())
    }

    /// Saves the current user's designation. Blank removes it, so the default "Consultant" shows again.
    func updateDesignation(userID: String, designation: String?) async -> Result<Void, Error> {
        let value = ClarivaDesignation.normalized(designation)
        if let value, value.count > ClarivaDesignation.maxLength {
            return .failure(ClarivaProfileError.designationTooLong)
        }
        switchUser(to: userID)
        do {
            try await updateSettings(userID: userID, key: ClarivaDesignation.settingsKey, value: value.map { .string($0) })
            currentUserDesignation = value
            designationCache[userID] = value ?? ""
            profileDidChange.send(userID)
            MXLog.info("[Profile] Designation updated")
            return .success(())
        } catch {
            MXLog.error("[Profile] Failed updating the designation: \(error)")
            return .failure(error)
        }
    }

    /// Saves the current user's "Last seen and online" choice.
    func updatePresencePrivacy(userID: String, privacy: PresencePrivacy) async -> Result<Void, Error> {
        switchUser(to: userID)
        do {
            try await updateSettings(userID: userID, key: PresencePrivacy.settingsKey, value: privacy.jsonValue)
            currentUserPresencePrivacy = privacy
            presencePrivacyCache[userID] = privacy
            profileDidChange.send(userID)
            MXLog.info("[Profile] Presence privacy updated")
            return .success(())
        } catch {
            MXLog.error("[Profile] Failed updating the presence privacy: \(error)")
            return .failure(error)
        }
    }

    // MARK: - Any user

    /// Last-known role of `userID` (true = consultant), or nil if it was never looked up.
    func cachedIsConsultant(userID: String) -> Bool? {
        isConsultantCache[userID]
    }

    /// Last-known designation of `userID`, or nil when none is set or it was never looked up.
    func cachedDesignation(userID: String) -> String? {
        designationCache[userID].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Last-known "Last seen and online" choice of `userID`, or nil if it was never looked up.
    func cachedPresencePrivacy(userID: String) -> PresencePrivacy? {
        presencePrivacyCache[userID]
    }

    /// The cached designation badge: the designation (or "Consultant") of a known consultant, else nil.
    func cachedDesignationBadge(userID: String) -> String? {
        ClarivaDesignation.badge(isConsultant: isConsultantCache[userID], designation: cachedDesignation(userID: userID))
    }

    /// The designation badge of `userID`, looked up once when the role isn't cached yet.
    func designationBadge(userID: String) async -> String? {
        if isConsultantCache[userID] == nil {
            await lookUpUser(userID)
        }
        return cachedDesignationBadge(userID: userID)
    }

    /// Whether `userID` is a consultant, or nil when unknown (lookup failed). Cache-first.
    func isUserConsultant(userID: String) async -> Bool? {
        if let cached = isConsultantCache[userID] {
            return cached
        }
        await lookUpUser(userID)
        return isConsultantCache[userID]
    }

    /// Re-reads `userID`'s role, designation and privacy choice, bypassing the cache, so a designation
    /// a consultant changed shows the next time their chat is opened. False when the lookup failed,
    /// in which case the previously cached values are kept.
    @discardableResult
    func refreshPeerProfile(userID: String) async -> Bool {
        await lookUpUser(userID)
    }

    // MARK: - Private

    private func switchUser(to userID: String) {
        guard currentUserID != userID else { return }
        if currentUserID != nil {
            currentUserDesignation = nil
            currentUserPresencePrivacy = nil
            isConsultantCache.removeAll()
            designationCache.removeAll()
            presencePrivacyCache.removeAll()
            lookupTasks.values.forEach { $0.cancel() }
            lookupTasks.removeAll()
        }
        currentUserID = userID
    }

    /// Fetches `userID`'s wallet record and refreshes the per-user caches. A 404 means the user has
    /// no wallet record — every consultant has one — so it is recorded as "not a consultant".
    @discardableResult
    private func lookUpUser(_ userID: String) async -> Bool {
        if let task = lookupTasks[userID] {
            return await task.value
        }
        let task = Task { [api] () async -> Bool in
            do {
                let response = try await api.getUserProfile(webuddyName: userID)
                guard !Task.isCancelled else { return false }
                self.store(isConsultant: response.isConsultant.map { $0 == 1 },
                           designation: ClarivaDesignation.designation(from: response.settings),
                           privacy: PresencePrivacy(jsonValue: response.settings?[PresencePrivacy.settingsKey]),
                           for: userID)
                return true
            } catch let error as WalletAPIError where error.statusCode == 404 {
                guard !Task.isCancelled else { return false }
                self.store(isConsultant: false, designation: nil, privacy: PresencePrivacy(), for: userID)
                return true
            } catch {
                if !Task.isCancelled {
                    MXLog.warning("[Profile] Failed looking up a user: \(error)")
                }
                return false
            }
        }
        lookupTasks[userID] = task
        let result = await task.value
        if lookupTasks[userID] == task {
            lookupTasks[userID] = nil
        }
        return result
    }

    private func store(isConsultant: Bool?, designation: String?, privacy: PresencePrivacy, for userID: String) {
        let changed = (isConsultant != nil && isConsultantCache[userID] != isConsultant) ||
            designationCache[userID] != (designation ?? "") ||
            presencePrivacyCache[userID] != privacy
        if let isConsultant {
            isConsultantCache[userID] = isConsultant
        }
        // No designation in the record is a real value ("none"), so it always overwrites.
        designationCache[userID] = designation ?? ""
        presencePrivacyCache[userID] = privacy
        if changed {
            profileDidChange.send(userID)
        }
    }

    /// Sets one key of `userID`'s `settings` JSON (`value == nil` removes it). The backend REPLACES the
    /// whole object, so this re-reads it first and writes it back with only that key changed.
    private func updateSettings(userID: String, key: String, value: ClarivaJSONValue?) async throws {
        var settings = try await api.getUserProfile(webuddyName: userID).settings ?? [:]
        settings[key] = value
        try await api.updateUserSettings(webuddyName: userID, settings: settings)
    }

    private func setIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<ClarivaProfileService, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }
}

// MARK: - Consultant ↔ consultant rule (Android `ConsultantChatNotAllowedException`)

/// Consultants may only chat with clients: a consultant can't start a chat with another consultant,
/// and an existing consultant ↔ consultant DM is read-only.
enum ConsultantChatRule {
    static let startChatTitle = "Can't start chat"
    static let startChatMessage = "You can't chat with other consultants. Consultants can only chat with clients."
    static let composerTitle = "You can't chat with other consultants."
    static let composerMessage = "Consultants can only chat with clients."

    /// True only when BOTH users are confirmed consultants; an unknown role fails open.
    @MainActor
    static func isConsultantToConsultant(ownUserID: String, otherUserID: String) async -> Bool {
        guard let profiles = ServiceLocator.shared.clarivaProfile else { return false }
        var isCurrentUserConsultant = ServiceLocator.shared.wallet?.isCurrentUserConsultant
        if isCurrentUserConsultant == nil {
            isCurrentUserConsultant = await profiles.isUserConsultant(userID: ownUserID)
        }
        guard isCurrentUserConsultant == true else { return false }
        return await profiles.isUserConsultant(userID: otherUserID) == true
    }
}

// MARK: - Presence heartbeat (Android `PresenceHeartbeat`)

/// Shows this account as "online" to its chat partners while the app is in use, like WhatsApp.
///
/// Simplified sliding sync never marks a user online, so this publishes "online" every 25 s while the
/// app is active or in a call — inside Synapse's 30 s online timeout and above its presence rate limit
/// (one update per 10 s) — and "offline" as soon as the app is backgrounded outside a call. If the process dies, Synapse's
/// timeout takes the account offline. Nothing is published while "Share presence" is off, or while
/// the "Last seen and online" choice lets nobody see it (chat partners' apps also honour that choice;
/// this only stops the homeserver from holding a status nobody may see).
///
/// Owned by the session's home screen: releasing it stops the heartbeat.
@MainActor
final class ClarivaPresenceHeartbeat {
    private enum Mode {
        case online
        case offline
        case hidden
    }

    private static let onlineRefresh: Duration = .seconds(25)

    private let userID: String
    private let presenceService: MatrixPresenceService
    private var cancellables = Set<AnyCancellable>()
    private var publishTask: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    init(userID: String,
         appSettings: AppSettings,
         profileService: ClarivaProfileService,
         ongoingCallRoomIDPublisher: CurrentValuePublisher<String?, Never>? = nil) {
        self.userID = userID
        presenceService = profileService.presenceService

        let isInForeground = Publishers.Merge(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).map { _ in true },
                                              NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification).map { _ in false })
            .prepend(UIApplication.shared.applicationState != .background)
        // Like Android's `isInCall`: a call carried on from the lock screen or another app keeps the account online.
        let isInCall = ongoingCallRoomIDPublisher.map { $0.map { $0 != nil }.eraseToAnyPublisher() } ?? Just(false).eraseToAnyPublisher()
        // Not loaded yet counts as shared (the default), as before this choice existed.
        let isVisibleToAnyone = profileService.$currentUserPresencePrivacy.map { $0?.sharesWithAnyone != false }

        Publishers.CombineLatest4(isInForeground, isInCall, appSettings.$sharePresence, isVisibleToAnyone)
            .map { isInForeground, isInCall, isSharingPresence, isVisibleToAnyone -> Mode in
                if !isSharingPresence || !isVisibleToAnyone {
                    .hidden
                } else if isInForeground || isInCall {
                    .online
                } else {
                    .offline
                }
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.publish(mode)
            }
            .store(in: &cancellables)
    }

    deinit {
        publishTask?.cancel()
    }

    private func publish(_ mode: Mode) {
        publishTask?.cancel()
        let presenceService = presenceService
        let userID = userID

        switch mode {
        case .online:
            publishTask = Task {
                while !Task.isCancelled {
                    await presenceService.setPresence(userID: userID, online: true)
                    try? await Task.sleep(for: Self.onlineRefresh)
                }
            }
        case .offline, .hidden:
            // Turning sharing off also ends any "online" shown right now. The app may be suspending,
            // so ask for a little background time to get the update out.
            endBackgroundTask()
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ClarivaPresenceOffline") { [weak self] in
                self?.endBackgroundTask()
            }
            publishTask = Task { [weak self] in
                await presenceService.setPresence(userID: userID, online: false)
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
