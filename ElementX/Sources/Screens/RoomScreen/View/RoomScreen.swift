//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI
import WysiwygComposer

struct RoomScreen: View {
    @ObservedObject private var context: RoomScreenViewModelType.Context
    @ObservedObject private var timelineContext: TimelineViewModelType.Context
    let composerToolbar: ComposerToolbar
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
    /// Clariva: the DM "Start a call" Voice/Video chooser.
    @State private var isCallTypeChooserPresented = false

    init(context: RoomScreenViewModelType.Context,
         timelineContext: TimelineViewModelType.Context,
         composerToolbar: ComposerToolbar) {
        self.context = context
        self.timelineContext = timelineContext
        self.composerToolbar = composerToolbar
    }

    var body: some View {
        TimelineView(timelineContext: timelineContext)
            .overlay(alignment: .bottomTrailing) {
                TimelineScrollToBottomButton(isVisible: isAtBottomAndLive) {
                    timelineContext.send(viewAction: .scrollToBottom)
                }
                .accessibilityIdentifier(A11yIdentifiers.roomScreen.scrollToBottom)
            }
            .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
            .topBanner(pinnedItemsBanner, isVisible: context.viewState.shouldShowPinnedEventsBanner && !isVoiceOverEnabled)
            // This can overlay on top of the pinnedItemsBanner
            .topBanner(knockRequestsBanner, isVisible: context.viewState.shouldSeeKnockRequests)
            .topBanner(refundBanner, isVisible: shouldShowRefundBanner)
            .safeAreaInset(edge: .top) {
                // When VoiceOver is enabled, the table view isn't reversed and the scroll gestures
                // don't trigger meaning the banner never hides itself and so the .overlay layout
                // above permanently obscures the top of the timeline. So whenever VoiceOver is
                // enabled we use a safe area inset to vertically stack it above the timeline.
                if context.viewState.shouldShowPinnedEventsBanner, isVoiceOverEnabled {
                    pinnedItemsBanner
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    RoomScreenFooterView(details: context.viewState.footerDetails,
                                         mediaProvider: context.mediaProvider) { action in
                        context.send(viewAction: .footerViewAction(action))
                    }
                    
                    composer
                        .padding(.top, 8)
                        .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
                        .environmentObject(timelineContext)
                        .environment(\.timelineContext, timelineContext)
                        // Make sure the reply header honours the hideTimelineMedia setting too.
                        .environment(\.shouldAutomaticallyLoadImages, !timelineContext.viewState.hideTimelineMedia)
                }
            }
            .toolbarRole(RoomHeaderView.toolbarRole)
            .navigationTitle(L10n.screenRoomTitle) // Hidden but used for back button text.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toolbarBackground(.visible, for: .navigationBar) // Fix the toolbar's background.
            .overlay { loadingIndicator }
            .timelineMediaPreview(viewModel: $context.mediaPreviewViewModel)
            .track(screen: .Room)
            .sentryTrace("\(Self.self)")
            .overlay(alignment: .top) { refundSnackbar }
            .alert(item: $context.alertInfo)
            .sheet(item: $context.approveRefundSheet) { sheet in
                ApproveRefundSheet(heldAmount: sheet.heldAmount,
                                   isInProgress: context.viewState.isRefundRequestInProgress,
                                   onApprove: { amount in context.send(viewAction: .approveRefund(amount: amount)) },
                                   onCancel: { context.approveRefundSheet = nil })
            }
    }

    /// Chat-local refund snackbar (request-sent / approved / rejected / error). Bypasses the
    /// global UserIndicatorController so the toast stays bound to this room — mirrors
    /// Android's chat-local SharedFlow approach so it doesn't leak onto the chat list
    /// scaffold when the user navigates back quickly.
    @ViewBuilder
    private var refundSnackbar: some View {
        if let message = context.viewState.refundSnackbar {
            Text(message)
                .font(.compound.bodyMDSemibold)
                .foregroundColor(.compound.textOnSolidPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.compound.bgActionPrimaryRest, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: message) {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    context.send(viewAction: .clearRefundSnackbar)
                }
        }
    }
    
    @ViewBuilder
    private var pinnedItemsBanner: some View {
        PinnedItemsBannerView(state: context.viewState.pinnedEventsBannerState,
                              onMainButtonTap: { context.send(viewAction: .tappedPinnedEventsBanner) },
                              onViewAllButtonTap: { context.send(viewAction: .viewAllPins) })
    }

    /// True iff a refund request is awaiting decision AND the local user is the consultant
    /// in this DM (server-authoritative). Banner offers Approve / Reject buttons.
    private var shouldShowRefundBanner: Bool {
        context.viewState.isConsultantInThisRoom &&
            context.viewState.refundStatus == "requested" &&
            context.viewState.refundRequestId != nil
    }

    @ViewBuilder
    private var refundBanner: some View {
        RefundRequestBanner(isInProgress: context.viewState.isRefundRequestInProgress,
                            onApprove: { context.send(viewAction: .approveRefundTapped) },
                            onReject: { context.send(viewAction: .rejectRefundTapped) })
    }
    
    @ViewBuilder
    private var knockRequestsBanner: some View {
        KnockRequestsBannerView(requests: context.viewState.displayedKnockRequests,
                                onDismiss: dismissKnockRequestsBanner,
                                onAccept: context.viewState.canAcceptKnocks ? acceptKnockRequest : nil,
                                onViewAll: onViewAllKnockRequests,
                                mediaProvider: context.mediaProvider)
            .padding(.top, 16)
    }
    
    private func dismissKnockRequestsBanner() {
        context.send(viewAction: .dismissKnockRequests)
    }
    
    private func acceptKnockRequest(eventID: String) {
        context.send(viewAction: .acceptKnock(eventID: eventID))
    }
    
    private func onViewAllKnockRequests() {
        context.send(viewAction: .viewKnockRequests)
    }
    
    private var isAtBottomAndLive: Bool {
        timelineContext.isScrolledToBottom && timelineContext.viewState.timelineState.isLive
    }
    
    @ViewBuilder
    private var composer: some View {
        if context.viewState.hasSuccessor {
            tombstonedDialogue
        } else if context.viewState.canSendMessage, context.viewState.isConsultantPeerBlocked {
            // Clariva (Android ee053dc156): consultants may only chat with clients, so an existing
            // consultant ↔ consultant DM is read-only.
            ChatRestrictedComposerView(isConsultantPeerBlocked: true)
        } else if context.viewState.canSendMessage, context.viewState.chatGate.isRestricted {
            // Clariva: replaces the whole composer (attachments and voice recording included). The
            // composer view model lives on in the coordinator, so the draft survives.
            ChatRestrictedComposerView(credits: context.viewState.chatGate.credits,
                                       requiredCredits: context.viewState.chatGate.recipientRate)
        } else if context.viewState.canSendMessage, !ProcessInfo.isRunningAccessibilityTests {
            // We are not sure why but when wrapped in the room screen the composer toolbar breaks the accessibility tests
            composerToolbar
        } else {
            ComposerDisabledView()
        }
    }
    
    private var tombstonedDialogue: some View {
        VStack(spacing: 16) {
            Text(L10n.screenRoomTimelineTombstonedRoomMessage)
                .font(.compound.bodyMD)
                .foregroundStyle(.compound.textPrimary)
            
            Button {
                context.send(viewAction: .displaySuccessorRoom)
            } label: {
                Text(L10n.screenRoomTimelineTombstonedRoomAction)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.compound(.primary, size: .medium))
        }
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .highlight(gradient: .compound.info,
                   borderColor: .compound.borderInfoSubtle,
                   backgroundColor: .compound.bgCanvasDefault)
    }
    
    @ViewBuilder
    private var loadingIndicator: some View {
        if timelineContext.viewState.showLoading {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.compound.textPrimary)
                .padding(16)
                .background(.ultraThickMaterial)
                .cornerRadius(8)
        }
    }
    
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // .principal + .primaryAction works better than .navigation leading + trailing
        // as the latter disables interaction in the action button for rooms with long names
        ToolbarItem(placement: .principal) {
            // Clariva: `RoomHeaderView` plus the DM partner's designation badge and presence.
            RoomScreenHeaderView(roomName: context.viewState.roomTitle,
                                 roomAvatar: context.viewState.roomAvatar,
                                 dmRecipientVerificationState: context.viewState.dmRecipientVerificationState,
                                 peerBadge: context.viewState.dmPeerStatus.badge,
                                 peerPresence: context.viewState.dmPeerStatus.presence,
                                 mediaProvider: context.mediaProvider)
                // Using a button stops it from getting truncated in the navigation bar
                .contentShape(.rect)
                .onTapGesture {
                    context.send(viewAction: .displayRoomDetails)
                }
        }
        
        // Client-side "Request refund" toolbar button, left of the call button. Mirrors Android
        // `MessagesViewTopBar` — shown only when an active hold exists, the local user is the
        // client side of that hold, and no refund has been requested or decided yet.
        if shouldShowRequestRefundButton {
            ToolbarItem(placement: .primaryAction) {
                requestRefundButton
            }
        }
        
        if !ProcessInfo.processInfo.isiOSAppOnMac {
            ToolbarItem(placement: .primaryAction) {
                // Also hidden (not disabled) when the chat gate restricts this client (Android f444b282d6).
                if context.viewState.shouldShowCallButton {
                    callButton
                        .disabled(!context.viewState.canJoinCall)
                }
            }
        }
    }

    /// Client-side: active hold + refunds active + not yet requested/decided + I am NOT the consultant.
    private var shouldShowRequestRefundButton: Bool {
        context.viewState.isRefundButtonVisible &&
            !context.viewState.isConsultantInThisRoom &&
            (context.viewState.refundStatus == nil || context.viewState.refundStatus == "none")
    }

    /// Compact "Refund" pill (Android ee053dc156): a full "Request refund" label left the DM title
    /// (name, designation badge, presence) too little room.
    private var requestRefundButton: some View {
        Button {
            context.send(viewAction: .requestRefundTapped)
        } label: {
            refundButtonLabel
        }
        .disabled(context.viewState.isRefundRequestInProgress)
        .accessibilityLabel("Request refund")
    }
    
    @ViewBuilder
    private var refundButtonLabel: some View {
        let label = Label("Refund", icon: \.restart, iconSize: .xSmall, relativeTo: .compound.bodySM)
            .labelStyle(.titleAndIcon)
            .font(.compound.bodySMSemibold)
            .lineLimit(1)
            .foregroundStyle(context.viewState.isRefundRequestInProgress ? Color.compound.textDisabled : Color.compound.textPrimary)
        if #available(iOS 26, *) {
            // Toolbar items already get a capsule background.
            label
        } else {
            label
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay {
                    Capsule()
                        .stroke(Color.compound.borderInteractiveSecondary, lineWidth: 1)
                }
        }
    }
    
    private var joinCallIcon: KeyPath<CompoundIcons, Image> {
        if context.viewState.ongoingCallIsVideo {
            \.videoCallSolid
        } else {
            \.voiceCallSolid
        }
    }
    
    @ViewBuilder
    private var callButton: some View {
        if context.viewState.hasOngoingCall {
            // Join: no chooser; the icon follows the type recorded by the caller (unknown → voice).
            Button {
                context.send(viewAction: .displayCall)
            } label: {
                Label(L10n.actionJoin, icon: joinCallIcon)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(ElementCallButtonStyle())
            .accessibilityLabel(L10n.a11yJoinCall)
            .accessibilityIdentifier(A11yIdentifiers.roomScreen.joinCall)
        } else if context.viewState.isDirectOneToOneRoom {
            // Clariva: DMs choose between a voice and a video call.
            Button {
                isCallTypeChooserPresented = true
            } label: {
                CompoundIcon(\.voiceCall)
            }
            .accessibilityLabel(L10n.a11yStartCall)
            .accessibilityIdentifier(A11yIdentifiers.roomScreen.joinCall)
            // Attached to the button (not the screen) so iOS anchors the popover to it.
            .confirmationDialog("Start a call", isPresented: $isCallTypeChooserPresented, titleVisibility: .visible) {
                Button("Voice call") {
                    context.send(viewAction: .startCall(isVoice: true))
                }
                Button("Video call") {
                    context.send(viewAction: .startCall(isVoice: false))
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Choose how you want to call.")
            }
        } else {
            Button {
                context.send(viewAction: .displayCall)
            } label: {
                CompoundIcon(\.videoCallSolid)
            }
            .accessibilityLabel(L10n.a11yStartCall)
            .accessibilityIdentifier(A11yIdentifiers.roomScreen.joinCall)
        }
    }
}

// MARK: - Previews

struct RoomScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModels = makeViewModels()
    static let readOnlyViewModels = makeViewModels(canSendMessage: false)
    static let tombstonedViewModels = makeViewModels(hasSuccessor: true)

    static var previews: some View {
        NavigationStack {
            RoomScreen(context: viewModels.room.context,
                       timelineContext: viewModels.timeline.context,
                       composerToolbar: ComposerToolbar.mock())
        }
        .previewDisplayName("Normal")
        
        NavigationStack {
            RoomScreen(context: readOnlyViewModels.room.context,
                       timelineContext: readOnlyViewModels.timeline.context,
                       composerToolbar: ComposerToolbar.mock())
        }
        .previewDisplayName("Read-only")
        .snapshotPreferences(expect: readOnlyViewModels.room.context.$viewState.map { !$0.canSendMessage })
        
        NavigationStack {
            RoomScreen(context: tombstonedViewModels.room.context,
                       timelineContext: tombstonedViewModels.timeline.context,
                       composerToolbar: ComposerToolbar.mock())
        }
        .previewDisplayName("Tombstoned")
        .snapshotPreferences(expect: tombstonedViewModels.room.context.$viewState.map(\.hasSuccessor))
    }
    
    static func makeViewModels(canSendMessage: Bool = true, hasSuccessor: Bool = false) -> ViewModels {
        let roomProxyMock = JoinedRoomProxyMock(.init(id: "stable_id",
                                                      name: "Preview room",
                                                      hasOngoingCall: true,
                                                      successor: hasSuccessor ? .init(roomId: UUID().uuidString, reason: nil) : nil,
                                                      powerLevelsConfiguration: .init(canUserSendMessage: canSendMessage)))
        let roomViewModel = RoomScreenViewModel.mock(roomProxyMock: roomProxyMock)
        let timelineViewModel = TimelineViewModel(roomProxy: roomProxyMock,
                                                  timelineController: MockTimelineController(),
                                                  userSession: UserSessionMock(.init()),
                                                  mediaPlayerProvider: MediaPlayerProviderMock(),
                                                  userIndicatorController: ServiceLocator.shared.userIndicatorController,
                                                  appMediator: AppMediatorMock.default,
                                                  appSettings: ServiceLocator.shared.settings,
                                                  analyticsService: ServiceLocator.shared.analytics,
                                                  emojiProvider: EmojiProvider(appSettings: ServiceLocator.shared.settings),
                                                  linkMetadataProvider: LinkMetadataProvider(),
                                                  timelineControllerFactory: TimelineControllerFactoryMock(.init()))
        
        return .init(room: roomViewModel, timeline: timelineViewModel)
    }
    
    struct ViewModels {
        let room: RoomScreenViewModelProtocol
        let timeline: TimelineViewModelProtocol
    }
}
