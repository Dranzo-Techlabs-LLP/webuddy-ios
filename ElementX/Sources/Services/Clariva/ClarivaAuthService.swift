//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AuthenticationServices
import Foundation

/// A Matrix session minted by the Clariva API. The device never sees a Matrix password.
struct ClarivaCredentials: Equatable {
    let matrixUserID: String
    let accessToken: String
    let deviceID: String
    /// Server-held passphrase for this account's secret storage (memory only, never persisted).
    /// nil on an older API: the session works but has no access to history.
    let recoveryPassphrase: String?
}

/// Google or Apple sign-in either completes, or stops to ask a new user for their role.
enum ClarivaGoogleOutcome: Equatable {
    case signedIn(ClarivaCredentials)
    case roleRequired(email: String?, name: String?, isExisting: Bool)
}

/// `message` is user-facing.
struct ClarivaAuthError: Error, Equatable {
    let message: String
}

// sourcery: AutoMockable
@MainActor
protocol ClarivaAuthServiceProtocol {
    func signUp(email: String, password: String, name: String, username: String, isConsultant: Bool) async -> Result<ClarivaCredentials, ClarivaAuthError>
    /// `identifier` is an email address or a username; the API resolves either.
    func signIn(identifier: String, password: String) async -> Result<ClarivaCredentials, ClarivaAuthError>
    /// `isConsultant` is nil on the first attempt so the server can answer `needsRole`.
    func signInWithGoogle(idToken: String, isConsultant: Bool?, isSignUp: Bool) async -> Result<ClarivaGoogleOutcome, ClarivaAuthError>
    /// Sign in with Apple. `name` is what Apple shared on this device (first sign-in only).
    func signInWithApple(identityToken: String, name: String?, isConsultant: Bool?, isSignUp: Bool) async -> Result<ClarivaGoogleOutcome, ClarivaAuthError>

    /// nil when the check could not be made, so the UI stays silent rather than claim it's taken.
    func isUsernameAvailable(_ username: String) async -> Bool?
    /// nil when the check could not be made, so the UI stays silent rather than claim it's taken.
    func isEmailAvailable(_ email: String) async -> Bool?

    func requestPasswordReset(email: String) async -> Result<Void, ClarivaAuthError>
    func resetPassword(email: String, code: String, newPassword: String) async -> Result<Void, ClarivaAuthError>

    /// Saves the just-signed-up consultant's payout bank account (`POST v1/experts/me/bank-details`).
    /// Only works while the sign-up/sign-in JWT is in memory: it is the proof of whose account this is.
    func saveMyBankDetails(_ request: ClarivaBankDetailsRequest) async -> Result<Void, ClarivaAuthError>

    /// nil when it couldn't be determined.
    func isGoogleAccount(matrixUserID: String) async -> Bool?
    /// Exactly one proof is required: `password` for an email account, or a fresh `googleIDToken` /
    /// `appleIDToken` for an account without a password (made with Google or Apple).
    func deactivate(matrixUserID: String, password: String?, googleIDToken: String?, appleIDToken: String?, eraseData: Bool) async -> Result<Void, ClarivaAuthError>
}

/// Clariva account sign-up / sign-in. Mirrors Android's `ClarivaAuthService`.
///
/// Flow: authenticate against the Clariva API, then exchange the returned JWT for a Matrix access
/// token. The JWT is held in memory only.
@MainActor
final class ClarivaAuthService: ClarivaAuthServiceProtocol {
    private let api: ClarivaAuthAPIClient

    /// The Clariva JWT of the last sign-up / sign-in. Kept in memory only (never persisted), mirrors Android.
    private var token: String?
    // periphery:ignore - kept in memory only, mirrors Android
    private(set) var lastAuthenticatedUser: ClarivaUser?

    static let networkErrorMessage = "Could not reach Clariva. Check your connection and try again."

    init(api: ClarivaAuthAPIClient = ClarivaAuthAPIClient()) {
        self.api = api
    }

    // MARK: - Sign-up / sign-in

    func signUp(email: String, password: String, name: String, username: String, isConsultant: Bool) async -> Result<ClarivaCredentials, ClarivaAuthError> {
        let request = ClarivaRegisterRequest(email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                                             password: password,
                                             name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                             username: username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                                             isConsultant: isConsultant ? 1 : 0)
        return await runAuth { try await self.api.register(request) }
    }

    func signIn(identifier: String, password: String) async -> Result<ClarivaCredentials, ClarivaAuthError> {
        let request = ClarivaLoginRequest(identifier: identifier.trimmingCharacters(in: .whitespacesAndNewlines),
                                          password: password)
        return await runAuth { try await self.api.login(request) }
    }

    func signInWithGoogle(idToken: String, isConsultant: Bool?, isSignUp: Bool) async -> Result<ClarivaGoogleOutcome, ClarivaAuthError> {
        await runExternalSignIn(provider: "Google") {
            try await self.api.google(ClarivaGoogleRequest(idToken: idToken,
                                                           isConsultant: isConsultant.map { $0 ? 1 : 0 },
                                                           mode: isSignUp ? "signup" : nil))
        }
    }

    func signInWithApple(identityToken: String, name: String?, isConsultant: Bool?, isSignUp: Bool) async -> Result<ClarivaGoogleOutcome, ClarivaAuthError> {
        await runExternalSignIn(provider: "Apple") {
            try await self.api.apple(ClarivaAppleRequest(identityToken: identityToken,
                                                         name: name,
                                                         isConsultant: isConsultant.map { $0 ? 1 : 0 },
                                                         mode: isSignUp ? "signup" : nil))
        }
    }

    /// Google and Apple answer alike: a session to exchange for a Matrix one, or `needsRole`.
    private func runExternalSignIn(provider: String,
                                   _ request: () async throws -> ClarivaGoogleResponse) async -> Result<ClarivaGoogleOutcome, ClarivaAuthError> {
        do {
            let response = try await request()

            if response.needsRole == true {
                return .success(.roleRequired(email: response.email,
                                              name: response.name,
                                              isExisting: response.isExisting == true))
            }

            guard let token = response.token else {
                return .failure(ClarivaAuthError(message: "Clariva did not return a session. Please try again."))
            }
            self.token = token
            lastAuthenticatedUser = response.user

            let session = try await api.matrixSession(token: token)
            MXLog.info("\(provider) auth OK, matrix session for \(session.userId)")
            return .success(.signedIn(credentials(from: session)))
        } catch ClarivaAuthAPIError.http(let status, let body) {
            MXLog.warning("\(provider) auth failed with HTTP \(status)")
            return .failure(ClarivaAuthError(message: Self.mapHTTPError(status: status, body: body)))
        } catch {
            MXLog.error("\(provider) auth failed: \(error)")
            return .failure(ClarivaAuthError(message: Self.networkErrorMessage))
        }
    }

    // MARK: - Availability

    func isUsernameAvailable(_ username: String) async -> Bool? {
        do {
            return try await api.usernameAvailable(username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).available
        } catch {
            MXLog.info("Username availability check failed: \(error)")
            return nil
        }
    }

    func isEmailAvailable(_ email: String) async -> Bool? {
        do {
            return try await api.emailAvailable(email.trimmingCharacters(in: .whitespacesAndNewlines)).available
        } catch {
            MXLog.info("Email availability check failed: \(error)")
            return nil
        }
    }

    // MARK: - Password reset

    func requestPasswordReset(email: String) async -> Result<Void, ClarivaAuthError> {
        do {
            try await api.forgotPassword(ClarivaForgotPasswordRequest(email: email.trimmingCharacters(in: .whitespacesAndNewlines)))
            return .success(())
        } catch ClarivaAuthAPIError.http(let status, let body) {
            MXLog.warning("forgot-password failed with HTTP \(status)")
            return .failure(ClarivaAuthError(message: Self.mapHTTPError(status: status, body: body)))
        } catch {
            MXLog.error("forgot-password failed: \(error)")
            return .failure(ClarivaAuthError(message: Self.networkErrorMessage))
        }
    }

    func resetPassword(email: String, code: String, newPassword: String) async -> Result<Void, ClarivaAuthError> {
        do {
            try await api.resetPassword(ClarivaResetPasswordRequest(email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                    code: code.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                    newPassword: newPassword))
            return .success(())
        } catch ClarivaAuthAPIError.http(let status, let body) {
            MXLog.warning("reset-password failed with HTTP \(status)")
            return .failure(ClarivaAuthError(message: Self.mapHTTPError(status: status, body: body)))
        } catch {
            MXLog.error("reset-password failed: \(error)")
            return .failure(ClarivaAuthError(message: Self.networkErrorMessage))
        }
    }

    // MARK: - Payout bank account

    func saveMyBankDetails(_ request: ClarivaBankDetailsRequest) async -> Result<Void, ClarivaAuthError> {
        guard let token else {
            return .failure(ClarivaAuthError(message: "Please sign in again to add bank details."))
        }
        do {
            try await api.saveMyBankDetails(token: token, request: request)
            return .success(())
        } catch ClarivaAuthAPIError.http(let status, let body) {
            MXLog.warning("Saving bank details failed with HTTP \(status)")
            return .failure(ClarivaAuthError(message: Self.serverMessage(body: body) ?? "Could not save bank details (error \(status))."))
        } catch {
            MXLog.error("Saving bank details failed: \(error)")
            return .failure(ClarivaAuthError(message: Self.networkErrorMessage))
        }
    }

    // MARK: - Deactivation

    func isGoogleAccount(matrixUserID: String) async -> Bool? {
        do {
            return try await api.reauthMethod(matrixUserID: matrixUserID).isGoogleAccount
        } catch {
            MXLog.info("Could not determine the re-auth method: \(error)")
            return nil
        }
    }

    func deactivate(matrixUserID: String, password: String?, googleIDToken: String?, appleIDToken: String?, eraseData: Bool) async -> Result<Void, ClarivaAuthError> {
        do {
            let response = try await api.deactivate(ClarivaDeactivateRequest(matrixUserId: matrixUserID,
                                                                              password: password,
                                                                              googleIdToken: googleIDToken,
                                                                              appleIdToken: appleIDToken,
                                                                              eraseData: eraseData))
            guard response.deactivated == true else {
                return .failure(ClarivaAuthError(message: "Could not deactivate the account. Please try again."))
            }
            return .success(())
        } catch ClarivaAuthAPIError.http(let status, let body) {
            MXLog.warning("Deactivation failed with HTTP \(status)")
            // The server message is preferred for any status.
            let message = Self.serverMessage(body: body) ?? Self.deactivationFallbackMessage(status: status)
            return .failure(ClarivaAuthError(message: message))
        } catch {
            MXLog.error("Deactivation failed: \(error)")
            return .failure(ClarivaAuthError(message: Self.networkErrorMessage))
        }
    }

    // MARK: - Private

    private func runAuth(_ authenticate: () async throws -> ClarivaAuthResponse) async -> Result<ClarivaCredentials, ClarivaAuthError> {
        do {
            let auth = try await authenticate()
            token = auth.token
            lastAuthenticatedUser = auth.user

            let session = try await api.matrixSession(token: auth.token)
            MXLog.info("Clariva auth OK, matrix session for \(session.userId)")
            return .success(credentials(from: session))
        } catch ClarivaAuthAPIError.http(let status, let body) {
            MXLog.warning("Clariva auth failed with HTTP \(status)")
            return .failure(ClarivaAuthError(message: Self.mapHTTPError(status: status, body: body)))
        } catch {
            MXLog.error("Clariva auth failed: \(error)")
            return .failure(ClarivaAuthError(message: Self.networkErrorMessage))
        }
    }

    private func credentials(from session: ClarivaMatrixSessionResponse) -> ClarivaCredentials {
        ClarivaCredentials(matrixUserID: session.userId,
                           accessToken: session.accessToken,
                           deviceID: session.deviceId,
                           recoveryPassphrase: session.recoveryPassphrase)
    }

    /// 400 and 409 carry an actionable, user-facing reason from the API, so prefer it.
    static func mapHTTPError(status: Int, body: Data) -> String {
        if status == 400 || status == 409, let message = serverMessage(body: body) {
            return message
        }

        switch status {
        case 400:
            return "Please check the details you entered and try again."
        case 401:
            return "Incorrect email or password."
        case 409:
            return "That email or username is already taken."
        case 500...599:
            return "Clariva is having trouble right now. Please try again shortly."
        default:
            return "Sign-in failed (error \(status))."
        }
    }

    private static func deactivationFallbackMessage(status: Int) -> String {
        switch status {
        case 401:
            return "Could not verify your identity. Please try again."
        case 400:
            return "Please re-authorise before deactivating."
        default:
            return "Could not deactivate the account (error \(status))."
        }
    }

    /// Pulls `message` out of Nest's error envelope; it may be a string or an array of strings
    /// (joined with a newline).
    static func serverMessage(body: Data) -> String? {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let message = object["message"] else {
            return nil
        }

        if let string = message as? String {
            return string.isEmpty ? nil : string
        }
        if let array = message as? [Any] {
            let joined = array.compactMap { $0 as? String }.joined(separator: "\n")
            return joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : joined
        }
        return nil
    }
}

/// What a Sign in with Apple attempt produced, built from `SignInWithAppleButton`'s completion.
enum ClarivaAppleSignInResult: Equatable {
    case success(identityToken: String, name: String?)
    case cancelled
    case failure(message: String)

    static let genericFailureMessage = "Could not sign in with Apple. Please try again."

    init(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                MXLog.error("Sign in with Apple returned no identity token")
                self = .failure(message: Self.genericFailureMessage)
                return
            }
            // Apple shares the name only the first time the user signs in to this app.
            let name = credential.fullName
                .map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self = .success(identityToken: identityToken, name: name?.isEmpty == false ? name : nil)
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled {
                self = .cancelled
            } else {
                MXLog.error("Sign in with Apple failed: \(error)")
                self = .failure(message: Self.genericFailureMessage)
            }
        }
    }
}
