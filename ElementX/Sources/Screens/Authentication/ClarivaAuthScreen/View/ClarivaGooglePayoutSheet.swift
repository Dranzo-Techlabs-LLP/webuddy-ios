//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// The sheet of a Google sign-up whose role is unknown: "Are you a consultant?", then - for a
/// consultant - the optional payout step. Reads the prompt from the context so the step switch is
/// always current.
struct ClarivaGoogleSignUpSheet: View {
    @Bindable var context: ClarivaAuthScreenViewModel.Context

    var body: some View {
        if let prompt = context.viewState.bindings.googleRolePrompt {
            Group {
                if prompt.isAskingPayouts {
                    ClarivaGooglePayoutSheet(context: context, prompt: prompt)
                        .presentationDetents([.large])
                } else {
                    // A consultant gets the same optional payout step as the email form.
                    ClarivaGoogleRoleSheet(prompt: prompt) { isConsultant in
                        context.send(viewAction: isConsultant ? .showGooglePayoutStep : .confirmGoogleRole(isConsultant: false, skipPayoutSetup: false))
                    } onCancel: {
                        context.send(viewAction: .cancelGoogleRole)
                    }
                }
            }
            // Not dismissible by swiping: an accidental dismiss would silently abandon a sign-up that
            // has already been through the Google sheet.
            .interactiveDismissDisabled(true)
        }
    }
}

/// Second step of Google sign-up for a consultant: the same optional chat rate and bank account the
/// email sign-up form asks for. Google sign-in has no form of its own, so without this a Google
/// consultant could only add them later. Mirrors Android `ClarivaGooglePayoutDialog`.
///
/// The account is created only from here ("Continue" or "Skip for now"), so going "Back" to the role
/// question still creates nothing.
struct ClarivaGooglePayoutSheet: View {
    @Bindable var context: ClarivaAuthScreenViewModel.Context
    let prompt: ClarivaGoogleRolePrompt

    @FocusState private var focusedField: ClarivaConsultantSetupField?

    private var canContinue: Bool {
        context.viewState.consultantSetup.isValid && !context.viewState.ifscStatus.blocksSave
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ClarivaConsultantSetupHeader(subtitle: prompt.payoutSubtitle)

                ClarivaConsultantSetupFields(setup: context.viewState.consultantSetup,
                                             ifscStatus: context.viewState.ifscStatus,
                                             holderNameHint: prompt.name,
                                             focus: $focusedField,
                                             onChange: setField,
                                             onDone: confirm,
                                             // Skip lives in the button row below, next to Continue.
                                             onSkip: nil,
                                             showsHeader: false)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)
            .readableFrame()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.compound.bgSubtleSecondaryLevel0.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                Button(action: confirm) {
                    Text(L10n.actionContinue)
                }
                .buttonStyle(.compound(.primary))
                .disabled(!canContinue)

                HStack {
                    Button("Back") {
                        focusedField = nil
                        context.send(viewAction: .backToGoogleRole)
                    }
                    .buttonStyle(.compound(.tertiary, size: .medium))

                    Spacer()

                    Button(ClarivaConsultantSetupStrings.skip) {
                        focusedField = nil
                        context.send(viewAction: .confirmGoogleRole(isConsultant: true, skipPayoutSetup: true))
                    }
                    .buttonStyle(.compound(.tertiary, size: .medium))
                }
            }
            .padding(16)
            .background(Color.compound.bgSubtleSecondaryLevel0.ignoresSafeArea())
        }
    }

    private func setField(_ field: ClarivaConsultantSetupField, _ value: String) {
        context.send(viewAction: .setConsultantSetupField(field, value))
    }

    private func confirm() {
        guard canContinue else { return }
        focusedField = nil
        context.send(viewAction: .confirmGoogleRole(isConsultant: true, skipPayoutSetup: false))
    }
}
