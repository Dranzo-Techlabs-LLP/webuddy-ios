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
         userIndicatorController: UserIndicatorControllerProtocol) {
        clientProxy = userSession.clientProxy
        self.roomProxy = roomProxy
        self.appSettings = appSettings
        self.analyticsService = analyticsService
        self.userIndicatorController = userIndicatorController
        
        self.initialSelectedPinnedEventID = initialSelectedPinnedEventID
        pinnedEventStringBuilder = .pinnedEventStringBuilder(userID: roomProxy.ownUserID)

        let viewState = RoomScreenViewState(roomTitle: roomProxy.infoPublisher.value.displayName ?? roomProxy.id,
                                            roomAvatar: roomProxy.infoPublisher.value.avatar,
                                            hasOngoingCall: roomProxy.infoPublisher.value.hasRoomCall,
                                            hasSuccessor: roomProxy.infoPublisher.value.successor != nil)
        super.init(initialViewState: appHooks.roomScreenHook.update(viewState),
                   mediaProvider: userSession.mediaProvider)
        
        updateRoomInfo(roomProxy.infoPublisher.value)
        setupSubscriptions(ongoingCallRoomIDPublisher: ongoingCallRoomIDPublisher)

        Task {
            await updateVerificationBadge()
        }

        // Refund / pending-hold status loop: poll the server every 15s while the room is open,
        // mirror Android MessagesPresenter LaunchedEffect. Drives banner visibility, button
        // gating, and the auto-approval push-notification claim flow. Cancelled in deinit.
        refundPollTask = Task { [weak self] in
            await self?.runRefundPollLoop()
        }
    }

    deinit {
        refundPollTask?.cancel()
    }

    private var refundPollTask: Task<Void, Never>?
    /// Local dedupe of refund-request ids we've already reacted to during this session.
    /// Mirrors Android `notifiedRefundRequestIds` — keeps us from pounding the
    /// auto-approval claim endpoint on every 15s tick.
    private var notifiedRefundRequestIds: Set<String> = []

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
            actionsSubject.send(.displayCall)
            actionsSubject.send(.removeComposerFocus)
            analyticsService.trackInteraction(name: .MobileRoomCallButton)
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
        case .requestRefund:
            handleRequestRefund()
        case .approveRefund:
            handleApproveRefund()
        case .rejectRefund:
            handleRejectRefund()
        case .clearRefundSnackbar:
            state.refundSnackbar = nil
        }
    }

    // MARK: - Refund

    /// Hardcoded mirror of Android `screen_messages_refund_*` resources (which are
    /// `translatable="false"`). Body text shown both in the chat history audit row AND on
    /// the lockscreen push preview, so emoji-prefixed for scannability.
    private static let refundRequestNotificationBody = "🔔 Refund requested for the held credits"
    private static let refundApprovedNotificationBody = "✅ Your refund was approved — credits returned to your wallet"
    private static let refundRejectedNotificationBody = "❌ Your refund was rejected by the consultant"
    private static let refundAutoApprovedNotificationBody = "⚙️ Refund auto-approved after 24h with no response — credits returned to the client"

    /// 15s poll mirroring Android MessagesPresenter LaunchedEffect.
    private func runRefundPollLoop() async {
        while !Task.isCancelled {
            await pollPendingHoldStatusOnce()
            try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
        }
    }

    private func partnerUserID() -> String? {
        guard roomProxy.isDirectOneToOneRoom else { return nil }
        let myID = roomProxy.ownUserID
        return roomProxy.membersPublisher.value.first { $0.userID != myID }?.userID
    }

    private func pollPendingHoldStatusOnce() async {
        guard roomProxy.isDirectOneToOneRoom, let partnerId = partnerUserID() else {
            await MainActor.run {
                state.isRefundButtonVisible = false
                state.refundStatus = nil
                state.refundPendingHoldId = nil
                state.refundRequestId = nil
            }
            return
        }
        let myUserId = roomProxy.ownUserID
        let wallet: WalletService = ServiceLocator.shared.wallet
        guard let status = await wallet.getPendingHoldStatus(clientId: myUserId, consultantId: partnerId) else {
            return
        }
        // Server bidirectional lookup: my role is determined by whether the hold's consultantId == me.
        let amConsultant = status.consultantId != nil && status.consultantId == myUserId
        await MainActor.run {
            state.isConsultantInThisRoom = amConsultant
            if status.exists && (status.isRefundActive ?? 1) == 1 {
                state.refundStatus = status.refundStatus
                state.refundPendingHoldId = status.holdIdString
                state.refundRequestId = status.refundRequestIdString
                state.isRefundButtonVisible = true
                if amConsultant, status.refundStatus == "requested", let reqId = status.refundRequestIdString {
                    notifiedRefundRequestIds.insert(reqId)
                }
            } else {
                state.isRefundButtonVisible = false
                state.refundStatus = nil
                state.refundPendingHoldId = nil
                state.refundRequestId = nil
            }
        }
        // Auto-approval push-notification pickup. First app to observe the
        // pendingAutoApprovalNotification + win the atomic claim posts the in-room
        // m.room.message; the other party (likely app-closed) gets the push via the
        // standard homeserver → Sygnal → APNs pipeline. Best-effort: claim or send
        // failure does NOT roll back the refund — credits are already returned.
        if let pending = status.pendingAutoApprovalNotification {
            let idString = String(pending.refundRequestId)
            if !notifiedRefundRequestIds.contains(idString) {
                notifiedRefundRequestIds.insert(idString)
                let claimed = await wallet.claimAutoApprovalNotification(refundRequestId: pending.refundRequestId,
                                                                          callerUserId: myUserId)
                if claimed {
                    _ = await roomProxy.timeline.sendMessage(Self.refundAutoApprovedNotificationBody,
                                                             html: nil,
                                                             inReplyToEventID: nil,
                                                             intentionalMentions: .empty)
                    MXLog.info("[Refund] Posted auto-approval Matrix message for refund \(idString)")
                } else {
                    MXLog.info("[Refund] Auto-approval claim lost for refund \(idString) (other side announced)")
                }
            }
        }
    }

    private func handleRequestRefund() {
        if state.isRefundRequestInProgress { return }
        guard let holdId = state.refundPendingHoldId, let partnerId = partnerUserID() else {
            MXLog.warning("[Refund] Cannot request refund: holdId=\(state.refundPendingHoldId ?? "nil"), partner=\(partnerUserID() ?? "nil")")
            return
        }
        state.isRefundRequestInProgress = true
        let myId = roomProxy.ownUserID
        Task { [weak self] in
            guard let self else { return }
            let wallet: WalletService = ServiceLocator.shared.wallet
            let result = await wallet.requestRefund(clientId: myId, consultantId: partnerId, pendingHoldId: holdId)
            switch result {
            case .success:
                await MainActor.run {
                    self.state.refundStatus = "requested"
                    self.state.refundSnackbar = "Refund request sent"
                }
                _ = await self.roomProxy.timeline.sendMessage(Self.refundRequestNotificationBody,
                                                              html: nil,
                                                              inReplyToEventID: nil,
                                                              intentionalMentions: .empty)
            case .failure(let error):
                MXLog.error("[Refund] requestRefund failed: \(error)")
                await MainActor.run { self.state.refundSnackbar = L10n.commonError }
            }
            await MainActor.run { self.state.isRefundRequestInProgress = false }
        }
    }

    private func handleApproveRefund() {
        if state.isRefundRequestInProgress { return }
        guard let reqId = state.refundRequestId, let holdId = state.refundPendingHoldId else {
            MXLog.warning("[Refund] Cannot approve: reqId=\(state.refundRequestId ?? "nil") holdId=\(state.refundPendingHoldId ?? "nil")")
            return
        }
        state.isRefundRequestInProgress = true
        let myId = roomProxy.ownUserID
        Task { [weak self] in
            guard let self else { return }
            let wallet: WalletService = ServiceLocator.shared.wallet
            let result = await wallet.approveRefund(refundRequestId: reqId, pendingHoldId: holdId)
            switch result {
            case .success:
                await MainActor.run {
                    self.state.refundStatus = "approved"
                    self.state.isRefundButtonVisible = false
                    self.state.refundSnackbar = "Refund approved"
                }
                // Drop the chat-list pending-refund badge for this client. Mirrors Android.
                await wallet.refreshPendingRefundRequests(consultantUserId: myId)
                _ = await self.roomProxy.timeline.sendMessage(Self.refundApprovedNotificationBody,
                                                              html: nil,
                                                              inReplyToEventID: nil,
                                                              intentionalMentions: .empty)
            case .failure(let error):
                MXLog.error("[Refund] approveRefund failed: \(error)")
                await MainActor.run { self.state.refundSnackbar = L10n.commonError }
            }
            await MainActor.run { self.state.isRefundRequestInProgress = false }
        }
    }

    private func handleRejectRefund() {
        if state.isRefundRequestInProgress { return }
        guard let reqId = state.refundRequestId else {
            MXLog.warning("[Refund] Cannot reject: reqId is nil")
            return
        }
        state.isRefundRequestInProgress = true
        let myId = roomProxy.ownUserID
        Task { [weak self] in
            guard let self else { return }
            let wallet: WalletService = ServiceLocator.shared.wallet
            let result = await wallet.rejectRefund(refundRequestId: reqId)
            switch result {
            case .success:
                await MainActor.run {
                    self.state.refundStatus = "rejected"
                    self.state.refundSnackbar = "Refund rejected"
                }
                await wallet.refreshPendingRefundRequests(consultantUserId: myId)
                _ = await self.roomProxy.timeline.sendMessage(Self.refundRejectedNotificationBody,
                                                              html: nil,
                                                              inReplyToEventID: nil,
                                                              intentionalMentions: .empty)
            case .failure(let error):
                MXLog.error("[Refund] rejectRefund failed: \(error)")
                await MainActor.run { self.state.refundSnackbar = L10n.commonError }
            }
            await MainActor.run { self.state.isRefundRequestInProgress = false }
        }
    }
    
    func stop() {
        // When navigating away from the room, we need to mark the room as fully read.
        // This does not affect the read receipts only the notification count.
        Task { await roomProxy.markAsRead(receiptType: .fullyRead) }
        // Work around QLPreviewController dismissal issues, see the InteractiveQuickLookModifier.
        state.bindings.mediaPreviewViewModel = nil
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
                     appHooks: AppHooks = AppHooks()) -> RoomScreenViewModel {
        RoomScreenViewModel(userSession: UserSessionMock(.init(clientProxy: clientProxyMock)),
                            roomProxy: roomProxyMock,
                            initialSelectedPinnedEventID: nil,
                            ongoingCallRoomIDPublisher: .init(.init(nil)),
                            appSettings: ServiceLocator.shared.settings,
                            appHooks: appHooks,
                            analyticsService: ServiceLocator.shared.analytics,
                            userIndicatorController: ServiceLocator.shared.userIndicatorController)
    }
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
