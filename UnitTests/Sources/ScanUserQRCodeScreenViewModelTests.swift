//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

@testable import ElementX

@MainActor
class ScanUserQRCodeScreenViewModelTests: XCTestCase {
    func testClarivaUserLinks() {
        // The exact payload of Android's (and iOS') "My QR code".
        XCTAssertEqual(ScanUserQRCodeScreenViewModel.userID(fromScannedText: "https://clarivahub.com/u/%40alice%3Aclarivahub.com"),
                       "@alice:clarivahub.com")
        // Unencoded, padded with whitespace.
        XCTAssertEqual(ScanUserQRCodeScreenViewModel.userID(fromScannedText: "  https://clarivahub.com/u/@bob:example.org\n"),
                       "@bob:example.org")
    }

    func testMatrixPermalinks() {
        XCTAssertEqual(ScanUserQRCodeScreenViewModel.userID(fromScannedText: "https://matrix.to/#/@carol:matrix.org"),
                       "@carol:matrix.org")
    }

    func testInvalidCodes() {
        XCTAssertNil(ScanUserQRCodeScreenViewModel.userID(fromScannedText: "Hello world"))
        XCTAssertNil(ScanUserQRCodeScreenViewModel.userID(fromScannedText: "https://example.com/u/@alice:example.com"))
        XCTAssertNil(ScanUserQRCodeScreenViewModel.userID(fromScannedText: "https://clarivahub.com/u/alice"))
        XCTAssertNil(ScanUserQRCodeScreenViewModel.userID(fromScannedText: "https://matrix.to/#/!room:matrix.org"))
    }
}
