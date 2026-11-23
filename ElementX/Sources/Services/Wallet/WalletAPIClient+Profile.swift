//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

// MARK: - Endpoints

/// The Clariva profile fields kept in the Wallet-API user record: the role and the free-form
/// `settings` JSON, which holds the consultant's designation and the "Last seen and online"
/// choice (Android ee053dc156 `WalletResponse.settings`).
///
/// Both routes are the same `v1/users/{Webuddy_name}` ones the wallet uses, and neither takes a
/// Bearer token on the backend (`UsersController` has no guard).
extension WalletAPIClient {
    /// `GET v1/users/{Webuddy_name}`, decoding only the profile fields.
    func getUserProfile(webuddyName: String) async throws -> WalletUserProfileResponse {
        try await send("GET", path: ["v1", "users", webuddyName])
    }

    /// `PATCH v1/users/{Webuddy_name}` with only `settings`. The backend REPLACES the whole object,
    /// so callers send the merged one (see `ClarivaProfileService.updateSettings`).
    func updateUserSettings(webuddyName: String, settings: [String: ClarivaJSONValue]) async throws {
        try await sendIgnoringResponse("PATCH", path: ["v1", "users", webuddyName], body: WalletUpdateSettingsRequest(settings: settings))
    }
}

// MARK: - Models

/// Profile view of `GET v1/users/{Webuddy_name}`. Everything is optional and parsed leniently: a
/// malformed `settings` value reads as "no settings" rather than failing the whole lookup.
struct WalletUserProfileResponse: Decodable {
    /// 0 = client, 1 = consultant.
    let isConsultant: Int?
    let settings: [String: ClarivaJSONValue]?

    enum CodingKeys: String, CodingKey {
        case isConsultant
        case settings
    }

    init(isConsultant: Int?, settings: [String: ClarivaJSONValue]?) {
        self.isConsultant = isConsultant
        self.settings = settings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isConsultant = container.flexibleInt(.isConsultant)
        settings = (try? container.decodeIfPresent([String: ClarivaJSONValue].self, forKey: .settings)) ?? nil
    }
}

/// Only `settings` is encoded: the API rejects unknown keys (`forbidNonWhitelisted`).
struct WalletUpdateSettingsRequest: Encodable {
    let settings: [String: ClarivaJSONValue]
}

/// Any JSON value, so keys of the `settings` object this app doesn't know survive a read-merge-write.
enum ClarivaJSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: ClarivaJSONValue])
    case array([ClarivaJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ClarivaJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ClarivaJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    /// The value when this is a JSON string, else nil (Android `JsonPrimitive.isString`).
    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var objectValue: [String: ClarivaJSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    var arrayValue: [ClarivaJSONValue]? {
        if case .array(let value) = self {
            return value
        }
        return nil
    }
}
