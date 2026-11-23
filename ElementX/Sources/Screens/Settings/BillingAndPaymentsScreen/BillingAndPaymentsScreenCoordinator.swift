//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct BillingAndPaymentsScreenCoordinatorParameters {
    let userID: String
    let wallet: WalletService
}

enum BillingAndPaymentsScreenCoordinatorAction {
    case bankDetails
}

final class BillingAndPaymentsScreenCoordinator: CoordinatorProtocol {
    private let viewModel: BillingAndPaymentsScreenViewModelProtocol

    private var cancellables = Set<AnyCancellable>()

    private let actionsSubject: PassthroughSubject<BillingAndPaymentsScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<BillingAndPaymentsScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: BillingAndPaymentsScreenCoordinatorParameters) {
        viewModel = BillingAndPaymentsScreenViewModel(userID: parameters.userID, wallet: parameters.wallet)

        viewModel.actionsPublisher.sink { [weak self] action in
            MXLog.info("Coordinator: received view model action: \(action)")

            guard let self else { return }
            switch action {
            case .bankDetails:
                actionsSubject.send(.bankDetails)
            }
        }
        .store(in: &cancellables)
    }

    func toPresentable() -> AnyView {
        AnyView(BillingAndPaymentsScreen(context: viewModel.context))
    }
}
