//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

@testable import ElementX

/// Android 049d08c0e2 / Wallet-API 7f1fb5b0d: a partial refund must be greater than 0 and LESS than
/// the held amount, and a completed refund ends the chat session.
final class RefundAmountValidatorTests: XCTestCase {
    func testFullRefundIsAlwaysValid() {
        XCTAssertTrue(RefundAmountValidator.isValid(isPartial: false, roundedAmount: nil, heldAmount: 50))
    }

    func testPartialRefundMustBeBelowTheHeldAmount() {
        XCTAssertTrue(RefundAmountValidator.isValid(isPartial: true, roundedAmount: 49.99, heldAmount: 50))
        XCTAssertTrue(RefundAmountValidator.isValid(isPartial: true, roundedAmount: 0.01, heldAmount: 50))
        XCTAssertFalse(RefundAmountValidator.isValid(isPartial: true, roundedAmount: 50, heldAmount: 50))
        XCTAssertFalse(RefundAmountValidator.isValid(isPartial: true, roundedAmount: 50.5, heldAmount: 50))
        XCTAssertFalse(RefundAmountValidator.isValid(isPartial: true, roundedAmount: 0, heldAmount: 50))
        XCTAssertFalse(RefundAmountValidator.isValid(isPartial: true, roundedAmount: nil, heldAmount: 50))
        // Unknown held amount: only the lower bound is checked (the server re-checks).
        XCTAssertTrue(RefundAmountValidator.isValid(isPartial: true, roundedAmount: 500, heldAmount: nil))
    }

    func testAmountsAreRoundedLikeTheBackend() {
        XCTAssertEqual(RefundAmountValidator.roundedAmount(from: "0.004"), 0)
        XCTAssertEqual(RefundAmountValidator.roundedAmount(from: "49.999"), 50)
        XCTAssertFalse(RefundAmountValidator.isValid(isPartial: true,
                                                     roundedAmount: RefundAmountValidator.roundedAmount(from: "49.999"),
                                                     heldAmount: 50))
    }

    func testHelperTextMatchesAndroid() {
        XCTAssertEqual(RefundAmountValidator.helperText(showsError: true, roundedAmount: 50, heldAmount: 50),
                       "A partial refund must be less than ₹50. To return everything, choose Full refund.")
        XCTAssertEqual(RefundAmountValidator.helperText(showsError: true, roundedAmount: 0, heldAmount: 12.5),
                       "Enter an amount greater than 0 and less than ₹12.5.")
        XCTAssertEqual(RefundAmountValidator.helperText(showsError: true, roundedAmount: nil, heldAmount: 50),
                       "Enter an amount greater than 0 and less than ₹50.")
        XCTAssertEqual(RefundAmountValidator.helperText(showsError: true, roundedAmount: 0, heldAmount: nil),
                       "Enter an amount greater than 0.")
        XCTAssertEqual(RefundAmountValidator.helperText(showsError: false, roundedAmount: 10, heldAmount: 50),
                       "The client gets this back; you keep the rest of ₹50.")
        XCTAssertEqual(RefundAmountValidator.helperText(showsError: false, roundedAmount: nil, heldAmount: nil),
                       "The client gets this back; you keep the remainder.")
    }

    // MARK: - Session end after a refund

    func testRefundableSessionEndIsNoticed() {
        let refundable = PendingHoldStatusResponse(exists: true, isRefundActive: 1, refundStatus: "requested")
        let gone = PendingHoldStatusResponse()
        let partiallyRefunded = PendingHoldStatusResponse(exists: true, isRefundActive: 0)

        XCTAssertTrue(refundable.isRefundableSession)
        XCTAssertFalse(gone.isRefundableSession)
        XCTAssertFalse(partiallyRefunded.isRefundableSession)

        XCTAssertTrue(WalletService.didRefundableSessionEnd(wasOpen: true, status: gone))
        XCTAssertTrue(WalletService.didRefundableSessionEnd(wasOpen: true, status: partiallyRefunded))
        XCTAssertFalse(WalletService.didRefundableSessionEnd(wasOpen: true, status: refundable))
        // Nothing was open (or nothing known yet, e.g. the first poll): nothing ended.
        XCTAssertFalse(WalletService.didRefundableSessionEnd(wasOpen: false, status: gone))
        XCTAssertFalse(WalletService.didRefundableSessionEnd(wasOpen: nil, status: gone))
    }
}
