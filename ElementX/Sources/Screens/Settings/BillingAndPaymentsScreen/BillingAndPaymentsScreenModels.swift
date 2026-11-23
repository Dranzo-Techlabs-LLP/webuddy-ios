//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum BillingAndPaymentsScreenViewModelAction {
    case bankDetails
}

enum BillingAndPaymentsScreenSaveResult {
    case saved
    case failed
}

struct BillingAndPaymentsScreenViewState: BindableState {
    /// `nil` until the wallet has been loaded for the first time (a spinner is shown instead of the field).
    var maxCredits: Int?
    /// The last value accepted by the server (Android `originalMaxCredits ?: maxCredits`).
    var savedMaxCredits: Int?
    /// The text in the Max Credits field: empty or digits only.
    var maxCreditsInput = ""
    var isSaving = false
    var saveResult: BillingAndPaymentsScreenSaveResult?

    var savedMaxCreditsString: String {
        savedMaxCredits.map(String.init) ?? ""
    }

    /// Save / Cancel are only shown while there is an unsaved change.
    var hasChanges: Bool {
        !maxCreditsInput.isEmpty && maxCreditsInput != savedMaxCreditsString
    }
}

enum BillingAndPaymentsScreenViewAction {
    case updateMaxCreditsInput(String)
    case save
    case cancel
    case bankDetails
}
