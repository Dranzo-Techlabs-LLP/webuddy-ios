//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Clariva deployment constants. Mirrors Android `ClarivaConfig` + `OnBoardingConfig` so both
/// clients talk to the same hosts. Foundation-only so it can also be compiled into the NSE.
enum ClarivaConfig {
    // MARK: - Clariva API (auth + wallet share one host, as on Android's WalletModule)

    /// Moved from wallet.dranzo.com (Android cfdce60c15 / Wallet-API 44e1449).
    static let productionAPIBaseURL = URL(string: "https://wallet.clarivahub.com/")!
    /// Simulator → host Mac. The ATS exception for `localhost` already exists in Info.plist.
    static let localAPIBaseURL = URL(string: "http://localhost:3000/")!
    static let apiBaseURL = productionAPIBaseURL

    // MARK: - Matrix

    /// Used for discovery (`/.well-known/matrix/client` points at `matrixHomeserverURL`).
    static let homeserverAddress = "https://clarivahub.com"
    /// Client-Server API base of the imported Clariva sessions.
    static let matrixHomeserverURL = "https://matrix.clarivahub.com"
    static let accountProvider = "clarivahub.com"
    static let allowedHomeserverHosts: Set<String> = ["clarivahub.com", "matrix.clarivahub.com"]

    /// Exact host match (no prefix/contains checks), so `clarivahub.com.attacker.net` and
    /// `https://clarivahub.com@attacker.net/` are both rejected. Mirrors Android's
    /// `DefaultEnterpriseService.isAllowedToConnectToHomeserver`.
    static func isAllowedHomeserver(_ address: String) -> Bool {
        let candidate = address.contains("://") ? address : "https://\(address)"
        guard let host = URLComponents(string: candidate)?.host?.lowercased() else {
            return false
        }
        return allowedHomeserverHosts.contains(host)
    }

    // MARK: - Google Sign-In

    /// Web/server OAuth client (GCP project 462109274571). ID tokens are requested for this
    /// audience so the Clariva API accepts them exactly as it does Android's.
    static let googleServerClientID = "462109274571-5qsno88m3vu5gijggbvccej3v8tt1qbe.apps.googleusercontent.com"
    /// iOS-type OAuth client, created in the same GCP project as the web client. Set it with
    /// `GOOGLE_IOS_CLIENT_NUMBER` in app.yml, which also registers its reversed form as the OAuth
    /// redirect URL scheme. Empty = Google sign-in disabled in this build.
    static let googleIOSClientID: String = {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !clientID.hasPrefix("."), // `GOOGLE_IOS_CLIENT_NUMBER` left empty
              !clientID.contains("$("), // unexpanded build setting
              clientID.hasSuffix(".apps.googleusercontent.com") else {
            return ""
        }
        return clientID
    }()
    static var isGoogleSignInConfigured: Bool {
        !googleIOSClientID.isEmpty
    }

    // MARK: - Network

    /// Android's OkHttp read/write timeout.
    static let requestTimeout: TimeInterval = 60
}

// MARK: - Group rooms

extension ClarivaConfig {
    /// Group rooms (and spaces) are not part of Clariva yet (Android `GROUP_ROOMS_ENABLED`, ee053dc156).
    /// False hides the "Rooms" chat-list filter, the "New room", "Join room by address" and room
    /// directory entries of Start chat, and the Spaces tab. 1:1 chats are unaffected, and group rooms
    /// a user is already in keep appearing in the chat list. Set to true to bring the room features back.
    static let groupRoomsEnabled = false
}
