//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

struct LastSeenPrivacyScreenCoordinatorParameters {
    let userSession: UserSessionProtocol
    let profileService: ClarivaProfileService
    let userIndicatorController: UserIndicatorControllerProtocol
}

/// WhatsApp-style "Last seen and online" privacy screen (Android ee053dc156 `LastSeenPrivacyNode`).
final class LastSeenPrivacyScreenCoordinator: CoordinatorProtocol {
    private let viewModel: LastSeenPrivacyScreenViewModelProtocol
    
    init(parameters: LastSeenPrivacyScreenCoordinatorParameters) {
        viewModel = LastSeenPrivacyScreenViewModel(userSession: parameters.userSession,
                                                   profileService: parameters.profileService,
                                                   userIndicatorController: parameters.userIndicatorController)
    }
    
    func toPresentable() -> AnyView {
        AnyView(LastSeenPrivacyScreen(context: viewModel.context))
    }
}
