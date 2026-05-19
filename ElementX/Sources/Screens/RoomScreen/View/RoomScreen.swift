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

/// Consultant-facing banner shown at the top of a DM when the client has requested a refund
/// of the active wallet hold. Offers Approve / Reject actions. Mirrors Android
/// `MessagesViewTopBar`'s refund affordance — rendered as an inline top banner since iOS has
/// no equivalent top-bar action slot for the two-button confirmation pair.
private struct RefundRequestBanner: View {
    let isApproveDisabled: Bool
    let isRejectDisabled: Bool
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CompoundIcon(\.infoSolid, size: .medium, relativeTo: .compound.bodyMD)
                .foregroundStyle(Color.compound.iconCriticalPrimary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Refund requested")
                    .font(.compound.bodyMDSemibold)
                    .foregroundColor(.compound.textPrimary)
                Text("The client is asking for the held credits back. Approve to return them now, or reject to keep the hold in place.")
                    .font(.compound.bodySM)
                    .foregroundColor(.compound.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(action: onReject) { Text("Reject") }
                        .buttonStyle(.compound(.secondary, size: .medium))
                        .disabled(isRejectDisabled)
                    Button(action: onApprove) { Text("Approve") }
                        .buttonStyle(.compound(.primary, size: .medium))
                        .disabled(isApproveDisabled)
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(Color.compound.bgCriticalSubtle, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct RoomScreen: View {
    @ObservedObject private var context: RoomScreenViewModelType.Context
    @ObservedObject private var timelineContext: TimelineViewModelType.Context
    let composerToolbar: ComposerToolbar
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled

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
        RefundRequestBanner(isApproveDisabled: context.viewState.isRefundRequestInProgress,
                            isRejectDisabled: context.viewState.isRefundRequestInProgress,
                            onApprove: { context.send(viewAction: .approveRefund) },
                            onReject: { context.send(viewAction: .rejectRefund) })
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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
            RoomHeaderView(roomName: context.viewState.roomTitle,
                           roomAvatar: context.viewState.roomAvatar,
                           dmRecipientVerificationState: context.viewState.dmRecipientVerificationState,
                           mediaProvider: context.mediaProvider)
                // Using a button stops it from getting truncated in the navigation bar
                .contentShape(.rect)
                .onTapGesture {
                    context.send(viewAction: .displayRoomDetails)
                }
        }
        
        if !ProcessInfo.processInfo.isiOSAppOnMac {
            ToolbarItem(placement: .primaryAction) {
                if context.viewState.shouldShowCallButton {
                    callButton
                        .disabled(!context.viewState.canJoinCall)
                }
            }
        }

        // Client-side "Request refund" toolbar button. Mirrors Android `MessagesViewTopBar`
        // refund action — shown only when an active hold exists, the local user is the
        // client side of that hold, and no refund decision has been recorded yet.
        if shouldShowRequestRefundButton {
            ToolbarItem(placement: .primaryAction) {
                requestRefundButton
            }
        }
    }

    /// Client-side: active hold + not yet decided + I am NOT the consultant on this hold.
    private var shouldShowRequestRefundButton: Bool {
        context.viewState.isRefundButtonVisible &&
            context.viewState.refundStatus != "requested" &&
            context.viewState.refundStatus != "approved" &&
            context.viewState.refundStatus != "rejected" &&
            !context.viewState.isConsultantInThisRoom
    }

    private var requestRefundButton: some View {
        Button {
            context.send(viewAction: .requestRefund)
        } label: {
            CompoundIcon(\.restart)
        }
        .disabled(context.viewState.isRefundRequestInProgress)
        .accessibilityLabel("Request refund")
    }
    
    @ViewBuilder
    private var callButton: some View {
        if context.viewState.hasOngoingCall {
            Button {
                context.send(viewAction: .displayCall)
            } label: {
                Label(L10n.actionJoin, icon: \.videoCallSolid)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(ElementCallButtonStyle())
            .accessibilityLabel(L10n.a11yJoinCall)
            .accessibilityIdentifier(A11yIdentifiers.roomScreen.joinCall)
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
