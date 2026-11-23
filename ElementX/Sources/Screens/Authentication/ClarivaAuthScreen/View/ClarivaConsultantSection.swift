//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// The "I am a consultant" switch, and below it - only once it is on - the optional payout setup:
/// chat rate and bank account. Grouped in one card so it reads as part of that choice, not as more
/// mandatory sign-up fields. Mirrors Android `ClarivaConsultantSection`.
struct ClarivaConsultantSection: View {
    @Bindable var context: ClarivaAuthScreenViewModel.Context
    let focus: FocusState<ClarivaConsultantSetupField?>.Binding
    let onSubmit: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 16)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: $context.isConsultant) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("I am a consultant")
                        .font(.compound.bodyLG)
                        .foregroundColor(.compound.textPrimary)
                    Text("Consultants are paid for chats.")
                        .font(.compound.bodySM)
                        .foregroundColor(.compound.textSecondary)
                }
            }
            .tint(Color.compound.iconAccentPrimary)

            if context.isConsultant {
                Divider()
                    .padding(.vertical, 16)

                if context.viewState.consultantSetup.isSkipped {
                    ClarivaSkippedConsultantSetup {
                        context.send(viewAction: .resumeConsultantSetup)
                    }
                } else {
                    ClarivaConsultantSetupFields(setup: context.viewState.consultantSetup,
                                                 ifscStatus: context.viewState.ifscStatus,
                                                 holderNameHint: context.viewState.bindings.name,
                                                 focus: focus,
                                                 onChange: setField,
                                                 onDone: onSubmit,
                                                 onSkip: skip)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.compound.bgCanvasDefault.opacity(0.85), in: shape)
        .overlay {
            shape.strokeBorder(Color.compound.borderInteractiveSecondary, lineWidth: 1)
        }
        .animation(.easeInOut(duration: 0.2), value: context.isConsultant)
        .animation(.easeInOut(duration: 0.2), value: context.viewState.consultantSetup.isSkipped)
    }

    private func setField(_ field: ClarivaConsultantSetupField, _ value: String) {
        context.send(viewAction: .setConsultantSetupField(field, value))
    }

    private func skip() {
        focus.wrappedValue = nil
        context.send(viewAction: .skipConsultantSetup)
    }
}

/// The optional chat rate + bank account fields. Shared by the sign-up card and the Google sign-up
/// payout step, so both ask for, and check, exactly the same. Mirrors Android `ConsultantSetupFields`.
///
/// `onSkip` nil hides the inline "Skip for now" (the Google step has its own).
struct ClarivaConsultantSetupFields: View {
    let setup: ClarivaConsultantSetupForm
    let ifscStatus: IfscStatus
    let holderNameHint: String?
    let focus: FocusState<ClarivaConsultantSetupField?>.Binding
    let onChange: (ClarivaConsultantSetupField, String) -> Void
    let onDone: () -> Void
    var onSkip: (() -> Void)?
    var showsHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                ClarivaConsultantSetupHeader(subtitle: ClarivaConsultantSetupStrings.subtitle)
                    .padding(.bottom, 16)
            }

            maxCreditsField

            bankHeader
                .padding(.top, 20)

            VStack(alignment: .leading, spacing: 12) {
                textField(.accountHolderName,
                          label: "Account holder name",
                          placeholder: holderNameHint?.trimmingCharacters(in: .whitespacesAndNewlines),
                          contentType: .name,
                          next: .bankName)

                textField(.bankName,
                          label: "Bank name",
                          placeholder: "e.g. State Bank of India",
                          contentType: .organizationName,
                          next: .accountNumber)

                ClarivaAuthField(label: "Account number",
                                 footer: setup.accountNumberError,
                                 state: setup.accountNumberError == nil ? .default : .error,
                                 isFocused: focus.wrappedValue == .accountNumber) {
                    TextField(text: binding(.accountNumber)) {
                        Text("Account number")
                    }
                    .focused(focus, equals: .accountNumber)
                    .keyboardType(.numberPad)
                    .autocorrectionDisabled()
                }

                ifscField

                ClarivaAuthField(label: "Branch name (optional)", isFocused: focus.wrappedValue == .branchName) {
                    TextField(text: binding(.branchName)) {
                        Text("Branch name (optional)")
                    }
                    .focused(focus, equals: .branchName)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit {
                        focus.wrappedValue = nil
                        onDone()
                    }
                }
            }
            .padding(.top, 12)

            // "Create account" stays disabled while a bank account is half typed, so say why.
            if setup.isBankDetailsIncomplete {
                HStack(alignment: .top, spacing: 6) {
                    CompoundIcon(\.info, size: .xSmall, relativeTo: .compound.bodySM)
                        .foregroundStyle(.compound.iconCriticalPrimary)
                    Text("Fill in all the bank fields (branch is optional), or leave them all empty.")
                        .font(.compound.bodySM)
                        .foregroundColor(.compound.textCriticalPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 12)
            }

            if let onSkip {
                HStack {
                    Spacer()
                    Button(ClarivaConsultantSetupStrings.skip, action: onSkip)
                        .buttonStyle(.compound(.tertiary, size: .medium))
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Fields

    private var maxCreditsField: some View {
        ClarivaAuthField(label: "Max credits per chat",
                         footer: setup.maxCreditsError ?? "What a client pays to chat with you. Leave empty to set it later.",
                         state: setup.maxCreditsError == nil ? .default : .error,
                         isFocused: focus.wrappedValue == .maxCredits) {
            HStack(spacing: 8) {
                TextField(text: binding(.maxCredits), prompt: .clarivaPrompt("e.g. 50")) {
                    Text("Max credits per chat")
                }
                .focused(focus, equals: .maxCredits)
                .keyboardType(.numberPad)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("credits")
                    .font(.compound.bodyMD)
                    .foregroundColor(.compound.textSecondary)
            }
        }
    }

    private var bankHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                CompoundIcon(\.lockSolid, size: .xSmall, relativeTo: .compound.bodyMD)
                    .foregroundStyle(.compound.iconSecondary)
                Text("Bank details")
                    .font(.compound.bodyMDSemibold)
                    .foregroundColor(.compound.textPrimary)
            }
            Text("Used only to send you your earnings.")
                .font(.compound.bodySM)
                .foregroundColor(.compound.textSecondary)
        }
    }

    private var ifscField: some View {
        ClarivaAuthField(label: "IFSC code",
                         footer: setup.ifscError ?? ifscStatus.message,
                         state: ifscFieldState,
                         isFocused: focus.wrappedValue == .ifscCode) {
            TextField(text: binding(.ifscCode), prompt: .clarivaPrompt("e.g. SBIN0001234")) {
                Text("IFSC code")
            }
            .focused(focus, equals: .ifscCode)
            .keyboardType(.asciiCapable)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .submitLabel(.next)
            .onSubmit { focus.wrappedValue = .branchName }
        }
    }

    private var ifscFieldState: ClarivaAuthFieldState {
        if setup.ifscError != nil || ifscStatus == .notFound {
            return .error
        }
        if case .found = ifscStatus {
            return .success
        }
        return .default
    }

    private func textField(_ field: ClarivaConsultantSetupField,
                           label: String,
                           placeholder: String?,
                           contentType: UITextContentType?,
                           next: ClarivaConsultantSetupField) -> some View {
        ClarivaAuthField(label: label, isFocused: focus.wrappedValue == field) {
            TextField(text: binding(field), prompt: placeholder.flatMap { $0.isEmpty ? nil : Text.clarivaPrompt($0) }) {
                Text(label)
            }
            .focused(focus, equals: field)
            .textContentType(contentType)
            .textInputAutocapitalization(.words)
            .submitLabel(.next)
            .onSubmit { focus.wrappedValue = next }
        }
    }

    /// Reads the form but routes every edit through the view model (filtering, IFSC lookup).
    private func binding(_ field: ClarivaConsultantSetupField) -> Binding<String> {
        Binding(get: { setup.value(of: field) },
                set: { onChange(field, $0) })
    }
}

/// "Set up payouts  [Optional]" and the line under it.
struct ClarivaConsultantSetupHeader: View {
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(ClarivaConsultantSetupStrings.title)
                    .font(.compound.bodyLGSemibold)
                    .foregroundColor(.compound.textPrimary)

                Text(ClarivaConsultantSetupStrings.optional)
                    .font(.compound.bodyXSSemibold)
                    .foregroundColor(.compound.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.compound.bgSubtleSecondary, in: Capsule())
            }

            Text(subtitle)
                .font(.compound.bodySM)
                .foregroundColor(.compound.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shown in place of the fields after "Skip for now", with a way back.
private struct ClarivaSkippedConsultantSetup: View {
    let onResume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                CompoundIcon(\.info, size: .xSmall, relativeTo: .compound.bodySM)
                    .foregroundStyle(.compound.iconSecondary)
                Text(ClarivaConsultantSetupStrings.skipped)
                    .font(.compound.bodySM)
                    .foregroundColor(.compound.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(ClarivaConsultantSetupStrings.resume, action: onResume)
                    .buttonStyle(.compound(.tertiary, size: .medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
