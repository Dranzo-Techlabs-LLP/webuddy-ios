//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// The Matrix access token of a signed-in session, read from the session store (the keychain's
/// restoration token, which the SDK keeps current through `ClientSessionDelegate`). Android:
/// `sessionStore.getSession(userId)?.accessToken`.
///
/// Used as the Bearer token of the wallet routes guarded by `ClarivaUserGuard`: the API checks it
/// with the homeserver (`whoami`), so a caller can only ever reach their own account. Unlike the
/// Clariva JWT, the app always holds this token. Never log it.
enum MatrixSessionAccessToken {
    static func forUser(_ userID: String) -> String? {
        let keychainController = KeychainController(service: .sessions,
                                                    accessGroup: InfoPlistReader.main.keychainAccessGroupIdentifier)
        return keychainController.restorationTokenForUsername(userID)?.session.accessToken
    }
}
