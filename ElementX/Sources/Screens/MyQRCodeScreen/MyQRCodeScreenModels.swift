//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import UIKit

struct MyQRCodeScreenViewState: BindableState {
    let userID: String
    var displayName: String?
    var avatarURL: URL?

    /// `https://clarivahub.com/u/<percent-encoded MXID>`, byte-identical to Android's payload.
    let link: URL?
    /// The QR code of `link`. `nil` if it couldn't be generated.
    let qrImage: UIImage?
}

enum MyQRCodeScreenViewAction { }
