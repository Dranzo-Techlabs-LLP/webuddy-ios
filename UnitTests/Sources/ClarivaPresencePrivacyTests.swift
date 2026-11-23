//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

@testable import ElementX

/// "Last seen and online" privacy rules (Android ee053dc156 `PresencePrivacy` / `visiblePresenceLabel`)
/// and the consultant designation helpers.
final class ClarivaPresencePrivacyTests: XCTestCase {
    private let alice = "@alice:clarivahub.com"
    private let bob = "@bob:clarivahub.com"
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    // MARK: - Except tokens

    func testExceptTokenMatchesAndroid() {
        // sha256("clariva-last-seen|owner|viewer"), first 16 bytes as lowercase hex, like Android.
        XCTAssertEqual(PresencePrivacy.exceptToken(ownerID: alice, viewerID: bob), "a707602d70604a0c607aa98e7369a7d5")
        XCTAssertEqual(PresencePrivacy.exceptToken(ownerID: bob, viewerID: alice), "ed95e616aa8a614eac07df93ac662544")
    }

    // MARK: - Audiences

    func testEveryone() {
        let privacy = PresencePrivacy()
        XCTAssertTrue(privacy.sharesLastSeen(ownerID: alice, viewerID: bob, isContact: false))
        XCTAssertTrue(privacy.sharesOnline(ownerID: alice, viewerID: bob, isContact: false))
        XCTAssertTrue(privacy.sharesWithAnyone)
    }

    func testMyContacts() {
        let privacy = PresencePrivacy(lastSeen: .myContacts, online: .sameAsLastSeen)
        XCTAssertTrue(privacy.sharesLastSeen(ownerID: alice, viewerID: bob, isContact: true))
        XCTAssertFalse(privacy.sharesLastSeen(ownerID: alice, viewerID: bob, isContact: false))
        XCTAssertTrue(privacy.sharesOnline(ownerID: alice, viewerID: bob, isContact: true))
        XCTAssertFalse(privacy.sharesOnline(ownerID: alice, viewerID: bob, isContact: false))
    }

    func testMyContactsExcept() {
        let carol = "@carol:clarivahub.com"
        let privacy = PresencePrivacy(lastSeen: .myContactsExcept,
                                      online: .sameAsLastSeen,
                                      lastSeenExcept: [PresencePrivacy.exceptToken(ownerID: alice, viewerID: bob)])
        XCTAssertFalse(privacy.sharesLastSeen(ownerID: alice, viewerID: bob, isContact: true))
        XCTAssertTrue(privacy.sharesLastSeen(ownerID: alice, viewerID: carol, isContact: true))
        XCTAssertFalse(privacy.sharesLastSeen(ownerID: alice, viewerID: carol, isContact: false))
        // The token is salted with the owner: it doesn't exclude Bob from someone else's last seen.
        XCTAssertTrue(privacy.sharesLastSeen(ownerID: carol, viewerID: bob, isContact: true))
    }

    func testNobody() {
        let privacy = PresencePrivacy(lastSeen: .nobody, online: .sameAsLastSeen)
        XCTAssertFalse(privacy.sharesLastSeen(ownerID: alice, viewerID: bob, isContact: true))
        XCTAssertFalse(privacy.sharesOnline(ownerID: alice, viewerID: bob, isContact: true))
        XCTAssertFalse(privacy.sharesWithAnyone)

        let onlineForEveryone = PresencePrivacy(lastSeen: .nobody, online: .everyone)
        XCTAssertFalse(onlineForEveryone.sharesLastSeen(ownerID: alice, viewerID: bob, isContact: true))
        XCTAssertTrue(onlineForEveryone.sharesOnline(ownerID: alice, viewerID: bob, isContact: false))
        XCTAssertTrue(onlineForEveryone.sharesWithAnyone)
    }

    // MARK: - Storage

    func testJSONRoundTrip() {
        let privacy = PresencePrivacy(lastSeen: .myContactsExcept, online: .sameAsLastSeen, lastSeenExcept: ["b", "a"])
        XCTAssertEqual(privacy.jsonValue, .object(["lastSeen": .string("contacts_except"),
                                                   "online": .string("same_as_last_seen"),
                                                   "lastSeenExcept": .array([.string("a"), .string("b")])]))
        XCTAssertEqual(PresencePrivacy(jsonValue: privacy.jsonValue), privacy)
    }

    func testExceptionsAreOnlyStoredForContactsExcept() {
        let privacy = PresencePrivacy(lastSeen: .myContacts, online: .everyone, lastSeenExcept: ["a"])
        XCTAssertEqual(privacy.jsonValue, .object(["lastSeen": .string("contacts"), "online": .string("everyone")]))
    }

    func testMissingOrUnknownValuesFallBackToEveryone() {
        XCTAssertEqual(PresencePrivacy(jsonValue: nil), PresencePrivacy())
        XCTAssertEqual(PresencePrivacy(jsonValue: .string("nobody")), PresencePrivacy())
        XCTAssertEqual(PresencePrivacy(jsonValue: .object(["lastSeen": .string("friends"), "online": .bool(true)])), PresencePrivacy())
    }

    func testDecodesTheWalletSettingsJSON() throws {
        let json = """
        {"isConsultant": "1", "Webuddy_name": "@alice:clarivahub.com",
         "settings": {"designation": "  Cardiologist ", "theme": {"dark": true, "size": 2},
                      "presencePrivacy": {"lastSeen": "nobody", "online": "everyone"}}}
        """
        let response = try JSONDecoder().decode(WalletUserProfileResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.isConsultant, 1)
        XCTAssertEqual(ClarivaDesignation.designation(from: response.settings), "Cardiologist")
        XCTAssertEqual(PresencePrivacy(jsonValue: response.settings?[PresencePrivacy.settingsKey]),
                       PresencePrivacy(lastSeen: .nobody, online: .everyone))
        // Keys this app doesn't know survive a read-merge-write.
        XCTAssertEqual(response.settings?["theme"], .object(["dark": .bool(true), "size": .number(2)]))

        let encoded = try JSONEncoder().encode(WalletUpdateSettingsRequest(settings: response.settings ?? [:]))
        let reparsed = try JSONDecoder().decode(WalletUserProfileResponse.self, from: encoded)
        XCTAssertEqual(reparsed.settings, response.settings)
    }

    func testMalformedSettingsReadAsNone() throws {
        let response = try JSONDecoder().decode(WalletUserProfileResponse.self, from: Data(#"{"isConsultant": 0, "settings": "oops"}"#.utf8))
        XCTAssertEqual(response.isConsultant, 0)
        XCTAssertNil(response.settings)
    }

    // MARK: - Visible presence (reciprocal, like WhatsApp)

    func testOnlineIsShownWhenBothShareIt() {
        XCTAssertEqual(label(online: true, myPrivacy: PresencePrivacy(), peerPrivacy: PresencePrivacy()), "online")
    }

    func testUnknownPeerChoiceFailsClosed() {
        XCTAssertNil(label(online: true, myPrivacy: PresencePrivacy(), peerPrivacy: nil))
        XCTAssertNil(label(online: false, myPrivacy: PresencePrivacy(), peerPrivacy: nil))
    }

    func testPeerHidingOnlineIsNeverDowngradedToLastSeen() {
        let peerPrivacy = PresencePrivacy(lastSeen: .nobody, online: .sameAsLastSeen)
        XCTAssertNil(label(online: true, myPrivacy: PresencePrivacy(), peerPrivacy: peerPrivacy))
    }

    func testHidingMyLastSeenHidesTheirs() {
        let myPrivacy = PresencePrivacy(lastSeen: .nobody, online: .everyone)
        XCTAssertNil(label(online: false, myPrivacy: myPrivacy, peerPrivacy: PresencePrivacy()))
        // Online is a separate choice: still shown both ways.
        XCTAssertEqual(label(online: true, myPrivacy: myPrivacy, peerPrivacy: PresencePrivacy()), "online")
    }

    func testHidingMyOnlineHidesTheirs() {
        let myPrivacy = PresencePrivacy(lastSeen: .nobody, online: .sameAsLastSeen)
        XCTAssertNil(label(online: true, myPrivacy: myPrivacy, peerPrivacy: PresencePrivacy()))
    }

    func testContactsOnlyNeedsAJoinedChat() {
        let peerPrivacy = PresencePrivacy(lastSeen: .myContacts, online: .sameAsLastSeen)
        XCTAssertNil(label(online: false, isContact: false, myPrivacy: PresencePrivacy(), peerPrivacy: peerPrivacy))
        XCTAssertNotNil(label(online: false, isContact: true, myPrivacy: PresencePrivacy(), peerPrivacy: peerPrivacy))
    }

    func testExcludedViewerDoesntSeeLastSeen() {
        let peerPrivacy = PresencePrivacy(lastSeen: .myContactsExcept,
                                          online: .sameAsLastSeen,
                                          lastSeenExcept: [PresencePrivacy.exceptToken(ownerID: bob, viewerID: alice)])
        XCTAssertNil(label(online: false, isContact: true, myPrivacy: PresencePrivacy(), peerPrivacy: peerPrivacy))
        XCTAssertNil(label(online: true, isContact: true, myPrivacy: PresencePrivacy(), peerPrivacy: peerPrivacy))
    }

    func testNoLastActiveTimeShowsNothing() {
        let presence = UserPresence(isOnline: false, lastActiveDate: nil)
        XCTAssertNil(ClarivaPresenceFormatter.visiblePresenceLabel(presence: presence, myID: alice, peerID: bob, isContact: true,
                                                                   myPrivacy: PresencePrivacy(), peerPrivacy: PresencePrivacy(), now: now))
    }

    // MARK: - Designation

    func testDesignationParsing() {
        XCTAssertEqual(ClarivaDesignation.designation(from: ["designation": .string(" Cardiologist ")]), "Cardiologist")
        XCTAssertNil(ClarivaDesignation.designation(from: ["designation": .string("   ")]))
        XCTAssertNil(ClarivaDesignation.designation(from: ["designation": .number(3)]))
        XCTAssertNil(ClarivaDesignation.designation(from: [:]))
        XCTAssertNil(ClarivaDesignation.designation(from: nil))
    }

    func testDesignationBadge() {
        XCTAssertEqual(ClarivaDesignation.badge(isConsultant: true, designation: nil), "Consultant")
        XCTAssertEqual(ClarivaDesignation.badge(isConsultant: true, designation: "Cardiologist"), "Cardiologist")
        XCTAssertNil(ClarivaDesignation.badge(isConsultant: false, designation: "Cardiologist"))
        XCTAssertNil(ClarivaDesignation.badge(isConsultant: nil, designation: "Cardiologist"))
    }

    // MARK: - Helpers

    /// Alice looks at Bob's presence.
    private func label(online: Bool, isContact: Bool = true, myPrivacy: PresencePrivacy, peerPrivacy: PresencePrivacy?) -> String? {
        ClarivaPresenceFormatter.visiblePresenceLabel(presence: UserPresence(isOnline: online, lastActiveDate: now.addingTimeInterval(-60)),
                                                      myID: alice,
                                                      peerID: bob,
                                                      isContact: isContact,
                                                      myPrivacy: myPrivacy,
                                                      peerPrivacy: peerPrivacy,
                                                      now: now)
    }
}
