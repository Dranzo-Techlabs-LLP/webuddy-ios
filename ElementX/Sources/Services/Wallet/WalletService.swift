//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

/// State holder for the wallet feature. Mirrors the Android `WalletService` so the iOS UI can
/// `.collect` (via `@Published`) the same flags — current credit balance, max credits, role.
///
/// All blocking work happens off the main actor; published values are pushed back on main.
@MainActor
final class WalletService: ObservableObject {
    static let defaultBaseURL = URL(string: "https://wallet.dranzo.com/")!

    let api: WalletAPIClient

    @Published private(set) var credits: Int?
    @Published private(set) var maxCredits: Int?
    @Published private(set) var originalMaxCredits: Int?
    /// nil = unknown, false = normal user (client), true = consultant.
    @Published private(set) var isCurrentUserConsultant: Bool?

    private var maxCreditsCache: [String: Int] = [:]

    init(baseURL: URL = WalletService.defaultBaseURL) {
        api = WalletAPIClient(baseURL: baseURL)
    }

    // MARK: - User lifecycle

    func ensureWalletUser(userId: String, name: String? = nil) async {
        do {
            _ = try await api.getWallet(webuddyName: userId)
        } catch WalletAPIError.http(let status, _) where status == 404 {
            // First time login — create the wallet user as a normal client by default.
            _ = try? await api.createUser(name: name ?? userId, webuddyName: userId, isConsultant: 0)
        } catch {
            MXLog.warning("[Wallet] ensureWalletUser failed: \(error)")
        }
    }

    func refreshBalance(userId: String) async {
        do {
            let response = try await api.getWallet(webuddyName: userId)
            credits = response.currentHoldInt
            maxCredits = response.maxCreditsInt
            originalMaxCredits = response.maxCreditsInt
            if let role = response.isConsultant {
                isCurrentUserConsultant = role == 1
            }
            maxCreditsCache[userId] = response.maxCreditsInt
        } catch {
            MXLog.warning("[Wallet] refreshBalance failed: \(error)")
            if credits == nil { credits = 0 }
            if maxCredits == nil { maxCredits = 100; originalMaxCredits = 100 }
        }
    }

    func setRole(userId: String, isConsultant: Bool) async -> Result<Void, Error> {
        do {
            _ = try await api.updateWallet(webuddyName: userId, isConsultant: isConsultant ? 1 : 0)
            isCurrentUserConsultant = isConsultant
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func updateMaxCredits(userId: String, _ value: Int) async -> Result<Void, Error> {
        do {
            _ = try await api.updateWallet(webuddyName: userId, maxCredits: value)
            maxCredits = value
            originalMaxCredits = value
            maxCreditsCache[userId] = value
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func setLocalMaxCredits(_ value: Int) {
        maxCredits = value
    }

    func getMaxCredits(userId: String) async -> Int? {
        if let cached = maxCreditsCache[userId] { return cached }
        do {
            let response = try await api.getWallet(webuddyName: userId)
            maxCreditsCache[userId] = response.maxCreditsInt
            return response.maxCreditsInt
        } catch {
            return nil
        }
    }

    // MARK: - Recharge

    func createOrder(userId: String, amount: Double) async -> Result<CreateOrderResponse, Error> {
        do { return .success(try await api.createOrder(userId: userId, amount: amount)) }
        catch { return .failure(error) }
    }

    func verifyPayment(_ body: VerifyPaymentRequest) async -> Result<VerifyPaymentResponse, Error> {
        do { return .success(try await api.verifyPayment(body)) }
        catch { return .failure(error) }
    }

    func getTransactionHistory(userId: String, page: Int, pageSize: Int) async -> Result<TransactionHistoryResponse, Error> {
        do { return .success(try await api.getTransactionHistory(userId: userId, page: page, pageSize: pageSize)) }
        catch { return .failure(error) }
    }

    // MARK: - Holds

    /// Consultants don't initiate holds. Short-circuit so we never spam the server with 403s.
    func initiateHold(clientId: String, consultantId: String) async {
        if isCurrentUserConsultant == true { return }
        do {
            try await api.initiateHold(clientId: clientId, consultantId: consultantId)
        } catch {
            MXLog.warning("[Wallet] initiateHold failed: \(error)")
        }
    }

    func checkHoldExists(clientId: String, consultantId: String) async -> Bool {
        (try? await api.checkHoldExists(clientId: clientId, consultantId: consultantId).exists) ?? false
    }

    func getPendingHoldStatus(clientId: String, consultantId: String) async -> PendingHoldStatusResponse? {
        try? await api.getPendingHoldStatus(clientId: clientId, consultantId: consultantId)
    }

    // MARK: - Refunds

    func requestRefund(clientId: String, consultantId: String, pendingHoldId: String) async -> Result<GenericRefundResponse, Error> {
        do { return .success(try await api.requestRefund(clientId: clientId, consultantId: consultantId, pendingHoldId: pendingHoldId)) }
        catch { return .failure(error) }
    }

    func approveRefund(refundRequestId: String, pendingHoldId: String) async -> Result<GenericRefundResponse, Error> {
        do { return .success(try await api.approveRefund(refundRequestId: refundRequestId, pendingHoldId: pendingHoldId)) }
        catch { return .failure(error) }
    }

    func rejectRefund(refundRequestId: String) async -> Result<GenericRefundResponse, Error> {
        do { return .success(try await api.rejectRefund(refundRequestId: refundRequestId)) }
        catch { return .failure(error) }
    }
}
