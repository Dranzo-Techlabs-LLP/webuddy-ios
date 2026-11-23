//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Minimal client for the Matrix presence API (`/_matrix/client/v3/presence/{userId}/status`).
/// Mirrors Android `MatrixPresenceService` (ee053dc156).
///
/// The Rust SDK bindings expose no presence API, and simplified sliding sync never marks anyone
/// online, so Clariva publishes its own presence explicitly (see `ClarivaPresenceHeartbeat`) and
/// reads a DM partner's presence on demand. Everything is best effort: failures return false / nil.
///
/// The homeserver URL and access token come from the session's restoration token in the keychain,
/// which the SDK's session delegate keeps up to date when tokens are refreshed (Android reads its
/// `SessionStore` the same way).
struct MatrixPresenceService {
    struct Credentials {
        let homeserverURL: String
        let accessToken: String
    }

    typealias CredentialsProvider = (_ userID: String) -> Credentials?

    private let credentialsProvider: CredentialsProvider
    private let session: URLSession
    private let timeout: TimeInterval

    init(credentialsProvider: @escaping CredentialsProvider, session: URLSession = .shared, timeout: TimeInterval = 15) {
        self.credentialsProvider = credentialsProvider
        self.session = session
        self.timeout = timeout
    }

    /// Reads the signed-in sessions from the app's keychain.
    static func keychainBacked() -> MatrixPresenceService {
        let keychainController = KeychainController(service: .sessions,
                                                    accessGroup: InfoPlistReader.main.keychainAccessGroupIdentifier)
        return MatrixPresenceService { userID in
            guard let session = keychainController.restorationTokenForUsername(userID)?.session else {
                return nil
            }
            return Credentials(homeserverURL: session.homeserverUrl, accessToken: session.accessToken)
        }
    }

    /// Publishes the presence of the account `userID`. Returns true when the server accepted it.
    @discardableResult
    func setPresence(userID: String, online: Bool) async -> Bool {
        guard var request = makeRequest(sessionUserID: userID, targetUserID: userID),
              let body = try? JSONEncoder().encode(SetPresenceBody(presence: online ? Self.online : Self.offline)) else {
            return false
        }
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return await run(request) != nil
    }

    /// Reads `userID`'s presence as seen by the account `viewerID`, or nil when unavailable.
    func getPresence(viewerID: String, userID: String) async -> UserPresence? {
        guard var request = makeRequest(sessionUserID: viewerID, targetUserID: userID) else {
            return nil
        }
        request.httpMethod = "GET"
        guard let response = await run(request),
              let status = try? JSONDecoder().decode(PresenceStatus.self, from: response.data) else {
            return nil
        }
        return UserPresence(isOnline: status.presence == Self.online,
                            lastActiveDate: status.lastActiveAgo.map { response.receivedAt.addingTimeInterval(-Double($0) / 1000) })
    }

    // MARK: - Private

    private static let online = "online"
    private static let offline = "offline"

    private func makeRequest(sessionUserID: String, targetUserID: String) -> URLRequest? {
        guard let credentials = credentialsProvider(sessionUserID),
              let encodedUserID = targetUserID.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) else {
            return nil
        }
        let base = credentials.homeserverURL.hasSuffix("/") ? String(credentials.homeserverURL.dropLast()) : credentials.homeserverURL
        guard let url = URL(string: "\(base)/_matrix/client/v3/presence/\(encodedUserID)/status") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Runs `request`; returns the body and the local time the response arrived, nil on any failure.
    /// Never logs the request: it carries the Matrix access token.
    private func run(_ request: URLRequest) async -> (data: Data, receivedAt: Date)? {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard (200..<300).contains(http.statusCode) else {
                // 403 = no shared room; also returned for PUT while presence is disabled server-side.
                MXLog.debug("[Presence] \(request.httpMethod ?? "") returned HTTP \(http.statusCode)")
                return nil
            }
            return (data, Date())
        } catch {
            if !Task.isCancelled {
                MXLog.debug("[Presence] \(request.httpMethod ?? "") failed: \(error.localizedDescription)")
            }
            return nil
        }
    }

    /// RFC 3986 pchar minus `/` (so a user ID can't add segments).
    private static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#")
        return set
    }()
}

private struct SetPresenceBody: Encodable {
    let presence: String
}

private struct PresenceStatus: Decodable {
    let presence: String?
    /// Milliseconds since the user's last activity.
    let lastActiveAgo: Int64?

    enum CodingKeys: String, CodingKey {
        case presence
        case lastActiveAgo = "last_active_ago"
    }
}
