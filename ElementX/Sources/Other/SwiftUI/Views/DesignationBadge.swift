//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// Green pill with a shield and a consultant's designation ("Consultant" by default), shown next to
/// their name in the chat list, the chat header and their profile. Long designations truncate at
/// `maxWidth` so the name keeps its room. Mirrors Android `DesignationBadge` (ee053dc156).
struct DesignationBadge: View {
    let text: String
    var maxWidth: CGFloat = 140

    var body: some View {
        MaxWidthLayout(maxWidth: maxWidth) {
            HStack(spacing: 3) {
                CompoundIcon(\.shield, size: .custom(12), relativeTo: .compound.bodyXS)
                    .foregroundStyle(.compound.iconSuccessPrimary)

                Text(text)
                    .font(.compound.bodyXS.weight(.medium))
                    .foregroundStyle(.compound.textSuccessPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.compound.bgSuccessSubtle, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.compound.borderSuccessSubtle, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Hugs its content like an unconstrained view, but never grows wider than `maxWidth`
/// (a `.frame(maxWidth:)` would always expand to the cap).
private struct MaxWidthLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let width = min(proposal.width ?? .infinity, maxWidth)
        return subview.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

// MARK: - Previews

struct DesignationBadge_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 8) {
            DesignationBadge(text: ClarivaDesignation.defaultConsultantDesignation)
            DesignationBadge(text: "Senior Interventional Cardiologist and Researcher")
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}
