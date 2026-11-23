//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

@testable import ElementX

@MainActor
class DeactivateAccountScreenViewModelTests: XCTestCase {
    var clientProxy: ClientProxyMock!
    var clarivaAuthService: ClarivaAuthServiceStub!
    var viewModel: DeactivateAccountScreenViewModelProtocol!
    
    var context: DeactivateAccountScreenViewModelType.Context {
        viewModel.context
    }
    
    override func setUpWithError() throws {
        clientProxy = ClientProxyMock(.init())
        clarivaAuthService = ClarivaAuthServiceStub()
        viewModel = DeactivateAccountScreenViewModel(clientProxy: clientProxy,
                                                     userIndicatorController: UserIndicatorControllerMock(),
                                                     clarivaAuthService: clarivaAuthService)
    }
    
    func testDeactivate() async throws {
        try await validateDeactivate(erasingData: false)
    }
    
    func testDeactivateAndErase() async throws {
        try await validateDeactivate(erasingData: true)
    }
    
    func validateDeactivate(erasingData shouldErase: Bool) async throws {
        let enteredPassword = UUID().uuidString
        
        // Wait for the re-authentication method (password) to be loaded.
        let deferredMethod = deferFulfillment(context.observe(\.viewState.isGoogleAccount)) { $0 == false }
        try await deferredMethod.fulfill()
        
        context.eraseData = shouldErase
        context.password = enteredPassword
        
        XCTAssertNil(context.alertInfo)
        XCTAssertTrue(context.viewState.canSubmit)
        
        let deferredState = deferFulfillment(context.observe(\.viewState.bindings.alertInfo)) { $0 != nil }
        context.send(viewAction: .deactivate)
        try await deferredState.fulfill()
        
        guard let confirmationAction = context.alertInfo?.primaryButton.action else {
            XCTFail("Couldn't find the confirmation action.")
            return
        }
        
        let deferredAction = deferFulfillment(viewModel.actionsPublisher) { $0 == .accountDeactivated }
        confirmationAction()
        try await deferredAction.fulfill()
        
        XCTAssertEqual(clarivaAuthService.deactivateInvocations.count, 1)
        XCTAssertEqual(clarivaAuthService.deactivateInvocations.first?.matrixUserID, clientProxy.userID)
        XCTAssertEqual(clarivaAuthService.deactivateInvocations.first?.password, enteredPassword)
        XCTAssertNil(clarivaAuthService.deactivateInvocations.first?.googleIDToken)
        XCTAssertNil(clarivaAuthService.deactivateInvocations.first?.appleIDToken)
        XCTAssertEqual(clarivaAuthService.deactivateInvocations.first?.eraseData, shouldErase)
    }

    func testDeactivateAccountMadeWithApple() async throws {
        clarivaAuthService.isGoogleAccountValue = true
        viewModel = DeactivateAccountScreenViewModel(clientProxy: clientProxy,
                                                     userIndicatorController: UserIndicatorControllerMock(),
                                                     clarivaAuthService: clarivaAuthService)

        // No password: the account must re-authorise with Google or Apple first.
        let deferredMethod = deferFulfillment(context.observe(\.viewState.isGoogleAccount)) { $0 == true }
        try await deferredMethod.fulfill()
        XCTAssertFalse(context.viewState.canSubmit)

        context.send(viewAction: .authorizedWithApple(.cancelled))
        XCTAssertFalse(context.viewState.canSubmit)

        context.send(viewAction: .authorizedWithApple(.success(identityToken: "apple-identity-token", name: nil)))
        XCTAssertTrue(context.viewState.canSubmit)
        XCTAssertEqual(context.viewState.authorizedProvider, "Apple")

        let deferredState = deferFulfillment(context.observe(\.viewState.bindings.alertInfo)) { $0 != nil }
        context.send(viewAction: .deactivate)
        try await deferredState.fulfill()

        let deferredAction = deferFulfillment(viewModel.actionsPublisher) { $0 == .accountDeactivated }
        context.alertInfo?.primaryButton.action?()
        try await deferredAction.fulfill()

        XCTAssertEqual(clarivaAuthService.deactivateInvocations.first?.appleIDToken, "apple-identity-token")
        XCTAssertNil(clarivaAuthService.deactivateInvocations.first?.googleIDToken)
        XCTAssertNil(clarivaAuthService.deactivateInvocations.first?.password)
    }
}

/// A minimal hand-written stand-in for the Clariva account API.
@MainActor
class ClarivaAuthServiceStub: ClarivaAuthServiceProtocol {
    struct DeactivateInvocation {
        let matrixUserID: String
        let password: String?
        let googleIDToken: String?
        let appleIDToken: String?
        let eraseData: Bool
    }
    
    var isGoogleAccountValue: Bool? = false
    var deactivateResult: Result<Void, ClarivaAuthError> = .success(())
    private(set) var deactivateInvocations: [DeactivateInvocation] = []
    
    func signUp(email: String, password: String, name: String, username: String, isConsultant: Bool) async -> Result<ClarivaCredentials, ClarivaAuthError> {
        .failure(ClarivaAuthError(message: "Not implemented"))
    }
    
    func signIn(identifier: String, password: String) async -> Result<ClarivaCredentials, ClarivaAuthError> {
        .failure(ClarivaAuthError(message: "Not implemented"))
    }
    
    func signInWithGoogle(idToken: String, isConsultant: Bool?, isSignUp: Bool) async -> Result<ClarivaGoogleOutcome, ClarivaAuthError> {
        .failure(ClarivaAuthError(message: "Not implemented"))
    }
    
    func signInWithApple(identityToken: String, name: String?, isConsultant: Bool?, isSignUp: Bool) async -> Result<ClarivaGoogleOutcome, ClarivaAuthError> {
        .failure(ClarivaAuthError(message: "Not implemented"))
    }
    
    func isUsernameAvailable(_ username: String) async -> Bool? {
        nil
    }
    
    func isEmailAvailable(_ email: String) async -> Bool? {
        nil
    }
    
    func requestPasswordReset(email: String) async -> Result<Void, ClarivaAuthError> {
        .success(())
    }
    
    func resetPassword(email: String, code: String, newPassword: String) async -> Result<Void, ClarivaAuthError> {
        .success(())
    }
    
    func isGoogleAccount(matrixUserID: String) async -> Bool? {
        isGoogleAccountValue
    }
    
    func deactivate(matrixUserID: String, password: String?, googleIDToken: String?, appleIDToken: String?, eraseData: Bool) async -> Result<Void, ClarivaAuthError> {
        deactivateInvocations.append(DeactivateInvocation(matrixUserID: matrixUserID,
                                                          password: password,
                                                          googleIDToken: googleIDToken,
                                                          appleIDToken: appleIDToken,
                                                          eraseData: eraseData))
        return deactivateResult
    }
    
    func saveMyBankDetails(_ request: ClarivaBankDetailsRequest) async -> Result<Void, ClarivaAuthError> {
        .success(())
    }
}
