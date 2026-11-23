//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum ScanUserQRCodeScreenViewModelAction: CustomStringConvertible {
    case userScanned(userID: String)

    var description: String {
        switch self {
        case .userScanned: "userScanned" // Don't log the user ID.
        }
    }
}

enum ScanUserQRCodeScreenScanState: Equatable {
    /// Waiting for the camera permission to be resolved.
    case initial
    case scanning
    case noPermission
    /// The scanned code isn't a Clariva/Matrix user link.
    case invalid
    /// A user was found, the screen is about to be replaced.
    case scanned
}

struct ScanUserQRCodeScreenViewState: BindableState {
    var scanState = ScanUserQRCodeScreenScanState.initial
    var bindings = ScanUserQRCodeScreenViewStateBindings()

    var isScanning: Bool {
        scanState == .scanning
    }

    /// The camera preview is only created once access has been granted.
    var showsCamera: Bool {
        switch scanState {
        case .scanning, .invalid, .scanned: true
        case .initial, .noPermission: false
        }
    }
}

struct ScanUserQRCodeScreenViewStateBindings {
    var qrResult: Data?
}

enum ScanUserQRCodeScreenViewAction {
    case startScan
    case tryAgain
    case grantCameraAccess
}
