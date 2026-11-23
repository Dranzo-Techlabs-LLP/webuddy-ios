//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// Mirrors Android `BankDetailsView` (093714e02a).
struct BankDetailsScreen: View {
    @Bindable var context: BankDetailsScreenViewModel.Context

    @FocusState private var focusedField: BankDetailsField?

    private var isSaving: Bool {
        context.viewState.isSaving
    }

    var body: some View {
        Form {
            savedAccountSection

            field(.accountHolderName,
                  title: "Account Holder Name",
                  capitalization: .words,
                  next: .bankName) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.viewState.formTitle)
                        .font(.compound.bodyLGSemibold)
                        .foregroundColor(.compound.textPrimary)
                    Text("Your earnings are paid into this account.")
                        .font(.compound.bodySM)
                        .foregroundColor(.compound.textSecondary)
                }
                .textCase(nil)
                .padding(.bottom, 16)
            }

            field(.bankName, title: "Bank Name", placeholder: "e.g. State Bank of India", capitalization: .words, next: .accountNumber)

            field(.accountNumber,
                  title: "Account Number",
                  capitalization: .never,
                  keyboard: .numberPad,
                  footer: context.viewState.form.accountNumberError,
                  isError: context.viewState.form.accountNumberError != nil,
                  next: .ifscCode)

            field(.ifscCode,
                  title: "IFSC Code",
                  placeholder: "e.g. SBIN0001234",
                  capitalization: .characters,
                  keyboard: .asciiCapable,
                  footer: context.viewState.ifscFooter,
                  isError: context.viewState.isIFSCInvalid,
                  isSuccess: isIFSCFound,
                  next: .branchName)

            field(.branchName, title: "Branch Name (optional)", capitalization: .words, next: nil)

            if let saveError = context.viewState.saveError {
                Section {
                    ListRow(kind: .custom {
                        HStack(alignment: .top, spacing: 6) {
                            CompoundIcon(\.error, size: .xSmall, relativeTo: .compound.bodySM)
                                .foregroundStyle(.compound.iconCriticalPrimary)
                            Text(saveError)
                                .font(.compound.bodySM)
                                .foregroundColor(.compound.textCriticalPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 4)
                    })
                    .listRowBackground(Color.clear)
                }
            }

            saveSection
        }
        .compoundList()
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Bank Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Saved account

    private var savedAccountSection: some View {
        Section {
            ListRow(kind: .custom {
                savedAccountContent
                    .padding(.horizontal, ListRowPadding.horizontal)
                    .padding(.vertical, ListRowPadding.vertical)
                    .frame(maxWidth: .infinity, alignment: .leading)
            })
        } header: {
            Text("Current payout account")
                .compoundListSectionHeader()
        }
    }

    @ViewBuilder
    private var savedAccountContent: some View {
        switch context.viewState.savedAccount {
        case .loading:
            ProgressView()
        case .loaded(.none):
            Text("None yet. Add one below to receive your earnings.")
                .font(.compound.bodyMD)
                .foregroundColor(.compound.textPrimary)
        case .loaded(.some(let account)):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    CompoundIcon(\.lockSolid, size: .xSmall, relativeTo: .compound.bodyLG)
                        .foregroundStyle(.compound.iconSecondary)
                    Text(account.maskedTitle)
                        .font(.compound.bodyLGSemibold)
                        .foregroundColor(.compound.textPrimary)
                }
                Text(account.detailsLine)
                    .font(.compound.bodySM)
                    .foregroundColor(.compound.textSecondary)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn't load your saved account.")
                    .font(.compound.bodyMD)
                    .foregroundColor(.compound.textCriticalPrimary)
                Button("Retry") {
                    context.send(viewAction: .retryLoad)
                }
                .buttonStyle(.compound(.textLink))
            }
        }
    }

    // MARK: - Form

    private var isIFSCFound: Bool {
        if case .found = context.viewState.ifscStatus {
            return true
        }
        return false
    }

    private func field(_ field: BankDetailsField,
                       title: String,
                       placeholder: String? = nil,
                       capitalization: TextInputAutocapitalization,
                       keyboard: UIKeyboardType = .default,
                       footer: String? = nil,
                       isError: Bool = false,
                       isSuccess: Bool = false,
                       next: BankDetailsField?,
                       @ViewBuilder intro: () -> some View = { EmptyView() }) -> some View {
        Section {
            ListRow(label: .plain(title: placeholder ?? title),
                    kind: .textField(text: binding(field)))
                .keyboardType(keyboard)
                .textInputAutocapitalization(capitalization)
                .autocorrectionDisabled()
                .focused($focusedField, equals: field)
                .submitLabel(next == nil ? .done : .next)
                .onSubmit {
                    if let next {
                        focusedField = next
                    } else {
                        save()
                    }
                }
                .disabled(isSaving)
        } header: {
            VStack(alignment: .leading, spacing: 0) {
                intro()
                Text(title)
                    .compoundListSectionHeader()
            }
        } footer: {
            if let footer {
                Text(footer)
                    // Applied on the Text itself so it wins over the footer's secondary colour.
                    .foregroundStyle(footerColor(isError: isError, isSuccess: isSuccess))
                    .compoundListSectionFooter()
            }
        }
    }

    private func footerColor(isError: Bool, isSuccess: Bool) -> Color {
        if isError {
            return .compound.textCriticalPrimary
        }
        return isSuccess ? .compound.textSuccessPrimary : .compound.textSecondary
    }

    private var saveSection: some View {
        Section {
            Button(action: save) {
                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView()
                            .tint(.compound.textOnSolidPrimary)
                    }
                    Text("Save Details")
                }
            }
            .buttonStyle(.compound(.primary))
            .disabled(!context.viewState.canSave)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)
        } footer: {
            Text("Saving replaces your current payout account. Only the last 4 digits of the account number are shown here.")
                .compoundListSectionFooter()
        }
    }

    private func save() {
        focusedField = nil
        guard context.viewState.canSave else { return }
        context.send(viewAction: .save)
    }

    /// Reads the form but routes every edit through the view model (filtering, IFSC lookup).
    private func binding(_ field: BankDetailsField) -> Binding<String> {
        Binding(get: { context.viewState.form.value(of: field) },
                set: { context.send(viewAction: .setField(field, $0)) })
    }
}

// MARK: - Previews

struct BankDetailsScreen_Previews: PreviewProvider, TestablePreview {
    static let emptyViewModel = makeViewModel(savedAccount: nil)
    static let savedViewModel = makeViewModel(savedAccount: SavedBankAccount(bankName: "State Bank of India",
                                                                             accountNumberLast4: "9012",
                                                                             ifscCode: "SBIN0001234",
                                                                             accountHolderName: "Jane Doe",
                                                                             branchName: "MG Road"))

    static var previews: some View {
        NavigationStack {
            BankDetailsScreen(context: emptyViewModel.context)
        }
        .previewDisplayName("No account yet")

        NavigationStack {
            BankDetailsScreen(context: savedViewModel.context)
        }
        .previewDisplayName("Saved account")
    }

    private static func makeViewModel(savedAccount: SavedBankAccount?) -> BankDetailsScreenViewModel {
        BankDetailsScreenViewModel(userID: "@consultant:example.com",
                                   payoutAccountService: PreviewPayoutAccountService(savedAccount: savedAccount),
                                   ifscLookup: PreviewIfscLookup(),
                                   userIndicatorController: UserIndicatorControllerMock())
    }
}

/// Answers at once and never touches the keychain or the network.
private struct PreviewPayoutAccountService: PayoutAccountServiceProtocol {
    let savedAccount: SavedBankAccount?

    func getMyBankDetails(userId: String) async -> Result<SavedBankAccount?, Error> {
        .success(savedAccount)
    }

    func saveMyBankDetails(userId: String, request: ClarivaBankDetailsRequest) async -> Result<SavedBankAccount, Error> {
        .success(SavedBankAccount(bankName: request.bankName,
                                  accountNumberLast4: String(request.accountNumber.suffix(4)),
                                  ifscCode: request.ifscCode,
                                  accountHolderName: request.accountHolderName,
                                  branchName: request.branchName))
    }
}

private struct PreviewIfscLookup: IfscLookupProtocol {
    func lookup(_ rawIFSC: String) async -> IfscStatus {
        .unavailable
    }
}
