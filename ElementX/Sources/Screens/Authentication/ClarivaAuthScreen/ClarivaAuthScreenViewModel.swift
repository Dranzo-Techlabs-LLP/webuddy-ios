//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias ClarivaAuthScreenViewModelType = StateStoreViewModelV2<ClarivaAuthScreenViewState, ClarivaAuthScreenViewAction>

/// Clariva account sign-up / sign-in (the app's landing page). Mirrors Android's `ClarivaAuthPresenter`.
///
/// The user never sees a Matrix password: we authenticate against the Clariva API, exchange the
/// resulting JWT for a Matrix access token and import that as a session.
class ClarivaAuthScreenViewModel: ClarivaAuthScreenViewModelType, ClarivaAuthScreenViewModelProtocol {
    private let authenticationService: AuthenticationServiceProtocol
    private let clarivaAuthService: ClarivaAuthServiceProtocol
    private let googleSignInService: GoogleSignInServiceProtocol
    private let walletService: WalletService?
    private let ifscLookup: IfscLookupProtocol
    /// App-wide, so the notice about an unsaved payout setup shows on the home screen after sign-up.
    private let userIndicatorController: UserIndicatorControllerProtocol?
    private let canReportProblem: Bool

    /// Homeserver discovery is independent of the credentials, so it is pre-warmed as soon as the
    /// screen opens. Consumed exactly once (see `importSession`).
    private var prewarmTask: Task<Result<Void, AuthenticationServiceError>, Never>?

    // periphery:ignore - auto cancels when reassigned
    @CancellableTask private var usernameCheckTask: Task<Void, Never>?
    // periphery:ignore - auto cancels when reassigned
    @CancellableTask private var emailCheckTask: Task<Void, Never>?
    /// The (mode, normalized value) last checked, so case-only edits don't re-query.
    private var usernameCheckKey: String?
    private var emailCheckKey: String?

    // periphery:ignore - auto cancels when reassigned
    @CancellableTask private var ifscLookupTask: Task<Void, Never>?
    /// The normalized IFSC last looked up (or cleared), so unrelated edits don't re-query.
    private var ifscLookupKey = ""
    /// What the last lookup filled in, so a new IFSC can replace it but never a value the user typed.
    private var ifscAutofill: IfscBranch?

    private static let genericErrorMessage = "Something went wrong. Please try again."
    /// Per call; the chat rate and bank account are saved in parallel, so sign-in waits 10 s at most.
    private static let consultantSetupTimeout: Duration = .seconds(10)
    /// About as long as Android's `SnackbarDuration.Long`.
    private static let setupNoticeDuration: Duration = .seconds(10)
    private static let setupNoticeIndicatorID = "ClarivaSignUpSetupNotice"

    private var actionsSubject: PassthroughSubject<ClarivaAuthScreenViewModelAction, Never> = .init()
    var actions: AnyPublisher<ClarivaAuthScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(authenticationService: AuthenticationServiceProtocol,
         clarivaAuthService: ClarivaAuthServiceProtocol,
         googleSignInService: GoogleSignInServiceProtocol,
         walletService: WalletService?,
         ifscLookup: IfscLookupProtocol,
         userIndicatorController: UserIndicatorControllerProtocol?,
         isBugReportServiceEnabled: Bool,
         appSettings: AppSettings) {
        self.authenticationService = authenticationService
        self.clarivaAuthService = clarivaAuthService
        self.googleSignInService = googleSignInService
        self.walletService = walletService
        self.ifscLookup = ifscLookup
        self.userIndicatorController = userIndicatorController
        canReportProblem = isBugReportServiceEnabled

        // Let's not deal with snapshotting a changing version string.
        let version = ProcessInfo.isRunningTests ? "0.0.0" : InfoPlistReader.main.bundleShortVersionString

        super.init(initialViewState: ClarivaAuthScreenViewState(isGoogleSignInConfigured: googleSignInService.isConfigured,
                                                                hideBrandChrome: appSettings.hideBrandChrome,
                                                                versionString: version))

        prewarmTask = Task { [authenticationService] in
            await authenticationService.prepareClarivaClient()
        }
    }

    override func process(viewAction: ClarivaAuthScreenViewAction) {
        switch viewAction {
        case .updateWindow(let window):
            guard state.window != window else { return }
            state.window = window

        case .setName(let name):
            state.bindings.name = Self.sanitize(name)
        case .setUsername(let username):
            // Stored exactly as typed; normalization happens at submit time and in the preview.
            state.bindings.username = Self.sanitize(username)
            scheduleUsernameCheck()
        case .setEmail(let email):
            state.bindings.email = Self.sanitize(email).trimmingCharacters(in: .whitespacesAndNewlines)
            scheduleEmailCheck()
        case .setPassword(let password):
            state.bindings.password = Self.sanitize(password)

        case .setConsultantSetupField(let field, let value):
            setConsultantSetupField(field, value: Self.sanitize(value))
        case .skipConsultantSetup:
            // Typed values are dropped: nothing from a skipped setup is ever saved.
            state.consultantSetup = ClarivaConsultantSetupForm(isSkipped: true)
            scheduleIFSCLookup()
        case .resumeConsultantSetup:
            state.consultantSetup.isSkipped = false

        case .submit:
            submit()
        case .toggleMode:
            guard !state.isLoading else { return }
            state.mode = state.mode == .signUp ? .signIn : .signUp
            scheduleUsernameCheck()
            scheduleEmailCheck()

        case .signInWithGoogle:
            signInWithGoogle()
        case .signInWithApple(let result):
            signInWithApple(result)
        case .showGooglePayoutStep:
            state.bindings.googleRolePrompt?.isAskingPayouts = true
            state.bindings.googleRolePrompt?.hasChosenConsultant = true
            // A "Skip for now" left over from the email form must not hide the fields here.
            state.consultantSetup.isSkipped = false
        case .backToGoogleRole:
            state.bindings.googleRolePrompt?.isAskingPayouts = false
        case .confirmGoogleRole(let isConsultant, let skipPayoutSetup):
            confirmGoogleRole(isConsultant: isConsultant, skipPayoutSetup: skipPayoutSetup)
        case .cancelGoogleRole:
            state.bindings.googleRolePrompt = nil
            state.isLoading = false

        case .forgotPasswordOpen:
            guard !state.isLoading else { return }
            // Prefill with whatever email-looking value was already typed.
            let email = state.bindings.email.trimmingCharacters(in: .whitespacesAndNewlines)
            state.bindings.forgotPassword = ClarivaForgotPasswordState(email: email.contains("@") ? email : "")
        case .forgotPasswordDismiss:
            dismissForgotPassword()
        case .forgotPasswordSetEmail(let email):
            state.bindings.forgotPassword?.email = Self.sanitize(email).trimmingCharacters(in: .whitespacesAndNewlines)
            state.bindings.forgotPassword?.error = nil
        case .forgotPasswordSetCode(let code):
            state.bindings.forgotPassword?.code = String(code.filter(ClarivaAuthConstants.isDigit).prefix(6))
            state.bindings.forgotPassword?.error = nil
        case .forgotPasswordSetNewPassword(let password):
            state.bindings.forgotPassword?.newPassword = Self.sanitize(password)
            state.bindings.forgotPassword?.error = nil
        case .forgotPasswordRequestCode:
            requestPasswordResetCode()
        case .forgotPasswordSubmit:
            submitPasswordReset()

        case .reportProblem:
            // Not while signing in: the flow coordinator only accepts the sign-in result from this screen's state.
            if canReportProblem, !state.isLoading {
                actionsSubject.send(.reportProblem)
            }
        }
    }

    // MARK: - Email / username

    private func submit() {
        guard state.submitEnabled else { return }

        let mode = state.mode
        let bindings = state.bindings
        let setupToSave = mode == .signUp && bindings.isConsultant && state.consultantSetup.hasAnythingToSave ? state.consultantSetup : nil
        state.isLoading = true

        Task {
            let result: Result<ClarivaCredentials, ClarivaAuthError>
            switch mode {
            case .signUp:
                result = await clarivaAuthService.signUp(email: bindings.email,
                                                         password: bindings.password,
                                                         name: bindings.name,
                                                         username: bindings.username,
                                                         isConsultant: bindings.isConsultant)
            case .signIn:
                // Holds an email OR a username on the sign-in screen.
                result = await clarivaAuthService.signIn(identifier: bindings.email, password: bindings.password)
            }

            switch result {
            case .success(let credentials):
                // Before the import, while the sign-up JWT is certainly in memory. The account exists
                // either way, so a failure here never blocks signing in.
                var setupNotice: String?
                if let setupToSave {
                    setupNotice = await saveConsultantSetup(setupToSave, matrixUserID: credentials.matrixUserID)
                }
                await importSession(credentials, chosenRole: mode == .signUp ? bindings.isConsultant : nil, setupNotice: setupNotice)
            case .failure(let error):
                showError(error.message)
            }
        }
    }

    // MARK: - Google

    private func signInWithGoogle() {
        guard !state.isLoading else { return }

        guard googleSignInService.isConfigured else {
            showError(GoogleSignInService.notConfiguredMessage)
            return
        }

        guard let presenter = state.window?.rootViewController else {
            MXLog.error("Missing a presentation anchor for Google sign-in.")
            showError(Self.genericErrorMessage)
            return
        }

        // Captured now: the follow-up call must match the screen the user actually used.
        let startedFromSignUp = state.mode == .signUp

        Task {
            switch await googleSignInService.requestIDToken(presenting: presenter) {
            case .cancelled:
                return
            case .failure(let message):
                showError(message)
            case .success(let idToken):
                state.isLoading = true
                // isConsultant = nil: let the server tell us whether the role is still unknown.
                let result = await clarivaAuthService.signInWithGoogle(idToken: idToken, isConsultant: nil, isSignUp: startedFromSignUp)
                await handleGoogleOutcome(result, idToken: idToken, chosenRole: nil, allowRolePrompt: true)
            }
        }
    }

    // MARK: - Apple

    private func signInWithApple(_ result: ClarivaAppleSignInResult) {
        guard !state.isLoading else { return }

        switch result {
        case .cancelled:
            return
        case .failure(let message):
            showError(message)
        case .success(let identityToken, let name):
            // Captured now: the follow-up call must match the screen the user actually used.
            let startedFromSignUp = state.mode == .signUp
            state.isLoading = true
            Task {
                // isConsultant = nil: let the server tell us whether the role is still unknown.
                let result = await clarivaAuthService.signInWithApple(identityToken: identityToken, name: name, isConsultant: nil, isSignUp: startedFromSignUp)
                await handleGoogleOutcome(result, idToken: identityToken, provider: .apple(name: name), chosenRole: nil, allowRolePrompt: true)
            }
        }
    }

    private func confirmGoogleRole(isConsultant: Bool, skipPayoutSetup: Bool) {
        guard let prompt = state.bindings.googleRolePrompt else { return }

        var setupToSave: ClarivaConsultantSetupForm?
        if isConsultant, !skipPayoutSetup {
            // "Continue" is disabled on an invalid setup; never drop it silently.
            guard state.consultantSetup.isValid, !state.ifscStatus.blocksSave else { return }
            setupToSave = state.consultantSetup.hasAnythingToSave ? state.consultantSetup : nil
        }

        state.bindings.googleRolePrompt = nil
        state.isLoading = true

        Task {
            // Never "signup" here: the server already said this identity needs a role, so re-asserting
            // sign-up would reject the very account being finished.
            let result: Result<ClarivaGoogleOutcome, ClarivaAuthError>
            switch prompt.provider {
            case .google:
                result = await clarivaAuthService.signInWithGoogle(idToken: prompt.idToken, isConsultant: isConsultant, isSignUp: false)
            case .apple(let name):
                result = await clarivaAuthService.signInWithApple(identityToken: prompt.idToken, name: name, isConsultant: isConsultant, isSignUp: false)
            }
            await handleGoogleOutcome(result, idToken: prompt.idToken, provider: prompt.provider, chosenRole: isConsultant, allowRolePrompt: false, setupToSave: setupToSave)
        }
    }

    /// `setupToSave` is saved once the account exists, before the import navigates away.
    private func handleGoogleOutcome(_ result: Result<ClarivaGoogleOutcome, ClarivaAuthError>,
                                     idToken: String,
                                     provider: ClarivaGoogleRolePrompt.Provider = .google,
                                     chosenRole: Bool?,
                                     allowRolePrompt: Bool,
                                     setupToSave: ClarivaConsultantSetupForm? = nil) async {
        switch result {
        case .success(.signedIn(let credentials)):
            var setupNotice: String?
            if let setupToSave {
                setupNotice = await saveConsultantSetup(setupToSave, matrixUserID: credentials.matrixUserID)
            }
            await importSession(credentials, chosenRole: chosenRole, setupNotice: setupNotice)
        case .success(.roleRequired(let email, let name, let isExisting)):
            if allowRolePrompt {
                state.isLoading = false
                state.bindings.googleRolePrompt = ClarivaGoogleRolePrompt(provider: provider, idToken: idToken, email: email, name: name, isExisting: isExisting)
            } else {
                // The server already asked once; a second prompt means something is wrong.
                showError(provider == .google ? "Could not complete Google sign-up. Please try again." : "Could not complete Apple sign-up. Please try again.")
            }
        case .failure(let error):
            showError(error.message)
        }
    }

    // MARK: - Session import

    /// Turns Clariva credentials into a live Matrix session. `setupNotice` (an unsaved payout setup) is
    /// shown once the session is up, i.e. over the home screen.
    private func importSession(_ credentials: ClarivaCredentials, chosenRole: Bool?, setupNotice: String? = nil) async {
        // Consume the pre-warm EXACTLY ONCE: preparing rotates (deletes) the previous session
        // directory and the import consumes the client, so any retry must prepare afresh.
        let prewarmed = await prewarmTask?.value
        prewarmTask = nil

        var isPrepared = false
        if let prewarmed, case .success = prewarmed {
            isPrepared = true
        }
        if !isPrepared {
            guard case .success = await authenticationService.prepareClarivaClient() else {
                MXLog.error("Failed preparing the Clariva client.")
                showError(Self.genericErrorMessage)
                return
            }
        }

        switch await authenticationService.importClarivaSession(userID: credentials.matrixUserID,
                                                                deviceID: credentials.deviceID,
                                                                accessToken: credentials.accessToken) {
        case .success(let userSession):
            MXLog.info("Clariva session imported for \(credentials.matrixUserID)")

            // Used by the wallet's create-on-404 fallback so the row gets the right role.
            if let chosenRole {
                walletService?.setPendingIsConsultant(chosenRole)
            }
            if credentials.recoveryPassphrase == nil {
                MXLog.warning("No recovery passphrase from the API; history will be unavailable on this device")
            }

            state.isLoading = false
            actionsSubject.send(.signedIn(userSession: userSession, recoveryPassphrase: credentials.recoveryPassphrase))
            if let setupNotice {
                showSetupNotice(setupNotice)
            }
        case .failure(let error):
            MXLog.error("Failed to import the Clariva session: \(error)")
            showError(Self.genericErrorMessage)
        }
    }

    // MARK: - Consultant setup

    private func setConsultantSetupField(_ field: ClarivaConsultantSetupField, value: String) {
        guard ClarivaConsultantSetupForm.accepts(value, for: field) else {
            // Rejected like Android's onValueChange: re-publish the kept value so the field drops the edit.
            state.consultantSetup = state.consultantSetup
            return
        }
        // Typed values are kept even if the switch goes off, so flipping it back does not lose them;
        // they are only ever saved for a consultant.
        state.consultantSetup = state.consultantSetup.with(field, value)
        if field == .ifscCode {
            scheduleIFSCLookup()
        }
    }

    /// Looks the payout IFSC up once it is well-formed: a code with no branch would only show up as a
    /// failed payout, and a found one fills in the bank and branch.
    private func scheduleIFSCLookup() {
        let normalized = state.consultantSetup.normalizedIFSC
        guard normalized != ifscLookupKey else { return }
        ifscLookupKey = normalized

        guard BankAccountRules.isValidIFSC(normalized) else {
            ifscLookupTask = nil
            state.ifscStatus = .none
            return
        }

        state.ifscStatus = .checking
        ifscLookupTask = Task { [weak self] in
            try? await Task.sleep(for: IfscLookup.debounce)
            guard !Task.isCancelled, let self else { return }

            let status = await ifscLookup.lookup(normalized)
            guard !Task.isCancelled else { return }

            state.ifscStatus = status
            if case .found(let branch) = status {
                applyIFSCAutofill(branch)
            }
        }
    }

    private func applyIFSCAutofill(_ found: IfscBranch) {
        let previous = ifscAutofill
        var setup = state.consultantSetup
        if setup.bankName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || setup.bankName == previous?.bank {
            setup.bankName = found.bank
        }
        if setup.branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || setup.branchName == previous?.branch {
            setup.branchName = found.branch
        }
        state.consultantSetup = setup
        ifscAutofill = found
    }

    /// Saves the optional chat rate and bank account typed at sign-up. Both run together and are
    /// bounded, so a slow API delays sign-in by seconds at most. Failures are not fatal: the user lands
    /// in the app and the returned notice says what to add later in Settings.
    private func saveConsultantSetup(_ setup: ClarivaConsultantSetupForm, matrixUserID: String) async -> String? {
        let maxCredits = setup.maxCreditsValue
        let bankDetails = setup.hasBankDetails ? setup.bankDetailsRequest : nil

        async let rateSaved = saveMaxCredits(maxCredits, matrixUserID: matrixUserID)
        async let bankSaved = saveBankDetails(bankDetails)
        let (isRateSaved, isBankSaved) = await (rateSaved, bankSaved)
        return ClarivaConsultantSetupStrings.failureNotice(rateSaved: isRateSaved, bankSaved: isBankSaved)
    }

    /// true when there was nothing to save.
    private func saveMaxCredits(_ maxCredits: Int?, matrixUserID: String) async -> Bool {
        guard let maxCredits else { return true }
        guard let walletService else { return false }

        let isSaved = await Self.withTimeout(Self.consultantSetupTimeout) {
            switch await walletService.updateMaxCredits(userId: matrixUserID, maxCredits) {
            case .success:
                return true
            case .failure(let error):
                MXLog.warning("Chat rate not saved at sign-up: \(error)")
                return false
            }
        }
        return isSaved == true
    }

    /// true when there was nothing to save.
    private func saveBankDetails(_ request: ClarivaBankDetailsRequest?) async -> Bool {
        guard let request else { return true }

        let clarivaAuthService = clarivaAuthService
        let isSaved = await Self.withTimeout(Self.consultantSetupTimeout) {
            switch await clarivaAuthService.saveMyBankDetails(request) {
            case .success:
                return true
            case .failure(let error):
                MXLog.warning("Bank details not saved at sign-up: \(error.message)")
                return false
            }
        }
        return isSaved == true
    }

    /// nil when `operation` didn't finish within `timeout` (it is then cancelled).
    private static func withTimeout(_ timeout: Duration, _ operation: @escaping @MainActor () async -> Bool) async -> Bool? {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Android posts a long snackbar on the home screen; the app-wide toast is the iOS equivalent.
    private func showSetupNotice(_ message: String) {
        guard let userIndicatorController else { return }
        userIndicatorController.submitIndicator(UserIndicator(id: Self.setupNoticeIndicatorID,
                                                              type: .toast,
                                                              title: message,
                                                              iconName: "exclamationmark.circle",
                                                              persistent: true))
        Task {
            try? await Task.sleep(for: Self.setupNoticeDuration)
            userIndicatorController.retractIndicatorWithId(Self.setupNoticeIndicatorID)
        }
    }

    // MARK: - Availability

    private func scheduleUsernameCheck() {
        let normalized = state.normalizedUsername
        let isWellFormed = state.isUsernameWellFormed
        let isSignUp = state.mode == .signUp

        let key = "\(isSignUp)|\(isWellFormed)|\(normalized)"
        guard key != usernameCheckKey else { return }
        usernameCheckKey = key

        guard isSignUp, isWellFormed else {
            usernameCheckTask = nil
            state.usernameAvailability = .unknown
            return
        }

        state.usernameAvailability = .checking
        usernameCheckTask = Task { [weak self] in
            try? await Task.sleep(for: ClarivaAuthConstants.availabilityDebounce)
            guard !Task.isCancelled, let self else { return }

            let isAvailable = await clarivaAuthService.isUsernameAvailable(normalized)
            guard !Task.isCancelled else { return }

            // A failed check stays quiet rather than wrongly claim the handle is taken.
            state.usernameAvailability = switch isAvailable {
            case .none: .unknown
            case .some(true): .available
            case .some(false): .taken
            }
        }
    }

    private func scheduleEmailCheck() {
        let normalized = state.bindings.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let isWellFormed = ClarivaAuthConstants.isEmailWellFormed(normalized)
        let isSignUp = state.mode == .signUp

        let key = "\(isSignUp)|\(isWellFormed)|\(normalized)"
        guard key != emailCheckKey else { return }
        emailCheckKey = key

        guard isSignUp, isWellFormed else {
            emailCheckTask = nil
            state.emailAvailability = .unknown
            return
        }

        state.emailAvailability = .checking
        emailCheckTask = Task { [weak self] in
            try? await Task.sleep(for: ClarivaAuthConstants.availabilityDebounce)
            guard !Task.isCancelled, let self else { return }

            let isAvailable = await clarivaAuthService.isEmailAvailable(normalized)
            guard !Task.isCancelled else { return }

            state.emailAvailability = switch isAvailable {
            case .none: .unknown
            case .some(true): .available
            case .some(false): .taken
            }
        }
    }

    // MARK: - Forgot password

    private func requestPasswordResetCode() {
        guard let current = state.bindings.forgotPassword, current.sendEnabled else { return }
        state.bindings.forgotPassword?.isLoading = true
        state.bindings.forgotPassword?.error = nil

        Task {
            let result = await clarivaAuthService.requestPasswordReset(email: current.email)
            // Drop the result if the sheet was dismissed meanwhile.
            guard state.bindings.forgotPassword != nil else { return }

            state.bindings.forgotPassword?.isLoading = false
            switch result {
            case .success:
                // Always advance: the server never reveals whether the email exists. A (re)send
                // invalidates earlier codes server-side, so clear any stale one.
                state.bindings.forgotPassword?.step = .enterCode
                state.bindings.forgotPassword?.code = ""
                state.bindings.forgotPassword?.error = nil
            case .failure(let error):
                state.bindings.forgotPassword?.error = error.message
            }
        }
    }

    private func submitPasswordReset() {
        guard let current = state.bindings.forgotPassword, current.resetEnabled else { return }
        state.bindings.forgotPassword?.isLoading = true
        state.bindings.forgotPassword?.error = nil

        Task {
            let result = await clarivaAuthService.resetPassword(email: current.email,
                                                                code: current.code,
                                                                newPassword: current.newPassword)
            guard state.bindings.forgotPassword != nil else { return }

            state.bindings.forgotPassword?.isLoading = false
            switch result {
            case .success:
                state.bindings.forgotPassword?.done = true
                state.bindings.forgotPassword?.error = nil
            case .failure(let error):
                state.bindings.forgotPassword?.error = error.message
            }
        }
    }

    private func dismissForgotPassword() {
        // After a successful reset, drop back to sign-in with the email prefilled so the user only
        // has to type the new password.
        if let forgotPassword = state.bindings.forgotPassword, forgotPassword.done {
            state.mode = .signIn
            state.bindings.email = forgotPassword.email
            state.bindings.password = ""
            scheduleUsernameCheck()
            scheduleEmailCheck()
        }
        state.bindings.forgotPassword = nil
    }

    // MARK: - Helpers

    private func showError(_ message: String?) {
        state.isLoading = false
        state.bindings.alertInfo = AlertInfo(id: .signInFailed,
                                             title: "Sign-in failed",
                                             message: message ?? Self.genericErrorMessage)
    }

    /// Every field strips pasted newlines.
    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: "")
    }
}
