//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum BankDetailsScreenViewModelAction {
    /// The details were saved, the screen should be popped.
    case done
}

/// The account payouts currently go to (Android `AsyncData<SavedBankAccount?>`).
enum BankDetailsSavedAccountState: Equatable {
    case loading
    /// `nil` when none is saved yet.
    case loaded(SavedBankAccount?)
    case failed

    var account: SavedBankAccount? {
        if case .loaded(let account) = self {
            return account
        }
        return nil
    }
}

enum BankDetailsField: Hashable {
    case accountHolderName
    case bankName
    case accountNumber
    case ifscCode
    case branchName
}

/// The replacement payout account being typed. Values are kept exactly as typed and normalised when
/// checked and saved. Mirrors the fields of Android `BankDetailsState`.
struct BankDetailsForm: Equatable {
    var accountHolderName = ""
    var bankName = ""
    var accountNumber = ""
    var ifscCode = ""
    var branchName = ""

    func value(of field: BankDetailsField) -> String {
        switch field {
        case .accountHolderName: accountHolderName
        case .bankName: bankName
        case .accountNumber: accountNumber
        case .ifscCode: ifscCode
        case .branchName: branchName
        }
    }

    func with(_ field: BankDetailsField, _ value: String) -> BankDetailsForm {
        var copy = self
        switch field {
        case .accountHolderName: copy.accountHolderName = value
        case .bankName: copy.bankName = value
        case .accountNumber: copy.accountNumber = value
        case .ifscCode: copy.ifscCode = value
        case .branchName: copy.branchName = value
        }
        return copy
    }

    /// Android's `onValueChange` filters: an edit that fails them is rejected, keeping the old value.
    static func accepts(_ value: String, for field: BankDetailsField) -> Bool {
        switch field {
        case .accountNumber:
            BankAccountRules.acceptsAccountNumberInput(value)
        case .ifscCode:
            BankAccountRules.acceptsIFSCInput(value)
        case .accountHolderName, .bankName, .branchName:
            BankAccountRules.acceptsTextInput(value)
        }
    }

    // Errors only once something is typed, so an empty form does not nag.

    var accountNumberError: String? {
        guard !Self.isBlank(accountNumber), !BankAccountRules.isValidAccountNumber(accountNumber) else { return nil }
        return BankAccountRules.accountNumberError
    }

    var ifscError: String? {
        guard !Self.isBlank(ifscCode), !BankAccountRules.isValidIFSC(ifscCode) else { return nil }
        return BankAccountRules.ifscError
    }

    /// Branch is optional; everything else must be valid.
    var isComplete: Bool {
        BankAccountRules.isValidName(accountHolderName)
            && BankAccountRules.isValidName(bankName)
            && BankAccountRules.isValidAccountNumber(accountNumber)
            && BankAccountRules.isValidIFSC(ifscCode)
    }

    /// Normalised here, not while typing: trimmed, IFSC upper-cased, a blank branch omitted.
    var request: ClarivaBankDetailsRequest {
        let branch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ClarivaBankDetailsRequest(accountHolderName: accountHolderName.trimmingCharacters(in: .whitespacesAndNewlines),
                                         bankName: bankName.trimmingCharacters(in: .whitespacesAndNewlines),
                                         accountNumber: accountNumber.trimmingCharacters(in: .whitespacesAndNewlines),
                                         ifscCode: BankAccountRules.normalizedIFSC(ifscCode),
                                         branchName: branch.isEmpty ? nil : branch)
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct BankDetailsScreenViewState: BindableState {
    var savedAccount = BankDetailsSavedAccountState.loading
    var form = BankDetailsForm()
    /// Live check of the IFSC against the IFSC directory.
    var ifscStatus = IfscStatus.none
    var isSaving = false
    /// Why the last save failed: the API's own reason when it gave one, else a generic message.
    var saveError: String?

    static let genericSaveError = "Couldn't save your bank details. Check your connection and try again."

    var formTitle: String {
        savedAccount.account != nil ? "Replace payout account" : "Add payout account"
    }

    var ifscFooter: String? {
        form.ifscError ?? ifscStatus.message
    }

    var isIFSCInvalid: Bool {
        form.ifscError != nil || ifscStatus == .notFound
    }

    var canSave: Bool {
        // An IFSC with no branch would only surface as a failed payout. While checking, wait; if the
        // directory is unreachable, allow it - the API checks again on save.
        !isSaving && form.isComplete && !ifscStatus.blocksSave
    }
}

enum BankDetailsScreenViewAction {
    case setField(BankDetailsField, String)
    case save
    /// Load the saved account again after a failed load.
    case retryLoad
}

extension SavedBankAccount {
    /// e.g. "State Bank of India •••• 9012".
    var maskedTitle: String {
        "\(bankName) •••• \(accountNumberLast4)"
    }

    /// e.g. "Jane Doe · IFSC SBIN0001234 · MG Road".
    var detailsLine: String {
        let branch = branchName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [accountHolderName, "IFSC \(ifscCode)", branch?.isEmpty == false ? branchName : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
