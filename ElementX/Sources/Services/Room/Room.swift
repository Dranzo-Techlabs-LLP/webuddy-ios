//
// Copyright 2025 Element Creations Ltd.
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import MatrixRustSDK

extension RoomProtocol {
    /// The Element Call intent to use when opening a call in this room.
    ///
    /// Clariva (Android `DefaultCallWidgetSettingsProvider` parity): a voice call in a DM uses the
    /// `*DmVoice` intents, from which Element Call derives a camera-off start. They only exist for
    /// DMs, so a voice call in any other room falls back to the normal intent.
    /// - Parameter startWithVideoMuted: `true` for a voice call (camera off).
    func joinCallIntent(startWithVideoMuted: Bool) async -> Intent {
        switch await (hasActiveRoomCall(), isDirect()) {
        case (true, true):
            return startWithVideoMuted ? .joinExistingDmVoice : .joinExistingDm
        case (true, false):
            return .joinExisting
        case (false, true):
            return startWithVideoMuted ? .startCallDmVoice : .startCallDm
        case (false, false):
            return .startCall
        }
    }
}
