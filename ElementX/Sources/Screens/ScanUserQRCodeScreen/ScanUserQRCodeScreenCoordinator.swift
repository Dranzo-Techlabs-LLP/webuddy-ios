//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct ScanUserQRCodeScreenCoordinatorParameters {
    let appMediator: AppMediatorProtocol
}

enum ScanUserQRCodeScreenCoordinatorAction: CustomStringConvertible {
    case userScanned(userID: String)

    var description: String {
        switch self {
        case .userScanned: "userScanned" // Don't log the user ID.
        }
    }
}

final class ScanUserQRCodeScreenCoordinator: CoordinatorProtocol {
    private let viewModel: ScanUserQRCodeScreenViewModelProtocol

    private var cancellables = Set<AnyCancellable>()

    private let actionsSubject: PassthroughSubject<ScanUserQRCodeScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<ScanUserQRCodeScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: ScanUserQRCodeScreenCoordinatorParameters) {
        viewModel = ScanUserQRCodeScreenViewModel(appMediator: parameters.appMediator)

        viewModel.actionsPublisher.sink { [weak self] action in
            MXLog.info("Coordinator: received view model action: \(action)")

            guard let self else { return }
            switch action {
            case .userScanned(let userID):
                actionsSubject.send(.userScanned(userID: userID))
            }
        }
        .store(in: &cancellables)
    }

    func toPresentable() -> AnyView {
        AnyView(ScanUserQRCodeScreen(context: viewModel.context))
    }
}
