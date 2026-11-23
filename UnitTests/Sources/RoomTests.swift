//
// Copyright 2025 Element Creations Ltd.
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import MatrixRustSDK
import MatrixRustSDKMocks
import XCTest

@testable import ElementX

class RoomTests: XCTestCase {
    func testCallIntent() async throws {
        let room = RoomSDKMock()
        room.hasActiveRoomCallReturnValue = false
        room.isDirectReturnValue = false

        var callIntent = await room.joinCallIntent(startWithVideoMuted: false)
        XCTAssertEqual(callIntent, .startCall)

        room.isDirectReturnValue = true
        callIntent = await room.joinCallIntent(startWithVideoMuted: false)
        XCTAssertEqual(callIntent, .startCallDm)

        room.hasActiveRoomCallReturnValue = true
        callIntent = await room.joinCallIntent(startWithVideoMuted: false)
        XCTAssertEqual(callIntent, .joinExistingDm)

        room.isDirectReturnValue = false
        callIntent = await room.joinCallIntent(startWithVideoMuted: false)
        XCTAssertEqual(callIntent, .joinExisting)
    }

    func testVoiceCallIntent() async throws {
        let room = RoomSDKMock()
        room.hasActiveRoomCallReturnValue = false
        room.isDirectReturnValue = false

        // There are no voice intents outside of DMs.
        var callIntent = await room.joinCallIntent(startWithVideoMuted: true)
        XCTAssertEqual(callIntent, .startCall)

        room.isDirectReturnValue = true
        callIntent = await room.joinCallIntent(startWithVideoMuted: true)
        XCTAssertEqual(callIntent, .startCallDmVoice)

        room.hasActiveRoomCallReturnValue = true
        callIntent = await room.joinCallIntent(startWithVideoMuted: true)
        XCTAssertEqual(callIntent, .joinExistingDmVoice)

        room.isDirectReturnValue = false
        callIntent = await room.joinCallIntent(startWithVideoMuted: true)
        XCTAssertEqual(callIntent, .joinExisting)
    }
}
