//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
@preconcurrency import KeychainAccess

/// Holds the server-derived key-storage passphrase (from `v1/auth/matrix-session`) only until the
/// device has unlocked key storage with it.
///
/// The API hands the passphrase out once, at sign-in. If the unlock is interrupted (the app is
/// killed or crashes, the network drops, the first sync is slow) a memory-only passphrase would be
/// lost and the device would never get history access or self-verify. Keeping it in the keychain —
/// next to the Matrix access token, which is at least as sensitive — lets the next launch resume.
/// Stored this-device-only (never synced to iCloud) and deleted as soon as the unlock finishes or
/// the user signs out.
struct ClarivaRecoveryPassphraseStore {
    private let keychain: Keychain

    init(accessGroup: String = InfoPlistReader.main.keychainAccessGroupIdentifier) {
        keychain = Keychain(service: InfoPlistReader.main.baseBundleIdentifier + ".keychain.clarivaRecoveryPassphrase",
                            accessGroup: accessGroup)
            .accessibility(.afterFirstUnlockThisDeviceOnly)
    }

    func savePassphrase(_ passphrase: String, for userID: String) {
        do {
            try keychain.set(passphrase, key: userID)
        } catch {
            MXLog.error("Failed storing the pending key storage passphrase: \(error)")
        }
    }

    func passphrase(for userID: String) -> String? {
        do {
            return try keychain.getString(userID)
        } catch {
            MXLog.error("Failed reading the pending key storage passphrase: \(error)")
            return nil
        }
    }

    func removePassphrase(for userID: String) {
        do {
            try keychain.remove(userID)
        } catch {
            MXLog.error("Failed removing the pending key storage passphrase: \(error)")
        }
    }
}
