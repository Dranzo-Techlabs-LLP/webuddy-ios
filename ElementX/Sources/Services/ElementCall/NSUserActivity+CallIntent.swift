//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Intents

/// A call requested by the system (e.g. a redial from the Phone app's Recents).
struct CallIntentRequest {
    let roomID: String
    /// `true` for a voice call, `false` for a video call, `nil` when the intent doesn't say.
    let startWithVideoMuted: Bool?
}

extension NSUserActivity {
    /// `INStartVideoCallIntent` is to be replaced with `INStartCallIntent` but calls from Recents
    /// still send it ¯\_(ツ)_/¯
    /// Clariva: voice calls are reported to CallKit as audio calls, so their Recents redial comes as an
    /// audio `INStartCallIntent` (or the legacy `INStartAudioCallIntent`) and must start camera-off.
    var callIntentRequest: CallIntentRequest? {
        let intent = interaction?.intent
        let contacts: [INPerson]?
        let startWithVideoMuted: Bool?

        if let intent = intent as? INStartCallIntent {
            contacts = intent.contacts
            switch intent.callCapability {
            case .audioCall:
                startWithVideoMuted = true
            case .videoCall:
                startWithVideoMuted = false
            default:
                startWithVideoMuted = nil
            }
        } else if let intent = intent as? INStartVideoCallIntent {
            contacts = intent.contacts
            startWithVideoMuted = false
        } else if let intent = intent as? INStartAudioCallIntent {
            contacts = intent.contacts
            startWithVideoMuted = true
        } else {
            return nil
        }

        guard let roomID = contacts?.first?.personHandle?.value else {
            return nil
        }

        return CallIntentRequest(roomID: roomID, startWithVideoMuted: startWithVideoMuted)
    }
}
