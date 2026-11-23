//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

/// State holder for the wallet feature. Mirrors the Android `WalletService` so the iOS UI can
/// observe (via `@Published`) the same flags — current credit balance, max credits, role.
///
/// Identity: every call uses the Matrix user ID as the wallet `Webuddy_name`. Android maps
/// `sessionStore.webuddyName ?: matrixId`, and the two are equal by construction (the create
/// request sends `Webuddy_name = userId`).
@MainActor
final class WalletService: ObservableObject {
    static let defaultBaseURL = ClarivaConfig.apiBaseURL
    
    /// Stand-in for views when no wallet is registered (unit/UI/preview test hosts). Its host never
    /// resolves, so it can't create or read real wallet rows.
    static let offline = WalletService(baseURL: URL(string: "https://wallet.invalid/")!)

    let api: WalletAPIClient

    @Published private(set) var credits: Int?
    @Published private(set) var maxCredits: Int?
    @Published private(set) var originalMaxCredits: Int?
    /// nil = unknown, false = normal user (client), true = consultant.
    @Published private(set) var isCurrentUserConsultant: Bool?
    /// Set of client matrix IDs that currently have an open refund request awaiting this
    /// consultant's decision. Powers the chat-list refund-pending badge.
    @Published private(set) var pendingRefundRequestClients: Set<String> = []
    /// Role selection captured during sign-up, consumed when the wallet user is created after
    /// login completes. Mirrors Android `WalletService.pendingIsConsultant`.
    @Published private(set) var pendingIsConsultant = false

    /// Emits the `client|consultant` key whenever the cached hold state for a pair changes, so an
    /// open chat gate can re-read it without polling.
    let holdStateDidChange = PassthroughSubject<String, Never>()

    /// Per-user `max_credits` (a consultant's chat rate). Never expires — mirrors Android.
    private var maxCreditsCache: [String: Int] = [:]
    /// Per-user `isConsultant`, populated as a side-effect of `getMaxCredits`.
    private var isConsultantCache: [String: Bool] = [:]
    /// Last known `pending-holds/exists` result per `client|consultant`, used to paint the chat
    /// gate instantly on open (Android fc38a7a6a0).
    private var holdExistsCache: [String: Bool] = [:]
    /// In-flight `initiateHold` requests per `client|consultant`. Two overlapping requests can make
    /// the server take two holds (its "reuse the live hold" check can miss one still committing),
    /// so a second billable event joins the request already on its way.
    private var initiateHoldTasks: [String: Task<Bool, Never>] = [:]
    /// Tracks the last user whose wallet was refreshed; on user change we flush stale
    /// in-memory state so a previous account's data doesn't leak into the new session.
    private var lastRefreshedUserId: String?
    /// Per `client|consultant` (as passed to `getPendingHoldStatus`): whether the last status showed
    /// a refundable session, so that session ending (its refund completed, fully or partially) is noticed.
    private var refundableSessionOpen: [String: Bool] = [:]

    /// The Bearer token of the `v1/experts/me/*` routes. Replaceable in tests.
    var sessionAccessToken: (String) -> String? = MatrixSessionAccessToken.forUser

    init(baseURL: URL = ClarivaConfig.apiBaseURL) {
        api = WalletAPIClient(baseURL: baseURL)
    }

    // MARK: - User lifecycle

    /// Makes sure a wallet row exists for `userId`, creating it with the role chosen at sign-up
    /// (`pendingIsConsultant`) on a 404. Returns whether the user exists afterwards.
    @discardableResult
    func ensureWalletUser(userId: String) async -> Bool {
        do {
            let response = try await api.getWallet(webuddyName: userId)
            apply(response, for: userId)
            return true
        } catch let error as WalletAPIError where error.statusCode == 404 {
            return await createUser(userId: userId)
        } catch {
            MXLog.warning("[Wallet] ensureWalletUser failed: \(error)")
            return false
        }
    }

    /// Android `createUser`: `name` and `Webuddy_name` are both the Matrix ID; the role and the
    /// pending flag only change when the server accepted the row.
    private func createUser(userId: String) async -> Bool {
        let isConsultant = pendingIsConsultant
        do {
            let response = try await api.createUser(name: userId, webuddyName: userId, isConsultant: isConsultant ? 1 : 0)
            setIfChanged(\.isCurrentUserConsultant, response.isConsultant.map { $0 == 1 } ?? isConsultant)
            pendingIsConsultant = false
            if lastRefreshedUserId == nil || lastRefreshedUserId == userId {
                apply(response, for: userId)
            }
            return true
        } catch {
            MXLog.warning("[Wallet] createUser failed: \(error)")
            return false
        }
    }

    func setPendingIsConsultant(_ value: Bool) {
        pendingIsConsultant = value
    }

    func refreshBalance(userId: String) async {
        // When the active user changes (account switch / logout+login), flush stale state
        // before fetching the new user's data so the previous account's credits/role never
        // bleed into the new session.
        if let previousUserId = lastRefreshedUserId, previousUserId != userId {
            credits = nil
            maxCredits = nil
            originalMaxCredits = nil
            isCurrentUserConsultant = nil
            pendingRefundRequestClients = []
            maxCreditsCache.removeAll()
            isConsultantCache.removeAll()
            holdExistsCache.removeAll()
            refundableSessionOpen.removeAll()
        }
        lastRefreshedUserId = userId

        do {
            let response = try await withUserSelfHeal(userId) {
                try await self.api.getWallet(webuddyName: userId)
            }
            apply(response, for: userId)
        } catch {
            // A cancelled refresh (e.g. a chat gate restarting its load when the DM partner
            // resolves) says nothing about the wallet: seeding `credits = 0` here would briefly
            // restrict a client who can afford the consultant.
            guard !Task.isCancelled else { return }
            MXLog.warning("[Wallet] refreshBalance failed: \(error)")
            // Only seed defaults when we have no value at all; preserve known-good values.
            if credits == nil { credits = 0 }
            if maxCredits == nil {
                maxCredits = 100
                originalMaxCredits = 100
            }
        }
    }

    /// Only overwrites on a parsed value, and only publishes real changes — every chat-list cell
    /// observes this object, and the home screen refreshes every 8 s.
    private func apply(_ response: WalletUserResponse, for userId: String) {
        guard lastRefreshedUserId == nil || lastRefreshedUserId == userId else { return }
        if let parsed = response.currentHoldInt {
            setIfChanged(\.credits, parsed)
        }
        if let parsedMax = response.maxCreditsInt {
            setIfChanged(\.maxCredits, parsedMax)
            setIfChanged(\.originalMaxCredits, parsedMax)
            maxCreditsCache[userId] = parsedMax
        }
        if let role = response.isConsultant {
            setIfChanged(\.isCurrentUserConsultant, role == 1)
            isConsultantCache[userId] = role == 1
        }
    }

    private func setIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<WalletService, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    /// Android fc87fb53ec: a 404 ("User not found") means the wallet row was never created (e.g.
    /// a sign-up whose provisioning call was lost). Create it and retry the original call once.
    private func withUserSelfHeal<T>(_ userId: String, _ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as WalletAPIError where error.statusCode == 404 {
            guard await createUser(userId: userId) else { throw error }
            return try await operation()
        }
    }

    /// Refresh the set of clients with an open refund request awaiting this consultant.
    /// No-op (and clears the set) if the current user is not a consultant — the chat-list
    /// badge only renders for consultants.
    func refreshPendingRefundRequests(consultantUserId: String) async {
        guard isCurrentUserConsultant == true else {
            setIfChanged(\.pendingRefundRequestClients, [])
            return
        }
        do {
            let response = try await api.pendingRefundsForConsultant(consultantId: consultantUserId)
            setIfChanged(\.pendingRefundRequestClients, Set(response.clientIds))
        } catch {
            // Leave the previous value untouched on transient failure — better to show a
            // stale badge than to clear correct state because of one network blip.
            MXLog.warning("[Wallet] refreshPendingRefundRequests failed: \(error)")
        }
    }

    func setRole(userId: String, isConsultant: Bool) async -> Result<Void, Error> {
        do {
            try await api.updateWallet(webuddyName: userId, isConsultant: isConsultant ? 1 : 0)
            isCurrentUserConsultant = isConsultant
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func updateMaxCredits(userId: String, _ value: Int) async -> Result<Void, Error> {
        do {
            try await api.updateWallet(webuddyName: userId, maxCredits: value)
            maxCredits = value
            originalMaxCredits = value
            maxCreditsCache[userId] = value
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Local optimistic value while the consultant types (Android `setMaxCredits`).
    func setLocalMaxCredits(_ value: Int) {
        maxCredits = value
    }

    /// Fetch the wallet info for `userId` — which may be a different user than the locally
    /// logged-in account. Populates `maxCreditsCache` and `isConsultantCache` as side effects.
    ///
    /// MUST NOT touch `maxCredits` / `originalMaxCredits`: those track the LOCAL user's own
    /// settings and are owned by `refreshBalance`.
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

    /// Synchronous first-paint hint for the chat gate (Android `getCachedMaxCredits`).
    func cachedMaxCredits(userId: String) -> Int? {
        maxCreditsCache[userId]
    }

    /// Returns `userId`'s chat rate (their `max_credits`) ONLY if they are a consultant.
    /// For clients (or unknown role) returns `nil` — clients don't have a rate, so the
    /// chat-list row stays blank rather than showing a meaningless number.
    func getRecipientChatRate(userId: String) async -> Int? {
        // getMaxCredits is cache-first and populates both caches as a side effect.
        let maxCreditsValue = await getMaxCredits(userId: userId)
        return isConsultantCache[userId] == true ? maxCreditsValue : nil
    }

    // MARK: - Bank details (Android 093714e02a)

    /// `userId`'s saved payout account, or `nil` when none is saved yet.
    func getMyBankDetails(userId: String) async -> Result<SavedBankAccount?, Error> {
        await withSessionToken(userId) { [api] bearerToken in
            try await api.getMyBankDetails(bearerToken: bearerToken).bankDetail
        }
    }

    /// Saves `userId`'s payout account, replacing the previous one. A 4xx carries the API's own
    /// reason (`WalletAPIError.userMessage`), e.g. an IFSC with no branch.
    func saveMyBankDetails(userId: String, request: ClarivaBankDetailsRequest) async -> Result<SavedBankAccount, Error> {
        await withSessionToken(userId) { [api] bearerToken in
            try await api.saveMyBankDetails(request, bearerToken: bearerToken)
        }
    }

    /// Runs a call authorised by `userId`'s Matrix access token (see `MatrixSessionAccessToken`).
    private func withSessionToken<T>(_ userId: String, _ operation: (String) async throws -> T) async -> Result<T, Error> {
        guard let accessToken = sessionAccessToken(userId) else {
            MXLog.error("[Wallet] No session access token for \(userId)")
            return .failure(WalletSessionError.noSession)
        }
        do {
            return try await .success(operation(accessToken))
        } catch {
            MXLog.error("[Wallet] Bank details call failed for \(userId): \(error)")
            return .failure(error)
        }
    }

    // MARK: - Recharge

    func createOrder(userId: String, amount: Double) async -> Result<CreateOrderResponse, Error> {
        do {
            let order = try await withUserSelfHeal(userId) {
                try await self.api.createOrder(userId: userId, amount: amount)
            }
            return .success(order)
        } catch {
            return .failure(error)
        }
    }

    /// On a verified payment the balance is refreshed here (Android does the same in the service).
    func verifyPayment(_ body: VerifyPaymentRequest) async -> Result<VerifyPaymentResponse, Error> {
        do {
            let response = try await api.verifyPayment(body)
            if response.success {
                await refreshBalance(userId: body.userId)
            }
            return .success(response)
        } catch {
            return .failure(error)
        }
    }

    /// Asks the server to credit recharges Razorpay captured that were never verified, and refreshes
    /// the balance when it did. Returns how many were credited (0 on any error: the server's own
    /// periodic reconciliation still catches them).
    @discardableResult
    func syncRecharges(userId: String, transactionId: String? = nil) async -> Int {
        do {
            let response = try await api.syncRecharges(userId: userId, transactionId: transactionId)
            if response.credited > 0 {
                MXLog.info("[Wallet] Sync credited \(response.credited) unverified recharge(s)")
                await refreshBalance(userId: userId)
            }
            return response.credited
        } catch {
            MXLog.warning("[Wallet] Recharge sync failed: \(error)")
            return 0
        }
    }

    func getTransactionHistory(userId: String, page: Int, pageSize: Int = 10) async -> Result<TransactionHistoryResponse, Error> {
        do {
            let response = try await withUserSelfHeal(userId) {
                try await self.api.getTransactionHistory(userId: userId, page: page, pageSize: pageSize)
            }
            return .success(response)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Holds

    private func holdKey(clientId: String, consultantId: String) -> String {
        "\(clientId)|\(consultantId)"
    }

    /// Takes (or reuses) the 24 h prepaid hold for the pair. Consultants never initiate holds, so
    /// this short-circuits to success for them (no 403 spam). The cache is set on success and
    /// cleared on failure — the server may have committed a hold whose response was lost.
    @discardableResult
    func initiateHold(clientId: String, consultantId: String) async -> Bool {
        if isCurrentUserConsultant == true { return true }
        let key = holdKey(clientId: clientId, consultantId: consultantId)
        if let inFlight = initiateHoldTasks[key] {
            return await inFlight.value
        }

        let task = Task { [api] () async -> Bool in
            do {
                try await api.initiateHold(clientId: clientId, consultantId: consultantId)
                self.holdExistsCache[key] = true
                self.holdStateDidChange.send(key)
                return true
            } catch {
                MXLog.warning("[Wallet] initiateHold failed: \(error)")
                self.holdExistsCache[key] = nil
                self.holdStateDidChange.send(key)
                return false
            }
        }
        initiateHoldTasks[key] = task
        let result = await task.value
        if initiateHoldTasks[key] == task {
            initiateHoldTasks[key] = nil
        }
        return result
    }

    /// `nil` on any error — unknown must never be treated as "no hold" (Android 165e2616fd), or a
    /// network blip would restrict a client who already paid.
    func checkHoldExists(clientId: String, consultantId: String) async -> Bool? {
        do {
            let exists = try await api.checkHoldExists(clientId: clientId, consultantId: consultantId).exists
            holdExistsCache[holdKey(clientId: clientId, consultantId: consultantId)] = exists
            return exists
        } catch {
            MXLog.warning("[Wallet] checkHoldExists failed: \(error)")
            return nil
        }
    }

    /// Synchronous first-paint hint for the chat gate (Android `getCachedHoldExists`).
    func cachedHoldExists(clientId: String, consultantId: String) -> Bool? {
        holdExistsCache[holdKey(clientId: clientId, consultantId: consultantId)]
    }

    /// Also notices a refundable session ending (Android 049d08c0e2): see `handleRefundableSessionEnded`.
    func getPendingHoldStatus(clientId: String, consultantId: String) async -> PendingHoldStatusResponse? {
        do {
            let status = try await api.getPendingHoldStatus(clientId: clientId, consultantId: consultantId)
            let key = holdKey(clientId: clientId, consultantId: consultantId)
            let wasOpen = refundableSessionOpen[key]
            refundableSessionOpen[key] = status.isRefundableSession
            if Self.didRefundableSessionEnd(wasOpen: wasOpen, status: status) {
                handleRefundableSessionEnded(clientId: clientId, consultantId: consultantId)
            }
            return status
        } catch {
            // Errors say nothing about the session: the tracked state is left untouched.
            MXLog.warning("[Wallet] getPendingHoldStatus failed: \(error)")
            return nil
        }
    }

    /// The previous status showed a refundable session and this one doesn't: its refund completed
    /// (fully or partially), was decided, or the session settled.
    nonisolated static func didRefundableSessionEnd(wasOpen: Bool?, status: PendingHoldStatusResponse) -> Bool {
        wasOpen == true && !status.isRefundableSession
    }

    /// A completed refund ends the session server-side (Wallet-API 7f1fb5b0d), so the chat may no longer
    /// be covered. Drop the cached hold answer and tell an open chat gate (it re-checks the hold, so
    /// the client's next message shows "Start a new session?" at once instead of after its 60 s
    /// refresh), and refresh the balance the refund credited.
    ///
    /// Unlike Android, `checkHoldExists` itself doesn't emit `holdStateDidChange`: the gate calls it
    /// in response to that event, so emitting there would loop.
    private func handleRefundableSessionEnded(clientId: String, consultantId: String) {
        let key = holdKey(clientId: clientId, consultantId: consultantId)
        MXLog.info("[Refund] Refundable session ended for \(key); re-checking the hold")
        holdExistsCache[key] = nil
        holdStateDidChange.send(key)

        // Only the signed-in user's own wallet is tracked here (a different id would flush it).
        guard let localUserId = lastRefreshedUserId, localUserId == clientId || localUserId == consultantId else {
            return
        }
        Task { [weak self] in
            await self?.refreshBalance(userId: localUserId)
        }
    }

    // MARK: - Refunds

    func requestRefund(clientId: String, consultantId: String, pendingHoldId: String) async -> Result<RefundResponse, Error> {
        do {
            return try await .success(api.requestRefund(clientId: clientId, consultantId: consultantId, pendingHoldId: pendingHoldId))
        } catch {
            return .failure(error)
        }
    }

    /// `refundAmount == nil` ⇒ full refund.
    func approveRefund(refundRequestId: String, pendingHoldId: String, refundAmount: Double? = nil) async -> Result<GenericRefundResponse, Error> {
        do {
            return try await .success(api.approveRefund(refundRequestId: refundRequestId, pendingHoldId: pendingHoldId, refundAmount: refundAmount))
        } catch {
            return .failure(error)
        }
    }

    func rejectRefund(refundRequestId: String) async -> Result<GenericRefundResponse, Error> {
        do {
            return try await .success(api.rejectRefund(refundRequestId: refundRequestId))
        } catch {
            return .failure(error)
        }
    }

    /// Try to atomically claim the right to post the in-room Matrix push-notification message
    /// for an auto-approved refund.
    ///
    /// Returns `true` if THIS device won the claim and should send the message. Returns
    /// `false` if another device already claimed it OR if the network call failed (do not send
    /// to avoid duplicates on retry). Mirrors Android `WalletService.claimAutoApprovalNotification`.
    func claimAutoApprovalNotification(refundRequestId: String, callerUserId: String) async -> Bool {
        do {
            let response = try await api.claimAutoApprovalNotification(refundRequestId: refundRequestId, callerUserId: callerUserId)
            return response.claimed
        } catch {
            MXLog.warning("[Wallet] claimAutoApprovalNotification failed for \(refundRequestId): \(error); skipping send")
            return false
        }
    }

    // MARK: - Call type

    /// Records the caller's media choice so the receiver (iOS or Android) can ring with the right
    /// type — the Matrix `m.rtc.notification` event carries no media field. Bounded to 2 s and
    /// never throws.
    func setRoomCallType(roomId: String, isVideo: Bool, callerId: String?) async {
        do {
            try await api.withTimeout(WalletAPIClient.callTypeTimeout)
                .setRoomCallType(roomId: roomId, callType: isVideo ? "video" : "voice", callerId: callerId)
        } catch {
            MXLog.warning("[Wallet] setRoomCallType failed for \(roomId): \(error)")
        }
    }

    /// "voice" | "video" | nil (unknown or error). Bounded to 2 s.
    func getRoomCallType(roomId: String) async -> String? {
        await api.fetchRoomCallType(roomId: roomId)
    }
}

enum WalletSessionError: Error, LocalizedError {
    /// No stored Matrix session for the user, so a `v1/experts/me/*` call can't be authorised.
    case noSession

    var errorDescription: String? {
        "Please sign in again."
    }
}

/// The caller's payout account, as the Bank Details screen needs it. `WalletService` is the real one;
/// previews and tests use a stub, so they never read the keychain or reach the network.
@MainActor
protocol PayoutAccountServiceProtocol {
    /// `userId`'s saved payout account, or `nil` when none is saved yet.
    func getMyBankDetails(userId: String) async -> Result<SavedBankAccount?, Error>
    /// Saves `userId`'s payout account, replacing the previous one.
    func saveMyBankDetails(userId: String, request: ClarivaBankDetailsRequest) async -> Result<SavedBankAccount, Error>
}

extension WalletService: PayoutAccountServiceProtocol { }
