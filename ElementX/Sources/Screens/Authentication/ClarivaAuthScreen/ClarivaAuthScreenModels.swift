//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import UIKit

// MARK: - Coordinator

enum ClarivaAuthScreenCoordinatorAction {
    /// The imported Clariva session is ready. `recoveryPassphrase` is held in memory only and is
    /// used to unlock key storage once the user session is running.
    case signedIn(userSession: UserSessionProtocol, recoveryPassphrase: String?)
    case reportProblem
}

enum ClarivaAuthScreenViewModelAction {
    case signedIn(userSession: UserSessionProtocol, recoveryPassphrase: String?)
    case reportProblem
}

// MARK: - View

enum ClarivaAuthMode {
    case signIn
    case signUp
}

/// Live result of a server-side availability lookup on the sign-up form.
enum ClarivaAvailability {
    /// Nothing typed yet, not well-formed enough to check, or the check failed.
    case unknown
    case checking
    case available
    case taken
}

enum ClarivaAuthConstants {
    /// Must match the API's `@MinLength(8)`.
    static let minPasswordLength = 8
    static let minNameLength = 2
    static let minUsernameLength = 3
    static let maxUsernameLength = 30
    /// Kept in sync with the API's USERNAME_PATTERN and Matrix localpart rules (applied to the normalized value).
    static let usernamePattern = "^[a-z0-9][a-z0-9._-]{2,29}$"
    /// Long enough that a normal typist triggers one lookup per handle, not one per key.
    static let availabilityDebounce: Duration = .milliseconds(450)

    static func matchesUsernamePattern(_ username: String) -> Bool {
        username.range(of: usernamePattern, options: .regularExpression) != nil
    }

    /// `0`-`9` only (`Character.isNumber` also accepts other scripts' digits, fractions etc.).
    static func isDigit(_ character: Character) -> Bool {
        ("0"..."9").contains(character)
    }
    
    static func isEmailWellFormed(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && trimmed.count >= 5
    }
}

struct ClarivaAuthScreenViewState: BindableState {
    /// Returning users are the common case, so the landing page defaults to signing in.
    var mode: ClarivaAuthMode = .signIn
    var isLoading = false
    var usernameAvailability: ClarivaAvailability = .unknown
    var emailAvailability: ClarivaAvailability = .unknown

    /// Optional chat rate + bank account; only shown, and only saved, for a consultant (Android 7e8f3c3e10).
    /// Edited through `setConsultantSetupField` so every keystroke is filtered like Android's.
    var consultantSetup = ClarivaConsultantSetupForm()
    /// Live check of the setup's IFSC against the IFSC directory (Android 093714e02a).
    var ifscStatus: IfscStatus = .none

    let isGoogleSignInConfigured: Bool
    let hideBrandChrome: Bool
    let versionString: String

    /// The presentation anchor used for Google Sign-In.
    var window: UIWindow?

    var bindings = ClarivaAuthScreenBindings()

    var isSignUp: Bool {
        mode == .signUp
    }

    /// The handle as it will actually exist: the server lowercases it.
    var normalizedUsername: String {
        bindings.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isUsernameWellFormed: Bool {
        !bindings.username.isEmpty && ClarivaAuthConstants.matchesUsernamePattern(normalizedUsername)
    }

    /// nil when acceptable (or empty), otherwise the reason shown under the field.
    var usernameError: String? {
        guard !bindings.username.isEmpty else { return nil }

        if normalizedUsername.count < ClarivaAuthConstants.minUsernameLength {
            return "At least \(ClarivaAuthConstants.minUsernameLength) characters"
        } else if normalizedUsername.count > ClarivaAuthConstants.maxUsernameLength {
            return "At most \(ClarivaAuthConstants.maxUsernameLength) characters"
        } else if !ClarivaAuthConstants.matchesUsernamePattern(normalizedUsername) {
            return "Use letters, numbers, dots, underscores or hyphens; start with a letter or number"
        } else if usernameAvailability == .taken {
            return "That username is already taken"
        } else {
            return nil
        }
    }

    /// Priority: hard error > live availability > MXID preview > help.
    var usernameFooter: String {
        if let usernameError {
            return usernameError
        }
        switch usernameAvailability {
        case .checking:
            return "Checking availability…"
        case .available:
            return "Available — you will be @\(normalizedUsername):clarivahub.com"
        case .unknown, .taken:
            if bindings.username.isEmpty {
                return "Your unique handle. This cannot be changed later."
            } else {
                return "You will be @\(normalizedUsername):clarivahub.com"
            }
        }
    }

    var usernameFieldState: ClarivaAuthFieldState {
        if usernameError != nil {
            return .error
        } else if usernameAvailability == .available {
            return .success
        } else {
            return .default
        }
    }

    var nameError: String? {
        let trimmed = bindings.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bindings.name.isEmpty, trimmed.count < ClarivaAuthConstants.minNameLength {
            return "Please enter your name"
        }
        return nil
    }

    /// Only shown on sign-up.
    var emailFooter: String? {
        guard isSignUp else { return nil }
        switch emailAvailability {
        case .checking:
            return "Checking availability…"
        case .available:
            return "Email is available"
        case .taken:
            return "That email is already registered. Sign in instead."
        case .unknown:
            return nil
        }
    }

    var emailFieldState: ClarivaAuthFieldState {
        guard isSignUp else { return .default }
        switch emailAvailability {
        case .taken:
            return .error
        case .available:
            return .success
        case .unknown, .checking:
            return .default
        }
    }

    private var credentialsValid: Bool {
        switch mode {
        case .signIn:
            // Sign-in accepts an email OR a username, so no '@' requirement here.
            bindings.email.count >= ClarivaAuthConstants.minUsernameLength
                && bindings.password.count >= ClarivaAuthConstants.minPasswordLength
        case .signUp:
            bindings.email.contains("@")
                && bindings.email.count >= 5
                && bindings.password.count >= ClarivaAuthConstants.minPasswordLength
        }
    }

    /// An unfinished/failed availability check doesn't block submit - the server is the real gate.
    var submitEnabled: Bool {
        guard !isLoading, credentialsValid else { return false }

        switch mode {
        case .signIn:
            return true
        case .signUp:
            return bindings.name.trimmingCharacters(in: .whitespacesAndNewlines).count >= ClarivaAuthConstants.minNameLength
                && isUsernameWellFormed
                && usernameAvailability != .taken
                && emailAvailability != .taken
                // The setup is optional, but what IS typed must be valid - half a bank account
                // would otherwise be silently dropped.
                && (!bindings.isConsultant || isConsultantSetupReady)
        }
    }

    /// The optional setup is skipped, or valid with an IFSC that is not known to be wrong.
    var isConsultantSetupReady: Bool {
        consultantSetup.isReady(ifscStatus: ifscStatus)
    }

    /// The setup fields are showing under the consultant switch, so the password's "Next" goes there.
    var hasConsultantSetupBelow: Bool {
        isSignUp && bindings.isConsultant && !consultantSetup.isSkipped
    }
}

struct ClarivaAuthScreenBindings {
    var name = ""
    var username = ""
    /// The email on sign-up, an email OR a username on sign-in.
    var email = ""
    var password = ""
    var isConsultant = false

    var alertInfo: AlertInfo<ClarivaAuthScreenAlertType>?
    /// Non-nil while the forgot-password sheet is shown.
    var forgotPassword: ClarivaForgotPasswordState?
    /// Non-nil while a Google user whose role is unknown is being asked for it.
    var googleRolePrompt: ClarivaGoogleRolePrompt?
}

enum ClarivaAuthScreenAlertType: Hashable {
    case signInFailed
}

enum ClarivaAuthFieldState {
    case `default`
    case success
    case error
}

/// The role of this Google identity is unknown, so it must be chosen before sign-in can complete.
/// `idToken` is kept so the choice can be submitted without re-prompting Google.
struct ClarivaGoogleRolePrompt: Identifiable {
    /// Which provider's token `idToken` is. The role sheets are the same for both.
    enum Provider: Equatable {
        case google
        /// The name Apple shared, resent with the role: Apple never repeats it.
        case apple(name: String?)
    }

    var provider: Provider = .google
    let idToken: String
    let email: String?
    /// The Google profile name, offered as the bank account holder placeholder.
    let name: String?
    // periphery:ignore - carried for parity with Android, not shown
    let isExisting: Bool
    /// "Yes, consultant" was picked and the optional payout step (chat rate + bank account, as on the
    /// email sign-up form) is showing. Nothing is created yet.
    var isAskingPayouts = false
    /// "Yes" was picked before, so coming Back keeps it selected.
    var hasChosenConsultant = false

    var id: String {
        idToken
    }

    var payoutSubtitle: String {
        if let email {
            ClarivaConsultantSetupStrings.googleSubtitle(email: email)
        } else {
            ClarivaConsultantSetupStrings.subtitle
        }
    }

    var subtitle: String {
        if let email {
            "Setting up \(email). Consultants are paid for the chats they take; this can be changed later in Settings."
        } else {
            "Consultants are paid for the chats they take. This can be changed later in Settings."
        }
    }
}

enum ClarivaForgotPasswordStep {
    case enterEmail
    case enterCode
}

struct ClarivaForgotPasswordState: Identifiable {
    let id = "forgot-password"

    var email: String
    var code = ""
    var newPassword = ""
    var step = ClarivaForgotPasswordStep.enterEmail
    var isLoading = false
    var error: String?
    /// True once the reset succeeded.
    var done = false

    var emailValid: Bool {
        ClarivaAuthConstants.isEmailWellFormed(email)
    }

    var codeValid: Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count == 6 && trimmed.allSatisfy(ClarivaAuthConstants.isDigit)
    }

    var newPasswordValid: Bool {
        newPassword.count >= ClarivaAuthConstants.minPasswordLength
    }

    var sendEnabled: Bool {
        !isLoading && emailValid
    }

    var resetEnabled: Bool {
        !isLoading && codeValid && newPasswordValid
    }
}

enum ClarivaAuthScreenViewAction {
    /// Updates the window used as the Google Sign-In presentation anchor.
    case updateWindow(UIWindow)

    case setName(String)
    case setUsername(String)
    case setEmail(String)
    case setPassword(String)

    case submit
    case toggleMode

    /// Optional consultant setup on sign-up (chat rate + payout bank account).
    case setConsultantSetupField(ClarivaConsultantSetupField, String)
    /// "Skip for now": nothing from the setup is saved; it can be done later in Settings.
    case skipConsultantSetup
    /// Re-open a skipped setup.
    case resumeConsultantSetup

    case signInWithGoogle
    /// The outcome of the Sign in with Apple sheet, which the button presents itself.
    case signInWithApple(ClarivaAppleSignInResult)
    /// Google user said they are a consultant: show the optional payout step before creating the account.
    case showGooglePayoutStep
    /// From the payout step back to "Are you a consultant?".
    case backToGoogleRole
    /// Finish creating the Google account. `skipPayoutSetup` ignores whatever was typed on the payout step.
    case confirmGoogleRole(isConsultant: Bool, skipPayoutSetup: Bool)
    case cancelGoogleRole

    case forgotPasswordOpen
    case forgotPasswordDismiss
    case forgotPasswordSetEmail(String)
    case forgotPasswordSetCode(String)
    case forgotPasswordSetNewPassword(String)
    case forgotPasswordRequestCode
    case forgotPasswordSubmit

    case reportProblem
}
