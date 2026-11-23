//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Compound
import HTMLParser
import SwiftUI
import WysiwygComposer

struct RoomScreenCoordinatorParameters {
    let userSession: UserSessionProtocol
    let roomProxy: JoinedRoomProxyProtocol
    var focussedEvent: FocusEvent?
    var sharedText: String?
    let timelineController: TimelineControllerProtocol
    let mediaPlayerProvider: MediaPlayerProviderProtocol
    let emojiProvider: EmojiProviderProtocol
    let linkMetadataProvider: LinkMetadataProviderProtocol
    let completionSuggestionService: CompletionSuggestionServiceProtocol
    let ongoingCallRoomIDPublisher: CurrentValuePublisher<String?, Never>
    let appMediator: AppMediatorProtocol
    let appSettings: AppSettings
    let appHooks: AppHooks
    let analytics: AnalyticsService
    let composerDraftService: ComposerDraftServiceProtocol
    let timelineControllerFactory: TimelineControllerFactoryProtocol
    let userIndicatorController: UserIndicatorControllerProtocol
}

enum RoomScreenCoordinatorAction {
    case presentReportContent(itemID: TimelineItemIdentifier, senderID: String)
    case presentMediaUploadPicker(mode: MediaPickerScreenMode)
    case presentMediaUploadPreviewScreen(mediaURLs: [URL])
    case presentRoomDetails
    case presentLocationPicker
    case presentPollForm(mode: PollFormMode)
    case presentLocationViewer(body: String, geoURI: GeoURI, description: String?)
    case presentEmojiPicker(itemID: TimelineItemIdentifier, selectedEmojis: Set<String>)
    case presentRoomMemberDetails(userID: String)
    case presentMessageForwarding(forwardingItem: MessageForwardingItem)
    case presentCallScreen
    case presentPinnedEventsTimeline
    case presentResolveSendFailure(failure: TimelineItemSendFailure.VerifiedUser, sendHandle: SendHandleProxy)
    case presentKnockRequestsList
    case presentThread(threadRootEventID: String, focussedEventID: String?)
    case presentRoom(roomID: String, via: [String])
}

final class RoomScreenCoordinator: CoordinatorProtocol {
    private var roomViewModel: RoomScreenViewModelProtocol
    private var timelineViewModel: TimelineViewModelProtocol
    private var composerViewModel: ComposerToolbarViewModelProtocol
    /// Clariva chat/call credit gate for this room (restricted composer, call button, new-session warning).
    private let walletGate: ChatWalletGate
    /// Drops repeated Send taps while an unknown hold state is being resolved.
    private var isResolvingSendDecision = false

    private var cancellables = Set<AnyCancellable>()

    private let actionsSubject: PassthroughSubject<RoomScreenCoordinatorAction, Never> = .init()
    var actions: AnyPublisher<RoomScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: RoomScreenCoordinatorParameters) {
        var selectedPinnedEventID: String?
        if let focussedEvent = parameters.focussedEvent {
            selectedPinnedEventID = focussedEvent.shouldSetPin ? focussedEvent.eventID : nil
        }
        
        let walletGate = ChatWalletGate(roomProxy: parameters.roomProxy, wallet: ServiceLocator.shared.wallet)
        self.walletGate = walletGate
        
        roomViewModel = RoomScreenViewModel(userSession: parameters.userSession,
                                            roomProxy: parameters.roomProxy,
                                            initialSelectedPinnedEventID: selectedPinnedEventID,
                                            ongoingCallRoomIDPublisher: parameters.ongoingCallRoomIDPublisher,
                                            appSettings: parameters.appSettings,
                                            appHooks: parameters.appHooks,
                                            analyticsService: parameters.analytics,
                                            userIndicatorController: parameters.userIndicatorController,
                                            chatGateStatePublisher: walletGate.statePublisher)
        
        timelineViewModel = TimelineViewModel(roomProxy: parameters.roomProxy,
                                              focussedEventID: parameters.focussedEvent?.eventID,
                                              timelineController: parameters.timelineController,
                                              userSession: parameters.userSession,
                                              mediaPlayerProvider: parameters.mediaPlayerProvider,
                                              userIndicatorController: parameters.userIndicatorController,
                                              appMediator: parameters.appMediator,
                                              appSettings: parameters.appSettings,
                                              analyticsService: parameters.analytics,
                                              emojiProvider: parameters.emojiProvider,
                                              linkMetadataProvider: parameters.linkMetadataProvider,
                                              timelineControllerFactory: parameters.timelineControllerFactory)
        
        let wysiwygViewModel = WysiwygComposerViewModel(minHeight: ComposerConstant.minHeight,
                                                        maxCompressedHeight: ComposerConstant.maxHeight,
                                                        maxExpandedHeight: ComposerConstant.maxHeight,
                                                        parserStyle: .elementX)
        let composerViewModel = ComposerToolbarViewModel(initialText: parameters.sharedText,
                                                         roomProxy: parameters.roomProxy,
                                                         wysiwygViewModel: wysiwygViewModel,
                                                         completionSuggestionService: parameters.completionSuggestionService,
                                                         mediaProvider: parameters.userSession.mediaProvider,
                                                         mentionDisplayHelper: ComposerMentionDisplayHelper(timelineContext: timelineViewModel.context),
                                                         appSettings: parameters.appSettings,
                                                         analyticsService: parameters.analytics,
                                                         composerDraftService: parameters.composerDraftService)
        self.composerViewModel = composerViewModel
    }
    
    // MARK: - Public
    
    func start() {
        timelineViewModel.actions
            .sink { [weak self] action in
                guard let self else { return }

                switch action {
                case .displayEmojiPicker(let itemID, let selectedEmojis):
                    actionsSubject.send(.presentEmojiPicker(itemID: itemID, selectedEmojis: selectedEmojis))
                case .displayReportContent(let itemID, let senderID):
                    actionsSubject.send(.presentReportContent(itemID: itemID, senderID: senderID))
                case .displayCameraPicker:
                    actionsSubject.send(.presentMediaUploadPicker(mode: .init(source: .camera, selectionType: .multiple)))
                case .displayMediaPicker:
                    actionsSubject.send(.presentMediaUploadPicker(mode: .init(source: .photoLibrary, selectionType: .multiple)))
                case .displayDocumentPicker:
                    actionsSubject.send(.presentMediaUploadPicker(mode: .init(source: .documents, selectionType: .multiple)))
                case .displayMediaPreview(let mediaPreviewViewModel):
                    roomViewModel.displayMediaPreview(mediaPreviewViewModel)
                case .displayLocationPicker:
                    actionsSubject.send(.presentLocationPicker)
                case .displayPollForm(let mode):
                    actionsSubject.send(.presentPollForm(mode: mode))
                case .displayMediaUploadPreviewScreen(let mediaURLs):
                    actionsSubject.send(.presentMediaUploadPreviewScreen(mediaURLs: mediaURLs))
                case .displaySenderDetails(userID: let userID):
                    actionsSubject.send(.presentRoomMemberDetails(userID: userID))
                case .displayMessageForwarding(let forwardingItem):
                    actionsSubject.send(.presentMessageForwarding(forwardingItem: forwardingItem))
                case .displayLocation(let body, let geoURI, let description):
                    actionsSubject.send(.presentLocationViewer(body: body, geoURI: geoURI, description: description))
                case .displayResolveSendFailure(let failure, let sendHandle):
                    actionsSubject.send(.presentResolveSendFailure(failure: failure, sendHandle: sendHandle))
                case .displayThread(let itemID):
                    guard let eventID = itemID.eventID else {
                        fatalError("A thread root has always an eventID")
                    }
                    actionsSubject.send(.presentThread(threadRootEventID: eventID, focussedEventID: nil))
                case .composer(let action):
                    composerViewModel.process(timelineAction: action)
                case .hasScrolled(direction: let direction):
                    roomViewModel.timelineHasScrolled(direction: direction)
                case .displayRoom(let roomID, let via):
                    actionsSubject.send(.presentRoom(roomID: roomID, via: via))
                case .viewInRoomTimeline, .displayMediaDetails:
                    fatalError("The action: \(action) should not be sent to this coordinator")
                }
            }
            .store(in: &cancellables)

        composerViewModel.actions
            .sink { [weak self] action in
                guard let self else { return }

                if case let .sendMessage(message, _, mode, _) = action, Self.canStartBillableSession(message: message, mode: mode) {
                    handleSendMessage(action)
                } else {
                    timelineViewModel.process(composerAction: action)
                }
            }
            .store(in: &cancellables)
        
        roomViewModel.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .focusEvent(eventID: let eventID):
                    focusOnEvent(FocusEvent(eventID: eventID, shouldSetPin: false))
                case .displayPinnedEventsTimeline:
                    actionsSubject.send(.presentPinnedEventsTimeline)
                case .displayRoomDetails:
                    actionsSubject.send(.presentRoomDetails)
                case .displayCall:
                    actionsSubject.send(.presentCallScreen)
                case .removeComposerFocus:
                    composerViewModel.process(timelineAction: .removeFocus)
                case .displayKnockRequests:
                    actionsSubject.send(.presentKnockRequestsList)
                case .displayRoom(let roomID, let via):
                    actionsSubject.send(.presentRoom(roomID: roomID, via: via))
                case .displayMessageForwarding(let forwardingItem):
                    actionsSubject.send(.presentMessageForwarding(forwardingItem: forwardingItem))
                case .displayThread(let threadRootEventID, let focussedEventID):
                    actionsSubject.send(.presentThread(threadRootEventID: threadRootEventID, focussedEventID: focussedEventID))
                }
            }
            .store(in: &cancellables)
        
        // Loading the draft requires the subscriptions to be set up first otherwise
        // the room won't be be able to propagate the information to the composer.
        composerViewModel.start()
        
        walletGate.start()
    }
    
    func focusOnEvent(_ focussedEvent: FocusEvent) {
        let eventID = focussedEvent.eventID
        if focussedEvent.shouldSetPin {
            roomViewModel.setSelectedPinnedEventID(eventID)
        }
        Task { await timelineViewModel.focusOnEvent(eventID: eventID) }
    }
    
    /// Sets the banner to selection to a specific event ID, even if not visible in the main timeline (like a threaded event).
    func setSelectedPin(eventID: String) {
        roomViewModel.setSelectedPinnedEventID(eventID)
    }
    
    func shareText(_ string: String) {
        composerViewModel.process(timelineAction: .setMode(mode: .default)) // Make sure we're not e.g. replying.
        composerViewModel.process(timelineAction: .setText(plainText: string, htmlText: nil))
        composerViewModel.process(timelineAction: .setFocus)
    }
    
    func stop() {
        composerViewModel.stop()
        roomViewModel.stop()
        walletGate.stop()
    }
    
    // MARK: - Clariva: new session warning (Android 165e2616fd)
    
    /// The `/join` slash command never sends a message nor starts a hold, so it is never warned.
    private static func canStartBillableSession(message: String, mode: ComposerMode) -> Bool {
        if case .default = mode, message.hasPrefix("/join ") {
            return false
        }
        return true
    }
    
    /// Intercepts a text send: when it would start a new billable session (no active hold with this
    /// consultant), the "Start a new session?" warning is shown first. The composer is only cleared
    /// by the timeline once the message is actually sent, so Cancel keeps the text in place.
    /// Voice messages are never warned (they don't go through `.sendMessage`).
    private func handleSendMessage(_ action: ComposerToolbarViewModelAction) {
        switch walletGate.preSendDecision() {
        case .send:
            timelineViewModel.process(composerAction: action)
        case .warn:
            presentNewSessionWarning(for: action)
        case .needsCheck:
            guard !isResolvingSendDecision else { return }
            isResolvingSendDecision = true
            Task { [weak self] in
                guard let self else { return }
                let decision = await walletGate.resolvePreSendDecision()
                isResolvingSendDecision = false
                if decision == .warn {
                    presentNewSessionWarning(for: action)
                } else {
                    timelineViewModel.process(composerAction: action)
                }
            }
        }
    }
    
    private func presentNewSessionWarning(for action: ComposerToolbarViewModelAction) {
        roomViewModel.presentNewSessionWarning { [weak self] neverRemindAgain in
            guard let self else { return }
            if neverRemindAgain {
                walletGate.optOutOfNewSessionWarning()
            }
            timelineViewModel.process(composerAction: action)
        }
    }
    
    func toPresentable() -> AnyView {
        let composerToolbar = ComposerToolbar(context: composerViewModel.context)

        return AnyView(RoomScreen(context: roomViewModel.context,
                                  timelineContext: timelineViewModel.context,
                                  composerToolbar: composerToolbar))
    }
}

enum ComposerConstant {
    static let minHeight: CGFloat = 22
    static let maxHeight: CGFloat = 250
    static let allowedHeightRange = minHeight...maxHeight
    static let translationThreshold: CGFloat = 60
}
