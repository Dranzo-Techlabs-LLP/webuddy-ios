//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

@testable import ElementX

/// The Wallet API isn't consistent about quoting numbers, and Android's kotlinx parser accepts both
/// forms — these make sure iOS decodes the same payloads Android does.
final class WalletAPITests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func encode(_ value: some Encodable) throws -> String {
        try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
    }

    // MARK: - Users

    func testWalletUserAcceptsQuotedAndUnquotedNumbers() throws {
        let user = try decode(WalletUserResponse.self, #"{"current_hold":"123.75","max_credits":50,"Webuddy_name":"@a:clarivahub.com","isConsultant":1,"id":"uuid","phoneNumber":null}"#)
        XCTAssertEqual(user.currentHoldInt, 123) // truncated like Android
        XCTAssertEqual(user.maxCreditsInt, 50)
        XCTAssertEqual(user.isConsultant, 1)

        let quotedRole = try decode(WalletUserResponse.self, #"{"isConsultant":"0","current_hold":0}"#)
        XCTAssertEqual(quotedRole.isConsultant, 0)
        XCTAssertEqual(quotedRole.currentHoldInt, 0)
    }

    func testWalletUserKeepsUnknownValuesNil() throws {
        let user = try decode(WalletUserResponse.self, #"{"current_hold":null,"max_credits":"abc"}"#)
        XCTAssertNil(user.currentHoldInt)
        XCTAssertNil(user.maxCreditsInt)
    }

    func testCreateUserAlwaysEncodesRole() throws {
        let json = try encode(WalletCreateUserRequest(name: "@a:h", webuddyName: "@a:h", isConsultant: 0))
        XCTAssertTrue(json.contains("\"isConsultant\":0"))
        XCTAssertTrue(json.contains("\"Webuddy_name\""))
    }

    // MARK: - Holds

    func testPendingHoldStatusDefaultsMatchAndroid() throws {
        XCTAssertEqual(try decode(PendingHoldStatusResponse.self, "{}"), PendingHoldStatusResponse())
    }

    func testPendingHoldStatusIsTolerant() throws {
        let status = try decode(PendingHoldStatusResponse.self, #"{"exists":true,"isRefundActive":1,"refund_status":"requested","id":"987","refundRequestId":"42","amount":"20.50","consultantId":"@c:h","pendingAutoApprovalNotification":{"refundRequestId":7,"amount":"20","clientId":"@a:h","consultantId":"@c:h"}}"#)
        XCTAssertEqual(status.holdIdString, "987") // falls back to `id`
        XCTAssertEqual(status.refundRequestIdString, "42")
        XCTAssertEqual(status.amount, 20.5)
        XCTAssertEqual(status.refundStatus, "requested")
        XCTAssertEqual(status.pendingAutoApprovalNotification?.refundRequestId, "7")

        let bigInt = try decode(PendingHoldStatusResponse.self, #"{"exists":1,"pendingHoldId":12345678901,"refundRequestId":null}"#)
        XCTAssertTrue(bigInt.exists)
        XCTAssertEqual(bigInt.holdIdString, "12345678901")
        XCTAssertNil(bigInt.refundRequestId)
    }

    func testHoldExists() throws {
        XCTAssertTrue(try decode(HoldExistsResponse.self, #"{"exists":true}"#).exists)
        XCTAssertFalse(try decode(HoldExistsResponse.self, #"{"exists":0}"#).exists)
        // A missing value must fail so the caller reports "unknown" and the chat gate stays open.
        XCTAssertThrowsError(try decode(HoldExistsResponse.self, "{}"))
    }

    // MARK: - Recharge

    func testRechargeResponsesAreTolerant() throws {
        let order = try decode(CreateOrderResponse.self, #"{"keyId":"rzp_test","orderId":"order_1","amountInPaise":"50000","currency":"INR","transactionId":991}"#)
        XCTAssertEqual(order.amountInPaise, 50000)
        XCTAssertEqual(order.transactionId, "991")

        // A quoted balance used to fail the decode and report "Verification failed" for a paid recharge.
        let verify = try decode(VerifyPaymentResponse.self, #"{"success":true,"newBalance":"600.00","transactionId":"t1"}"#)
        XCTAssertTrue(verify.success)
        XCTAssertEqual(verify.newBalance, 600)

        let history = try decode(TransactionHistoryResponse.self, #"{"data":[{"id":null,"userId":"@a:h","amount":"100.00","type":"CREDIT","status":"completed","source":"RECHARGE","createdAt":"2026-08-17T10:00:00Z","metaData":{"x":1}}],"total":"1","page":1,"pageSize":10,"totalPages":1}"#)
        XCTAssertEqual(history.data.count, 1)
        XCTAssertEqual(history.data.first?.amountValue, 100)
        XCTAssertEqual(history.total, 1)
    }

    // MARK: - Bank details (Android 093714e02a)

    func testBankDetailsRequestOmitsBlankBranch() throws {
        let json = try encode(ClarivaBankDetailsRequest(accountHolderName: "Jane Doe",
                                                        bankName: "State Bank of India",
                                                        accountNumber: "123456789",
                                                        ifscCode: "SBIN0001234",
                                                        branchName: nil))
        XCTAssertFalse(json.contains("branchName"))
        XCTAssertFalse(json.contains("expertId")) // whose account it is comes from the token
        XCTAssertTrue(json.contains("\"ifscCode\":\"SBIN0001234\""))

        XCTAssertTrue(try encode(ClarivaBankDetailsRequest(accountHolderName: "J", bankName: "B", accountNumber: "1", ifscCode: "I", branchName: "MG Road"))
            .contains("\"branchName\":\"MG Road\""))
    }

    func testSavedBankAccountIsMasked() throws {
        let response = try decode(MyBankAccountResponse.self, #"{"bankDetail":{"id":"7f6c","bankName":"State Bank of India","accountNumberLast4":"9012","ifscCode":"SBIN0001234","accountHolderName":"Jane Doe","branchName":null,"isActive":true,"updatedAt":"2026-10-29T10:00:00.000Z"}}"#)
        XCTAssertEqual(response.bankDetail, SavedBankAccount(id: "7f6c",
                                                             bankName: "State Bank of India",
                                                             accountNumberLast4: "9012",
                                                             ifscCode: "SBIN0001234",
                                                             accountHolderName: "Jane Doe",
                                                             branchName: nil))
        XCTAssertNil(try decode(MyBankAccountResponse.self, #"{"bankDetail":null}"#).bankDetail)
        XCTAssertEqual(try decode(SavedBankAccount.self, #"{"id":12,"bankName":"B","accountNumberLast4":"1234","ifscCode":"I","accountHolderName":"H","branchName":"Br"}"#).id, "12")
    }

    func testUserMessageOnlyForClientErrors() {
        XCTAssertEqual(WalletAPIError.http(status: 400, body: #"{"message":"No bank branch found for IFSC ABCD0123456. Please check the code."}"#).userMessage,
                       "No bank branch found for IFSC ABCD0123456. Please check the code.")
        XCTAssertEqual(WalletAPIError.http(status: 400, body: #"{"message":["Account number must be 9 to 18 digits","IFSC code must look like ABCD0123456"]}"#).userMessage,
                       "Account number must be 9 to 18 digits\nIFSC code must look like ABCD0123456")
        XCTAssertNil(WalletAPIError.http(status: 500, body: #"{"message":"Internal server error"}"#).userMessage)
        XCTAssertNil(WalletAPIError.http(status: 403, body: "<html>").userMessage)
        XCTAssertNil(WalletAPIError.transport(underlying: URLError(.notConnectedToInternet)).userMessage)
    }

    func testBankDetailsURL() {
        XCTAssertEqual(WalletAPIClient().makeURL(path: ["v1", "experts", "me", "bank-details"], query: [:])?.absoluteString,
                       "https://wallet.clarivahub.com/v1/experts/me/bank-details")
    }

    // MARK: - Refunds and calls

    func testApproveRefundOmitsAmountForFullRefund() throws {
        XCTAssertFalse(try encode(ApproveRefundBody(refundRequestId: "1", pendingHoldId: "2", refundAmount: nil)).contains("refundAmount"))
        XCTAssertTrue(try encode(ApproveRefundBody(refundRequestId: "1", pendingHoldId: "2", refundAmount: 12.5)).contains("\"refundAmount\":12.5"))
    }

    func testCallTypeOmitsMissingCaller() throws {
        XCTAssertFalse(try encode(SetCallTypeRequest(roomId: "!r:h", callType: "voice", callerId: nil)).contains("callerId"))
    }

    // MARK: - Errors

    func testErrorDescriptionUsesServerMessage() {
        XCTAssertEqual(WalletAPIError.http(status: 404, body: #"{"statusCode":404,"message":"User not found"}"#).errorDescription, "User not found")
        XCTAssertEqual(WalletAPIError.http(status: 400, body: #"{"message":["amount must be positive","x"]}"#).errorDescription, "amount must be positive")
        XCTAssertEqual(WalletAPIError.http(status: 502, body: "<html>").errorDescription, "HTTP 502")
        XCTAssertEqual(WalletAPIError.http(status: 404, body: nil).statusCode, 404)
    }

    // MARK: - URLs

    func testURLsEncodeMatrixIdentifiers() {
        let api = WalletAPIClient()
        XCTAssertEqual(api.makeURL(path: ["v1", "users", "@a.b:clarivahub.com"], query: [:])?.absoluteString,
                       "https://wallet.clarivahub.com/v1/users/@a.b:clarivahub.com")
        XCTAssertEqual(api.makeURL(path: ["v1", "pending-holds", "exists"], query: ["clientId": "@a+b:h", "consultantId": "@c:h"])?.absoluteString,
                       "https://wallet.clarivahub.com/v1/pending-holds/exists?clientId=@a%2Bb:h&consultantId=@c:h")
        XCTAssertEqual(api.makeURL(path: ["v1", "calls", "type"], query: ["roomId": "!abc:clarivahub.com"])?.absoluteString,
                       "https://wallet.clarivahub.com/v1/calls/type?roomId=!abc:clarivahub.com")
        XCTAssertEqual(api.makeURL(path: ["v1", "users", "a/b"], query: [:])?.absoluteString,
                       "https://wallet.clarivahub.com/v1/users/a%2Fb")
    }

    func testCallTypeLookupIsHardCapped() async {
        let start = Date()
        // Non-routable address: the request never completes on its own.
        let type = await WalletAPIClient(baseURL: "http://10.255.255.1/").fetchRoomCallType(roomId: "!r:h")
        XCTAssertNil(type)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    // MARK: - Clariva config and links

    func testHomeserverAllowList() {
        XCTAssertTrue(ClarivaConfig.isAllowedHomeserver("https://matrix.clarivahub.com"))
        XCTAssertTrue(ClarivaConfig.isAllowedHomeserver("clarivahub.com"))
        XCTAssertFalse(ClarivaConfig.isAllowedHomeserver("https://clarivahub.com.attacker.net"))
        XCTAssertFalse(ClarivaConfig.isAllowedHomeserver("https://clarivahub.com@attacker.net/"))
        XCTAssertFalse(ClarivaConfig.isAllowedHomeserver("https://matrix.org"))
    }

    func testClarivaUserLinkMatchesAndroid() {
        XCTAssertEqual(ClarivaUserLink.url(for: "@mohamed.shimil4:clarivahub.com")?.absoluteString,
                       "https://clarivahub.com/u/%40mohamed.shimil4%3Aclarivahub.com")
        XCTAssertEqual(ClarivaUserLink.userID(from: "https://clarivahub.com/u/%40a%3Ab.com"), "@a:b.com")
        XCTAssertEqual(ClarivaUserLink.userID(from: "  https://clarivahub.com/u/@a:b.com/extra \n"), "@a:b.com")
        XCTAssertNil(ClarivaUserLink.userID(from: "https://www.clarivahub.com/u/%40a%3Ab.com"))
        XCTAssertNil(ClarivaUserLink.userID(from: "https://clarivahub.com/u/alice"))
        XCTAssertNil(ClarivaUserLink.userID(from: "https://matrix.to/#/@a:b.com"))
    }
}
