//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum ClarivaAuthAPIError: Error {
    case invalidURL
    case invalidResponse
    /// A non-2xx response. `body` is the raw error body (Nest error envelope).
    case http(status: Int, body: Data)
    case transport(underlying: Error)
    case decoding(underlying: Error)
}

/// Thin URLSession wrapper for the Clariva account API (`v1/auth/*`).
/// Mirrors the Android `ClarivaAuthApi` Retrofit interface so both clients hit the same endpoints.
struct ClarivaAuthAPIClient {
    let baseURL: URL
    private let session: URLSession
    private let timeout: TimeInterval

    init(baseURL: URL = ClarivaConfig.apiBaseURL,
         session: URLSession = .shared,
         timeout: TimeInterval = ClarivaConfig.requestTimeout) {
        self.baseURL = baseURL
        self.session = session
        self.timeout = timeout
    }

    // MARK: - Sign-up / sign-in

    func register(_ request: ClarivaRegisterRequest) async throws -> ClarivaAuthResponse {
        try await send("POST", path: ["v1", "auth", "register"], body: request)
    }

    func login(_ request: ClarivaLoginRequest) async throws -> ClarivaAuthResponse {
        try await send("POST", path: ["v1", "auth", "login"], body: request)
    }

    func google(_ request: ClarivaGoogleRequest) async throws -> ClarivaGoogleResponse {
        try await send("POST", path: ["v1", "auth", "google"], body: request)
    }

    /// Answers exactly like `google` (a session, or `needsRole`).
    func apple(_ request: ClarivaAppleRequest) async throws -> ClarivaGoogleResponse {
        try await send("POST", path: ["v1", "auth", "apple"], body: request)
    }

    /// Exchanges the Clariva session JWT for a Matrix access token.
    func matrixSession(token: String) async throws -> ClarivaMatrixSessionResponse {
        let data = try await perform("POST",
                                     path: ["v1", "auth", "matrix-session"],
                                     query: [:],
                                     body: nil,
                                     headers: ["Authorization": "Bearer \(token)"])
        return try decode(data)
    }

    // MARK: - Availability

    func usernameAvailable(_ username: String) async throws -> ClarivaAvailabilityResponse {
        let data = try await perform("GET", path: ["v1", "auth", "username-available"], query: ["username": username], body: nil)
        return try decode(data)
    }

    func emailAvailable(_ email: String) async throws -> ClarivaAvailabilityResponse {
        let data = try await perform("GET", path: ["v1", "auth", "email-available"], query: ["email": email], body: nil)
        return try decode(data)
    }

    // MARK: - Password reset

    /// Any 2xx is success (the server always answers `{ ok: true }`, it never reveals whether the email exists).
    func forgotPassword(_ request: ClarivaForgotPasswordRequest) async throws {
        _ = try await perform("POST", path: ["v1", "auth", "forgot-password"], query: [:], body: encode(request))
    }

    func resetPassword(_ request: ClarivaResetPasswordRequest) async throws {
        _ = try await perform("POST", path: ["v1", "auth", "reset-password"], query: [:], body: encode(request))
    }

    // MARK: - Deactivation

    func reauthMethod(matrixUserID: String) async throws -> ClarivaReauthMethodResponse {
        let data = try await perform("GET", path: ["v1", "auth", "reauth-method"], query: ["matrixUserId": matrixUserID], body: nil)
        return try decode(data)
    }

    func deactivate(_ request: ClarivaDeactivateRequest) async throws -> ClarivaDeactivateResponse {
        try await send("POST", path: ["v1", "auth", "deactivate"], body: request)
    }

    // MARK: - Payout bank account

    /// `POST v1/experts/me/bank-details`, authorised by the Clariva JWT: whose account it is comes from
    /// the token, not the body. Any 2xx is success (the masked account it echoes is not needed).
    func saveMyBankDetails(token: String, request: ClarivaBankDetailsRequest) async throws {
        _ = try await perform("POST",
                              path: ["v1", "experts", "me", "bank-details"],
                              query: [:],
                              body: encode(request),
                              headers: ["Authorization": "Bearer \(token)"])
    }

    // MARK: - Internals

    private func send<B: Encodable, T: Decodable>(_ method: String, path: [String], body: B) async throws -> T {
        let data = try await perform(method, path: path, query: [:], body: encode(body))
        return try decode(data)
    }

    private func encode<B: Encodable>(_ body: B) throws -> Data {
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw ClarivaAuthAPIError.decoding(underlying: error)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ClarivaAuthAPIError.decoding(underlying: error)
        }
    }

    private func perform(_ method: String,
                         path: [String],
                         query: [String: String],
                         body: Data?,
                         headers: [String: String] = [:]) async throws -> Data {
        guard let url = makeURL(path: path, query: query) else {
            throw ClarivaAuthAPIError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClarivaAuthAPIError.transport(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClarivaAuthAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ClarivaAuthAPIError.http(status: httpResponse.statusCode, body: data)
        }
        return data
    }

    /// Query values are percent-encoded with a strict (unreserved only) set so that `+`, `&`, `=`,
    /// `@` and `:` (emails, Matrix IDs) survive the round trip.
    private func makeURL(path: [String], query: [String: String]) -> URL? {
        var url = baseURL
        for segment in path {
            url = url.appendingPathComponent(segment)
        }

        guard !query.isEmpty else {
            return url
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.percentEncodedQuery = query
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
        return components.url
    }

    private static let queryAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
