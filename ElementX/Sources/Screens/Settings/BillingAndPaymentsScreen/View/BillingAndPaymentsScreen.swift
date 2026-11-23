//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct BillingAndPaymentsScreen: View {
    @Bindable var context: BillingAndPaymentsScreenViewModel.Context

    var body: some View {
        Form {
            Section {
                ListRow(kind: .custom {
                    maxCreditsEditor
                })

                ListRow(label: .default(title: "Bank Details", icon: \.settings),
                        kind: .navigationLink {
                            context.send(viewAction: .bankDetails)
                        })
            } header: {
                Text("Wallet")
                    .compoundListSectionHeader()
            }
        }
        .compoundList()
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Billing and Payments")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Private

    private var maxCreditsInput: Binding<String> {
        Binding(get: { context.viewState.maxCreditsInput },
                set: { context.send(viewAction: .updateMaxCreditsInput($0)) })
    }

    private var maxCreditsEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Text("Max Credits")
                    .font(.compound.bodyLG.weight(.medium))
                    .foregroundStyle(.compound.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if context.viewState.maxCredits == nil {
                    // Initial load only. While saving the field stays visible (the Save button
                    // shows the progress) so the focused field is never removed mid-save.
                    ProgressView()
                } else {
                    TextField("", text: maxCreditsInput)
                        .keyboardType(.numberPad)
                        .font(.compound.bodyLG)
                        .foregroundStyle(.compound.textPrimary)
                        .tint(.compound.iconAccentTertiary)
                        .padding(8)
                        .frame(width: 80)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.compound.borderInteractiveSecondary, lineWidth: 1)
                        }
                        .accessibilityLabel("Max Credits")
                }
            }

            if context.viewState.hasChanges {
                HStack(spacing: 8) {
                    Spacer()

                    Button("Cancel") {
                        context.send(viewAction: .cancel)
                    }
                    .buttonStyle(.compound(.tertiary, size: .medium))

                    Button(context.viewState.isSaving ? "Saving…" : "Save") {
                        context.send(viewAction: .save)
                    }
                    .buttonStyle(.compound(.primary, size: .medium))
                }
                .disabled(context.viewState.isSaving)
                .padding(.top, 8)
            }

            switch context.viewState.saveResult {
            case .saved:
                Text("Max credits saved")
                    .font(.compound.bodyMD.weight(.medium))
                    .foregroundStyle(.compound.textSuccessPrimary)
                    .padding(.top, 6)
            case .failed:
                Text("Couldn't save max credits. Please try again.")
                    .font(.compound.bodyMD.weight(.medium))
                    .foregroundStyle(.compound.textCriticalPrimary)
                    .padding(.top, 6)
            case .none:
                EmptyView()
            }
        }
        .padding(.horizontal, ListRowPadding.horizontal)
        .padding(.vertical, 8)
    }
}

// MARK: - Previews

struct BillingAndPaymentsScreen_Previews: PreviewProvider, TestablePreview {
    // An unresolvable host: the preview must never create wallet rows on the real server. The
    // failed load seeds the default max credits (100).
    static let viewModel = BillingAndPaymentsScreenViewModel(userID: "@consultant:example.com",
                                                             wallet: WalletService(baseURL: "https://wallet.invalid/"))

    static var previews: some View {
        NavigationStack {
            BillingAndPaymentsScreen(context: viewModel.context)
        }
        .snapshotPreferences(expect: viewModel.context.observe(\.viewState.maxCredits).map { $0 != nil })
    }
}
