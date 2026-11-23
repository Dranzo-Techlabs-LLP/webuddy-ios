//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Format rules for a payout bank account, shared by consultant sign-up and Settings > Bank Details.
/// Kept in sync with the API's `AddMyBankDetailDto`. Mirrors Android `BankAccountRules`.
enum BankAccountRules {
    static let accountNumberMaxDigits = 18
    static let ifscLength = 11
    /// The API's `@MaxLength(120)` on the text fields.
    static let maxTextLength = 120
    static let minNameLength = 2

    /// `[0-9]` rather than `\d`: ICU's `\d` also accepts other scripts' digits, the API's doesn't.
    private static let accountNumberPattern = "^[0-9]{9,18}$"
    private static let ifscPattern = "^[A-Z]{4}0[A-Z0-9]{6}$"

    static let accountNumberError = "Account number must be 9 to 18 digits"
    static let ifscError = "IFSC code looks like ABCD0123456"

    /// IFSCs are checked and saved upper-cased; the field keeps what was typed.
    static func normalizedIFSC(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func isValidAccountNumber(_ value: String) -> Bool {
        matches(value.trimmingCharacters(in: .whitespacesAndNewlines), accountNumberPattern)
    }

    static func isValidIFSC(_ value: String) -> Bool {
        matches(normalizedIFSC(value), ifscPattern)
    }

    static func isValidName(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).count >= minNameLength
    }

    // MARK: - Input filters (a rejected edit keeps the previous value, like Android's onValueChange)

    /// `0`-`9` only (`isASCII` also rules out a digit followed by a combining mark).
    static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    /// `A`-`Z`, `a`-`z` and `0`-`9` only.
    static func isASCIILetterOrDigit(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    static func acceptsAccountNumberInput(_ value: String) -> Bool {
        value.count <= accountNumberMaxDigits && value.allSatisfy(isDigit)
    }

    static func acceptsIFSCInput(_ value: String) -> Bool {
        value.count <= ifscLength && value.allSatisfy(isASCIILetterOrDigit)
    }

    /// UTF-16 length, as the API's class-validator measures it.
    static func acceptsTextInput(_ value: String) -> Bool {
        value.utf16.count <= maxTextLength
    }

    // MARK: - Private

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
