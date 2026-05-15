//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct ServerConfirmationScreen: View {
    @Bindable var context: ServerConfirmationScreenViewModel.Context
    @ObservedObject private var wallet: WalletService = ServiceLocator.shared.wallet
    
    private var backgroundColor: Color {
        switch context.viewState.mode {
        case .confirmation: .compound.bgCanvasDefault
        case .picker: .compound.bgSubtleSecondaryLevel0
        }
    }
    
    private var headerIcon: KeyPath<CompoundIcons, Image> {
        switch context.viewState.mode {
        case .confirmation: \.userProfileSolid
        case .picker: \.homeSolid
        }
    }
    
    private var headerIconStyle: BigIcon.Style {
        switch context.viewState.mode {
        case .confirmation: .defaultSolid
        case .picker: .default
        }
    }
    
    var body: some View {
        FullscreenDialog(topPadding: UIConstants.iconTopPaddingToNavigationBar) {
            VStack(spacing: 36) {
                header
                mainContent
            }
        } bottomContent: {
            buttons
        }
        .background()
        .backgroundStyle(backgroundColor)
        .alert(item: $context.alertInfo)
        .introspect(.window, on: .supportedVersions) { window in
            context.send(viewAction: .updateWindow(window))
        }
    }
    
    /// The main content of the view to be shown in a scroll view.
    var header: some View {
        VStack(spacing: 8) {
            BigIcon(icon: headerIcon, style: headerIconStyle)
                .padding(.bottom, 8)
            
            Text(context.viewState.title)
                .font(.compound.headingMDBold)
                .multilineTextAlignment(.center)
                .foregroundColor(.compound.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            
            if let message = context.viewState.message {
                Text(message)
                    .font(.compound.bodyMD)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.compound.textSecondary)
            }
        }
        .padding(.horizontal, 16)
    }
    
    @ViewBuilder
    var mainContent: some View {
        if case .picker(let accountProviders) = context.viewState.mode {
            FakeInlinePicker(items: accountProviders,
                             icon: \.host,
                             selection: $context.pickerSelection)
                .accessibilityIdentifier(A11yIdentifiers.serverConfirmationScreen.serverPicker)
        }
        if context.viewState.authenticationFlow == .register {
            RolePickerSection(isConsultant: wallet.pendingIsConsultant) { isConsultant in
                wallet.setPendingIsConsultant(isConsultant)
            }
        }
    }
    
    /// The action buttons shown at the bottom of the view.
    var buttons: some View {
        VStack(spacing: 16) {
            Button { context.send(viewAction: .confirm) } label: {
                Text(L10n.actionContinue)
            }
            .buttonStyle(.compound(.primary))
            .accessibilityIdentifier(A11yIdentifiers.serverConfirmationScreen.continue)
            
            if case .confirmation = context.viewState.mode {
                Button { context.send(viewAction: .changeServer) } label: {
                    Text(L10n.screenServerConfirmationChangeServer)
                        .font(.compound.bodyLGSemibold)
                        .padding(14)
                }
                .accessibilityIdentifier(A11yIdentifiers.serverConfirmationScreen.changeServer)
            }
        }
    }
}

/// Role picker shown only on the account-creation flow. The selection is stored in
/// `WalletService.pendingIsConsultant` and consumed by `ensureWalletUser` after login
/// completes (mirrors Android `ConfirmAccountProviderPresenter` / `RustMatrixAuthenticationService`).
private struct RolePickerSection: View {
    let isConsultant: Bool
    let onSelect: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("I'll use Clariva as")
                    .font(.compound.bodyLGSemibold)
                    .foregroundColor(.compound.textPrimary)
                Text("Normal users initiate paid chats with consultants. Keep the default if you're not sure.")
                    .font(.compound.bodySM)
                    .foregroundColor(.compound.textSecondary)
            }
            VStack(spacing: 0) {
                RoleOptionRow(label: "Normal User",
                              description: "Initiate paid chats and recharge your wallet.",
                              selected: !isConsultant) { onSelect(false) }
                Divider()
                    .hidden()
                    .overlay(Color.compound._borderInteractiveSecondaryAlpha)
                    .padding(.leading, 16)
                RoleOptionRow(label: "Consultant",
                              description: "Receive paid chats from normal users.",
                              selected: isConsultant) { onSelect(true) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .background(Color.compound.bgCanvasDefaultLevel1, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct RoleOptionRow: View {
    let label: String
    let description: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.compound.iconAccentTertiary : Color.compound.iconSecondary)
                    .font(.system(size: 22))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.compound.bodyLGSemibold)
                        .foregroundColor(.compound.textPrimary)
                    Text(description)
                        .font(.compound.bodySM)
                        .foregroundColor(.compound.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// This is such a hack. I hate it!
// But… We're not in a List/Form, the compound picker doesn't
// support icons and this screen's design might change so 🤷‍♂️.
private struct FakeInlinePicker: View {
    let items: [String]
    let icon: KeyPath<CompoundIcons, Image>
    @Binding var selection: String?
    
    var body: some View {
        VStack(spacing: 0) {
            ForEach(items, id: \.self) { item in
                ListRow(label: .default(title: item, icon: icon),
                        kind: .selection(isSelected: selection == item) {
                            selection = item
                        })
                        .overlay(alignment: .bottom) {
                            if item != items.last {
                                Divider()
                                    .hidden()
                                    .overlay(Color.compound._borderInteractiveSecondaryAlpha)
                                    .padding(.leading, 54)
                            }
                        }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Previews

struct ServerConfirmationScreen_Previews: PreviewProvider, TestablePreview {
    static let loginViewModel = makeViewModel(mode: .confirmation("matrix.org"), flow: .login)
    static let registerViewModel = makeViewModel(mode: .confirmation("matrix.org"), flow: .register)
    static let pickerViewModel = makeViewModel(mode: .picker(["dept1.company.com", "dept2.company.com", "dept3.company.com"]), flow: .login)
    
    static var previews: some View {
        NavigationStack {
            ServerConfirmationScreen(context: loginViewModel.context)
                .toolbar(.visible, for: .navigationBar)
        }
        .previewDisplayName("Login")
        
        NavigationStack {
            ServerConfirmationScreen(context: registerViewModel.context)
                .toolbar(.visible, for: .navigationBar)
        }
        .previewDisplayName("Register")
        
        NavigationStack {
            ServerConfirmationScreen(context: pickerViewModel.context)
                .toolbar(.visible, for: .navigationBar)
        }
        .previewDisplayName("Picker")
    }
    
    static func makeViewModel(mode: ServerConfirmationScreenMode, flow: AuthenticationFlow) -> ServerConfirmationScreenViewModel {
        ServerConfirmationScreenViewModel(authenticationService: AuthenticationService.mock,
                                          mode: mode,
                                          authenticationFlow: flow,
                                          appSettings: ServiceLocator.shared.settings,
                                          userIndicatorController: UserIndicatorControllerMock())
    }
}
