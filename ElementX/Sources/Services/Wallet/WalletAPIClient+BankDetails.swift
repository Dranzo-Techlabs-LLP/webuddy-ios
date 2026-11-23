//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// The caller's payout bank account (Android `WalletApi.getMyBankDetails` / `saveMyBankDetails`).
/// `bearerToken` is the session's Matrix access token (or the Clariva JWT): the API resolves whose
/// account it is from the token, so a caller can only ever reach their own.
extension WalletAPIClient {
    /// `GET v1/experts/me/bank-details` → `{ bankDetail: … | null }`.
    func getMyBankDetails(bearerToken: String) async throws -> MyBankAccountResponse {
        try await send("GET", path: ["v1", "experts", "me", "bank-details"], bearerToken: bearerToken)
    }

    /// `POST v1/experts/me/bank-details`: saves (replaces) the payout account and returns it masked.
    func saveMyBankDetails(_ request: ClarivaBankDetailsRequest, bearerToken: String) async throws -> SavedBankAccount {
        try await send("POST", path: ["v1", "experts", "me", "bank-details"], body: request, bearerToken: bearerToken)
    }
}
