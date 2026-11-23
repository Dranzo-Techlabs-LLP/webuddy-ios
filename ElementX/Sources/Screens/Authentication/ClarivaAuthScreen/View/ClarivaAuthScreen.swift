//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AuthenticationServices
import Compound
import SwiftUI

/// Clariva landing screen: this IS the app's welcome page. The logo and welcome copy sit at the top
/// and the sign-in / sign-up fields follow directly beneath them. Mirrors Android's `ClarivaAuthView`.
struct ClarivaAuthScreen: View {
    enum Field: Hashable {
        case name
        case username
        case email
        case password
    }

    @Bindable var context: ClarivaAuthScreenViewModel.Context

    @FocusState private var focusedField: Field?
    /// The optional consultant setup fields under the consultant switch.
    @FocusState private var setupFocusedField: ClarivaConsultantSetupField?
    @State private var isPasswordVisible = false
    @Environment(\.colorScheme) private var colorScheme

    private var isSignUp: Bool {
        context.viewState.isSignUp
    }

    private var isLoading: Bool {
        context.viewState.isLoading
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
                    .readableFrame()
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background {
            ClarivaAuthBackground()
        }
        .navigationBarHidden(true)
        .introspect(.window, on: .supportedVersions) { window in
            context.send(viewAction: .updateWindow(window))
        }
        .onChange(of: isLoading) { _, newValue in
            if newValue {
                isPasswordVisible = false
            }
        }
        .alert(item: $context.alertInfo)
        .sheet(item: forgotPasswordBinding) { _ in
            ClarivaForgotPasswordSheet(context: context)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)

            AuthenticationStartLogo(hideBrandChrome: context.viewState.hideBrandChrome)

            Text("Welcome to Clariva")
                .font(.compound.headingLGBold)
                .foregroundColor(.compound.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, 28)

            Text("Private conversations. Real value.\nEncrypted chats with trusted consultants.")
                .font(.compound.bodyLG)
                .foregroundColor(.compound.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            form
                .padding(.top, 32)

            submitButton
                .padding(.top, 24)

            Text("or")
                .font(.compound.bodySM)
                .foregroundColor(.compound.textSecondary)
                .padding(.top, 16)

            appleButton
                .padding(.top, 16)

            googleButton
                .padding(.top, 12)

            if !context.viewState.isGoogleSignInConfigured {
                Text("Google sign-in needs an iOS client ID to be configured.")
                    .font(.compound.bodyXS)
                    .foregroundColor(.compound.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }

            Button {
                focusedField = nil
                context.send(viewAction: .toggleMode)
            } label: {
                Text(isSignUp ? "Already have an account? Sign in" : "New to Clariva? Create an account")
                    .font(.compound.bodyMDSemibold)
                    .foregroundColor(.compound.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .padding(.top, 28)

            Text(L10n.screenOnboardingAppVersion(context.viewState.versionString))
                .font(.compound.bodySM)
                .foregroundColor(.compound.textSecondary)
                .padding(.top, 20)
                .onTapGesture(count: 7) {
                    context.send(viewAction: .reportProblem)
                }

            Spacer(minLength: 8)
        }
        .sheet(item: $context.googleRolePrompt) { _ in
            ClarivaGoogleSignUpSheet(context: context)
        }
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isSignUp {
                nameField
                usernameField
            }

            emailField
            passwordField

            if isSignUp {
                ClarivaConsultantSection(context: context, focus: $setupFocusedField, onSubmit: submit)
                    .padding(.top, 4)
            } else {
                forgotPasswordLink
            }
        }
        .disabled(isLoading)
    }

    private var nameField: some View {
        ClarivaAuthField(label: "Name",
                         footer: context.viewState.nameError,
                         state: context.viewState.nameError == nil ? .default : .error,
                         isFocused: focusedField == .name) {
            TextField(text: binding(\.name, action: ClarivaAuthScreenViewAction.setName),
                      prompt: .clarivaPrompt("Your full name")) {
                Text("Name")
            }
            .focused($focusedField, equals: .name)
            .textContentType(.name)
            .textInputAutocapitalization(.words)
            .submitLabel(.next)
            .onSubmit { focusedField = .username }
        }
    }

    private var usernameField: some View {
        ClarivaAuthField(label: "Username",
                         footer: context.viewState.usernameFooter,
                         state: context.viewState.usernameFieldState,
                         isFocused: focusedField == .username) {
            TextField(text: binding(\.username, action: ClarivaAuthScreenViewAction.setUsername),
                      prompt: .clarivaPrompt("e.g. jane.doe")) {
                Text("Username")
            }
            .focused($focusedField, equals: .username)
            .keyboardType(.asciiCapable)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.next)
            .onSubmit { focusedField = .email }
        }
    }

    private var emailField: some View {
        ClarivaAuthField(label: isSignUp ? "Email" : "Email or username",
                         footer: context.viewState.emailFooter,
                         state: context.viewState.emailFieldState,
                         isFocused: focusedField == .email) {
            TextField(text: binding(\.email, action: ClarivaAuthScreenViewAction.setEmail),
                      prompt: .clarivaPrompt(isSignUp ? "you@example.com" : "you@example.com or jane.doe")) {
                Text(isSignUp ? "Email" : "Email or username")
            }
            .focused($focusedField, equals: .email)
            // Plain keyboard on sign-in: the email keyboard is wrong for a username.
            .keyboardType(isSignUp ? UIKeyboardType.emailAddress : UIKeyboardType.default)
            .textContentType(isSignUp ? UITextContentType.emailAddress : UITextContentType.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.next)
            .onSubmit { focusedField = .password }
        }
    }

    private var passwordField: some View {
        ClarivaAuthField(label: "Password", isFocused: focusedField == .password) {
            ClarivaPasswordInput(text: binding(\.password, action: ClarivaAuthScreenViewAction.setPassword),
                                 placeholder: isSignUp ? "At least \(ClarivaAuthConstants.minPasswordLength) characters" : nil,
                                 contentType: isSignUp ? UITextContentType.newPassword : UITextContentType.password,
                                 isVisible: $isPasswordVisible,
                                 focus: $focusedField,
                                 focusValue: Field.password)
                // With the consultant setup open, "Next" carries on into it instead of submitting.
                .submitLabel(context.viewState.hasConsultantSetupBelow ? .next : .done)
                .onSubmit {
                    if context.viewState.hasConsultantSetupBelow {
                        setupFocusedField = .maxCredits
                    } else {
                        submit()
                    }
                }
        }
    }

    private var forgotPasswordLink: some View {
        HStack {
            Spacer()

            Button {
                focusedField = nil
                context.send(viewAction: .forgotPasswordOpen)
            } label: {
                Text("Forgot password?")
                    .font(.compound.bodyMDSemibold)
                    .foregroundColor(.compound.textPrimary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Buttons

    private var submitButton: some View {
        Button(action: submit) {
            ZStack {
                Text(isSignUp ? "Create account" : "Sign in")
                    .opacity(isLoading ? 0 : 1)

                if isLoading {
                    ProgressView()
                }
            }
        }
        .buttonStyle(.compound(.primary))
        .disabled(!context.viewState.submitEnabled)
    }

    /// Apple's own button, as its guidelines require; it presents the Sign in with Apple sheet itself.
    private var appleButton: some View {
        SignInWithAppleButton(isSignUp ? .signUp : .signIn) { request in
            focusedField = nil
            request.requestedScopes = [.fullName, .email]
        } onCompletion: { result in
            context.send(viewAction: .signInWithApple(ClarivaAppleSignInResult(result)))
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 48)
        .clipShape(Capsule())
        .disabled(isLoading)
        // Re-created with the mode so the button's label follows it.
        .id(isSignUp)
    }

    private var googleButton: some View {
        Button {
            focusedField = nil
            context.send(viewAction: .signInWithGoogle)
        } label: {
            Text(isSignUp ? "Sign up with Google" : "Sign in with Google")
        }
        .buttonStyle(.compound(.secondary))
        .disabled(isLoading)
    }

    // MARK: - Helpers

    private func submit() {
        guard context.viewState.submitEnabled else { return }
        focusedField = nil
        setupFocusedField = nil
        context.send(viewAction: .submit)
    }

    /// Reads from the bindings but routes every edit through the view model (sanitising, live checks).
    private func binding(_ keyPath: KeyPath<ClarivaAuthScreenBindings, String>,
                         action: @escaping (String) -> ClarivaAuthScreenViewAction) -> Binding<String> {
        Binding(get: { context.viewState.bindings[keyPath: keyPath] },
                set: { context.send(viewAction: action($0)) })
    }

    private var forgotPasswordBinding: Binding<ClarivaForgotPasswordState?> {
        Binding(get: { context.viewState.bindings.forgotPassword },
                set: { newValue in
                    if newValue == nil {
                        context.send(viewAction: .forgotPasswordDismiss)
                    }
                })
    }
}

/// The Clariva brand gradient (Android `clarivaBrandBrush`).
struct ClarivaAuthBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(stops: colorScheme == .dark ? Self.darkStops : Self.lightStops,
                       startPoint: .top,
                       endPoint: .bottom)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    private static let lightStops: [Gradient.Stop] = [
        .init(color: color(0xEAF8F3), location: 0.0),
        .init(color: color(0x74D2BC), location: 0.2),
        .init(color: color(0xE2F6EF), location: 0.4),
        .init(color: color(0x9FE2D3), location: 0.62),
        .init(color: color(0xF4FBF9), location: 1.0)
    ]

    private static let darkStops: [Gradient.Stop] = [
        .init(color: color(0x0B1622), location: 0.0),
        .init(color: color(0x0F5A50), location: 0.2),
        .init(color: color(0x0D1F2C), location: 0.4),
        .init(color: color(0x10463F), location: 0.62),
        .init(color: color(0x0A1420), location: 1.0)
    ]

    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Previews

struct ClarivaAuthScreen_Previews: PreviewProvider {
    static let viewModel = ClarivaAuthScreenViewModel(authenticationService: AuthenticationService.mock,
                                                      clarivaAuthService: ClarivaAuthService(),
                                                      googleSignInService: GoogleSignInService(),
                                                      walletService: nil,
                                                      ifscLookup: IfscLookup.shared,
                                                      userIndicatorController: nil,
                                                      isBugReportServiceEnabled: false,
                                                      appSettings: ServiceLocator.shared.settings)

    static var previews: some View {
        NavigationStack {
            ClarivaAuthScreen(context: viewModel.context)
        }
    }
}
