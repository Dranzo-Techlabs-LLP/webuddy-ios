//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Decoded shape for `GET /v1/users/{webuddyName}` and the response from POST/PATCH.
/// `current_hold` and `max_credits` come back as JSON strings (decimal). isConsultant is 0|1.
struct WalletUserResponse: Decodable {
    let id: String?
    let phoneNumber: String?
    let name: String?
    let webuddyName: String?
    let currentHold: String?
    let maxCredits: String?
    let isConsultant: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case phoneNumber
        case name
        case webuddyName = "Webuddy_name"
        case currentHold = "current_hold"
        case maxCredits = "max_credits"
        case isConsultant
    }

    /// Parses the JSON string credits to Int. Returns nil when the field is absent or
    /// unparseable so callers can preserve the last-known-good value instead of clobbering
    /// it with a default (B4 fix mirrored from Android).
    var currentHoldInt: Int? { currentHold.flatMap { Double($0).map(Int.init) } }
    var maxCreditsInt: Int? { maxCredits.flatMap { Double($0).map(Int.init) } }
}

struct WalletCreateUserRequest: Encodable {
    let name: String
    let webuddyName: String
    let isConsultant: Int

    enum CodingKeys: String, CodingKey {
        case name
        case webuddyName = "Webuddy_name"
        case isConsultant
    }
}

struct WalletUpdateUserRequest: Encodable {
    let maxCredits: Int?
    let isConsultant: Int?

    enum CodingKeys: String, CodingKey {
        case maxCredits = "max_credits"
        case isConsultant
    }
}

struct CreateOrderResponse: Decodable {
    let keyId: String
    let orderId: String
    let amountInPaise: Int64
    let currency: String
    let transactionId: String
}

struct CreateOrderRequest: Encodable {
    let userId: String
    let amount: Double
}

struct VerifyPaymentRequest: Encodable {
    let userId: String
    let transactionId: String
    let razorpayOrderId: String
    let razorpayPaymentId: String
    let razorpaySignature: String

    enum CodingKeys: String, CodingKey {
        case userId
        case transactionId
        case razorpayOrderId = "razorpay_order_id"
        case razorpayPaymentId = "razorpay_payment_id"
        case razorpaySignature = "razorpay_signature"
    }
}

struct VerifyPaymentResponse: Decodable {
    let success: Bool
    let newBalance: Double
    let transactionId: String
}

struct WalletTransactionDTO: Decodable {
    let id: String?
    let userId: String?
    let amount: String
    let currency: String?
    let type: String
    let source: String?
    let status: String
    let provider: String?
    let createdAt: String?
}

struct TransactionHistoryResponse: Decodable {
    let data: [WalletTransactionDTO]
    let total: Int?
    let page: Int
    let pageSize: Int
    let totalPages: Int
}

struct InitiateHoldRequest: Encodable {
    let clientId: String
    let consultantId: String
}

struct HoldExistsResponse: Decodable {
    let exists: Bool
}

struct PendingHoldStatusResponse: Decodable {
    let exists: Bool
    let isActive: Int?
    let isRefundActive: Int?
    let refundStatus: String?
    let pendingHoldId: Int?
    let clientId: String?
    let consultantId: String?
    let refundRequestId: Int?
    /// Populated by the server when the cron auto-approved a refund and the in-room
    /// Matrix push-notification still needs to be sent. Whichever app sees this first
    /// calls `POST /v1/refund/auto-approval-claim/:id` to atomically claim the right
    /// to send the m.room.message that triggers the OTHER party's push notification.
    /// Null when there's nothing to announce.
    let pendingAutoApprovalNotification: PendingAutoApprovalNotification?

    enum CodingKeys: String, CodingKey {
        case exists
        case isActive
        case isRefundActive
        case refundStatus = "refund_status"
        case pendingHoldId
        case clientId
        case consultantId
        case refundRequestId
        case pendingAutoApprovalNotification
    }

    var holdIdString: String? { pendingHoldId.map(String.init) }
    var refundRequestIdString: String? { refundRequestId.map(String.init) }
}

struct PendingAutoApprovalNotification: Decodable {
    let refundRequestId: Int
    let amount: Double
    let clientId: String
    let consultantId: String
}

struct ClaimAutoApprovalBody: Encodable {
    let userId: String
}

struct ClaimAutoApprovalResponse: Decodable {
    let claimed: Bool
}

struct RefundRequestBody: Encodable {
    let clientId: String
    let consultantId: String
    let pendingHoldId: String
}

struct ApproveRefundBody: Encodable {
    let refundRequestId: String
    let pendingHoldId: String
}

struct RejectRefundBody: Encodable {
    let refundRequestId: String
}

struct GenericRefundResponse: Decodable {
    let message: String?
    let amount: Double?
}

/// Response from `POST /v1/refund/request`. The server returns `{ message, refundRequestId }`
/// — there is NO `success` field. Marking `success` as a required non-nullable Bool would make
/// every successful refund-request response throw a decoding error, which the catch handler
/// would turn into Result.failure → "Error" snackbar even though the row had been inserted
/// server-side. All fields optional; presence of [message] indicates a non-error response.
/// Mirrors Android `RefundResponse` post-c980878.
struct RefundResponse: Decodable {
    let message: String?
    let refundRequestId: Int?
}

/// Response for GET v1/refund/pending-for-consultant — list of client matrix IDs
/// that currently have an open refund request waiting on the given consultant.
struct PendingRefundsForConsultantResponse: Decodable {
    let clientIds: [String]

    enum CodingKeys: String, CodingKey { case clientIds }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientIds = try container.decodeIfPresent([String].self, forKey: .clientIds) ?? []
    }
}

enum WalletAPIError: Error {
    case invalidResponse
    case http(status: Int, body: String?)
    case transport(underlying: Error)
    case decoding(underlying: Error)
}
