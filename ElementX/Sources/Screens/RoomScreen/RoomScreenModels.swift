//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import OrderedCollections

enum RoomScreenViewModelAction: Equatable {
    case focusEvent(eventID: String)
    case displayThread(threadRootEventID: String, focussedEventID: String)
    case displayPinnedEventsTimeline
    case displayRoomDetails
    case displayCall
    case removeComposerFocus
    case displayKnockRequests
    case displayRoom(roomID: String, via: [String])
    case displayMessageForwarding(MessageForwardingItem)
}

enum RoomScreenViewAction {
    case tappedPinnedEventsBanner
    case viewAllPins
    case displayRoomDetails
    case displayCall
    case footerViewAction(RoomScreenFooterViewAction)
    case acceptKnock(eventID: String)
    case dismissKnockRequests
    case viewKnockRequests
    case displaySuccessorRoom
    /// The DM call chooser's "Voice call" / "Video call" choice (Android `onStartCallWithType`).
    case startCall(isVoice: Bool)
    /// Client taps "Request refund" in the top bar: shows the "Request Refund" confirmation, whose
    /// "Request" button sends the request (Android `MessagesEvents.RequestRefund`).
    case requestRefundTapped
    /// Consultant taps "Approve" on the refund banner: presents the Full/Partial approve sheet.
    case approveRefundTapped
    /// Consultant confirms the approve sheet. `amount == nil` ⇒ full refund (Android `ApproveRefund`).
    case approveRefund(amount: Double?)
    /// Consultant taps "Reject" on the refund banner: shows the "Reject Refund" confirmation, whose
    /// "Reject" button rejects the request (Android `RejectRefund`).
    case rejectRefundTapped
    /// Snackbar consumed; clear it so the next refund event can show one.
    case clearRefundSnackbar
}

struct RoomScreenViewState: BindableState {
    var roomTitle = ""
    var roomAvatar: RoomAvatar
    var dmRecipientVerificationState: UserIdentityVerificationState?
    
    var lastScrollDirection: ScrollDirection?
    // This is used to control the banner
    var pinnedEventsBannerState: PinnedEventsBannerState = .loading(numbersOfEvents: 0)
    var shouldShowPinnedEventsBanner: Bool {
        !pinnedEventsBannerState.isEmpty && lastScrollDirection != .top
    }
    
    var canSendMessage = true
    
    /// Whether or not starting a call is supported.
    var isCallingEnabled = true
    /// Whether or not the user is allowed to join calls in this room.
    var canJoinCall = false
    /// Whether or not this room currently has a call in progress.
    var hasOngoingCall: Bool
    /// Whether or not the user is already part of a call in another room.
    var isParticipatingInOngoingCall = false
    /// Whether the room is a 1:1 DM, which gets the Voice/Video call chooser.
    var isDirectOneToOneRoom = false
    /// The type recorded server-side for the ongoing call (`GET v1/calls/type`); picks the Join icon.
    /// Unknown defaults to voice, like Android.
    var ongoingCallIsVideo = false
    var shouldShowCallButton: Bool {
        isCallingEnabled &&
            !isParticipatingInOngoingCall && // Hide the join call button when already in the call
            !chatGate.isRestricted && // Clariva: a client who can't afford the consultant can't call either
            !isConsultantPeerBlocked // Clariva: nor can two consultants (Android ee053dc156)
    }
    
    /// Clariva chat/call credit gate (see `ChatWalletGate`).
    var chatGate = ChatGateState()
    
    /// Clariva: both sides of this DM are confirmed consultants. Consultants may only chat with
    /// clients, so the composer is replaced by that reason and calls are hidden (Android
    /// `MessageComposerState.isConsultantPeerBlocked`). An unknown role never blocks.
    var isConsultantPeerBlocked = false
    /// Clariva DM header: the partner's designation badge and "online" / "last seen …" label.
    var dmPeerStatus = DMPeerStatus()
    
    var isKnockingEnabled = false
    var isKnockableRoom = false
    var canAcceptKnocks = false
    var canDeclineKnocks = false
    var canBan = false
    var unseenKnockRequests: [KnockRequestInfo] = []
    var handledEventIDs: Set<String> = []
    
    var hasSuccessor: Bool
    
    var displayedKnockRequests: [KnockRequestInfo] {
        unseenKnockRequests.filter { !handledEventIDs.contains($0.eventID) }
    }
    
    var shouldSeeKnockRequests: Bool {
        isKnockingEnabled &&
            isKnockableRoom &&
            !displayedKnockRequests.isEmpty &&
            (canAcceptKnocks || canDeclineKnocks || canBan)
    }
    
    var identityViolationDetails: RoomScreenFooterViewDetails?
    var historyVisibleDetails: RoomScreenFooterViewDetails?

    // MARK: Refund state (mirrors Android `MessagesState` refund fields)
    /// Server-reported refund status: nil / "none" / "requested" / "approved" / "rejected".
    /// Drives banner and button visibility.
    var refundStatus: String?
    /// Pending hold row id needed to invoke approveRefund. nil until poll resolves.
    var refundPendingHoldId: String?
    /// Refund request row id needed to approve/reject. Non-nil only when refundStatus == requested.
    var refundRequestId: String?
    /// The held amount (`PendingHoldStatusResponse.amount`), the upper bound of a partial refund.
    var refundHeldAmount: Double?
    /// Whether the local user is the consultant on this DM hold (server-authoritative —
    /// derived from `consultantId` returned by /pending-holds/status, not local role flag).
    var isConsultantInThisRoom = false
    /// Whether the refund-request action affordance should render for the client.
    /// True iff an active hold exists; goes false once the refund is approved/rejected.
    var isRefundButtonVisible = false
    /// In-flight refund action — disables buttons + skips re-entry.
    var isRefundRequestInProgress = false
    /// One-shot snackbar message rendered above the composer.
    var refundSnackbar: String?
    
    var footerDetails: RoomScreenFooterViewDetails? {
        if let identityViolationDetails {
            return identityViolationDetails
        }
        guard canSendMessage else {
            return nil
        }
        return historyVisibleDetails
    }
    
    var bindings = RoomScreenViewStateBindings()
}

struct RoomScreenViewStateBindings {
    /// The view model used to present a QuickLook media preview.
    var mediaPreviewViewModel: TimelineMediaPreviewViewModel?
    
    /// Refund confirmations and the "Start a new session?" warning.
    var alertInfo: AlertInfo<RoomScreenAlertType>?
    
    /// The consultant's Full/Partial refund sheet.
    var approveRefundSheet: ApproveRefundSheetModel?
}

enum RoomScreenAlertType: Hashable {
    case newSessionWarning
    case requestRefund
    case rejectRefund
}

struct ApproveRefundSheetModel: Identifiable {
    let id = UUID()
    /// The held amount, when known.
    let heldAmount: Double?
}

enum RoomScreenFooterViewAction {
    case resolvePinViolation(userID: String)
    case resolveVerificationViolation(userID: String)
    case dismissHistoryVisibleAlert
}

enum RoomScreenFooterViewDetails {
    case pinViolation(member: RoomMemberProxyProtocol, learnMoreURL: URL)
    case verificationViolation(member: RoomMemberProxyProtocol, learnMoreURL: URL)
    case historyVisible(learnMoreURL: URL)
}

enum PinnedEventsBannerState: Equatable {
    case loading(numbersOfEvents: Int)
    case loaded(state: PinnedEventsState)
    
    var isEmpty: Bool {
        switch self {
        case .loaded(let state):
            return state.pinnedEventContents.isEmpty
        case .loading(let numberOfEvents):
            return numberOfEvents == 0
        }
    }
    
    var isLoading: Bool {
        switch self {
        case .loading:
            return true
        default:
            return false
        }
    }
    
    var selectedPinnedEventID: String? {
        switch self {
        case .loaded(let state):
            return state.selectedPinnedEventID
        default:
            return nil
        }
    }
    
    var count: Int {
        switch self {
        case .loaded(let state):
            return state.pinnedEventContents.count
        case .loading(let numberOfEvents):
            return numberOfEvents
        }
    }
    
    var selectedPinnedIndex: Int {
        switch self {
        case .loaded(let state):
            return state.selectedPinnedIndex
        case .loading(let numbersOfEvents):
            // We always want the index to be the last one when loading, since is the default one.
            return numbersOfEvents - 1
        }
    }
    
    var displayedMessage: AttributedString {
        switch self {
        case .loading:
            return AttributedString(L10n.screenRoomPinnedBannerLoadingDescription)
        case .loaded(let state):
            return state.selectedPinnedContent
        }
    }
    
    var bannerIndicatorDescription: AttributedString {
        let index = selectedPinnedIndex + 1
        let boldPlaceholder = "{bold}"
        var finalString = AttributedString(L10n.screenRoomPinnedBannerIndicatorDescription(boldPlaceholder))
        var boldString = AttributedString(L10n.screenRoomPinnedBannerIndicator(index, count))
        boldString.bold()
        finalString.replace(boldPlaceholder, with: boldString)
        return finalString
    }
    
    mutating func previousPin() {
        switch self {
        case .loaded(var state):
            state.previousPin()
            self = .loaded(state: state)
        default:
            break
        }
    }
    
    mutating func setPinnedEventContents(_ pinnedEventContents: OrderedDictionary<String, AttributedString>) {
        switch self {
        case .loading:
            // The default selected event should always be the last one.
            self = .loaded(state: .init(pinnedEventContents: pinnedEventContents, selectedPinnedEventID: pinnedEventContents.keys.last))
        case .loaded(var state):
            state.pinnedEventContents = pinnedEventContents
            self = .loaded(state: state)
        }
    }
    
    // Note that if we are setting this value, this is definitely sent from the pinned events timeline
    // so we can assume that the pinned events timeline is already loaded and we only need to set the
    // selection for the loaded state
    mutating func setSelectedPinnedEventID(_ eventID: String) {
        switch self {
        case .loaded(var state):
            state.selectedPinnedEventID = eventID
            self = .loaded(state: state)
        case .loading:
            break
        }
    }
}

struct PinnedEventsState: Equatable {
    var pinnedEventContents: OrderedDictionary<String, AttributedString> = [:] {
        didSet {
            if selectedPinnedEventID == nil, !pinnedEventContents.keys.isEmpty {
                // The default selected event should always be the last one.
                selectedPinnedEventID = pinnedEventContents.keys.last
            } else if pinnedEventContents.isEmpty {
                selectedPinnedEventID = nil
            } else if let selectedPinnedEventID, !pinnedEventContents.keys.set.contains(selectedPinnedEventID) {
                self.selectedPinnedEventID = pinnedEventContents.keys.last
            }
        }
    }
    
    var selectedPinnedEventID: String?
    
    var selectedPinnedIndex: Int {
        let defaultValue = pinnedEventContents.isEmpty ? 0 : pinnedEventContents.count - 1
        guard let selectedPinnedEventID else {
            return defaultValue
        }
        return pinnedEventContents.keys.firstIndex(of: selectedPinnedEventID) ?? defaultValue
    }
    
    var selectedPinnedContent: AttributedString {
        var content = AttributedString(" ")
        if let selectedPinnedEventID,
           let pinnedEventContent = pinnedEventContents[selectedPinnedEventID] {
            content = pinnedEventContent
        }
        content.font = .compound.bodyMD
        content.link = nil
        return content
    }
    
    mutating func previousPin() {
        guard !pinnedEventContents.isEmpty else {
            return
        }
        let currentIndex = selectedPinnedIndex
        let nextIndex = currentIndex - 1
        if nextIndex == -1 {
            selectedPinnedEventID = pinnedEventContents.keys.last
        } else {
            selectedPinnedEventID = pinnedEventContents.keys[nextIndex % pinnedEventContents.count]
        }
    }
}
