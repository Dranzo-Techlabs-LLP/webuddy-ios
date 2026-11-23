//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// Forgot / reset password with a 6-digit emailed code. Mirrors Android's `ClarivaForgotPasswordDialog`.
struct ClarivaForgotPasswordSheet: View {
    enum Field: Hashable {
        case email
        case code
        case newPassword
    }

    let context: ClarivaAuthScreenViewModel.Context

    @FocusState private var focusedField: Field?
    @State private var isPasswordVisible = false

    var body: some View {
        ScrollView {
            if let state = context.viewState.bindings.forgotPassword {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Reset password")
                        .font(.compound.headingSMSemibold)
                        .foregroundColor(.compound.textPrimary)

                    if state.done {
                        doneContent
                    } else {
                        switch state.step {
                        case .enterEmail:
                            enterEmailContent(state)
                        case .enterCode:
                            enterCodeContent(state)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Steps

    @ViewBuilder
    private func enterEmailContent(_ state: ClarivaForgotPasswordState) -> some View {
        Text("Enter your account email and we'll send you a 6-digit reset code.")
            .font(.compound.bodyMD)
            .foregroundColor(.compound.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

        ClarivaAuthField(label: "Email", isFocused: focusedField == .email) {
            TextField(text: emailBinding, prompt: .clarivaPrompt("you@example.com")) {
                Text("Email")
            }
            .focused($focusedField, equals: .email)
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onSubmit { context.send(viewAction: .forgotPasswordRequestCode) }
        }
        .disabled(state.isLoading)

        errorText(state.error)

        buttons(primaryTitle: "Send code",
                isPrimaryEnabled: state.sendEnabled,
                isLoading: state.isLoading) {
            focusedField = nil
            context.send(viewAction: .forgotPasswordRequestCode)
        }
    }

    @ViewBuilder
    private func enterCodeContent(_ state: ClarivaForgotPasswordState) -> some View {
        Text("If an account exists for \(state.email), a 6-digit code is on its way. Enter it below with your new password.")
            .font(.compound.bodyMD)
            .foregroundColor(.compound.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

        ClarivaAuthField(label: "6-digit code", isFocused: focusedField == .code) {
            TextField(text: codeBinding) {
                Text("6-digit code")
            }
            .focused($focusedField, equals: .code)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
        }
        .disabled(state.isLoading)

        ClarivaAuthField(label: "New password", isFocused: focusedField == .newPassword) {
            ClarivaPasswordInput(text: newPasswordBinding,
                                 placeholder: "At least \(ClarivaAuthConstants.minPasswordLength) characters",
                                 contentType: .newPassword,
                                 isVisible: $isPasswordVisible,
                                 focus: $focusedField,
                                 focusValue: Field.newPassword)
                .submitLabel(.done)
                .onSubmit { context.send(viewAction: .forgotPasswordSubmit) }
        }
        .disabled(state.isLoading)

        errorText(state.error)

        Button {
            focusedField = nil
            context.send(viewAction: .forgotPasswordRequestCode)
        } label: {
            Text("Resend code")
                .font(.compound.bodyMDSemibold)
                .foregroundColor(.compound.textPrimary)
        }
        .buttonStyle(.plain)
        .disabled(state.isLoading)

        buttons(primaryTitle: "Reset password",
                isPrimaryEnabled: state.resetEnabled,
                isLoading: state.isLoading) {
            focusedField = nil
            context.send(viewAction: .forgotPasswordSubmit)
        }
    }

    @ViewBuilder
    private var doneContent: some View {
        Text("Password reset. Sign in with your new password.")
            .font(.compound.bodyMD)
            .foregroundColor(.compound.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

        Button {
            context.send(viewAction: .forgotPasswordDismiss)
        } label: {
            Text("Sign in")
        }
        .buttonStyle(.compound(.primary))
    }

    // MARK: - Components

    @ViewBuilder
    private func errorText(_ error: String?) -> some View {
        if let error {
            Text(error)
                .font(.compound.bodySM)
                .foregroundColor(.compound.textCriticalPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func buttons(primaryTitle: String,
                         isPrimaryEnabled: Bool,
                         isLoading: Bool,
                         primaryAction: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Spacer()

            Button {
                context.send(viewAction: .forgotPasswordDismiss)
            } label: {
                Text(L10n.actionCancel)
            }
            .buttonStyle(.compound(.secondary, size: .medium))

            Button(action: primaryAction) {
                ZStack {
                    Text(primaryTitle)
                        .opacity(isLoading ? 0 : 1)

                    if isLoading {
                        ProgressView()
                    }
                }
            }
            .buttonStyle(.compound(.primary, size: .medium))
            .disabled(!isPrimaryEnabled)
        }
        .padding(.top, 8)
    }

    // MARK: - Bindings

    private var emailBinding: Binding<String> {
        Binding(get: { context.viewState.bindings.forgotPassword?.email ?? "" },
                set: { context.send(viewAction: .forgotPasswordSetEmail($0)) })
    }

    private var codeBinding: Binding<String> {
        Binding(get: { context.viewState.bindings.forgotPassword?.code ?? "" },
                set: { context.send(viewAction: .forgotPasswordSetCode($0)) })
    }

    private var newPasswordBinding: Binding<String> {
        Binding(get: { context.viewState.bindings.forgotPassword?.newPassword ?? "" },
                set: { context.send(viewAction: .forgotPasswordSetNewPassword($0)) })
    }
}
