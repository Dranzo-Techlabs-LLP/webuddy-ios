//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// `https://clarivahub.com/u/<percent-encoded MXID>` — the payload of "My QR code" and the target
/// of the Clariva universal link. Byte-identical to Android (`CLARIVA_USER_LINK_PREFIX +
/// Uri.encode(userId)`), and parsed with the same rules as Android's `parseClarivaUserLink`.
enum ClarivaUserLink {
    static let host = "clarivahub.com"
    static let prefix = "https://clarivahub.com/u/"

    /// The unreserved set of `android.net.Uri.encode`, so both platforms produce the same QR code.
    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-!.~'()*")

    static func url(for userID: String) -> URL? {
        guard let encoded = userID.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: prefix + encoded)
    }

    /// Exact host match (no `www.`, no `matrix.`), scheme not checked, first path segment `u`,
    /// second segment a (percent-decoded) Matrix user ID. Extra segments are ignored.
    static func userID(from url: URL) -> String? {
        guard url.host?.lowercased() == host else {
            return nil
        }
        let segments = url.pathComponents.filter { $0 != "/" } // already percent-decoded
        guard segments.count >= 2, segments[0] == "u" else {
            return nil
        }
        let candidate = segments[1]
        guard candidate.hasPrefix("@"), candidate.contains(":") else {
            return nil
        }
        return candidate
    }

    static func userID(from text: String) -> String? {
        URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap(userID(from:))
    }
}
