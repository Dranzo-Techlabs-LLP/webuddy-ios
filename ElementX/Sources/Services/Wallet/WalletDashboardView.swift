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
/// Android WalletScreen.
struct WalletDashboardView: View {
    @ObservedObject var wallet: WalletService = ServiceLocator.shared.wallet
    let userID: String

    @State private var transactions: [WalletTransactionDTO] = []
    @State private var isLoading = false
    @State private var page = 1
    @State private var canLoadMore = true

    @State private var showRechargeAmountPrompt = false
    @State private var rechargeAmountString = ""
    @State private var rechargeOrder: CreateOrderResponse?
    @State private var rechargeError: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current Balance")
                        .font(.compound.bodyMD)
                        .foregroundStyle(.secondary)
                    Text("\(wallet.credits ?? 0) credits")
                        .font(.compound.headingLGBold)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)

                if wallet.isCurrentUserConsultant != true {
                    // Consultants don't recharge — they only receive credits.
                    Button {
                        rechargeAmountString = ""
                        showRechargeAmountPrompt = true
                    } label: {
                        Text("Recharge Credits")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let error = rechargeError {
                    Text(error)
                        .font(.compound.bodySM)
                        .foregroundStyle(Color.red)
                }
            }

            Section {
                if transactions.isEmpty, !isLoading {
                    Text("No transactions yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(transactions, id: \.id) { row in
                        TransactionRow(row: row)
                    }
                    if canLoadMore {
                        Button("Load more") { Task { await loadMore() } }
                            .disabled(isLoading)
                    }
                }
            } header: {
                Text("Transactions")
            }
        }
        .navigationTitle("Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await wallet.refreshBalance(userId: userID)
            await refreshTransactions()
        }
        .alert("Recharge", isPresented: $showRechargeAmountPrompt) {
            TextField("Amount", text: $rechargeAmountString)
                .keyboardType(.numberPad)
            Button("Continue") { Task { await beginRecharge() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter the number of credits you want to add.")
        }
        .sheet(item: $rechargeOrder) { order in
            RazorpayCheckoutView(order: order,
                                 userName: userID,
                                 userContact: nil) { result in
                Task { await handleRazorpay(result: result, order: order) }
            }
        }
    }

    private func refreshTransactions() async {
        isLoading = true
        defer { isLoading = false }
        page = 1
        canLoadMore = true
        let result = await wallet.getTransactionHistory(userId: userID, page: 1, pageSize: 20)
        if case .success(let response) = result {
            transactions = response.data
            canLoadMore = response.page < response.totalPages
            page = response.page
        }
    }

    private func loadMore() async {
        guard canLoadMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let result = await wallet.getTransactionHistory(userId: userID, page: page + 1, pageSize: 20)
        if case .success(let response) = result {
            transactions.append(contentsOf: response.data)
            canLoadMore = response.page < response.totalPages
            page = response.page
        }
    }

    private func beginRecharge() async {
        guard let amount = Double(rechargeAmountString), amount > 0 else { return }
        rechargeError = nil
        let result = await wallet.createOrder(userId: userID, amount: amount)
        switch result {
        case .success(let order):
            rechargeOrder = order
        case .failure(let error):
            rechargeError = "Could not create order: \(error.localizedDescription)"
        }
    }

    private func handleRazorpay(result: RazorpayResult, order: CreateOrderResponse) async {
        rechargeOrder = nil
        switch result {
        case .success(let paymentId, let orderId, let signature):
            let body = VerifyPaymentRequest(userId: userID,
                                            transactionId: order.transactionId,
                                            razorpayOrderId: orderId,
                                            razorpayPaymentId: paymentId,
                                            razorpaySignature: signature)
            let verify = await wallet.verifyPayment(body)
            if case .failure(let error) = verify {
                rechargeError = "Verification failed: \(error.localizedDescription)"
            } else {
                await wallet.refreshBalance(userId: userID)
                await refreshTransactions()
            }
        case .failure(_, let message):
            rechargeError = "Payment failed: \(message)"
        case .cancelled:
            break
        }
    }
}

// `CreateOrderResponse` needs to be Identifiable so SwiftUI's `.sheet(item:)` can latch on.
extension CreateOrderResponse: Identifiable {
    var id: String { orderId }
}

private struct TransactionRow: View {
    let row: WalletTransactionDTO

    var body: some View {
        HStack {
            Image(systemName: isCredit ? "arrow.up" : "arrow.down")
                .foregroundStyle(isCredit ? Color.green : Color.red)
            VStack(alignment: .leading) {
                Text(label)
                    .font(.compound.bodyMD)
                Text(row.createdAt?.split(separator: "T").first.map(String.init) ?? "")
                    .font(.compound.bodySM)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(row.amount) cr")
                .font(.compound.bodyMD)
        }
    }

    private var isCredit: Bool {
        !row.type.uppercased().contains("DEBIT")
    }

    private var label: String {
        switch (row.source ?? row.type).uppercased() {
        case "RECHARGE": return "Recharge"
        case "HOLD": return "Chat hold"
        case "HOLD_SETTLED": return "Earnings"
        case "REFUND": return "Refund"
        case "REFERRAL": return "Referral bonus"
        case "BONUS": return "Bonus"
        case "CREDIT": return "Credit"
        case "DEBIT": return "Debit"
        default: return (row.source ?? row.type).capitalized
        }
    }
}
