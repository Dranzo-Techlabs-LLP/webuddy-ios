//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// Consultant-facing banner shown under the top bar of a DM when the client has requested a refund
/// of the active hold. Mirrors Android `RefundRequestBanner` (ca49777b4e, 165e2616fd): same copy,
/// Approve before Reject, both disabled while a refund action is in flight. Approve opens the
/// Full/Partial sheet and Reject a confirmation; both are presented by the room screen.
struct RefundRequestBanner: View {
    let isInProgress: Bool
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            CompoundIcon(\.infoSolid, size: .small, relativeTo: .compound.bodyMD)
                .foregroundStyle(.compound.iconPrimary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Refund request")
                    .font(.compound.bodyMDSemibold)
                    .foregroundStyle(.compound.textPrimary)

                Text("The client has asked for a refund. Approve to return the held amount (in full or in part) immediately, or reject to keep the funds (transferred at the end of the hold window).")
                    .font(.compound.bodySM)
                    .foregroundStyle(.compound.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Approve", action: onApprove)
                        .buttonStyle(.compound(.primary, size: .medium))

                    Button("Reject", action: onReject)
                        .buttonStyle(.compound(.secondary, size: .medium))
                }
                .disabled(isInProgress)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.compound.bgSubtlePrimary, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.compound.borderInteractiveSecondary, lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Previews

struct RefundRequestBanner_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            RefundRequestBanner(isInProgress: false, onApprove: { }, onReject: { })
            RefundRequestBanner(isInProgress: true, onApprove: { }, onReject: { })
        }
    }
}
