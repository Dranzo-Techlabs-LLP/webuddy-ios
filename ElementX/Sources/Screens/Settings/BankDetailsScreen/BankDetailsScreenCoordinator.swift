//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct BankDetailsScreenCoordinatorParameters {
    let userID: String
    let wallet: WalletService
    let userIndicatorController: UserIndicatorControllerProtocol
}

enum BankDetailsScreenCoordinatorAction {
    case done
}

final class BankDetailsScreenCoordinator: CoordinatorProtocol {
    private let viewModel: BankDetailsScreenViewModelProtocol

    private var cancellables = Set<AnyCancellable>()

    private let actionsSubject: PassthroughSubject<BankDetailsScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<BankDetailsScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: BankDetailsScreenCoordinatorParameters) {
        viewModel = BankDetailsScreenViewModel(userID: parameters.userID,
                                               payoutAccountService: parameters.wallet,
                                               ifscLookup: IfscLookup.shared,
                                               userIndicatorController: parameters.userIndicatorController)

        viewModel.actionsPublisher.sink { [weak self] action in
            MXLog.info("Coordinator: received view model action: \(action)")

            guard let self else { return }
            switch action {
            case .done:
                actionsSubject.send(.done)
            }
        }
        .store(in: &cancellables)
    }

    func toPresentable() -> AnyView {
        AnyView(BankDetailsScreen(context: viewModel.context))
    }
}
