//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

@testable import ElementX

/// The payout bank account rules shared by consultant sign-up and Settings > Bank Details
/// (Android 7e8f3c3e10 + 093714e02a), kept in sync with the API's `AddMyBankDetailDto`.
@MainActor
final class BankAccountRulesTests: XCTestCase {
    // MARK: - BankAccountRules

    func testAccountNumberIs9To18Digits() {
        XCTAssertTrue(BankAccountRules.isValidAccountNumber("123456789"))
        XCTAssertTrue(BankAccountRules.isValidAccountNumber("123456789012345678"))
        XCTAssertTrue(BankAccountRules.isValidAccountNumber(" 123456789 ")) // trimmed
        XCTAssertFalse(BankAccountRules.isValidAccountNumber("12345678"))
        XCTAssertFalse(BankAccountRules.isValidAccountNumber("1234567890123456789"))
        XCTAssertFalse(BankAccountRules.isValidAccountNumber("12345678a"))
        XCTAssertFalse(BankAccountRules.isValidAccountNumber("١٢٣٤٥٦٧٨٩")) // other scripts' digits
        XCTAssertFalse(BankAccountRules.isValidAccountNumber(""))
    }

    func testIFSCFormat() {
        XCTAssertTrue(BankAccountRules.isValidIFSC("SBIN0001234"))
        XCTAssertTrue(BankAccountRules.isValidIFSC("sbin0001234")) // upper-cased when checked
        XCTAssertTrue(BankAccountRules.isValidIFSC(" HDFC0ABC123 "))
        XCTAssertFalse(BankAccountRules.isValidIFSC("SBIN1001234")) // 5th character must be 0
        XCTAssertFalse(BankAccountRules.isValidIFSC("SBI00001234")) // 4 letters first
        XCTAssertFalse(BankAccountRules.isValidIFSC("SBIN000123"))
        XCTAssertFalse(BankAccountRules.isValidIFSC("SBIN00012345"))
        XCTAssertFalse(BankAccountRules.isValidIFSC("SBIN0-01234"))
        XCTAssertEqual(BankAccountRules.normalizedIFSC(" sbin0001234 "), "SBIN0001234")
    }

    func testNamesNeedTwoCharacters() {
        XCTAssertTrue(BankAccountRules.isValidName("Jo"))
        XCTAssertFalse(BankAccountRules.isValidName(" J "))
        XCTAssertFalse(BankAccountRules.isValidName(""))
    }

    func testInputFilters() {
        XCTAssertTrue(BankAccountRules.acceptsAccountNumberInput("123456789012345678"))
        XCTAssertFalse(BankAccountRules.acceptsAccountNumberInput("1234567890123456789"))
        XCTAssertFalse(BankAccountRules.acceptsAccountNumberInput("12 34"))
        XCTAssertTrue(BankAccountRules.acceptsIFSCInput("sbin0001234"))
        XCTAssertFalse(BankAccountRules.acceptsIFSCInput("SBIN00012345"))
        XCTAssertFalse(BankAccountRules.acceptsIFSCInput("SBIN-"))
        XCTAssertTrue(BankAccountRules.acceptsTextInput(String(repeating: "a", count: 120)))
        XCTAssertFalse(BankAccountRules.acceptsTextInput(String(repeating: "a", count: 121)))
    }

    // MARK: - Sign-up consultant setup

    func testEmptySetupIsValidAndSavesNothing() {
        let setup = ClarivaConsultantSetupForm()
        XCTAssertTrue(setup.isValid)
        XCTAssertFalse(setup.hasAnythingToSave)
        XCTAssertFalse(setup.isBankDetailsIncomplete)
    }

    func testMaxCreditsRange() {
        XCTAssertEqual(ClarivaConsultantSetupForm(maxCredits: "50").maxCreditsValue, 50)
        XCTAssertEqual(ClarivaConsultantSetupForm(maxCredits: "100000").maxCreditsValue, 100_000)
        XCTAssertNil(ClarivaConsultantSetupForm(maxCredits: "0").maxCreditsValue)
        XCTAssertNil(ClarivaConsultantSetupForm(maxCredits: "100001").maxCreditsValue)

        XCTAssertEqual(ClarivaConsultantSetupForm(maxCredits: "0").maxCreditsError, "Enter a whole number from 1 to 100000")
        XCTAssertFalse(ClarivaConsultantSetupForm(maxCredits: "0").isValid)
        XCTAssertNil(ClarivaConsultantSetupForm(maxCredits: "").maxCreditsError)

        let rateOnly = ClarivaConsultantSetupForm(maxCredits: "50")
        XCTAssertTrue(rateOnly.isValid)
        XCTAssertTrue(rateOnly.hasAnythingToSave)
        XCTAssertFalse(rateOnly.hasBankDetails)
    }

    func testHalfFilledBankAccountBlocksSubmit() {
        let setup = ClarivaConsultantSetupForm(accountHolderName: "Jane Doe", ifscCode: "sbin01")
        XCTAssertTrue(setup.hasBankDetails)
        XCTAssertTrue(setup.isBankDetailsIncomplete)
        XCTAssertFalse(setup.isValid)
        XCTAssertEqual(setup.ifscError, "IFSC code looks like ABCD0123456")

        // Only the optional branch typed still counts as starting a bank account.
        XCTAssertFalse(ClarivaConsultantSetupForm(branchName: "MG Road").isValid)
    }

    func testCompleteBankAccountIsValidAndNormalised() {
        let setup = ClarivaConsultantSetupForm(accountHolderName: " Jane Doe ",
                                               bankName: "State Bank of India",
                                               accountNumber: "123456789",
                                               ifscCode: "sbin0001234",
                                               branchName: "  ")
        XCTAssertTrue(setup.isValid)
        XCTAssertTrue(setup.hasAnythingToSave)
        XCTAssertEqual(setup.bankDetailsRequest, ClarivaBankDetailsRequest(accountHolderName: "Jane Doe",
                                                                           bankName: "State Bank of India",
                                                                           accountNumber: "123456789",
                                                                           ifscCode: "SBIN0001234",
                                                                           branchName: nil))
    }

    func testSkippedSetupIsValidAndSavesNothing() {
        let setup = ClarivaConsultantSetupForm(isSkipped: true, maxCredits: "0", accountHolderName: "J")
        XCTAssertTrue(setup.isValid)
        XCTAssertFalse(setup.hasAnythingToSave)
        XCTAssertTrue(setup.isReady(ifscStatus: .notFound))
    }

    func testIFSCLookupGatesReadiness() {
        let setup = ClarivaConsultantSetupForm(accountHolderName: "Jane Doe",
                                               bankName: "State Bank of India",
                                               accountNumber: "123456789",
                                               ifscCode: "SBIN0001234")
        XCTAssertFalse(setup.isReady(ifscStatus: .checking))
        XCTAssertFalse(setup.isReady(ifscStatus: .notFound))
        XCTAssertTrue(setup.isReady(ifscStatus: .unavailable)) // the API checks again
        XCTAssertTrue(setup.isReady(ifscStatus: .found(IfscBranch(bank: "State Bank of India", branch: "Hajiganj", city: "Patna"))))
        XCTAssertTrue(setup.isReady(ifscStatus: .none))
    }

    func testSetupInputFilters() {
        XCTAssertTrue(ClarivaConsultantSetupForm.accepts("123456", for: .maxCredits))
        XCTAssertFalse(ClarivaConsultantSetupForm.accepts("1234567", for: .maxCredits))
        XCTAssertFalse(ClarivaConsultantSetupForm.accepts("5a", for: .maxCredits))
        XCTAssertTrue(ClarivaConsultantSetupForm.accepts("sbin0", for: .ifscCode))
        XCTAssertFalse(ClarivaConsultantSetupForm.accepts("sbin 0", for: .ifscCode))
        XCTAssertTrue(ClarivaConsultantSetupForm.accepts("Jane Doe", for: .accountHolderName))
    }

    func testSetupFailureNotices() {
        XCTAssertNil(ClarivaConsultantSetupStrings.failureNotice(rateSaved: true, bankSaved: true))
        XCTAssertEqual(ClarivaConsultantSetupStrings.failureNotice(rateSaved: false, bankSaved: true),
                       "Account created, but your chat rate wasn't saved. Set it in Settings › Billing and payments.")
        XCTAssertEqual(ClarivaConsultantSetupStrings.failureNotice(rateSaved: true, bankSaved: false),
                       "Account created, but your bank details weren't saved. Please add them again later.")
        XCTAssertEqual(ClarivaConsultantSetupStrings.failureNotice(rateSaved: false, bankSaved: false),
                       "Account created, but your chat rate and bank details weren't saved. Please add them again later.")
    }

    // MARK: - Settings > Bank Details

    func testBankDetailsFormCanSave() {
        var state = BankDetailsScreenViewState()
        XCTAssertFalse(state.canSave)

        state.form = BankDetailsForm(accountHolderName: "Jane Doe", bankName: "State Bank of India", accountNumber: "123456789", ifscCode: "sbin0001234")
        XCTAssertTrue(state.canSave) // branch is optional
        XCTAssertEqual(state.form.request.ifscCode, "SBIN0001234")
        XCTAssertNil(state.form.request.branchName)

        state.ifscStatus = .checking
        XCTAssertFalse(state.canSave)
        state.ifscStatus = .notFound
        XCTAssertFalse(state.canSave)
        XCTAssertTrue(state.isIFSCInvalid)
        state.ifscStatus = .unavailable
        XCTAssertTrue(state.canSave)

        state.isSaving = true
        XCTAssertFalse(state.canSave)
    }

    func testBankDetailsErrorsOnlyOnceTyped() {
        XCTAssertNil(BankDetailsForm().accountNumberError)
        XCTAssertNil(BankDetailsForm().ifscError)
        XCTAssertEqual(BankDetailsForm(accountNumber: "1234").accountNumberError, "Account number must be 9 to 18 digits")
        XCTAssertEqual(BankDetailsForm(ifscCode: "SBIN").ifscError, "IFSC code looks like ABCD0123456")
    }

    func testSavedAccountShowsOnlyTheLastFourDigits() {
        let account = SavedBankAccount(bankName: "State Bank of India",
                                       accountNumberLast4: "9012",
                                       ifscCode: "SBIN0001234",
                                       accountHolderName: "Jane Doe",
                                       branchName: "MG Road")
        XCTAssertEqual(account.maskedTitle, "State Bank of India •••• 9012")
        XCTAssertEqual(account.detailsLine, "Jane Doe · IFSC SBIN0001234 · MG Road")

        let noBranch = SavedBankAccount(bankName: "B", accountNumberLast4: "1", ifscCode: "I", accountHolderName: "H", branchName: " ")
        XCTAssertEqual(noBranch.detailsLine, "H · IFSC I")

        var state = BankDetailsScreenViewState()
        XCTAssertEqual(state.formTitle, "Add payout account")
        state.savedAccount = .loaded(account)
        XCTAssertEqual(state.formTitle, "Replace payout account")
    }

    // MARK: - IFSC lookup

    func testIFSCDirectoryResponseIsParsedAndTitleCased() throws {
        let data = Data(#"{"BANK":"State Bank of India","BRANCH":"HAJIGANJ","CITY":"PATNA","STATE":"BIHAR","IFSC":"SBIN0001234"}"#.utf8)
        let branch = try XCTUnwrap(IfscLookup.branch(from: data))
        XCTAssertEqual(branch, IfscBranch(bank: "State Bank of India", branch: "Hajiganj", city: "Patna"))
        XCTAssertEqual(branch.summary, "State Bank of India · Hajiganj, Patna")
        XCTAssertEqual(IfscStatus.found(branch).message, "State Bank of India · Hajiganj, Patna")

        // No bank is "unavailable", never "not found".
        XCTAssertNil(IfscLookup.branch(from: Data(#"{"BRANCH":"X"}"#.utf8)))
        XCTAssertNil(IfscLookup.branch(from: Data("Not Found".utf8)))

        let noCity = try XCTUnwrap(IfscLookup.branch(from: Data(#"{"BANK":"HDFC Bank","BRANCH":"","CITY":" "}"#.utf8)))
        XCTAssertEqual(noCity.summary, "HDFC Bank · ")
        XCTAssertNil(noCity.city)
    }

    func testTitleCase() {
        XCTAssertEqual(IfscLookup.titleCase("MG ROAD, BANGALORE"), "Mg Road, Bangalore")
        XCTAssertEqual(IfscLookup.titleCase(" new delhi "), "New Delhi")
        XCTAssertEqual(IfscLookup.titleCase(""), "")
    }

    func testIFSCStatusBlocksSave() {
        XCTAssertTrue(IfscStatus.checking.blocksSave)
        XCTAssertTrue(IfscStatus.notFound.blocksSave)
        XCTAssertFalse(IfscStatus.unavailable.blocksSave)
        XCTAssertFalse(IfscStatus.none.blocksSave)
        XCTAssertEqual(IfscStatus.notFound.message, "No bank branch found for this IFSC. Please check the code.")
        XCTAssertEqual(IfscStatus.unavailable.message, "Couldn't verify this IFSC right now. It will be checked when you save.")
        XCTAssertEqual(IfscStatus.checking.message, "Checking IFSC…")
        XCTAssertNil(IfscStatus.none.message)
    }

    func testMalformedIFSCIsNeverLookedUp() async {
        // An unroutable directory: a well-formed code would hang until the timeout.
        let lookup = IfscLookup(baseURL: "http://10.255.255.1/", timeout: 1)
        let status = await lookup.lookup("SBIN1")
        XCTAssertEqual(status, IfscStatus.none)
    }
}
