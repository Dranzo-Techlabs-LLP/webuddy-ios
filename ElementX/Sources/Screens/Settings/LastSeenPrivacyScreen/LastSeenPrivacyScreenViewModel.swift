//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatrixRustSDK
import SwiftUI

typealias LastSeenPrivacyScreenViewModelType = StateStoreViewModelV2<LastSeenPrivacyScreenViewState, LastSeenPrivacyScreenViewAction>

/// Android ee053dc156 `LastSeenPrivacyPresenter`. The choice is stored in the Wallet-API `settings`
/// JSON (see `ClarivaProfileService.updatePresencePrivacy`).
class LastSeenPrivacyScreenViewModel: LastSeenPrivacyScreenViewModelType, LastSeenPrivacyScreenViewModelProtocol {
    typealias ContactsLoader = () async -> [UserProfileProxy]

    private let userID: String
    private let profileService: ClarivaProfileService
    private let userIndicatorController: UserIndicatorControllerProtocol

    /// The saved choice; nil until loaded.
    private var savedPrivacy: PresencePrivacy?
    /// Shown while a change is being saved, then dropped, so a failed save reverts the screen.
    private var pendingPrivacy: PresencePrivacy?

    init(userSession: UserSessionProtocol,
         profileService: ClarivaProfileService,
         userIndicatorController: UserIndicatorControllerProtocol,
         contactsLoader: ContactsLoader? = nil) {
        userID = userSession.clientProxy.userID
        self.profileService = profileService
        self.userIndicatorController = userIndicatorController
        savedPrivacy = profileService.currentUserPresencePrivacy

        super.init(initialViewState: .init(privacy: savedPrivacy ?? PresencePrivacy()),
                   mediaProvider: userSession.mediaProvider)

        profileService.$currentUserPresencePrivacy
            .receive(on: DispatchQueue.main)
            .sink { [weak self] privacy in
                guard let self else { return }
                savedPrivacy = privacy
                updatePrivacy()
            }
            .store(in: &cancellables)

        // Normally loaded at startup; this covers a startup fetch that failed.
        if savedPrivacy == nil {
            let userID = userID
            Task { await profileService.refreshCurrentUser(userID: userID) }
        }

        let clientProxy = userSession.clientProxy
        let loadContacts = contactsLoader ?? { await LastSeenPrivacyScreenViewModel.loadContacts(clientProxy: clientProxy) }
        Task { [weak self] in
            let contacts = await loadContacts()
            guard let self else { return }
            state.contacts = contacts
            // The picker may have opened before the contacts loaded, with nobody ticked: tick the people
            // already excluded, or Done would silently let them see the last seen again.
            if var picker = state.bindings.exceptionsPicker {
                picker.excludedUserIDs.formUnion(excludedUserIDs(of: state.privacy))
                state.bindings.exceptionsPicker = picker
            }
        }
    }

    // MARK: - Public

    override func process(viewAction: LastSeenPrivacyScreenViewAction) {
        let privacy = state.privacy

        switch viewAction {
        case .setLastSeenAudience(let audience):
            if audience == .myContactsExcept {
                state.bindings.exceptionsPicker = LastSeenExceptionsPickerState(excludedUserIDs: excludedUserIDs(of: privacy))
            } else if audience != privacy.lastSeen {
                save(PresencePrivacy(lastSeen: audience, online: privacy.online, lastSeenExcept: []))
            }
        case .setOnlineAudience(let audience):
            if audience != privacy.online {
                save(PresencePrivacy(lastSeen: privacy.lastSeen, online: audience, lastSeenExcept: privacy.lastSeenExcept))
            }
        case .toggleException(let userID):
            guard var picker = state.bindings.exceptionsPicker else { return }
            if picker.excludedUserIDs.contains(userID) {
                picker.excludedUserIDs.remove(userID)
            } else {
                picker.excludedUserIDs.insert(userID)
            }
            state.bindings.exceptionsPicker = picker
        case .saveExceptions:
            guard let picker = state.bindings.exceptionsPicker else { return }
            state.bindings.exceptionsPicker = nil

            // Keep exclusions of people missing from the list (e.g. a chat not loaded yet).
            let listedTokens = Set((state.contacts ?? []).map { token(for: $0.userID) })
            let currentTokens = privacy.lastSeen == .myContactsExcept ? privacy.lastSeenExcept : []
            let newTokens = Set(picker.excludedUserIDs.map { token(for: $0) })
            save(PresencePrivacy(lastSeen: .myContactsExcept,
                                 online: privacy.online,
                                 lastSeenExcept: currentTokens.subtracting(listedTokens).union(newTokens)))
        case .cancelExceptions:
            state.bindings.exceptionsPicker = nil
        }
    }

    // MARK: - Private

    private func updatePrivacy() {
        let privacy = pendingPrivacy ?? savedPrivacy ?? PresencePrivacy()
        if state.privacy != privacy {
            state.privacy = privacy
        }
    }

    private func token(for viewerID: String) -> String {
        PresencePrivacy.exceptToken(ownerID: userID, viewerID: viewerID)
    }

    /// Which of the listed contacts are currently excluded from seeing the last seen.
    private func excludedUserIDs(of privacy: PresencePrivacy) -> Set<String> {
        Set((state.contacts ?? []).map(\.userID).filter { privacy.lastSeenExcept.contains(token(for: $0)) })
    }

    private func save(_ privacy: PresencePrivacy) {
        pendingPrivacy = privacy
        updatePrivacy()

        let indicatorID = "\(Self.self)-Saving"
        userIndicatorController.submitIndicator(UserIndicator(id: indicatorID,
                                                              type: .modal(progress: .indeterminate, interactiveDismissDisabled: true, allowsInteraction: false),
                                                              title: L10n.commonSaving,
                                                              persistent: true),
                                                delay: .milliseconds(200))

        let userID = userID
        let profileService = profileService
        let userIndicatorController = userIndicatorController
        Task { [weak self] in
            let result = await profileService.updatePresencePrivacy(userID: userID, privacy: privacy)
            // Retracted even if the screen was closed mid-save, or the blocking modal would stay up.
            userIndicatorController.retractIndicatorWithId(indicatorID)
            guard let self else { return }
            if pendingPrivacy == privacy {
                pendingPrivacy = nil
            }
            updatePrivacy()
            if case .failure = result {
                state.bindings.alertInfo = AlertInfo(id: .saveFailed,
                                                     title: L10n.commonError,
                                                     message: "Couldn't save your choice. Please try again.")
            }
        }
    }

    /// The user's "contacts": everyone they have a DM with that both of them have joined, by name.
    private static func loadContacts(clientProxy: ClientProxyProtocol) async -> [UserProfileProxy] {
        let provider = clientProxy.staticRoomSummaryProvider
        // Give the room list up to 5 s to load (Android `CONTACTS_TIMEOUT`).
        var attempts = 0
        while !provider.statePublisher.value.isLoaded, attempts < 20, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            attempts += 1
        }

        let ownUserID = clientProxy.userID
        var seenUserIDs = Set<String>()
        var contacts = [UserProfileProxy]()
        for summary in provider.roomListPublisher.value where summary.isDirect && !summary.isSpace && summary.joinRequestType == nil {
            guard let partner = summary.heroes.first(where: { $0.userID != ownUserID }),
                  !seenUserIDs.contains(partner.userID),
                  let roomInfo = try? await summary.room.roomInfo(),
                  roomInfo.membership == .joined,
                  roomInfo.joinedMembersCount == 2 else {
                continue
            }
            seenUserIDs.insert(partner.userID)
            contacts.append(partner)
        }

        return contacts.sorted { ($0.displayName ?? $0.userID).lowercased() < ($1.displayName ?? $1.userID).lowercased() }
    }
}
