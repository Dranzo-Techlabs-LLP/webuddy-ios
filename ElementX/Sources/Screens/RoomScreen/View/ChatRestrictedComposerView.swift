//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// Replaces the whole composer (text field, attachments, voice recording, send) when a client can't
/// afford the consultant and has no active hold. Mirrors Android `RestrictedComposerView` (13d3a6a237).
/// It has no action, exactly like Android.
///
/// Also used in a consultant ↔ consultant DM, which is read-only: consultants may only chat with
/// clients (Android ee053dc156 `isConsultantPeerBlocked`).
struct ChatRestrictedComposerView: View {
    /// The client's balance.
    var credits: Int?
    /// The consultant's rate.
    var requiredCredits: Int?
    /// Both sides of this DM are consultants: shows that reason instead of the wallet one.
    var isConsultantPeerBlocked = false

    var body: some View {
        HStack(spacing: 12) {
            CompoundIcon(\.infoSolid, size: .small, relativeTo: .compound.bodyMD)
                .foregroundStyle(.compound.iconPrimary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                if isConsultantPeerBlocked {
                    Text(ConsultantChatRule.composerTitle)
                        .font(.compound.bodyMDSemibold)
                        .foregroundStyle(.compound.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Text(ConsultantChatRule.composerMessage)
                        .font(.compound.bodySM)
                        .foregroundStyle(.compound.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Chat restricted. Please recharge your wallet to continue.")
                        .font(.compound.bodyMDSemibold)
                        .foregroundStyle(.compound.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let credits, let requiredCredits {
                        Text(verbatim: "Current: \(credits) | Required: \(requiredCredits)")
                            .font(.compound.bodySM)
                            .foregroundStyle(.compound.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.compound.bgSubtlePrimary, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.compound.borderInteractiveSecondary, lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.compound.bgCanvasDefault)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

struct ChatRestrictedComposerView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            ChatRestrictedComposerView(credits: 20, requiredCredits: 50)
            ChatRestrictedComposerView(credits: nil, requiredCredits: 50)
            ChatRestrictedComposerView(isConsultantPeerBlocked: true)
        }
    }
}
