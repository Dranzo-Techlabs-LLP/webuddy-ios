//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

// MARK: - Lenient scalars

/// The Wallet API is not consistent about quoting numbers (MySQL DECIMAL/BIGINT columns come back
/// as strings, computed values as numbers). Android's kotlinx parser accepts both, so iOS must too —
/// otherwise a single quoted number fails the whole decode (e.g. a successful recharge reported as
/// "Verification failed").
struct FlexibleDouble: Decodable, Equatable {
    let value: Double?

    init(_ value: Double?) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = Double(string.trimmingCharacters(in: .whitespaces))
        } else {
            value = nil
        }
    }
}

/// Identifier that may be serialised as a number or a string. Always exposed as a string because
/// every endpoint that consumes it back takes a string.
struct FlexibleID: Decodable, Equatable {
    let value: String?

    init(_ value: String?) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let int = try? container.decode(Int64.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = double.rounded() == double ? String(Int64(double)) : String(double)
        } else if let string = try? container.decode(String.self) {
            value = string.isEmpty ? nil : string
        } else {
            value = nil
        }
    }
}

extension KeyedDecodingContainer {
    func flexibleDouble(_ key: Key) -> Double? {
        guard let wrapped = try? decodeIfPresent(FlexibleDouble.self, forKey: key) else {
            return nil
        }
        return wrapped.value
    }

    func flexibleID(_ key: Key) -> String? {
        guard let wrapped = try? decodeIfPresent(FlexibleID.self, forKey: key) else {
            return nil
        }
        return wrapped.value
    }

    func flexibleInt(_ key: Key) -> Int? {
        flexibleDouble(key).map { Int($0) }
    }

    func lenientString(_ key: Key) -> String? {
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            return string
        }
        return flexibleID(key)
    }
}

// MARK: - Users / wallet

/// Decoded shape for `GET /v1/users/{webuddyName}` and the response from POST/PATCH.
/// `current_hold` (the spendable balance) and `max_credits` (the user's chat rate) may come back as
/// decimal strings or numbers. `isConsultant` is 0|1.
struct WalletUserResponse: Decodable {
    let webuddyName: String?
    let currentHold: Double?
    let maxCredits: Double?
    let isConsultant: Int?

    enum CodingKeys: String, CodingKey {
        case webuddyName = "Webuddy_name"
        case currentHold = "current_hold"
        case maxCredits = "max_credits"
        case isConsultant
    }

    init(webuddyName: String?, currentHold: Double?, maxCredits: Double?, isConsultant: Int?) {
        self.webuddyName = webuddyName
        self.currentHold = currentHold
        self.maxCredits = maxCredits
        self.isConsultant = isConsultant
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        webuddyName = container.lenientString(.webuddyName)
        currentHold = container.flexibleDouble(.currentHold)
        maxCredits = container.flexibleDouble(.maxCredits)
        isConsultant = container.flexibleInt(.isConsultant)
    }

    /// Truncated to Int like Android (`toDouble().toInt()`). nil when absent/unparseable so callers
    /// keep the last-known-good value instead of clobbering it with a default.
    var currentHoldInt: Int? {
        currentHold.map { Int($0) }
    }

    var maxCreditsInt: Int? {
        maxCredits.map { Int($0) }
    }
}

struct WalletCreateUserRequest: Encodable {
    let name: String
    let webuddyName: String
    /// Always encoded (non-optional) — the API validates it as 0|1.
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

// MARK: - Bank details

/// `POST v1/experts/me/bank-details` (Android `ClarivaBankDetailsRequest`). There is no expert ID:
/// whose account it is comes from the Bearer token (Clariva JWT or the session's Matrix access token).
/// `branchName` is optional on the API and omitted rather than sent blank (synthesized `encodeIfPresent`).
struct ClarivaBankDetailsRequest: Encodable, Equatable {
    let accountHolderName: String
    let bankName: String
    let accountNumber: String
    /// Upper-cased.
    let ifscCode: String
    let branchName: String?
}

/// The saved payout account as the API returns it (`MaskedBankDetail`): never the full account number.
struct SavedBankAccount: Decodable, Equatable {
    // periphery:ignore - echoed by the API, kept for parity with Android
    let id: String?
    let bankName: String
    let accountNumberLast4: String
    let ifscCode: String
    let accountHolderName: String
    let branchName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case bankName
        case accountNumberLast4
        case ifscCode
        case accountHolderName
        case branchName
    }

    init(id: String? = nil, bankName: String, accountNumberLast4: String, ifscCode: String, accountHolderName: String, branchName: String? = nil) {
        self.id = id
        self.bankName = bankName
        self.accountNumberLast4 = accountNumberLast4
        self.ifscCode = ifscCode
        self.accountHolderName = accountHolderName
        self.branchName = branchName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleID(.id)
        bankName = try container.decode(String.self, forKey: .bankName)
        accountNumberLast4 = try container.decode(String.self, forKey: .accountNumberLast4)
        ifscCode = try container.decode(String.self, forKey: .ifscCode)
        accountHolderName = try container.decode(String.self, forKey: .accountHolderName)
        branchName = try? container.decodeIfPresent(String.self, forKey: .branchName)
    }
}

/// `GET v1/experts/me/bank-details`. `bankDetail` is null until a payout account has been saved.
struct MyBankAccountResponse: Decodable, Equatable {
    let bankDetail: SavedBankAccount?
}

// MARK: - Recharge

struct CreateOrderRequest: Encodable {
    let userId: String
    let amount: Double
}

struct CreateOrderResponse: Decodable, Equatable {
    let keyId: String
    let orderId: String
    let amountInPaise: Int64
    let currency: String
    let transactionId: String

    enum CodingKeys: String, CodingKey {
        case keyId, orderId, amountInPaise, currency, transactionId
    }

    init(keyId: String, orderId: String, amountInPaise: Int64, currency: String, transactionId: String) {
        self.keyId = keyId
        self.orderId = orderId
        self.amountInPaise = amountInPaise
        self.currency = currency
        self.transactionId = transactionId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyId = try container.decode(String.self, forKey: .keyId)
        orderId = try container.decode(String.self, forKey: .orderId)
        guard let paise = container.flexibleDouble(.amountInPaise) else {
            throw DecodingError.dataCorruptedError(forKey: .amountInPaise, in: container, debugDescription: "Missing amountInPaise")
        }
        amountInPaise = Int64(paise)
        currency = container.lenientString(.currency) ?? "INR"
        guard let transactionId = container.flexibleID(.transactionId) else {
            throw DecodingError.dataCorruptedError(forKey: .transactionId, in: container, debugDescription: "Missing transactionId")
        }
        self.transactionId = transactionId
    }
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

struct SyncRechargesRequest: Encodable {
    let userId: String
    /// Only this recharge; nil syncs all of the user's recent unfinished recharges.
    let transactionId: String?
}

struct SyncRechargesResponse: Decodable {
    /// How many recharges this call credited.
    let credited: Int
    let newBalance: Double?

    enum CodingKeys: String, CodingKey {
        case credited, newBalance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        credited = container.flexibleInt(.credited) ?? 0
        newBalance = container.flexibleDouble(.newBalance)
    }
}

struct VerifyPaymentResponse: Decodable {
    let success: Bool
    let newBalance: Double?
    let transactionId: String?

    enum CodingKeys: String, CodingKey {
        case success, newBalance, transactionId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = (try? container.decode(Bool.self, forKey: .success)) ?? (container.flexibleInt(.success) == 1)
        newBalance = container.flexibleDouble(.newBalance)
        transactionId = container.flexibleID(.transactionId)
    }
}

struct WalletTransactionDTO: Decodable, Equatable {
    let id: String?
    let userId: String?
    /// Kept as the raw server string; `amountValue` parses it.
    let amount: String
    let type: String
    let source: String?
    let status: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, userId, amount, type, source, status, createdAt
    }

    init(id: String?, userId: String?, amount: String, type: String, source: String?, status: String, createdAt: String?) {
        self.id = id
        self.userId = userId
        self.amount = amount
        self.type = type
        self.source = source
        self.status = status
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleID(.id)
        userId = container.lenientString(.userId)
        amount = container.lenientString(.amount) ?? "0"
        type = container.lenientString(.type) ?? ""
        source = container.lenientString(.source)
        status = container.lenientString(.status) ?? ""
        createdAt = container.lenientString(.createdAt)
    }

    /// Android parses the string to Double and falls back to 0.0.
    var amountValue: Double {
        Double(amount.trimmingCharacters(in: .whitespaces)) ?? 0
    }
}

struct TransactionHistoryResponse: Decodable {
    let data: [WalletTransactionDTO]
    let total: Int?
    let page: Int
    let pageSize: Int
    let totalPages: Int

    enum CodingKeys: String, CodingKey {
        case data, total, page, pageSize, totalPages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = (try? container.decode([WalletTransactionDTO].self, forKey: .data)) ?? []
        total = container.flexibleInt(.total)
        page = container.flexibleInt(.page) ?? 1
        pageSize = container.flexibleInt(.pageSize) ?? data.count
        totalPages = container.flexibleInt(.totalPages) ?? page
    }
}

// MARK: - Pending holds

struct InitiateHoldRequest: Encodable {
    let clientId: String
    let consultantId: String
}

struct HoldExistsResponse: Decodable {
    let exists: Bool
    
    enum CodingKeys: String, CodingKey { case exists }
    
    init(exists: Bool) {
        self.exists = exists
    }
    
    /// Accepts `true`/`false` and `1`/`0`. A missing/unparseable value throws, so the caller reports
    /// "unknown" (nil) and the gate fails open.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let bool = try? container.decode(Bool.self, forKey: .exists) {
            exists = bool
        } else if let number = container.flexibleInt(.exists) {
            exists = number == 1
        } else {
            throw DecodingError.dataCorruptedError(forKey: .exists, in: container, debugDescription: "Missing exists")
        }
    }
}

/// `GET v1/pending-holds/status`. Defaults mirror Android's `PendingHoldStatusResponse`
/// (`exists=false`, `isActive=1`, `isRefundActive=1`, `refund_status="none"`) so a sparse payload
/// never fails the decode and silently hides the refund UI.
struct PendingHoldStatusResponse: Decodable, Equatable {
    let exists: Bool
    let isActive: Int
    let isRefundActive: Int
    /// 'none' | 'requested' | 'approved' | 'rejected'
    let refundStatus: String
    let pendingHoldId: String?
    let id: String?
    let clientId: String?
    let consultantId: String?
    /// The held amount — the upper bound of a partial refund.
    let amount: Double?
    let refundRequestId: String?
    /// Populated by the server when the cron auto-approved a refund and the in-room Matrix
    /// push-notification still needs to be sent. Whichever app sees this first calls
    /// `POST /v1/refund/auto-approval-claim/:id` to atomically claim the right to send it.
    let pendingAutoApprovalNotification: PendingAutoApprovalNotification?

    enum CodingKeys: String, CodingKey {
        case exists
        case isActive
        case isRefundActive
        case refundStatus = "refund_status"
        case pendingHoldId
        case id
        case clientId
        case consultantId
        case amount
        case refundRequestId
        case pendingAutoApprovalNotification
    }

    init(exists: Bool = false,
         isActive: Int = 1,
         isRefundActive: Int = 1,
         refundStatus: String = "none",
         pendingHoldId: String? = nil,
         id: String? = nil,
         clientId: String? = nil,
         consultantId: String? = nil,
         amount: Double? = nil,
         refundRequestId: String? = nil,
         pendingAutoApprovalNotification: PendingAutoApprovalNotification? = nil) {
        self.exists = exists
        self.isActive = isActive
        self.isRefundActive = isRefundActive
        self.refundStatus = refundStatus
        self.pendingHoldId = pendingHoldId
        self.id = id
        self.clientId = clientId
        self.consultantId = consultantId
        self.amount = amount
        self.refundRequestId = refundRequestId
        self.pendingAutoApprovalNotification = pendingAutoApprovalNotification
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exists = (try? container.decode(Bool.self, forKey: .exists)) ?? (container.flexibleInt(.exists) == 1)
        isActive = container.flexibleInt(.isActive) ?? 1
        isRefundActive = container.flexibleInt(.isRefundActive) ?? 1
        refundStatus = container.lenientString(.refundStatus) ?? "none"
        pendingHoldId = container.flexibleID(.pendingHoldId)
        id = container.flexibleID(.id)
        clientId = container.lenientString(.clientId)
        consultantId = container.lenientString(.consultantId)
        amount = container.flexibleDouble(.amount)
        refundRequestId = container.flexibleID(.refundRequestId)
        pendingAutoApprovalNotification = try? container.decodeIfPresent(PendingAutoApprovalNotification.self, forKey: .pendingAutoApprovalNotification)
    }

    /// Android: `pendingHoldId ?: id`.
    var holdIdString: String? {
        pendingHoldId ?? id
    }

    /// A session whose refund can still be requested or decided: the chat shows the refund UI.
    /// Android `status.exists && status.isRefundActive == 1`.
    var isRefundableSession: Bool {
        exists && isRefundActive == 1
    }

    var refundRequestIdString: String? {
        refundRequestId
    }
}

struct PendingAutoApprovalNotification: Decodable, Equatable {
    let refundRequestId: String
    let amount: Double?
    let clientId: String?
    let consultantId: String?

    enum CodingKeys: String, CodingKey {
        case refundRequestId, amount, clientId, consultantId
    }

    init(refundRequestId: String, amount: Double?, clientId: String?, consultantId: String?) {
        self.refundRequestId = refundRequestId
        self.amount = amount
        self.clientId = clientId
        self.consultantId = consultantId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let refundRequestId = container.flexibleID(.refundRequestId) else {
            throw DecodingError.dataCorruptedError(forKey: .refundRequestId, in: container, debugDescription: "Missing refundRequestId")
        }
        self.refundRequestId = refundRequestId
        amount = container.flexibleDouble(.amount)
        clientId = container.lenientString(.clientId)
        consultantId = container.lenientString(.consultantId)
    }
}

struct ClaimAutoApprovalBody: Encodable {
    let userId: String
}

struct ClaimAutoApprovalResponse: Decodable {
    let claimed: Bool
}

// MARK: - Refunds

struct RefundRequestBody: Encodable {
    let clientId: String
    let consultantId: String
    let pendingHoldId: String
}

struct ApproveRefundBody: Encodable {
    let refundRequestId: String
    let pendingHoldId: String
    /// Omitted (nil) ⇒ full refund. Synthesised `Encodable` uses `encodeIfPresent`, matching
    /// Android's "absent means full".
    let refundAmount: Double?
}

struct RejectRefundBody: Encodable {
    let refundRequestId: String
}

struct GenericRefundResponse: Decodable {
    let message: String?
    /// The amount actually returned to the client.
    let amount: Double?

    enum CodingKeys: String, CodingKey {
        case message, amount
    }

    init(message: String?, amount: Double?) {
        self.message = message
        self.amount = amount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = container.lenientString(.message)
        amount = container.flexibleDouble(.amount)
    }
}

/// Response from `POST /v1/refund/request`. The server returns `{ message, refundRequestId }`
/// — there is NO `success` field. All fields optional; presence of `message` indicates a
/// non-error response. Mirrors Android `RefundResponse` post-c980878.
struct RefundResponse: Decodable {
    let message: String?
    let refundRequestId: String?

    enum CodingKeys: String, CodingKey {
        case message, refundRequestId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = container.lenientString(.message)
        refundRequestId = container.flexibleID(.refundRequestId)
    }
}

/// Response for GET v1/refund/pending-for-consultant — list of client matrix IDs
/// that currently have an open refund request waiting on the given consultant.
struct PendingRefundsForConsultantResponse: Decodable {
    let clientIds: [String]

    enum CodingKeys: String, CodingKey { case clientIds }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientIds = (try? container.decodeIfPresent([String].self, forKey: .clientIds)) ?? []
    }
}

// MARK: - Call type

/// `POST v1/calls/type`. One record per room, last writer wins. The Matrix `m.rtc.notification`
/// event has no media field, so this record is how a receiver learns voice vs video.
struct SetCallTypeRequest: Encodable {
    let roomId: String
    /// "voice" | "video"
    let callType: String
    /// The caller's Matrix user ID. Omitted when nil.
    let callerId: String?
}

struct CallTypeResponse: Decodable {
    let roomId: String?
    let callType: String?
    let updatedAt: String?
}

// MARK: - Errors

enum WalletAPIError: Error, LocalizedError {
    case invalidResponse
    case http(status: Int, body: String?)
    case transport(underlying: Error)
    case decoding(underlying: Error)

    var statusCode: Int? {
        if case let .http(status, _) = self {
            return status
        }
        return nil
    }

    /// Human readable: the server's NestJS `message` (string, or the first of an array) when
    /// present, otherwise `HTTP <status>`.
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case let .http(status, body):
            return Self.serverMessage(from: body) ?? "HTTP \(status)"
        case let .transport(underlying):
            return underlying.localizedDescription
        case .decoding:
            return "Unexpected response from server"
        }
    }

    /// The API's own explanation of a refused request (e.g. "No bank branch found for IFSC ..."),
    /// only for a 4xx, where it is fit to show the user. Android `WalletApiException.userMessage`.
    var userMessage: String? {
        guard case let .http(status, body) = self, (400...499).contains(status),
              let message = Self.serverMessage(from: body, joinArrayWith: "\n"),
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return message
    }

    /// Parses the NestJS error envelope: `message` is either a string or an array of strings.
    static func serverMessage(from body: String?, joinArrayWith separator: String? = nil) -> String? {
        guard let data = body?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        if let messages = object["message"] as? [String], !messages.isEmpty {
            if let separator {
                return messages.joined(separator: separator)
            }
            return messages.first
        }
        return nil
    }
}
