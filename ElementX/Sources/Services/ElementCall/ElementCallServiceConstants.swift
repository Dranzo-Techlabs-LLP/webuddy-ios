//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum ElementCallServiceNotificationKey: String {
    case roomID
    case roomDisplayName
    /// When an incoming call is set to ring, there will be a `m.rtc.notification`event  (MSC4075).
    /// Keep the notification event id as it is needed to decline calls (MSC4310).
    case rtcNotifyEventID
    /// The Date at which the incoming call should stop ringing.
    case expirationDate
    /// Clariva: whether the caller chose a video call (`Bool`), resolved by the NSE from the Wallet
    /// API call-type record. Missing when the type is unknown, in which case the app looks it up.
    case isVideo
}

let ElementCallServiceNotificationDiscardDelta = 15.0
