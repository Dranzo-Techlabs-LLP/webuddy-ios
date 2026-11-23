//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX

extension AppSettings {
    /// Clariva locks the app to `clarivahub.com` and replaces the upstream start/server-selection
    /// screens with the Clariva auth screen. Those upstream screens are kept (unreachable) and still
    /// tested, so their tests run with the upstream defaults: matrix.org, any server allowed.
    func useUpstreamAccountProviders() {
        override(accountProviders: ["matrix.org"],
                 allowOtherAccountProviders: true,
                 hideBrandChrome: hideBrandChrome,
                 pushGatewayBaseURL: pushGatewayBaseURL,
                 oidcRedirectURL: oidcRedirectURL,
                 websiteURL: websiteURL,
                 logoURL: logoURL,
                 copyrightURL: copyrightURL,
                 acceptableUseURL: acceptableUseURL,
                 privacyURL: privacyURL,
                 encryptionURL: encryptionURL,
                 deviceVerificationURL: deviceVerificationURL,
                 chatBackupDetailsURL: chatBackupDetailsURL,
                 identityPinningViolationDetailsURL: identityPinningViolationDetailsURL,
                 historySharingDetailsURL: historySharingDetailsURL,
                 elementWebHosts: elementWebHosts,
                 accountProvisioningHost: accountProvisioningHost,
                 bugReportApplicationID: bugReportApplicationID,
                 analyticsTermsURL: analyticsTermsURL,
                 mapTilerConfiguration: mapTilerConfiguration)
    }
}
