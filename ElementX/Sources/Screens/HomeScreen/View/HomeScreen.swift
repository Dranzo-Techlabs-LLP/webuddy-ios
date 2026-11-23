//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Compound
import SentrySwiftUI
import SwiftUI

struct HomeScreen: View {
    @ObservedObject var context: HomeScreenViewModel.Context
    @ObservedObject private var wallet: WalletService = ServiceLocator.shared.wallet ?? .offline

    @State private var scrollViewAdapter = ScrollViewAdapter()
    @State private var walletSheetShown = false

    var body: some View {
        HomeScreenContent(context: context, scrollViewAdapter: scrollViewAdapter)
            .alert(item: $context.alertInfo)
            .alert(item: $context.leaveRoomAlertItem,
                   actions: leaveRoomAlertActions,
                   message: leaveRoomAlertMessage)
            .navigationTitle(L10n.screenRoomlistMainSpaceTitle)
            .toolbar { toolbar }
            .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
            .track(screen: .Home)
            .toolbarBloom(hasSearchBar: true)
            .sentryTrace("\(Self.self)")
            .task(id: context.viewState.userID) {
                let userID = context.viewState.userID
                // ensureWalletUser now consumes pendingIsConsultant set on the signup screen,
                // so no post-login role popup is needed.
                await wallet.ensureWalletUser(userId: userID)
                await wallet.refreshBalance(userId: userID)
            }
            .sheet(isPresented: $walletSheetShown) {
                NavigationStack {
                    WalletDashboardView(userID: context.viewState.userID)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Close") { walletSheetShown = false }
                            }
                        }
                }
            }
    }


    // MARK: - Private
        
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            settingsButton
        }
        .backportSharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .principal) {
            walletBadge
        }

        ToolbarItem(placement: .primaryAction) {
            if #available(iOS 26, *) {
                newRoomButton
            } else {
                newRoomButton
                    .buttonStyle(.compound(.super, size: .toolbarIcon))
            }
        }
    }

    @ViewBuilder
    private var walletBadge: some View {
        Button {
            walletSheetShown = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wallet.bifold.fill")
                    .font(.compound.bodyMD)
                    .foregroundStyle(.compound.iconPrimary)
                    // Android: the icon is described as "Wallet", the balance is still read out.
                    .accessibilityLabel("Wallet")
                Text(verbatim: wallet.credits.map { "\($0) credits" } ?? "Loading...")
                    .font(.compound.bodyLGSemibold)
                    .foregroundColor(.compound.textPrimary)
            }
        }
    }
    
    private var settingsButton: some View {
        Button {
            context.send(viewAction: .showSettings)
        } label: {
            LoadableAvatarImage(url: context.viewState.userAvatarURL,
                                name: context.viewState.userDisplayName,
                                contentID: context.viewState.userID,
                                avatarSize: .user(on: .chats),
                                mediaProvider: context.mediaProvider)
                .accessibilityIdentifier(A11yIdentifiers.homeScreen.userAvatar)
                .clipShape(.circle)
                .overlayBadge(10, isBadged: context.viewState.requiresExtraAccountSetup)
                .compositingGroup()
        }
        .accessibilityLabel(L10n.commonSettings)
    }
    
    @ViewBuilder
    private var newRoomButton: some View {
        switch context.viewState.roomListMode {
        case .empty, .rooms:
            Button {
                context.send(viewAction: .startChat)
            } label: {
                CompoundIcon(\.plus)
            }
            .accessibilityLabel(L10n.actionStartChat)
            .accessibilityIdentifier(A11yIdentifiers.homeScreen.startChat)
        default:
            EmptyView()
        }
    }
    
    @ViewBuilder
    private func leaveRoomAlertActions(_ item: LeaveRoomAlertItem) -> some View {
        Button(item.cancelTitle, role: .cancel) { }
        Button(item.confirmationTitle, role: .destructive) {
            context.send(viewAction: .confirmLeaveRoom(roomIdentifier: item.roomID))
        }
    }
    
    private func leaveRoomAlertMessage(_ item: LeaveRoomAlertItem) -> some View {
        Text(item.subtitle)
    }
}

// MARK: - Previews

struct HomeScreen_Previews: PreviewProvider, TestablePreview {
    static let loadingViewModel = viewModel(.skeletons)
    static let emptyViewModel = viewModel(.empty)
    static let loadedViewModel = viewModel(.rooms)
    
    static var previews: some View {
        NavigationStack {
            HomeScreen(context: loadingViewModel.context)
        }
        .snapshotPreferences(expect: loadedViewModel.context.$viewState.map { state in
            state.roomListMode == .skeletons
        })
        .previewDisplayName("Loading")
        
        NavigationStack {
            HomeScreen(context: emptyViewModel.context)
        }
        .snapshotPreferences(expect: emptyViewModel.context.$viewState.map { state in
            state.roomListMode == .empty
        })
        .previewDisplayName("Empty")
        
        NavigationStack {
            HomeScreen(context: loadedViewModel.context)
        }
        .snapshotPreferences(expect: loadedViewModel.context.$viewState.map { state in
            state.roomListMode == .rooms
        })
        .previewDisplayName("Loaded")
    }
    
    static func viewModel(_ mode: HomeScreenRoomListMode) -> HomeScreenViewModel {
        let userID = "@alice:example.com"
        
        let roomSummaryProviderState: RoomSummaryProviderMockConfigurationState = switch mode {
        case .skeletons:
            .loading
        case .empty:
            .loaded([])
        case .rooms:
            .loaded(.mockRooms)
        }
        
        let clientProxy = ClientProxyMock(.init(userID: userID,
                                                roomSummaryProvider: RoomSummaryProviderMock(.init(state: roomSummaryProviderState))))
        
        let userSession = UserSessionMock(.init(clientProxy: clientProxy))
        
        return HomeScreenViewModel(userSession: userSession,
                                   selectedRoomPublisher: CurrentValueSubject<String?, Never>(nil).asCurrentValuePublisher(),
                                   appSettings: ServiceLocator.shared.settings,
                                   analyticsService: ServiceLocator.shared.analytics,
                                   notificationManager: NotificationManagerMock(),
                                   userIndicatorController: ServiceLocator.shared.userIndicatorController)
    }
}
