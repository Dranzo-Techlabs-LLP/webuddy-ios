//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import UIKit

enum DeactivateAccountScreenViewModelAction {
    case accountDeactivated
}

struct DeactivateAccountScreenViewState: BindableState {
    let info: AttributedString
    let infoPoint1: AttributedString
    let infoPoint2 = AttributedString(L10n.screenDeactivateAccountListItem2)
    let infoPoint3 = AttributedString(L10n.screenDeactivateAccountListItem3)
    let infoPoint4 = AttributedString(L10n.screenDeactivateAccountListItem4)
    
    /// Clariva: whether the account re-authenticates with Google (no password) rather than a password.
    /// nil while loading or when the API couldn't tell, in which case deactivation isn't possible.
    var isGoogleAccount: Bool?
    /// Clariva: a fresh Google ID token or Apple identity token is held, proving ownership of an
    /// account without a password (made with Google or Apple).
    var hasGoogleToken = false
    /// Which provider re-authorised: shown in the confirmation row.
    var authorizedProvider = "Google"
    /// The presentation anchor used for Google Sign-In.
    var window: UIWindow?
    
    var bindings = DeactivateAccountScreenViewStateBindings()
    
    /// Exactly one proof is required: a password for an email account, a Google token for a Google one.
    var canSubmit: Bool {
        switch isGoogleAccount {
        case .none:
            false
        case .some(true):
            hasGoogleToken
        case .some(false):
            !bindings.password.isEmpty
        }
    }
    
    init() {
        let boldPlaceholder = "{bold}"
        var attributedString = AttributedString(L10n.screenDeactivateAccountDescription(boldPlaceholder))
        var boldString = AttributedString(L10n.screenDeactivateAccountDescriptionBoldPart)
        boldString.bold()
        attributedString.replace(boldPlaceholder, with: boldString)
        info = attributedString
        
        attributedString = AttributedString(L10n.screenDeactivateAccountListItem1(boldPlaceholder))
        boldString = AttributedString(L10n.screenDeactivateAccountListItem1BoldPart)
        boldString.bold()
        attributedString.replace(boldPlaceholder, with: boldString)
        infoPoint1 = attributedString
    }
}

struct DeactivateAccountScreenViewStateBindings {
    var password = ""
    var eraseData = false
    var alertInfo: AlertInfo<DeactivateAccountScreenAlert>?
}

enum DeactivateAccountScreenAlert {
    case confirmation
    case deactivationFailed
    case googleAuthorizationFailed
}

enum DeactivateAccountScreenViewAction {
    case deactivate
    /// Clariva: re-authorise with Google instead of entering a password.
    case authorizeWithGoogle
    /// Clariva: the outcome of re-authorising with Apple (the button presents the sheet itself).
    case authorizedWithApple(ClarivaAppleSignInResult)
    case updateWindow(UIWindow)
}
