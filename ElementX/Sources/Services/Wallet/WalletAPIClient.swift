//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Thin URLSession wrapper for the Clariva Wallet API.
/// Mirrors the Android `WalletApi` Retrofit interface so both clients hit the same endpoints.
/// Foundation-only so it can also be compiled into the NSE (call-type lookup for incoming calls).
struct WalletAPIClient {
    let baseURL: URL
    private let session: URLSession
    private let timeout: TimeInterval
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(baseURL: URL = ClarivaConfig.apiBaseURL, session: URLSession = .shared, timeout: TimeInterval = ClarivaConfig.requestTimeout) {
        self.baseURL = baseURL
        self.session = session
        self.timeout = timeout
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    /// A copy of this client whose requests give up after `timeout` seconds.
    func withTimeout(_ timeout: TimeInterval) -> WalletAPIClient {
        WalletAPIClient(baseURL: baseURL, session: session, timeout: timeout)
    }

    // MARK: - Users / wallet

    func createUser(name: String, webuddyName: String, isConsultant: Int) async throws -> WalletUserResponse {
        try await send("POST", path: ["v1", "users"], body: WalletCreateUserRequest(name: name, webuddyName: webuddyName, isConsultant: isConsultant))
    }

    func getWallet(webuddyName: String) async throws -> WalletUserResponse {
        try await send("GET", path: ["v1", "users", webuddyName])
    }

    func updateWallet(webuddyName: String, maxCredits: Int? = nil, isConsultant: Int? = nil) async throws {
        try await sendIgnoringResponse("PATCH", path: ["v1", "users", webuddyName], body: WalletUpdateUserRequest(maxCredits: maxCredits, isConsultant: isConsultant))
    }

    // MARK: - Bank details

    // See `WalletAPIClient+BankDetails.swift` (`v1/experts/me/bank-details`). The legacy
    // `POST v1/experts/bank-details` always failed ("Expert not found") and was removed with Android 093714e02a.

    // MARK: - Recharge

    func createOrder(userId: String, amount: Double) async throws -> CreateOrderResponse {
        try await send("POST", path: ["v1", "wallet", "recharge"], body: CreateOrderRequest(userId: userId, amount: amount))
    }

    func verifyPayment(_ body: VerifyPaymentRequest) async throws -> VerifyPaymentResponse {
        try await send("POST", path: ["v1", "wallet", "verify"], body: body)
    }

    /// Credits recharges that Razorpay captured but that were never verified (the checkout was closed
    /// while a UPI app finished the payment, the app was killed, …). The server asks Razorpay.
    func syncRecharges(userId: String, transactionId: String?) async throws -> SyncRechargesResponse {
        try await send("POST", path: ["v1", "wallet", "sync"], body: SyncRechargesRequest(userId: userId, transactionId: transactionId))
    }

    func getTransactionHistory(userId: String, page: Int, pageSize: Int) async throws -> TransactionHistoryResponse {
        try await send("GET", path: ["v1", "wallet", "history"], query: ["userId": userId, "page": String(page), "pageSize": String(pageSize)])
    }

    // MARK: - Pending holds

    func initiateHold(clientId: String, consultantId: String) async throws {
        try await sendIgnoringResponse("POST", path: ["v1", "pending-holds", "initiate"], body: InitiateHoldRequest(clientId: clientId, consultantId: consultantId))
    }

    func checkHoldExists(clientId: String, consultantId: String) async throws -> HoldExistsResponse {
        try await send("GET", path: ["v1", "pending-holds", "exists"], query: ["clientId": clientId, "consultantId": consultantId])
    }

    func getPendingHoldStatus(clientId: String, consultantId: String) async throws -> PendingHoldStatusResponse {
        try await send("GET", path: ["v1", "pending-holds", "status"], query: ["clientId": clientId, "consultantId": consultantId])
    }

    // MARK: - Refunds

    /// Returns the server's `{ message, refundRequestId }` payload. There is intentionally NO
    /// `success: Bool` field in the response shape — see `RefundResponse` doc comment.
    func requestRefund(clientId: String, consultantId: String, pendingHoldId: String) async throws -> RefundResponse {
        try await send("POST", path: ["v1", "refund", "request"], body: RefundRequestBody(clientId: clientId, consultantId: consultantId, pendingHoldId: pendingHoldId))
    }

    /// `refundAmount == nil` ⇒ full refund (the key is omitted from the body).
    func approveRefund(refundRequestId: String, pendingHoldId: String, refundAmount: Double?) async throws -> GenericRefundResponse {
        try await send("POST", path: ["v1", "refund", "approve"],
                       body: ApproveRefundBody(refundRequestId: refundRequestId, pendingHoldId: pendingHoldId, refundAmount: refundAmount))
    }

    func rejectRefund(refundRequestId: String) async throws -> GenericRefundResponse {
        try await send("POST", path: ["v1", "refund", "reject"], body: RejectRefundBody(refundRequestId: refundRequestId))
    }

    /// Bulk lookup: which clients currently have an open refund request directed at
    /// `consultantId`? Returns matrix IDs only — the caller already knows which rooms
    /// those map to in the chat list.
    func pendingRefundsForConsultant(consultantId: String) async throws -> PendingRefundsForConsultantResponse {
        try await send("GET", path: ["v1", "refund", "pending-for-consultant"], query: ["consultantId": consultantId])
    }

    /// Atomic claim for the in-room Matrix push-notification on an auto-approved refund.
    /// Server returns `{ claimed: true }` exactly once across all callers — the first app to
    /// claim wins the right to post the `m.room.message`; later calls return `{ claimed: false }`
    /// and the caller MUST skip the send so the room doesn't get duplicate notifications.
    func claimAutoApprovalNotification(refundRequestId: String, callerUserId: String) async throws -> ClaimAutoApprovalResponse {
        try await send("POST", path: ["v1", "refund", "auto-approval-claim", refundRequestId], body: ClaimAutoApprovalBody(userId: callerUserId))
    }

    // MARK: - Call type

    func setRoomCallType(roomId: String, callType: String, callerId: String?) async throws {
        try await sendIgnoringResponse("POST", path: ["v1", "calls", "type"], body: SetCallTypeRequest(roomId: roomId, callType: callType, callerId: callerId))
    }

    func getRoomCallType(roomId: String) async throws -> CallTypeResponse {
        try await send("GET", path: ["v1", "calls", "type"], query: ["roomId": roomId])
    }
    
    /// Android bounds the call-type POST/GET to 2 s so starting/answering a call never waits long.
    static let callTypeTimeout: TimeInterval = 2
    
    /// "voice" | "video" | nil (unknown, timed out or failed). Never throws. Usable from the NSE.
    /// Hard-capped at `callTypeTimeout` (a URLRequest timeout is only an idle timeout), because the
    /// incoming-call path must not be delayed by a slow server.
    func fetchRoomCallType(roomId: String) async -> String? {
        let client = withTimeout(Self.callTypeTimeout)
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                try? await client.getRoomCallType(roomId: roomId).callType?.lowercased()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(Self.callTypeTimeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Internals
    
    // Internal (not private) so endpoint groups can live in `WalletAPIClient+<Feature>.swift` files.
    // `bearerToken` is for the authorised routes (Clariva JWT or the session's Matrix access token).
    
    func send<T: Decodable>(_ method: String, path: [String], query: [String: String] = [:], bearerToken: String? = nil) async throws -> T {
        let data = try await perform(method, path: path, query: query, body: Data?.none, bearerToken: bearerToken)
        return try decode(data)
    }
    
    func send<B: Encodable, T: Decodable>(_ method: String, path: [String], query: [String: String] = [:], body: B, bearerToken: String? = nil) async throws -> T {
        let data = try await perform(method, path: path, query: query, body: encoder.encode(body), bearerToken: bearerToken)
        return try decode(data)
    }
    
    /// For endpoints whose body Android never reads (`Unit` responses) — a 2xx is success whatever
    /// the payload looks like (empty, plain text, or JSON).
    func sendIgnoringResponse<B: Encodable>(_ method: String, path: [String], body: B, bearerToken: String? = nil) async throws {
        _ = try await perform(method, path: path, query: [:], body: encoder.encode(body), bearerToken: bearerToken)
    }
    
    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw WalletAPIError.decoding(underlying: error)
        }
    }
    
    /// Never log the request headers: they can carry the Clariva JWT or the Matrix access token
    /// (Android 58233a769a redacts the Authorization header for the same reason).
    private func perform(_ method: String, path: [String], query: [String: String], body: Data?, bearerToken: String?) async throws -> Data {
        guard let url = makeURL(path: path, query: query) else {
            throw WalletAPIError.invalidResponse
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw WalletAPIError.transport(underlying: error)
        }
        
        guard let http = response as? HTTPURLResponse else {
            throw WalletAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WalletAPIError.http(status: http.statusCode, body: String(data: data, encoding: .utf8))
        }
        return data
    }
    
    /// Path segments are percent-encoded individually (Matrix IDs contain `@`, `:` and `!`), query
    /// values are encoded with a strict set so `+`, `&` and `=` survive the round trip.
    func makeURL(path: [String], query: [String: String]) -> URL? {
        let encodedPath = path
            .map { $0.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? $0 }
            .joined(separator: "/")
        guard var components = URLComponents(url: baseURL.appendingPathComponent(""), resolvingAgainstBaseURL: false) else {
            return nil
        }
        let basePath = components.percentEncodedPath.hasSuffix("/") ? components.percentEncodedPath : components.percentEncodedPath + "/"
        components.percentEncodedPath = basePath + encodedPath
        if !query.isEmpty {
            components.percentEncodedQueryItems = query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed)) }
        }
        return components.url
    }

    /// RFC 3986 pchar minus `/` (so a value can't add segments).
    private static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#")
        return set
    }()

    /// Unreserved characters plus the ones Matrix IDs use that are safe in a query value.
    private static let queryValueAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~@:!")
}
