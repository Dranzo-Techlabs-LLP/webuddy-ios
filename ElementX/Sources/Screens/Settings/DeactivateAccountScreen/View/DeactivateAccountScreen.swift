//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AuthenticationServices
import Compound
import SwiftUI

struct DeactivateAccountScreen: View {
    @Bindable var context: DeactivateAccountScreenViewModel.Context
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        Form {
            infoSection
            eraseDataSection
            
            // Clariva: Google accounts have no password, they re-authorise with Google instead.
            if context.viewState.isGoogleAccount == true {
                googleSection
            } else {
                passwordSection
            }
        }
        .compoundList()
        .safeAreaInset(edge: .bottom) {
            Button(L10n.actionDeactivateAccount, role: .destructive) {
                context.send(viewAction: .deactivate)
            }
            .buttonStyle(.compound(.primary))
            .disabled(!context.viewState.canSubmit)
            .padding(16)
            .background(Color.compound.bgSubtleSecondaryLevel0.ignoresSafeArea())
        }
        .navigationTitle(L10n.screenDeactivateAccountTitle)
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $context.alertInfo)
        .introspect(.window, on: .supportedVersions) { window in
            context.send(viewAction: .updateWindow(window))
        }
    }
    
    private var infoSection: some View {
        ListRow(kind: .custom {
            VStack(alignment: .leading, spacing: 16) {
                Text(context.viewState.info)
                
                VStack(alignment: .leading, spacing: 8) {
                    InfoItem(title: context.viewState.infoPoint1)
                    InfoItem(title: context.viewState.infoPoint2)
                    InfoItem(title: context.viewState.infoPoint3)
                    InfoItem(title: context.viewState.infoPoint4, isSuccess: true)
                }
            }
            .foregroundColor(.compound.textSecondary)
            .font(.compound.bodyMD)
            // Clariva: keeps the first line clear of the row's rounded corner, which clipped its first letter on iOS 26.
            .padding(.horizontal, ListRowPadding.horizontal)
            .padding(.vertical, ListRowPadding.vertical)
            .listRowBackground(Color.clear)
        })
    }
    
    private var eraseDataSection: some View {
        Section {
            ListRow(label: .plain(title: L10n.screenDeactivateAccountDeleteAllMessages),
                    kind: .toggle($context.eraseData))
        } footer: {
            Text(L10n.screenDeactivateAccountDeleteAllMessagesNotice)
                .compoundListSectionFooter()
        }
    }
    
    private var googleSection: some View {
        Section {
            if context.viewState.hasGoogleToken {
                ListRow(kind: .custom {
                    Text("Authorised with \(context.viewState.authorizedProvider). You can now deactivate.")
                        .font(.compound.bodyMD)
                        .foregroundColor(.compound.textSuccessPrimary)
                        .padding(.horizontal, ListRowPadding.horizontal)
                        .padding(.vertical, ListRowPadding.vertical)
                        .frame(maxWidth: .infinity, alignment: .leading)
                })
            } else {
                ListRow(label: .plain(title: "Authorise with Google"),
                        kind: .button { context.send(viewAction: .authorizeWithGoogle) })
                ListRow(kind: .custom {
                    SignInWithAppleButton(.continue) { request in
                        request.requestedScopes = [.email]
                    } onCompletion: { result in
                        context.send(viewAction: .authorizedWithApple(ClarivaAppleSignInResult(result)))
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 44)
                    .padding(.horizontal, ListRowPadding.horizontal)
                    .padding(.vertical, ListRowPadding.vertical)
                })
            }
        } footer: {
            Text("You signed up with Google or Apple, so there is no password to confirm. Re-authorise with the same one to prove this is your account.")
                .compoundListSectionFooter()
        }
    }
    
    private var passwordSection: some View {
        Section {
            ListRow(label: .plain(title: L10n.commonPassword),
                    kind: .secureField(text: $context.password))
                .submitLabel(.done)
        } header: {
            Text(L10n.actionConfirmPassword)
                .compoundListSectionHeader()
        }
    }
}

private struct InfoItem: View {
    let title: AttributedString
    var isSuccess = false
    
    var body: some View {
        Label {
            Text(title).padding(.vertical, 1)
        } icon: {
            CompoundIcon(isSuccess ? \.check : \.close,
                         size: .small,
                         relativeTo: .compound.bodyMD)
                .foregroundStyle(isSuccess ? .compound.iconSuccessPrimary : .compound.iconCriticalPrimary)
        }
        .labelStyle(.custom(spacing: 8, alignment: .top))
    }
}

// MARK: - Previews

struct DeactivateAccountScreen_Previews: PreviewProvider, TestablePreview {
    // Never hit the real Clariva API from previews/snapshot tests.
    static let viewModel = DeactivateAccountScreenViewModel(clientProxy: ClientProxyMock(.init()),
                                                            userIndicatorController: UserIndicatorControllerMock(),
                                                            clarivaAuthService: PreviewClarivaAuthService())
    static var previews: some View {
        NavigationStack {
            DeactivateAccountScreen(context: viewModel.context)
        }
    }
}

/// An offline stand-in for the Clariva account API: a password (non-Google) account.
@MainActor
private final class PreviewClarivaAuthService: ClarivaAuthServiceProtocol {
    func signUp(email: String, password: String, name: String, username: String, isConsultant: Bool) async -> Result<ClarivaCredentials, ClarivaAuthError> {
        .failure(ClarivaAuthError(message: "Unavailable in previews"))
    }
    
    func signIn(identifier: String, password: String) async -> Result<ClarivaCredentials, ClarivaAuthError> {
        .failure(ClarivaAuthError(message: "Unavailable in previews"))
    }
    
    func signInWithGoogle(idToken: String, isConsultant: Bool?, isSignUp: Bool) async -> Result<ClarivaGoogleOutcome, ClarivaAuthError> {
        .failure(ClarivaAuthError(message: "Unavailable in previews"))
    }
    
    func signInWithApple(identityToken: String, name: String?, isConsultant: Bool?, isSignUp: Bool) async -> Result<ClarivaGoogleOutcome, ClarivaAuthError> {
        .failure(ClarivaAuthError(message: "Unavailable in previews"))
    }
    
    func isUsernameAvailable(_ username: String) async -> Bool? { nil }
    
    func isEmailAvailable(_ email: String) async -> Bool? { nil }
    
    func requestPasswordReset(email: String) async -> Result<Void, ClarivaAuthError> { .success(()) }
    
    func resetPassword(email: String, code: String, newPassword: String) async -> Result<Void, ClarivaAuthError> { .success(()) }
    
    func isGoogleAccount(matrixUserID: String) async -> Bool? { false }
    
    func deactivate(matrixUserID: String, password: String?, googleIDToken: String?, appleIDToken: String?, eraseData: Bool) async -> Result<Void, ClarivaAuthError> {
        .success(())
    }
    
    func saveMyBankDetails(_ request: ClarivaBankDetailsRequest) async -> Result<Void, ClarivaAuthError> { .success(()) }
}
