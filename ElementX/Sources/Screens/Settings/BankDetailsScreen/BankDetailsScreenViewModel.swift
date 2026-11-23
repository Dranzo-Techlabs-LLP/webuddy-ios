//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias BankDetailsScreenViewModelType = StateStoreViewModelV2<BankDetailsScreenViewState, BankDetailsScreenViewAction>

/// Settings > Bank Details (Android `BankDetailsPresenter`, 093714e02a): shows the current payout account
/// (last 4 digits only) and replaces it through `v1/experts/me/bank-details`, authorised by the
/// session's Matrix access token. The IFSC is looked up live while typing.
class BankDetailsScreenViewModel: BankDetailsScreenViewModelType, BankDetailsScreenViewModelProtocol {
    private let userID: String
    private let payoutAccountService: PayoutAccountServiceProtocol
    private let ifscLookup: IfscLookupProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol

    // periphery:ignore - auto cancels when reassigned
    @CancellableTask private var loadTask: Task<Void, Never>?
    // periphery:ignore - auto cancels when reassigned
    @CancellableTask private var ifscLookupTask: Task<Void, Never>?
    /// The normalized IFSC last looked up (or cleared), so unrelated edits don't re-query.
    private var ifscLookupKey = ""
    /// What the last lookup filled in, so a new IFSC can replace it but never a value the user typed.
    private var ifscAutofill: IfscBranch?

    private let actionsSubject: PassthroughSubject<BankDetailsScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<BankDetailsScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(userID: String,
         payoutAccountService: PayoutAccountServiceProtocol,
         ifscLookup: IfscLookupProtocol,
         userIndicatorController: UserIndicatorControllerProtocol) {
        self.userID = userID
        self.payoutAccountService = payoutAccountService
        self.ifscLookup = ifscLookup
        self.userIndicatorController = userIndicatorController

        super.init(initialViewState: BankDetailsScreenViewState())

        loadSavedAccount()
    }

    // MARK: - Public

    override func process(viewAction: BankDetailsScreenViewAction) {
        switch viewAction {
        case .setField(let field, let value):
            setField(field, value: value.replacingOccurrences(of: "\n", with: ""))
        case .save:
            Task { await save() }
        case .retryLoad:
            loadSavedAccount()
        }
    }

    // MARK: - Private

    private func loadSavedAccount() {
        state.savedAccount = .loading
        loadTask = Task { [weak self, payoutAccountService, userID] in
            let result = await payoutAccountService.getMyBankDetails(userId: userID)
            guard !Task.isCancelled, let self else { return }

            switch result {
            case .success(let account):
                state.savedAccount = .loaded(account)
            case .failure:
                state.savedAccount = .failed
            }
        }
    }

    private func setField(_ field: BankDetailsField, value: String) {
        guard BankDetailsForm.accepts(value, for: field) else {
            // Rejected like Android's onValueChange: re-publish the kept value so the field drops the edit.
            state.form = state.form
            return
        }
        state.form = state.form.with(field, value)
        if field == .ifscCode {
            scheduleIFSCLookup()
        }
    }

    private func scheduleIFSCLookup() {
        let normalized = BankAccountRules.normalizedIFSC(state.form.ifscCode)
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
            if case .found(let found) = status {
                // Fill in the bank and branch, without overwriting what the user typed.
                var form = state.form
                if form.bankName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || form.bankName == ifscAutofill?.bank {
                    form.bankName = found.bank
                }
                if form.branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || form.branchName == ifscAutofill?.branch {
                    form.branchName = found.branch
                }
                state.form = form
                ifscAutofill = found
            }
        }
    }

    private func save() async {
        guard state.canSave else { return }

        state.isSaving = true
        state.saveError = nil
        defer { state.isSaving = false }

        switch await payoutAccountService.saveMyBankDetails(userId: userID, request: state.form.request) {
        case .success(let saved):
            state.savedAccount = .loaded(saved)
            userIndicatorController.submitIndicator(UserIndicator(title: L10n.commonSavedChanges, iconName: "checkmark"))
            actionsSubject.send(.done)
        case .failure(let error):
            // The values stay in place so the consultant can retry. The API's own reason for a
            // rejected save (e.g. an unknown IFSC), else a generic one.
            state.saveError = (error as? WalletAPIError)?.userMessage ?? BankDetailsScreenViewState.genericSaveError
        }
    }
}
