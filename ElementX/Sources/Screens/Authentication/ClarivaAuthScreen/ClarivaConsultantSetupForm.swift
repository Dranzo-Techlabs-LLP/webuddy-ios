//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// The fields of the optional consultant setup on the sign-up form (also used as focus values).
enum ClarivaConsultantSetupField: Hashable {
    case maxCredits
    case accountHolderName
    case bankName
    case accountNumber
    case ifscCode
    case branchName
}

/// Optional chat rate and payout bank account, shown on sign-up only once the user says they are a
/// consultant. Everything here can be left empty or skipped; it can all be set later in Settings >
/// Billing and payments. Mirrors Android `ConsultantSetupForm` (7e8f3c3e10 + 093714e02a).
///
/// Values are kept exactly as typed and normalised by the getters below.
struct ClarivaConsultantSetupForm: Equatable {
    static let minMaxCredits = 1
    static let maxMaxCredits = 100_000
    static let maxCreditsMaxDigits = 6

    var isSkipped = false
    var maxCredits = ""
    var accountHolderName = ""
    var bankName = ""
    var accountNumber = ""
    var ifscCode = ""
    var branchName = ""

    func value(of field: ClarivaConsultantSetupField) -> String {
        switch field {
        case .maxCredits: maxCredits
        case .accountHolderName: accountHolderName
        case .bankName: bankName
        case .accountNumber: accountNumber
        case .ifscCode: ifscCode
        case .branchName: branchName
        }
    }

    func with(_ field: ClarivaConsultantSetupField, _ value: String) -> ClarivaConsultantSetupForm {
        var copy = self
        switch field {
        case .maxCredits: copy.maxCredits = value
        case .accountHolderName: copy.accountHolderName = value
        case .bankName: copy.bankName = value
        case .accountNumber: copy.accountNumber = value
        case .ifscCode: copy.ifscCode = value
        case .branchName: copy.branchName = value
        }
        return copy
    }

    /// Android's `onValueChange` filters: an edit that fails them is rejected, keeping the old value.
    static func accepts(_ value: String, for field: ClarivaConsultantSetupField) -> Bool {
        switch field {
        case .maxCredits:
            value.count <= maxCreditsMaxDigits && value.allSatisfy(BankAccountRules.isDigit)
        case .accountNumber:
            BankAccountRules.acceptsAccountNumberInput(value)
        case .ifscCode:
            // Kept as typed (the keyboard capitalises); upper-cased when checked and saved.
            BankAccountRules.acceptsIFSCInput(value)
        case .accountHolderName, .bankName, .branchName:
            BankAccountRules.acceptsTextInput(value)
        }
    }

    // MARK: - Normalised values

    /// nil when left empty (the rate is then set later) or out of range.
    var maxCreditsValue: Int? {
        guard let value = Int(maxCredits.trimmingCharacters(in: .whitespacesAndNewlines)),
              (Self.minMaxCredits...Self.maxMaxCredits).contains(value) else {
            return nil
        }
        return value
    }

    var normalizedIFSC: String {
        BankAccountRules.normalizedIFSC(ifscCode)
    }

    /// What is sent to `POST v1/experts/me/bank-details`: trimmed, IFSC upper-cased, blank branch omitted.
    var bankDetailsRequest: ClarivaBankDetailsRequest {
        let branch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ClarivaBankDetailsRequest(accountHolderName: accountHolderName.trimmingCharacters(in: .whitespacesAndNewlines),
                                         bankName: bankName.trimmingCharacters(in: .whitespacesAndNewlines),
                                         accountNumber: accountNumber.trimmingCharacters(in: .whitespacesAndNewlines),
                                         ifscCode: normalizedIFSC,
                                         branchName: branch.isEmpty ? nil : branch)
    }

    // MARK: - Errors (only once something is typed)

    var maxCreditsError: String? {
        guard !Self.isBlank(maxCredits), maxCreditsValue == nil else { return nil }
        return "Enter a whole number from \(Self.minMaxCredits) to \(Self.maxMaxCredits)"
    }

    var accountNumberError: String? {
        guard !Self.isBlank(accountNumber), !BankAccountRules.isValidAccountNumber(accountNumber) else { return nil }
        return BankAccountRules.accountNumberError
    }

    var ifscError: String? {
        guard !Self.isBlank(ifscCode), !BankAccountRules.isValidIFSC(ifscCode) else { return nil }
        return BankAccountRules.ifscError
    }

    // MARK: - Validity

    /// True once any bank field is filled: from then on all the required ones are needed.
    var hasBankDetails: Bool {
        [accountHolderName, bankName, accountNumber, ifscCode, branchName].contains { !Self.isBlank($0) }
    }

    private var isBankDetailsComplete: Bool {
        BankAccountRules.isValidName(accountHolderName)
            && BankAccountRules.isValidName(bankName)
            && BankAccountRules.isValidAccountNumber(accountNumber)
            && BankAccountRules.isValidIFSC(ifscCode)
    }

    /// Shown under the bank section while it is only partly filled.
    var isBankDetailsIncomplete: Bool {
        hasBankDetails && !isBankDetailsComplete
    }

    /// Skipped, empty, or fully valid: anything else blocks "Create account".
    var isValid: Bool {
        isSkipped || (maxCreditsError == nil && (!hasBankDetails || isBankDetailsComplete))
    }

    /// Something will actually be saved after the account is created.
    var hasAnythingToSave: Bool {
        !isSkipped && (maxCreditsValue != nil || hasBankDetails)
    }

    /// Skipped, or valid with an IFSC that is not known to be wrong (Android `isConsultantSetupReady`).
    func isReady(ifscStatus: IfscStatus) -> Bool {
        isSkipped || (isValid && !ifscStatus.blocksSave)
    }

    /// Kotlin `isBlank`.
    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Copy of the optional payout setup (Android `clariva_strings.xml`).
enum ClarivaConsultantSetupStrings {
    static let title = "Set up payouts"
    static let optional = "Optional"
    static let subtitle = "Add your chat rate and the bank account you're paid into. You can skip this and do it later in Settings."
    static let skip = "Skip for now"
    static let skipped = "Payout setup skipped. You can add your chat rate and bank details later in Settings › Billing and payments."
    static let resume = "Add now"

    static let failedRate = "Account created, but your chat rate wasn't saved. Set it in Settings › Billing and payments."
    static let failedBank = "Account created, but your bank details weren't saved. Please add them again later."
    static let failedBoth = "Account created, but your chat rate and bank details weren't saved. Please add them again later."

    static func googleSubtitle(email: String) -> String {
        "Signing up \(email) as a consultant. Add your chat rate and the bank account you're paid into, or skip and do it later in Settings."
    }

    /// The home-screen notice after sign-up, or nil when everything that was attempted was saved.
    static func failureNotice(rateSaved: Bool, bankSaved: Bool) -> String? {
        switch (rateSaved, bankSaved) {
        case (false, false): failedBoth
        case (true, false): failedBank
        case (false, true): failedRate
        case (true, true): nil
        }
    }
}
