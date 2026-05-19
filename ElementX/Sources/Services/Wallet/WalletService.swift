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
    /// Set of client matrix IDs that currently have an open refund request awaiting this
    /// consultant's decision. Powers the chat-list refund-pending badge.
    @Published private(set) var pendingRefundRequestClients: Set<String> = []
    /// Role selection captured on the signup screen, consumed when the wallet user is
    /// created after login completes. Mirrors Android `WalletService.pendingIsConsultant`.
    @Published private(set) var pendingIsConsultant: Bool = false

    private var maxCreditsCache: [String: Int] = [:]
    /// Per-user `isConsultant` cache populated as a side-effect of `getMaxCredits`. Used by
    /// `getRecipientChatRate` to decide whether to render the chat-list per-row credits: only
    /// a consultant has a chat rate; client-to-client and consultant-side-viewing-a-client
    /// rooms stay blank. Mirrors Android `WalletService.isConsultantCache`.
    private var isConsultantCache: [String: Bool] = [:]
    /// Tracks the last user whose wallet was refreshed; on user change we flush stale
    /// in-memory state so a previous account's data doesn't leak into the new session.
    private var lastRefreshedUserId: String?

    init(baseURL: URL = WalletService.defaultBaseURL) {
        api = WalletAPIClient(baseURL: baseURL)
    }

    // MARK: - User lifecycle

    func ensureWalletUser(userId: String, name: String? = nil) async {
        do {
            _ = try await api.getWallet(webuddyName: userId)
        } catch WalletAPIError.http(let status, _) where status == 404 {
            // First-time login — create the wallet user using the role chosen on the
            // signup screen (pendingIsConsultant; defaults to normal user = 0).
            let isConsultant = pendingIsConsultant ? 1 : 0
            _ = try? await api.createUser(name: name ?? userId, webuddyName: userId, isConsultant: isConsultant)
            isCurrentUserConsultant = pendingIsConsultant
            // Clear the pending flag so a subsequent login doesn't inherit stale state.
            pendingIsConsultant = false
        } catch {
            MXLog.warning("[Wallet] ensureWalletUser failed: \(error)")
        }
    }

    func setPendingIsConsultant(_ value: Bool) {
        pendingIsConsultant = value
    }

    func refreshBalance(userId: String) async {
        // When the active user changes (account switch / logout+login), flush stale state
        // before fetching the new user's data. Avoids the previous account's credits/role
        // bleeding into the new session for the window between login and refresh completing.
        if let previousUserId = lastRefreshedUserId, previousUserId != userId {
            credits = nil
            maxCredits = nil
            originalMaxCredits = nil
            isCurrentUserConsultant = nil
            pendingRefundRequestClients = []
            maxCreditsCache.removeAll()
            isConsultantCache.removeAll()
        }
        lastRefreshedUserId = userId

        do {
            let response = try await api.getWallet(webuddyName: userId)
            // Only overwrite credits / maxCredits on a real parsed value; never clobber the
            // last-known-good value with nil from a partial response.
            if let parsed = response.currentHoldInt { credits = parsed }
            if let parsedMax = response.maxCreditsInt {
                maxCredits = parsedMax
                originalMaxCredits = parsedMax
                maxCreditsCache[userId] = parsedMax
            }
            if let role = response.isConsultant {
                isCurrentUserConsultant = role == 1
            }
        } catch {
            MXLog.warning("[Wallet] refreshBalance failed: \(error)")
            // Only seed defaults when we have no value at all; preserve known-good values.
            if credits == nil { credits = 0 }
            if maxCredits == nil { maxCredits = 100; originalMaxCredits = 100 }
        }
    }

    /// Refresh the set of clients with an open refund request awaiting this consultant.
    /// No-op (and clears the set) if the current user is not a consultant — the chat-list
    /// badge only renders for consultants.
    func refreshPendingRefundRequests(consultantUserId: String) async {
        guard isCurrentUserConsultant == true else {
            pendingRefundRequestClients = []
            return
        }
        do {
            let response = try await api.pendingRefundsForConsultant(consultantId: consultantUserId)
            pendingRefundRequestClients = Set(response.clientIds)
        } catch {
            // Leave the previous value untouched on transient failure — better to show a
            // stale badge than to clear correct state because of one network blip.
            MXLog.warning("[Wallet] refreshPendingRefundRequests failed: \(error)")
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

    /// Fetch the wallet info for `userId` — which may be a different user than the locally
    /// logged-in account. Populates `maxCreditsCache` and `isConsultantCache` as side effects.
    ///
    /// MUST NOT touch `maxCredits` / `originalMaxCredits`: those track the LOCAL user's own
    /// settings and are owned by `refreshBalance`. Writing every queried recipient's
    /// max_credits into the local state would corrupt the consultant's own rate every time
    /// the chat list looked up a chat partner.
    func getMaxCredits(userId: String) async -> Int? {
        if let cached = maxCreditsCache[userId] { return cached }
        do {
            let response = try await api.getWallet(webuddyName: userId)
            if let parsed = response.maxCreditsInt {
                maxCreditsCache[userId] = parsed
            }
            if let role = response.isConsultant {
                isConsultantCache[userId] = role == 1
            }
            return response.maxCreditsInt
        } catch {
            return nil
        }
    }

    /// Returns `userId`'s chat rate (their `max_credits`) ONLY if they are a consultant.
    /// For clients (or unknown role) returns `nil` — clients don't have a rate, so the
    /// chat-list row stays blank rather than showing a meaningless number. Mirrors Android
    /// `WalletService.getRecipientChatRate`.
    func getRecipientChatRate(userId: String) async -> Int? {
        // getMaxCredits is cache-first and populates both caches as a side effect.
        let maxCreditsValue = await getMaxCredits(userId: userId)
        return isConsultantCache[userId] == true ? maxCreditsValue : nil
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

    func requestRefund(clientId: String, consultantId: String, pendingHoldId: String) async -> Result<RefundResponse, Error> {
        do { return .success(try await api.requestRefund(clientId: clientId, consultantId: consultantId, pendingHoldId: pendingHoldId)) }
        catch { return .failure(error) }
    }

    func approveRefund(refundRequestId: String, pendingHoldId: String) async -> Result<GenericRefundResponse, Error> {
        do {
            let response = try await api.approveRefund(refundRequestId: refundRequestId, pendingHoldId: pendingHoldId)
            return .success(response)
        } catch { return .failure(error) }
    }

    func rejectRefund(refundRequestId: String) async -> Result<GenericRefundResponse, Error> {
        do { return .success(try await api.rejectRefund(refundRequestId: refundRequestId)) }
        catch { return .failure(error) }
    }

    /// Try to atomically claim the right to post the in-room Matrix push-notification message
    /// for an auto-approved refund.
    ///
    /// Returns `true` if THIS device won the claim and should send the message. Returns
    /// `false` if another device already claimed it (do not send, the room is covered)
    /// OR if the network call failed (do not send to avoid duplicates on retry). Mirrors
    /// Android `WalletService.claimAutoApprovalNotification`.
    func claimAutoApprovalNotification(refundRequestId: Int, callerUserId: String) async -> Bool {
        do {
            let response = try await api.claimAutoApprovalNotification(refundRequestId: String(refundRequestId),
                                                                       callerUserId: callerUserId)
            return response.claimed
        } catch {
            MXLog.warning("[Wallet] claimAutoApprovalNotification failed for \(refundRequestId): \(error); skipping send")
            return false
        }
    }
}
