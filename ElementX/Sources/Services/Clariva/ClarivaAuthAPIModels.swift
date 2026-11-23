//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

// Request/response bodies of the Clariva account API (`v1/auth/*`). Mirrors Android's
// `ClarivaAuthApi.kt`. JSON keys are camelCase on the wire, so the synthesized coding keys match.
// Optional request fields are omitted from the JSON when nil (synthesized `encodeIfPresent`),
// which is exactly what the API checks for.

// MARK: - Requests

struct ClarivaRegisterRequest: Encodable {
    let email: String
    let password: String
    /// Display name - mandatory.
    let name: String
    /// Unique handle; becomes `@username:clarivahub.com`. A clash returns 409.
    let username: String
    /// Always encoded (non-optional): the API validates it as 0 or 1.
    let isConsultant: Int
}

struct ClarivaLoginRequest: Encodable {
    /// Email address OR username - the API accepts either.
    let identifier: String
    let password: String
}

struct ClarivaGoogleRequest: Encodable {
    let idToken: String
    /// nil on the first call so the server can answer `needsRole`.
    let isConsultant: Int?
    /// `"signup"` makes an already-registered email a hard error. nil keeps sign-in behaviour.
    let mode: String?
}

/// Sign in with Apple (`POST v1/auth/apple`). Same flow and responses as Google.
struct ClarivaAppleRequest: Encodable {
    let identityToken: String
    /// Apple gives the name to the app only on the first sign-in, never in the token.
    let name: String?
    /// nil on the first call so the server can answer `needsRole`.
    let isConsultant: Int?
    /// `"signup"` makes an already-registered email a hard error. nil keeps sign-in behaviour.
    let mode: String?
}

struct ClarivaForgotPasswordRequest: Encodable {
    let email: String
}

struct ClarivaResetPasswordRequest: Encodable {
    let email: String
    let code: String
    let newPassword: String
}

struct ClarivaDeactivateRequest: Encodable {
    let matrixUserId: String
    let password: String?
    let googleIdToken: String?
    /// For accounts made with Sign in with Apple.
    let appleIdToken: String?
    /// Always encoded (non-optional).
    let eraseData: Bool
}

// MARK: - Responses

struct ClarivaUser: Decodable {
    let id: String
    let email: String?
    let username: String?
    let name: String?
    let matrixUserId: String?
    let isConsultant: Int?
    let isGoogleAccount: Bool?
}

struct ClarivaAuthResponse: Decodable {
    let token: String
    let user: ClarivaUser?

    enum CodingKeys: String, CodingKey {
        case token
        case user
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        // The user payload is informational only, never let it fail an otherwise valid sign-in.
        user = try? container.decodeIfPresent(ClarivaUser.self, forKey: .user)
    }
}

/// Either a completed sign-in (`token` + `user`) or a request for the role of a brand-new user
/// (`needsRole == true`). Both arrive as HTTP 200, so every field is optional.
struct ClarivaGoogleResponse: Decodable {
    let needsRole: Bool?
    let email: String?
    let name: String?
    /// The row already exists and only its role is missing.
    let isExisting: Bool?
    let token: String?
    let user: ClarivaUser?

    enum CodingKeys: String, CodingKey {
        case needsRole
        case email
        case name
        case isExisting
        case token
        case user
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        needsRole = try container.decodeIfPresent(Bool.self, forKey: .needsRole)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        isExisting = try container.decodeIfPresent(Bool.self, forKey: .isExisting)
        token = try container.decodeIfPresent(String.self, forKey: .token)
        user = try? container.decodeIfPresent(ClarivaUser.self, forKey: .user)
    }
}

struct ClarivaAvailabilityResponse: Decodable {
    let available: Bool
    let reason: String?
}

struct ClarivaReauthMethodResponse: Decodable {
    let isGoogleAccount: Bool
}

struct ClarivaDeactivateResponse: Decodable {
    let deactivated: Bool?
}

struct ClarivaMatrixSessionResponse: Decodable {
    let userId: String
    let accessToken: String
    let deviceId: String
    /// Unlocks this account's secret storage on any device. nil on an older API.
    let recoveryPassphrase: String?
}
