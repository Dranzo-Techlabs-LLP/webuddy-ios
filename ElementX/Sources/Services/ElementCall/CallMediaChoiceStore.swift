//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Hands a call's media choice (voice = start with the camera off) from where the call is started
/// or answered — the room screen's Voice/Video chooser, the CallKit answer action — to where the
/// Element Call configuration is built (`UserSessionFlowCoordinator.presentCallScreen`), without
/// threading it through every flow coordinator's `presentCallScreen` action.
///
/// No entry for a room means "no explicit choice" (Join on an ongoing call, Room details, Recents…):
/// the call screen then resolves the type from the Wallet API record like Android does.
@MainActor
final class CallMediaChoiceStore {
    static let shared = CallMediaChoiceStore()

    private var startWithVideoMuted: [String: Bool] = [:]

    func setStartWithVideoMuted(_ muted: Bool, for roomID: String) {
        startWithVideoMuted[roomID] = muted
    }

    /// Returns and clears the pending choice for `roomID`.
    func consumeStartWithVideoMuted(for roomID: String) -> Bool? {
        startWithVideoMuted.removeValue(forKey: roomID)
    }
}
