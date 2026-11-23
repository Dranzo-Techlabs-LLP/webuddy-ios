//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// A labelled input box in the style of the Android Clariva auth form: the label sits ABOVE an
/// outlined box, with optional supporting text below it.
struct ClarivaAuthField<Content: View>: View {
    @Environment(\.isEnabled) private var isEnabled

    let label: String
    var footer: String?
    var state: ClarivaAuthFieldState = .default
    var isFocused = false
    @ViewBuilder let content: () -> Content

    private let shape = RoundedRectangle(cornerRadius: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.compound.bodyMD)
                .foregroundColor(textColor)

            content()
                .font(.compound.bodyLG)
                .foregroundColor(textColor)
                .tint(Color.compound.iconAccentTertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(backgroundColor, in: shape)
                .overlay {
                    shape.strokeBorder(borderColor, lineWidth: borderWidth)
                }

            if let footer {
                Text(footer)
                    .font(.compound.bodySM)
                    .foregroundColor(footerColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var textColor: Color {
        isEnabled ? Color.compound.textPrimary : Color.compound.textDisabled
    }

    private var backgroundColor: Color {
        Color.compound.bgCanvasDefault.opacity(isEnabled ? 1 : 0.6)
    }

    private var borderWidth: CGFloat {
        isFocused || state == .error ? 2 : 1
    }

    private var borderColor: Color {
        switch state {
        case .error:
            return Color.compound.textCriticalPrimary
        case .success, .default:
            return isFocused ? Color.compound.iconAccentTertiary : Color.compound.borderInteractiveSecondary
        }
    }

    private var footerColor: Color {
        switch state {
        case .default:
            return Color.compound.textSecondary
        case .error:
            return Color.compound.textCriticalPrimary
        case .success:
            return Color.compound.textSuccessPrimary
        }
    }
}

/// The input inside a `ClarivaAuthField` for passwords, with the trailing show/hide toggle.
struct ClarivaPasswordInput<FocusValue: Hashable>: View {
    @Binding var text: String
    var placeholder: String?
    var contentType: UITextContentType?
    @Binding var isVisible: Bool
    let focus: FocusState<FocusValue?>.Binding
    let focusValue: FocusValue
    
    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isVisible {
                    TextField(text: $text, prompt: placeholder.map(Text.clarivaPrompt)) {
                        Text(placeholder ?? "")
                    }
                } else {
                    SecureField(text: $text, prompt: placeholder.map(Text.clarivaPrompt)) {
                        Text(placeholder ?? "")
                    }
                }
            }
            .focused(focus, equals: focusValue)
            .textContentType(contentType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Button {
                let wasFocused = focus.wrappedValue == focusValue
                isVisible.toggle()
                if wasFocused {
                    // Swapping SecureField <-> TextField drops the focus, so restore it.
                    DispatchQueue.main.async {
                        focus.wrappedValue = focusValue
                    }
                }
            } label: {
                Image(systemName: isVisible ? "eye" : "eye.slash")
                    .foregroundColor(Color.compound.iconSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isVisible ? "Hide password" : "Show password")
        }
    }
}

extension Text {
    /// Placeholder text for an input inside a `ClarivaAuthField`.
    static func clarivaPrompt(_ placeholder: String) -> Text {
        Text(placeholder).foregroundColor(Color.compound.textSecondary)
    }
}
