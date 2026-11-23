//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias DeactivateAccountScreenViewModelType = StateStoreViewModelV2<DeactivateAccountScreenViewState, DeactivateAccountScreenViewAction>

/// Clariva: accounts are deactivated through the Clariva API (re-authenticated with the Clariva password
/// or a Google ID token), as Matrix UIA needs a Matrix password that no Clariva user knows.
class DeactivateAccountScreenViewModel: DeactivateAccountScreenViewModelType, DeactivateAccountScreenViewModelProtocol {
    private let clientProxy: ClientProxyProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    private let clarivaAuthService: ClarivaAuthServiceProtocol
    private let googleSignInService: GoogleSignInServiceProtocol

    /// Held in memory only, sent as the deactivation proof for Google accounts.
    private var googleIDToken: String?
    /// Held in memory only, sent as the deactivation proof for accounts made with Apple.
    private var appleIDToken: String?

    private let actionsSubject: PassthroughSubject<DeactivateAccountScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<DeactivateAccountScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    /// The Clariva services default to the shared auth service and a new Google Sign-In service so
    /// that callers (e.g. `SettingsFlowCoordinator`) don't need to provide them.
    init(clientProxy: ClientProxyProtocol,
         userIndicatorController: UserIndicatorControllerProtocol,
         clarivaAuthService: ClarivaAuthServiceProtocol? = nil,
         googleSignInService: GoogleSignInServiceProtocol? = nil) {
        self.clientProxy = clientProxy
        self.userIndicatorController = userIndicatorController

        if let clarivaAuthService {
            self.clarivaAuthService = clarivaAuthService
        } else if let sharedClarivaAuthService = ServiceLocator.shared.clarivaAuth {
            self.clarivaAuthService = sharedClarivaAuthService
        } else {
            self.clarivaAuthService = ClarivaAuthService()
        }

        if let googleSignInService {
            self.googleSignInService = googleSignInService
        } else {
            self.googleSignInService = GoogleSignInService()
        }

        super.init(initialViewState: DeactivateAccountScreenViewState())

        loadReauthenticationMethod()
    }

    override func process(viewAction: DeactivateAccountScreenViewAction) {
        switch viewAction {
        case .deactivate:
            MXLog.info("View model: received view action: deactivate")
            showDeactivationConfirmation()
        case .authorizeWithGoogle:
            MXLog.info("View model: received view action: authorizeWithGoogle")
            authorizeWithGoogle()
        case .authorizedWithApple(let result):
            MXLog.info("View model: received view action: authorizedWithApple")
            switch result {
            case .success(let identityToken, _):
                appleIDToken = identityToken
                googleIDToken = nil
                state.authorizedProvider = "Apple"
                state.hasGoogleToken = true
            case .cancelled:
                break
            case .failure(let message):
                state.bindings.alertInfo = .init(id: .googleAuthorizationFailed, title: L10n.commonError, message: message)
            }
        case .updateWindow(let window):
            guard state.window != window else { return }
            state.window = window
        }
    }

    // MARK: - Private

    private let deactivatingIndicatorID = "\(DeactivateAccountScreenViewModel.self)-Deactivating"

    /// Password field or "Authorise with Google"?
    private func loadReauthenticationMethod() {
        let userID = clientProxy.userID
        Task { [weak self] in
            guard let self else { return }
            let isGoogleAccount = await clarivaAuthService.isGoogleAccount(matrixUserID: userID)
            MXLog.info("Re-authentication method loaded, is Google account: \(String(describing: isGoogleAccount))")
            state.isGoogleAccount = isGoogleAccount
        }
    }

    private func authorizeWithGoogle() {
        guard let presenter = state.window?.rootViewController else {
            MXLog.error("Missing a presentation anchor for Google sign-in.")
            state.bindings.alertInfo = .init(id: .googleAuthorizationFailed,
                                             title: L10n.commonError,
                                             message: GoogleSignInService.genericFailureMessage)
            return
        }

        Task {
            switch await googleSignInService.requestIDToken(presenting: presenter) {
            case .success(let idToken):
                googleIDToken = idToken
                appleIDToken = nil
                state.authorizedProvider = "Google"
                state.hasGoogleToken = true
            case .cancelled:
                break
            case .failure(let message):
                state.bindings.alertInfo = .init(id: .googleAuthorizationFailed,
                                                 title: L10n.commonError,
                                                 message: message)
            }
        }
    }

    func showDeactivationConfirmation() {
        guard state.canSubmit else { return }

        state.bindings.alertInfo = .init(id: .confirmation,
                                         title: L10n.screenDeactivateAccountTitle,
                                         message: L10n.screenDeactivateAccountConfirmationDialogContent,
                                         primaryButton: .init(title: L10n.actionDeactivate) {
                                             Task { await self.deactivateAccount() }
                                         },
                                         secondaryButton: .init(title: L10n.actionCancel, role: .cancel, action: nil))
    }

    func deactivateAccount() async {
        userIndicatorController.submitIndicator(UserIndicator(id: deactivatingIndicatorID,
                                                              type: .modal(progress: .indeterminate, interactiveDismissDisabled: true, allowsInteraction: false),
                                                              title: L10n.commonPleaseWait,
                                                              persistent: true))

        MXLog.warning("Deactivating account.")

        // Exactly one proof is sent.
        let isGoogleAccount = state.isGoogleAccount == true
        switch await clarivaAuthService.deactivate(matrixUserID: clientProxy.userID,
                                                   password: isGoogleAccount ? nil : state.bindings.password,
                                                   googleIDToken: isGoogleAccount ? googleIDToken : nil,
                                                   appleIDToken: isGoogleAccount ? appleIDToken : nil,
                                                   eraseData: state.bindings.eraseData) {
        case .success:
            MXLog.info("Account deactivated.")
            // The settings flow signs out (logout errors are ignored as the token is now invalid).
            actionsSubject.send(.accountDeactivated)
        case .failure(let error):
            MXLog.info("Deactivation failed \(error).")
            userIndicatorController.retractIndicatorWithId(deactivatingIndicatorID)
            state.bindings.alertInfo = .init(id: .deactivationFailed,
                                             title: L10n.screenDeactivateAccountTitle,
                                             message: error.message)
        }
    }
}
