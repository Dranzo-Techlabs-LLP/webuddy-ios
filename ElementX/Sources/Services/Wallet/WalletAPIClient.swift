//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Thin URLSession wrapper for the Webuddy Wallet API.
/// Mirrors the Android `WalletApi` Retrofit interface so both clients hit the same endpoints.
struct WalletAPIClient {
    let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    // MARK: - Users / wallet

    func createUser(name: String, webuddyName: String, isConsultant: Int) async throws -> WalletUserResponse {
        try await post("v1/users", body: WalletCreateUserRequest(name: name, webuddyName: webuddyName, isConsultant: isConsultant))
    }

    func getWallet(webuddyName: String) async throws -> WalletUserResponse {
        try await get("v1/users/\(percentEncode(webuddyName))")
    }

    func updateWallet(webuddyName: String, maxCredits: Int? = nil, isConsultant: Int? = nil) async throws -> WalletUserResponse {
        try await patch("v1/users/\(percentEncode(webuddyName))", body: WalletUpdateUserRequest(maxCredits: maxCredits, isConsultant: isConsultant))
    }

    // MARK: - Recharge

    func createOrder(userId: String, amount: Double) async throws -> CreateOrderResponse {
        try await post("v1/wallet/recharge", body: CreateOrderRequest(userId: userId, amount: amount))
    }

    func verifyPayment(_ body: VerifyPaymentRequest) async throws -> VerifyPaymentResponse {
        try await post("v1/wallet/verify", body: body)
    }

    func getTransactionHistory(userId: String, page: Int, pageSize: Int) async throws -> TransactionHistoryResponse {
        let query = "userId=\(percentEncode(userId))&page=\(page)&pageSize=\(pageSize)"
        return try await get("v1/wallet/history?\(query)")
    }

    // MARK: - Pending holds

    func initiateHold(clientId: String, consultantId: String) async throws {
        let _: EmptyResponse = try await post("v1/pending-holds/initiate", body: InitiateHoldRequest(clientId: clientId, consultantId: consultantId))
    }

    func checkHoldExists(clientId: String, consultantId: String) async throws -> HoldExistsResponse {
        let query = "clientId=\(percentEncode(clientId))&consultantId=\(percentEncode(consultantId))"
        return try await get("v1/pending-holds/exists?\(query)")
    }

    func getPendingHoldStatus(clientId: String, consultantId: String) async throws -> PendingHoldStatusResponse {
        let query = "clientId=\(percentEncode(clientId))&consultantId=\(percentEncode(consultantId))"
        return try await get("v1/pending-holds/status?\(query)")
    }

    // MARK: - Refunds

    func requestRefund(clientId: String, consultantId: String, pendingHoldId: String) async throws -> GenericRefundResponse {
        try await post("v1/refund/request", body: RefundRequestBody(clientId: clientId, consultantId: consultantId, pendingHoldId: pendingHoldId))
    }

    func approveRefund(refundRequestId: String, pendingHoldId: String) async throws -> GenericRefundResponse {
        try await post("v1/refund/approve", body: ApproveRefundBody(refundRequestId: refundRequestId, pendingHoldId: pendingHoldId))
    }

    func rejectRefund(refundRequestId: String) async throws -> GenericRefundResponse {
        try await post("v1/refund/reject", body: RejectRefundBody(refundRequestId: refundRequestId))
    }

    // MARK: - Internals

    private func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await send(method: "GET", path: path, body: Optional<EmptyBody>.none)
    }

    private func post<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        try await send(method: "POST", path: path, body: body)
    }

    private func patch<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        try await send(method: "PATCH", path: path, body: body)
    }

    private func send<B: Encodable, T: Decodable>(method: String, path: String, body: B?) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw WalletAPIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = body {
            request.httpBody = try encoder.encode(body)
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
        if !(200..<300).contains(http.statusCode) {
            throw WalletAPIError.http(status: http.statusCode, body: String(data: data, encoding: .utf8))
        }
        if data.isEmpty, let empty = EmptyResponse() as? T {
            return empty
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw WalletAPIError.decoding(underlying: error)
        }
    }
}

private struct EmptyBody: Encodable {}

/// Sentinel for endpoints that return no body (or that we don't need to decode).
struct EmptyResponse: Decodable { init() {} }
