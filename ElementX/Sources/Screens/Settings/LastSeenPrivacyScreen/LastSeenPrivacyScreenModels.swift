//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

struct LastSeenPrivacyScreenViewState: BindableState {
    var privacy = PresencePrivacy()
    /// People with a DM both have joined, offered by "My contacts except..."; nil while loading.
    var contacts: [UserProfileProxy]?
    
    var bindings = LastSeenPrivacyScreenViewStateBindings()
    
    /// "No contacts excluded" / "1 contact excluded" / "N contacts excluded".
    var excludedSummary: String {
        switch privacy.lastSeenExcept.count {
        case 0:
            "No contacts excluded"
        case 1:
            "1 contact excluded"
        case let count:
            "\(count) contacts excluded"
        }
    }
}

struct LastSeenPrivacyScreenViewStateBindings {
    var alertInfo: AlertInfo<LastSeenPrivacyScreenAlertType>?
    /// The "My contacts except..." picker while it is shown, with the selection being edited.
    var exceptionsPicker: LastSeenExceptionsPickerState?
}

/// A fresh selection each time the picker opens, starting from what is saved.
struct LastSeenExceptionsPickerState: Identifiable {
    let id = UUID()
    var excludedUserIDs: Set<String>
}

enum LastSeenPrivacyScreenAlertType: Hashable {
    case saveFailed
}

enum LastSeenPrivacyScreenViewAction {
    /// Picking "My contacts except..." opens the contact picker instead of saving straight away.
    case setLastSeenAudience(LastSeenAudience)
    case setOnlineAudience(OnlineAudience)
    case toggleException(userID: String)
    case saveExceptions
    /// Back / Cancel from the picker: nothing is saved.
    case cancelExceptions
}

extension LastSeenAudience {
    var title: String {
        switch self {
        case .everyone:
            "Everyone"
        case .myContacts:
            "My contacts"
        case .myContactsExcept:
            "My contacts except..."
        case .nobody:
            "Nobody"
        }
    }
}

extension OnlineAudience {
    var title: String {
        switch self {
        case .everyone:
            "Everyone"
        case .sameAsLastSeen:
            "Same as last seen"
        }
    }
}
