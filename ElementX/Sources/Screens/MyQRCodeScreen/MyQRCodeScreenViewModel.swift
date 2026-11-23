//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias MyQRCodeScreenViewModelType = StateStoreViewModelV2<MyQRCodeScreenViewState, MyQRCodeScreenViewAction>

/// Settings → "My QR code" (Android `MyQrCodePresenter`): a QR code of the user's Clariva link
/// that the in-app scanner (Start chat → "Scan QR code") resolves to this user's profile.
class MyQRCodeScreenViewModel: MyQRCodeScreenViewModelType, MyQRCodeScreenViewModelProtocol {
    init(userSession: UserSessionProtocol) {
        let clientProxy = userSession.clientProxy
        let link = ClarivaUserLink.url(for: clientProxy.userID)
        let qrImage = link.flatMap { UIImage(qrCodeData: Data($0.absoluteString.utf8)) }

        super.init(initialViewState: MyQRCodeScreenViewState(userID: clientProxy.userID,
                                                             displayName: clientProxy.userDisplayNamePublisher.value,
                                                             avatarURL: clientProxy.userAvatarURLPublisher.value,
                                                             link: link,
                                                             qrImage: qrImage),
                   mediaProvider: userSession.mediaProvider)

        clientProxy.userDisplayNamePublisher
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.displayName, on: self)
            .store(in: &cancellables)

        clientProxy.userAvatarURLPublisher
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.avatarURL, on: self)
            .store(in: &cancellables)
    }
}
