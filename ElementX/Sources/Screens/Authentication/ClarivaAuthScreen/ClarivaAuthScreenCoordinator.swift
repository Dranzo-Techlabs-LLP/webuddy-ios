//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct ClarivaAuthScreenCoordinatorParameters {
    let authenticationService: AuthenticationServiceProtocol
    let clarivaAuthService: ClarivaAuthServiceProtocol
    let googleSignInService: GoogleSignInServiceProtocol
    /// Receives the role chosen during sign-up (wallet create-on-404 fallback). nil in tests.
    let walletService: WalletService?
    let isBugReportServiceEnabled: Bool
    let appSettings: AppSettings
}

final class ClarivaAuthScreenCoordinator: CoordinatorProtocol {
    private let viewModel: ClarivaAuthScreenViewModelProtocol
    private let actionsSubject: PassthroughSubject<ClarivaAuthScreenCoordinatorAction, Never> = .init()
    private var cancellables = Set<AnyCancellable>()

    var actions: AnyPublisher<ClarivaAuthScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(parameters: ClarivaAuthScreenCoordinatorParameters) {
        viewModel = ClarivaAuthScreenViewModel(authenticationService: parameters.authenticationService,
                                               clarivaAuthService: parameters.clarivaAuthService,
                                               googleSignInService: parameters.googleSignInService,
                                               walletService: parameters.walletService,
                                               ifscLookup: IfscLookup.shared,
                                               // App-wide (the overlay window), so a notice posted at the end of
                                               // sign-up stays visible over the home screen.
                                               userIndicatorController: ServiceLocator.shared.userIndicatorController,
                                               isBugReportServiceEnabled: parameters.isBugReportServiceEnabled,
                                               appSettings: parameters.appSettings)
    }

    // MARK: - Public

    func start() {
        viewModel.actions
            .sink { [weak self] action in
                guard let self else { return }

                switch action {
                case .signedIn(let userSession, let recoveryPassphrase):
                    actionsSubject.send(.signedIn(userSession: userSession, recoveryPassphrase: recoveryPassphrase))
                case .reportProblem:
                    actionsSubject.send(.reportProblem)
                }
            }
            .store(in: &cancellables)
    }

    func toPresentable() -> AnyView {
        AnyView(ClarivaAuthScreen(context: viewModel.context))
    }
}
