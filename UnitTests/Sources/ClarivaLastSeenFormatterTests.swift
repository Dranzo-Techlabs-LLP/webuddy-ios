//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

@testable import ElementX

/// WhatsApp-style "last seen" label (Android ee053dc156 `formatLastSeen`): today / yesterday / weekday
/// within the past week at the time, otherwise date + time.
final class ClarivaLastSeenFormatterTests: XCTestCase {
    /// en_GB: 24 h times and day/month/year dates, so the expectations don't depend on the device.
    private let locale = Locale(identifier: "en_GB")
    private var calendar: Calendar!
    /// Thursday 29 October 2026, 15:00.
    private var now: Date!

    override func setUp() {
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        now = date(2026, 10, 29, 15, 0)
    }

    func testUnknownLastActive() {
        XCTAssertNil(format(nil))
    }

    func testToday() {
        XCTAssertEqual(format(date(2026, 10, 29, 10, 30)), "last seen today at 10:30")
        XCTAssertEqual(format(date(2026, 10, 29, 0, 5)), "last seen today at 00:05")
    }

    func testYesterday() {
        XCTAssertEqual(format(date(2026, 10, 28, 22, 45)), "last seen yesterday at 22:45")
        XCTAssertEqual(format(date(2026, 10, 28, 0, 0)), "last seen yesterday at 00:00")
    }

    func testWithinTheWeekShowsTheWeekday() {
        XCTAssertEqual(format(date(2026, 10, 27, 9, 5)), "last seen Tue at 09:05")
        // 6 calendar days ago is still "this week".
        XCTAssertEqual(format(date(2026, 10, 23, 18, 0)), "last seen Fri at 18:00")
    }

    func testOlderShowsTheDate() {
        XCTAssertEqual(format(date(2026, 10, 22, 10, 30)), "last seen 22/10/26, 10:30")
        XCTAssertEqual(format(date(2025, 1, 3, 7, 15)), "last seen 03/01/25, 07:15")
    }

    func testClockSkewCountsAsToday() {
        XCTAssertEqual(format(date(2026, 10, 29, 15, 2)), "last seen today at 15:02")
    }

    func testDaylightSavingChangeStillCountsWholeDays() {
        // UK clocks went back on Sunday 25 October 2026 (a 25 hour day).
        now = date(2026, 10, 25, 12, 0)
        XCTAssertEqual(format(date(2026, 10, 24, 23, 30)), "last seen yesterday at 23:30")
        now = date(2026, 10, 26, 0, 30)
        XCTAssertEqual(format(date(2026, 10, 25, 0, 30)), "last seen yesterday at 00:30")
    }

    func testVisibleLabelUsesTheFormat() {
        let presence = UserPresence(isOnline: false, lastActiveDate: date(2026, 10, 28, 22, 45))
        let label = ClarivaPresenceFormatter.visiblePresenceLabel(presence: presence,
                                                                  myID: "@alice:clarivahub.com",
                                                                  peerID: "@bob:clarivahub.com",
                                                                  isContact: true,
                                                                  myPrivacy: PresencePrivacy(),
                                                                  peerPrivacy: PresencePrivacy(),
                                                                  now: now,
                                                                  calendar: calendar,
                                                                  locale: locale)
        XCTAssertEqual(label, "last seen yesterday at 22:45")
    }

    // MARK: - Helpers

    private func format(_ lastActive: Date?) -> String? {
        ClarivaPresenceFormatter.formatLastSeen(lastActive, now: now, calendar: calendar, locale: locale)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}
