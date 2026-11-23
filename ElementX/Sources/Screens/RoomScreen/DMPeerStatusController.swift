//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import UIKit

/// What the DM header shows under / beside the partner's name.
struct DMPeerStatus: Equatable {
    /// The partner's designation when they are a consultant ("Consultant" by default); nil otherwise.
    var badge: String?
    /// WhatsApp-style "online" / "last seen today at 10:30 AM"; nil when unknown or not shared.
    var presence: String?
    /// The partner's role: true = consultant, nil = unknown.
    var isPeerConsultant: Bool?
}

/// Resolves `DMPeerStatus` for the other person in a DM (Android ee053dc156 `DmPeerStatusPresenter`):
/// their consultant designation from the Wallet-API, and their presence, polled from the homeserver
/// while the chat is on screen and the app is active.
///
/// Presence honours both people's "Last seen and online" choice, the WhatsApp way: the partner's
/// status shows only if they share it with this user, AND this user shares the same kind of status
/// (last seen / online) with them.
@MainActor
final class DMPeerStatusController {
    private static let presencePollInterval: Duration = .seconds(20)
    /// Re-read the partner's privacy choice every 3 polls (about once a minute).
    private static let privacyRefreshEveryPolls = 3

    private let ownUserID: String
    private let profiles: ClarivaProfileService
    private let appSettings: AppSettings

    private let statusSubject = CurrentValueSubject<DMPeerStatus, Never>(.init())
    var statusPublisher: CurrentValuePublisher<DMPeerStatus, Never> {
        statusSubject.asCurrentValuePublisher()
    }

    private var peerID: String?
    /// A "contact" for last-seen privacy: both people have joined the chat.
    private var isPeerJoined = false
    private var presence: UserPresence?
    private var isInForeground: Bool
    private var isStopped = false

    private var refreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(ownUserID: String, profiles: ClarivaProfileService, appSettings: AppSettings) {
        self.ownUserID = ownUserID
        self.profiles = profiles
        self.appSettings = appSettings
        isInForeground = UIApplication.shared.applicationState != .background

        profiles.$currentUserPresencePrivacy
            .removeDuplicates()
            // @Published emits in willSet: recompute on the next run loop, once the value is stored.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)

        profiles.profileDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] userID in
                guard let self, userID == peerID || userID == ownUserID else { return }
                recompute()
            }
            .store(in: &cancellables)

        appSettings.$sharePresence
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartPolling() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self, !isInForeground else { return }
                isInForeground = true
                restartPolling()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                isInForeground = false
                restartPolling()
            }
            .store(in: &cancellables)
    }

    deinit {
        refreshTask?.cancel()
        pollTask?.cancel()
    }

    /// Called whenever the DM partner or their membership changes (nil = not a DM / not loaded yet).
    func update(peerID: String?, isPeerJoined: Bool) {
        guard !isStopped else { return }

        let isNewPeer = peerID != self.peerID
        self.peerID = peerID
        self.isPeerJoined = isPeerJoined

        guard isNewPeer else {
            recompute()
            return
        }

        // Seeded from the cache (the chat list usually looked the partner up already) so the badge is
        // there at first paint, then re-read once per chat open so a designation the consultant just
        // changed shows up.
        presence = nil
        recompute()

        refreshTask?.cancel()
        refreshTask = nil
        if let peerID {
            let profiles = profiles
            refreshTask = Task { [weak self] in
                await profiles.refreshPeerProfile(userID: peerID)
                guard !Task.isCancelled else { return }
                self?.recompute()
            }
        }
        restartPolling()
    }

    func stop() {
        isStopped = true
        cancellables.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Private

    /// Presence is polled only while the chat is shown, the app is active and "Share presence" is on.
    /// The partner's privacy choice is re-read now and then so a change applies without reopening the
    /// chat. A failed poll keeps the last known value rather than blanking the label.
    private func restartPolling() {
        pollTask?.cancel()
        pollTask = nil

        guard !isStopped, let peerID, isInForeground, appSettings.sharePresence else {
            if !appSettings.sharePresence {
                presence = nil
                recompute()
            }
            return
        }

        let ownUserID = ownUserID
        let profiles = profiles
        let presenceService = profiles.presenceService
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                if tick > 0, tick % Self.privacyRefreshEveryPolls == 0 {
                    await profiles.refreshPeerProfile(userID: peerID)
                }
                tick += 1

                if let presence = await presenceService.getPresence(viewerID: ownUserID, userID: peerID) {
                    guard !Task.isCancelled else { return }
                    // Only hold `self` for the update, never across the sleep.
                    do {
                        guard let self, self.peerID == peerID else { return }
                        self.presence = presence
                        self.recompute()
                    }
                }
                try? await Task.sleep(for: Self.presencePollInterval)
            }
        }
    }

    private func recompute() {
        guard let peerID else {
            send(DMPeerStatus())
            return
        }

        let isPeerConsultant = profiles.cachedIsConsultant(userID: peerID)
        let badge = ClarivaDesignation.badge(isConsultant: isPeerConsultant,
                                             designation: profiles.cachedDesignation(userID: peerID))
        let label = presence.flatMap { presence in
            ClarivaPresenceFormatter.visiblePresenceLabel(presence: presence,
                                                          myID: ownUserID,
                                                          peerID: peerID,
                                                          isContact: isPeerJoined,
                                                          myPrivacy: profiles.currentUserPresencePrivacy ?? PresencePrivacy(),
                                                          peerPrivacy: profiles.cachedPresencePrivacy(userID: peerID),
                                                          now: Date())
        }
        send(DMPeerStatus(badge: badge, presence: label, isPeerConsultant: isPeerConsultant))
    }

    private func send(_ status: DMPeerStatus) {
        if status != statusSubject.value {
            statusSubject.send(status)
        }
    }
}
