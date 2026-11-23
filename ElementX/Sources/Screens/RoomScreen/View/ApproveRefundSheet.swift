//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// Android `formatAmount`: drop the fractional part of whole numbers (20.0 → "20", 12.5 → "12.5").
enum RefundAmountFormatter {
    static func format(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0, abs(value) < Double(Int64.max) {
            return String(Int64(value))
        }
        return String(value)
    }
}

/// Validation for the partial refund amount, mirroring Android `ApproveRefundDialog` (165e2616fd,
/// 049d08c0e2): a partial amount must be greater than 0 and LESS than the held amount - returning
/// everything is the full refund (the Wallet-API rejects anything else since 7f1fb5b0d).
enum RefundAmountValidator {
    /// Tolerance of the comparison with the held amount, as on Android.
    private static let epsilon = 1e-6

    /// Digits and at most one decimal point.
    static func isAcceptableInput(_ text: String) -> Bool {
        text.isEmpty || text.range(of: #"^[0-9]*\.?[0-9]*$"#, options: .regularExpression) != nil
    }

    /// Rounded to 2 decimals exactly like the backend's `round2`, so Approve is never enabled for a
    /// value the server would reject (e.g. 0.004 → 0.00).
    static func roundedAmount(from text: String) -> Double? {
        guard let parsed = Double(text.trimmingCharacters(in: .whitespaces)) else { return nil }
        return (parsed * 100).rounded() / 100
    }

    static func isValid(isPartial: Bool, roundedAmount: Double?, heldAmount: Double?) -> Bool {
        guard isPartial else { return true }
        guard let roundedAmount, roundedAmount > 0 else { return false }
        return !isAtLeastHeldAmount(roundedAmount, heldAmount: heldAmount)
    }

    /// The amount would return everything (or more): that is the full refund, not a partial one.
    static func isAtLeastHeldAmount(_ roundedAmount: Double?, heldAmount: Double?) -> Bool {
        guard let roundedAmount, let heldAmount else { return false }
        return roundedAmount >= heldAmount - epsilon
    }

    /// The text under the amount field; `showsError` when a typed amount is not valid.
    static func helperText(showsError: Bool, roundedAmount: Double?, heldAmount: Double?) -> String {
        switch (showsError, heldAmount) {
        case (true, .some(let heldAmount)) where isAtLeastHeldAmount(roundedAmount, heldAmount: heldAmount):
            "A partial refund must be less than ₹\(RefundAmountFormatter.format(heldAmount)). To return everything, choose Full refund."
        case (true, .some(let heldAmount)):
            "Enter an amount greater than 0 and less than ₹\(RefundAmountFormatter.format(heldAmount))."
        case (true, .none):
            "Enter an amount greater than 0."
        case (false, .some(let heldAmount)):
            "The client gets this back; you keep the rest of ₹\(RefundAmountFormatter.format(heldAmount))."
        case (false, .none):
            "The client gets this back; you keep the remainder."
        }
    }
}

/// The consultant's "Approve Refund" choice: the full held amount, or a partial amount below it (the
/// consultant keeps the remainder, paid out when the session settles). `onApprove` receives nil for a
/// full refund.
struct ApproveRefundSheet: View {
    let heldAmount: Double?
    let isInProgress: Bool
    let onApprove: (_ refundAmount: Double?) -> Void
    let onCancel: () -> Void

    @State private var isPartial = false
    @State private var amountText = ""
    @FocusState private var isAmountFieldFocused: Bool

    private var roundedAmount: Double? {
        RefundAmountValidator.roundedAmount(from: amountText)
    }

    private var isAmountValid: Bool {
        RefundAmountValidator.isValid(isPartial: isPartial, roundedAmount: roundedAmount, heldAmount: heldAmount)
    }

    private var showsAmountError: Bool {
        isPartial && !amountText.trimmingCharacters(in: .whitespaces).isEmpty && !isAmountValid
    }

    private var fullRefundTitle: String {
        if let heldAmount {
            return "Full refund (₹\(RefundAmountFormatter.format(heldAmount)))"
        }
        return "Full refund"
    }

    private var amountHelperText: String {
        RefundAmountValidator.helperText(showsError: showsAmountError, roundedAmount: roundedAmount, heldAmount: heldAmount)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ListRow(label: .plain(title: fullRefundTitle),
                            kind: .selection(isSelected: !isPartial) {
                                isPartial = false
                                isAmountFieldFocused = false
                            })

                    ListRow(label: .plain(title: "Partial refund"),
                            kind: .selection(isSelected: isPartial) {
                                isPartial = true
                                isAmountFieldFocused = true
                            })
                } footer: {
                    if !isPartial {
                        Text("The full held amount will be returned to the client immediately.")
                            .compoundListSectionFooter()
                    }
                }

                if isPartial {
                    Section {
                        ListRow(label: .plain(title: "Refund amount"),
                                kind: .textField(text: $amountText))
                            .keyboardType(.decimalPad)
                            .focused($isAmountFieldFocused)
                    } header: {
                        Text("Refund amount")
                            .compoundListSectionHeader()
                    } footer: {
                        Text(amountHelperText)
                            // Applied on the Text itself so it wins over the footer's secondary colour.
                            .foregroundStyle(showsAmountError ? Color.compound.textCriticalPrimary : Color.compound.textSecondary)
                            .compoundListSectionFooter()
                    }
                }
            }
            .compoundList()
            .navigationTitle("Approve Refund")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Approve") {
                        onApprove(isPartial ? roundedAmount : nil)
                    }
                    .disabled(isInProgress || !isAmountValid)
                }
            }
            .onChange(of: amountText) { oldValue, newValue in
                // Some locales show "," on the decimal pad.
                let normalized = newValue.replacingOccurrences(of: ",", with: ".")
                if !RefundAmountValidator.isAcceptableInput(normalized) {
                    amountText = oldValue
                } else if normalized != newValue {
                    amountText = normalized
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Previews

struct ApproveRefundSheet_Previews: PreviewProvider {
    static var previews: some View {
        ApproveRefundSheet(heldAmount: 50, isInProgress: false, onApprove: { _ in }, onCancel: { })
            .previewDisplayName("Held amount known")

        ApproveRefundSheet(heldAmount: nil, isInProgress: false, onApprove: { _ in }, onCancel: { })
            .previewDisplayName("Held amount unknown")
    }
}
