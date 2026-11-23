//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias BillingAndPaymentsScreenViewModelType = StateStoreViewModelV2<BillingAndPaymentsScreenViewState, BillingAndPaymentsScreenViewAction>

/// Consultant-only "Billing and Payments" (Android `BillingAndPaymentsView`): the Max Credits
/// editor with an explicit Save / Cancel and an inline result, plus the entry to Bank Details.
class BillingAndPaymentsScreenViewModel: BillingAndPaymentsScreenViewModelType, BillingAndPaymentsScreenViewModelProtocol {
    private let userID: String
    private let wallet: WalletService

    private let actionsSubject: PassthroughSubject<BillingAndPaymentsScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<BillingAndPaymentsScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(userID: String, wallet: WalletService) {
        self.userID = userID
        self.wallet = wallet

        let savedMaxCredits = wallet.originalMaxCredits ?? wallet.maxCredits
        super.init(initialViewState: BillingAndPaymentsScreenViewState(maxCredits: wallet.maxCredits,
                                                                       savedMaxCredits: savedMaxCredits,
                                                                       maxCreditsInput: savedMaxCredits.map(String.init) ?? ""))

        wallet.$maxCredits
            .combineLatest(wallet.$originalMaxCredits)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] maxCredits, originalMaxCredits in
                self?.walletValuesChanged(maxCredits: maxCredits, originalMaxCredits: originalMaxCredits)
            }
            .store(in: &cancellables)

        // Populates `maxCredits` / `originalMaxCredits` (Android refreshes on screen start too).
        Task { await wallet.refreshBalance(userId: userID) }
    }

    // MARK: - Public

    override func process(viewAction: BillingAndPaymentsScreenViewAction) {
        switch viewAction {
        case .updateMaxCreditsInput(let input):
            updateMaxCreditsInput(input)
        case .save:
            saveMaxCredits()
        case .cancel:
            // Revert to the last saved value.
            state.maxCreditsInput = state.savedMaxCreditsString
            state.saveResult = nil
        case .bankDetails:
            actionsSubject.send(.bankDetails)
        }
    }

    // MARK: - Private

    private func updateMaxCreditsInput(_ input: String) {
        // Android only accepts an empty value or digits.
        let digits = input.filter { $0.isASCII && $0.isNumber }
        let didChange = digits != state.maxCreditsInput
        // Always assign so that a rejected character disappears from the field.
        state.maxCreditsInput = digits

        if didChange {
            // Editing again clears any prior save result.
            state.saveResult = nil
        }
    }

    private func walletValuesChanged(maxCredits: Int?, originalMaxCredits: Int?) {
        // Only follow the wallet while the user isn't editing, so the home screen's balance poll
        // never overwrites a value being typed.
        let isInputUntouched = state.maxCreditsInput == state.savedMaxCreditsString

        state.maxCredits = maxCredits
        state.savedMaxCredits = originalMaxCredits ?? maxCredits

        if isInputUntouched, !state.isSaving {
            state.maxCreditsInput = state.savedMaxCreditsString
        }
    }

    private func saveMaxCredits() {
        // Like Android, a value that doesn't fit in an Int is silently not saved.
        guard !state.isSaving, let value = Int(state.maxCreditsInput) else {
            return
        }

        state.isSaving = true
        state.saveResult = nil

        Task {
            switch await wallet.updateMaxCredits(userId: userID, value) {
            case .success:
                state.maxCredits = value
                state.savedMaxCredits = value
                state.maxCreditsInput = String(value)
                state.saveResult = .saved
            case .failure(let error):
                MXLog.error("[Wallet] Failed saving max credits: \(error)")
                state.saveResult = .failed
            }

            state.isSaving = false
        }
    }
}
