//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// Standalone wallet screen showing the current credit balance, an optional recharge action
/// (clients only), and the transaction history fetched from `/v1/wallet/history`. Mirrors the
/// Android `WalletView` (presented as a sheet from the home top bar on iOS).
struct WalletDashboardView: View {
    /// Android `WalletPresenter` page size.
    private static let pageSize = 10

    @ObservedObject var wallet: WalletService = ServiceLocator.shared.wallet ?? .offline
    let userID: String
    @Environment(\.scenePhase) private var scenePhase

    @State private var transactions: [WalletTransactionDTO] = []
    @State private var isLoading = false
    @State private var page = 1
    @State private var canLoadMore = true
    /// Bumped by every refresh so a "load more" page that lands after it is discarded instead of
    /// being appended to the fresh first page (duplicate rows).
    @State private var historyGeneration = 0

    @State private var showRechargeAmountPrompt = false
    @State private var rechargeAmountString = ""
    @State private var rechargeOrder: CreateOrderResponse?
    /// The order of the checkout on screen, until its payment is verified. When the checkout closes
    /// without that (cancelled, failed, swiped away, or the payment finished in a UPI app the
    /// checkout never heard back from) the server is asked whether Razorpay captured it anyway.
    @State private var unverifiedOrder: CreateOrderResponse?
    /// `createOrder` (or the payment verification) is in flight.
    @State private var isProcessingRecharge = false
    @State private var rechargeError: String?

    /// Android only accepts an integer number of credits greater than zero.
    private var rechargeAmount: Int? {
        guard let amount = Int(rechargeAmountString.trimmingCharacters(in: .whitespacesAndNewlines)), amount > 0 else {
            return nil
        }
        return amount
    }

    var body: some View {
        Form {
            balanceSection
            transactionsSection
        }
        .compoundList()
        .navigationTitle("Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Opening the wallet shows a fresh balance, not the last cached value.
            await wallet.refreshBalance(userId: userID)
            await refreshTransactions()
            await syncRecharges()
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from a UPI app (or anywhere else) with the wallet open.
            guard phase == .active, rechargeOrder == nil else { return }
            Task { await syncRecharges() }
        }
        .alert("Recharge Wallet", isPresented: $showRechargeAmountPrompt) {
            TextField("e.g. 500", text: $rechargeAmountString)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {
                rechargeAmountString = ""
            }
            Button("Recharge") {
                guard let amount = rechargeAmount else { return }
                rechargeAmountString = ""
                Task { await beginRecharge(amount: amount) }
            }
            .disabled(rechargeAmount == nil)
        } message: {
            Text("Enter the number of credits to purchase.")
        }
        .sheet(item: $rechargeOrder, onDismiss: checkoutDismissed) { order in
            RazorpayCheckoutView(order: order,
                                 userName: nil,
                                 userContact: nil) { result in
                Task { await handleRazorpay(result: result, order: order) }
            }
        }
    }

    // MARK: - Sections

    private var balanceSection: some View {
        Section {
            VStack(spacing: 4) {
                Text("Current Balance")
                    .font(.compound.bodyLG)
                    .foregroundStyle(.compound.textPrimary)
                Text(verbatim: "\(wallet.credits ?? 0) credits")
                    .font(.compound.headingLGBold)
                    .foregroundStyle(.compound.textPrimary)

                if wallet.isCurrentUserConsultant != true {
                    // Consultants don't recharge — they only receive credits.
                    rechargeControl
                        .padding(.top, 24)
                }

                if let rechargeError {
                    Text(rechargeError)
                        .font(.compound.bodyMD)
                        .foregroundStyle(.compound.textCriticalPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var rechargeControl: some View {
        if isProcessingRecharge {
            VStack(spacing: 8) {
                ProgressView()
                Text("Processing recharge...")
                    .font(.compound.bodyMD)
                    .foregroundStyle(.compound.textSecondary)
            }
        } else {
            Button {
                rechargeAmountString = ""
                showRechargeAmountPrompt = true
            } label: {
                Text("Recharge Credits")
            }
            .buttonStyle(.compound(.primary))
        }
    }

    private var transactionsSection: some View {
        Section {
            TransactionHeaderRow()
                .listRowInsets(EdgeInsets())

            // Index based identity: `WalletTransactionDTO.id` is optional and duplicates would
            // collapse rows.
            ForEach(Array(transactions.enumerated()), id: \.offset) { index, transaction in
                TransactionRow(row: transaction)
                    .listRowInsets(EdgeInsets())
                    .onAppear {
                        // Android loads the next page when the last visible row is within the
                        // last two items.
                        if index >= transactions.count - 2 {
                            Task { await loadMore() }
                        }
                    }
            }

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .listRowInsets(EdgeInsets())
            } else if transactions.isEmpty {
                Text("No transactions found")
                    .font(.compound.bodyLG)
                    .foregroundStyle(.compound.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(32)
                    .listRowInsets(EdgeInsets())
            }
        } header: {
            Text("Transaction History")
                .font(.compound.headingSMSemibold)
                .foregroundStyle(.compound.textPrimary)
                .textCase(nil)
                .padding(.bottom, 8)
        }
    }

    // MARK: - Transactions

    private func refreshTransactions() async {
        historyGeneration += 1
        let generation = historyGeneration
        isLoading = true
        defer { if generation == historyGeneration { isLoading = false } }

        let result = await wallet.getTransactionHistory(userId: userID, page: 1, pageSize: Self.pageSize)
        guard generation == historyGeneration else { return }
        if case .success(let response) = result {
            transactions = response.data
            canLoadMore = response.page < response.totalPages
            page = response.page
        }
        // Errors are silent (Android): the spinner simply stops.
    }

    private func loadMore() async {
        guard canLoadMore, !isLoading else { return }
        let generation = historyGeneration
        isLoading = true
        defer { if generation == historyGeneration { isLoading = false } }

        let result = await wallet.getTransactionHistory(userId: userID, page: page + 1, pageSize: Self.pageSize)
        guard generation == historyGeneration else { return }
        if case .success(let response) = result {
            transactions.append(contentsOf: response.data)
            canLoadMore = response.page < response.totalPages
            page = response.page
        }
    }

    // MARK: - Recharge

    private func beginRecharge(amount: Int) async {
        guard !isProcessingRecharge else { return }
        rechargeError = nil
        isProcessingRecharge = true

        let result = await wallet.createOrder(userId: userID, amount: Double(amount))
        isProcessingRecharge = false

        switch result {
        case .success(let order):
            unverifiedOrder = order
            rechargeOrder = order
        case .failure(let error):
            rechargeError = "Recharge failed: \(error.localizedDescription)"
        }
    }

    private func handleRazorpay(result: RazorpayResult, order: CreateOrderResponse) async {
        rechargeOrder = nil
        switch result {
        case .success(let paymentId, let orderId, let signature):
            // Verified below; `checkoutDismissed` mustn't sync it at the same time.
            unverifiedOrder = nil
            isProcessingRecharge = true
            defer { isProcessingRecharge = false }

            let body = VerifyPaymentRequest(userId: userID,
                                            transactionId: order.transactionId,
                                            razorpayOrderId: orderId,
                                            razorpayPaymentId: paymentId,
                                            razorpaySignature: signature)
            // The service refreshes the balance itself on a successful verification.
            switch await wallet.verifyPayment(body) {
            case .success(let response) where response.success:
                await refreshTransactions()
            case .success:
                rechargeError = "Verification failed: the payment could not be verified."
                await syncAfterCheckout(order)
            case .failure(let error):
                rechargeError = "Verification failed: \(error.localizedDescription)"
                await syncAfterCheckout(order)
            }
        case .failure(_, let message):
            rechargeError = "Recharge failed: \(message)"
        case .cancelled:
            // Unlike Android (where the SDK reports a cancel as an error) a user cancel is silent.
            break
        }
    }

    private func checkoutDismissed() {
        guard let order = unverifiedOrder else { return }
        unverifiedOrder = nil
        Task { await syncAfterCheckout(order) }
    }

    /// A checkout closed without a verified payment: the payment may still have gone through, e.g.
    /// in a UPI app. Razorpay can take a few seconds to capture it, so ask a few times.
    private func syncAfterCheckout(_ order: CreateOrderResponse) async {
        for delay in [0, 3, 8] as [UInt64] {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay * NSEC_PER_SEC)
            }
            if await wallet.syncRecharges(userId: userID, transactionId: order.transactionId) > 0 {
                rechargeError = nil
                await refreshTransactions()
                return
            }
        }
    }

    /// Any of the user's recent recharges that Razorpay captured but that were never verified.
    private func syncRecharges() async {
        if await wallet.syncRecharges(userId: userID) > 0 {
            rechargeError = nil
            await refreshTransactions()
        }
    }
}

// `CreateOrderResponse` needs to be Identifiable so SwiftUI's `.sheet(item:)` can latch on.
extension CreateOrderResponse: Identifiable {
    var id: String { orderId }
}

// MARK: - Transaction table

/// Lays its children out as table columns with Android's 1.2 / 1 / 1 / 1 weights so that the
/// header and every row line up.
private struct TransactionColumns: Layout {
    private static let weights: [CGFloat] = [1.2, 1, 1, 1]
    private static let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let widths = columnWidths(totalWidth: width, count: subviews.count)

        var height: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: widths[index], height: nil))
            height = max(height, size.height)
        }

        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(totalWidth: bounds.width, count: subviews.count)

        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: x, y: bounds.midY),
                          anchor: .leading,
                          proposal: ProposedViewSize(width: widths[index], height: nil))
            x += widths[index] + Self.spacing
        }
    }

    private func columnWidths(totalWidth: CGFloat, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }

        let weights = (0..<count).map { $0 < Self.weights.count ? Self.weights[$0] : 1 }
        let totalWeight = weights.reduce(0, +)
        let available = max(0, totalWidth - Self.spacing * CGFloat(count - 1))
        return weights.map { available * $0 / totalWeight }
    }
}

private struct TransactionHeaderRow: View {
    var body: some View {
        let columns = TransactionColumns()
        return columns {
            Text("Date")
            Text("Type")
            Text("Amount")
            Text("Status")
        }
        .font(.compound.bodyMDSemibold)
        .foregroundStyle(.compound.textPrimary)
        .lineLimit(1)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .accessibilityHidden(true)
    }
}

private struct TransactionRow: View {
    let row: WalletTransactionDTO

    var body: some View {
        let columns = TransactionColumns()
        return columns {
            Text(row.createdAt?.split(separator: "T").first.map(String.init) ?? "")
                .font(.compound.bodySM)
                .foregroundStyle(.compound.textPrimary)

            HStack(spacing: 4) {
                Image(systemName: isCredit ? "arrow.up" : "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isCredit ? Color.compound.iconSuccessPrimary : Color.compound.iconCriticalPrimary)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.compound.bodySM)
                    .foregroundStyle(.compound.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            // Android parses the amount to a Double and prints it as is (e.g. "100.0 cr").
            Text(verbatim: "\(row.amountValue.description) cr")
                .font(.compound.bodySM)
                .foregroundStyle(.compound.textPrimary)

            Text(statusText)
                .font(.compound.bodySMSemibold)
                .foregroundStyle(statusColor)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }

    /// The direction comes from the ledger `type` (CREDIT / DEBIT / BONUS).
    private var isCredit: Bool {
        row.type.uppercased() != "DEBIT"
    }

    /// The label prefers the business `source`, falling back to the raw `type` for legacy rows.
    private var label: String {
        let key = (row.source ?? row.type).uppercased()
        switch key {
        case "RECHARGE": return "Recharge"
        case "HOLD": return "Chat hold"
        case "HOLD_SETTLED": return "Earnings"
        case "REFUND": return "Refund"
        case "REFERRAL": return "Referral bonus"
        case "BONUS": return "Bonus"
        case "CREDIT": return "Credit"
        case "DEBIT": return "Debit"
        default: return Self.capitalizingFirstLetter(key.lowercased())
        }
    }

    private var statusText: String {
        Self.capitalizingFirstLetter(row.status.lowercased())
    }

    private var statusColor: Color {
        switch row.status.lowercased() {
        case "completed", "success", "paid": .compound.textSuccessPrimary
        case "failed": .compound.textCriticalPrimary
        default: .compound.textSecondary
        }
    }

    /// Kotlin `replaceFirstChar { it.uppercase() }`: only the first character changes.
    private static func capitalizingFirstLetter(_ string: String) -> String {
        guard let first = string.first else { return string }
        return first.uppercased() + string.dropFirst()
    }
}
