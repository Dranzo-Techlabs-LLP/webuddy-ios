//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct MyQRCodeScreenCoordinatorParameters {
    let userSession: UserSessionProtocol
}

final class MyQRCodeScreenCoordinator: CoordinatorProtocol {
    private let viewModel: MyQRCodeScreenViewModelProtocol

    init(parameters: MyQRCodeScreenCoordinatorParameters) {
        viewModel = MyQRCodeScreenViewModel(userSession: parameters.userSession)
    }

    func toPresentable() -> AnyView {
        AnyView(MyQRCodeScreen(context: viewModel.context))
    }
}
