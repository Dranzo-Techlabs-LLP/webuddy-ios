//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// "Are you a consultant?" for a Google identity whose role is still unknown. Not dismissible by
/// swiping: an accidental dismiss would silently abandon a sign-up that already went through Google.
/// Mirrors Android's `ClarivaGoogleRoleDialog`.
struct ClarivaGoogleRoleSheet: View {
    let prompt: ClarivaGoogleRolePrompt
    let onContinue: (_ isConsultant: Bool) -> Void
    let onCancel: () -> Void

    /// Staged selection, committed by Continue. "No" is pre-selected, unless "Yes" was picked before
    /// and the user came Back from the payout step.
    @State private var isConsultant: Bool

    init(prompt: ClarivaGoogleRolePrompt,
         onContinue: @escaping (_ isConsultant: Bool) -> Void,
         onCancel: @escaping () -> Void) {
        self.prompt = prompt
        self.onContinue = onContinue
        self.onCancel = onCancel
        _isConsultant = State(initialValue: prompt.hasChosenConsultant)
    }

    var body: some View {
        Form {
            Section {
                ListRow(label: .plain(title: "No",
                                      description: "Chat with consultants and pay per conversation."),
                        kind: .selection(isSelected: !isConsultant) {
                            isConsultant = false
                        })

                ListRow(label: .plain(title: "Yes",
                                      description: "Get paid for the chats you take."),
                        kind: .selection(isSelected: isConsultant) {
                            isConsultant = true
                        })
            } header: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Are you a consultant?")
                        .font(.compound.headingSMSemibold)
                        .foregroundColor(.compound.textPrimary)

                    Text(prompt.subtitle)
                        .font(.compound.bodyMD)
                        .foregroundColor(.compound.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .textCase(nil)
                .padding(.bottom, 8)
            }
        }
        .compoundList()
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button {
                    onContinue(isConsultant)
                } label: {
                    Text(L10n.actionContinue)
                }
                .buttonStyle(.compound(.primary))

                Button {
                    onCancel()
                } label: {
                    Text(L10n.actionCancel)
                }
                .buttonStyle(.compound(.secondary))
            }
            .padding(16)
            .background(Color.compound.bgSubtleSecondaryLevel0.ignoresSafeArea())
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(true)
    }
}
