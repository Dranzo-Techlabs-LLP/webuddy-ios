//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CryptoKit
import Foundation

// MARK: - Privacy choice (Android `PresencePrivacy.kt`, ee053dc156)

/// "Who can see my last seen" (WhatsApp's options).
enum LastSeenAudience: String, CaseIterable {
    case everyone
    case myContacts = "contacts"
    case myContactsExcept = "contacts_except"
    case nobody
}

/// "Who can see when I'm online".
enum OnlineAudience: String, CaseIterable {
    case everyone
    case sameAsLastSeen = "same_as_last_seen"
}

/// A user's "Last seen and online" privacy choice. It is stored in their Wallet-API `settings` so
/// chat partners' apps can honour it.
///
/// A "contact" is someone the user has a DM with that both of them have joined (an unanswered chat
/// request doesn't count). Excluded contacts are stored as `exceptToken`s rather than user IDs, so
/// the public settings record doesn't list who was excluded.
struct PresencePrivacy: Equatable {
    var lastSeen: LastSeenAudience = .everyone
    var online: OnlineAudience = .everyone
    var lastSeenExcept: Set<String> = []

    /// Whether `ownerID` (whose choice this is) shows their last seen to `viewerID`.
    func sharesLastSeen(ownerID: String, viewerID: String, isContact: Bool) -> Bool {
        switch lastSeen {
        case .everyone:
            true
        case .myContacts:
            isContact
        case .myContactsExcept:
            isContact && !lastSeenExcept.contains(Self.exceptToken(ownerID: ownerID, viewerID: viewerID))
        case .nobody:
            false
        }
    }

    /// Whether `ownerID` shows "online" to `viewerID`.
    func sharesOnline(ownerID: String, viewerID: String, isContact: Bool) -> Bool {
        online == .everyone || sharesLastSeen(ownerID: ownerID, viewerID: viewerID, isContact: isContact)
    }

    /// False when nobody at all may see this user's presence, so it needn't be published.
    var sharesWithAnyone: Bool {
        online == .everyone || lastSeen != .nobody
    }

    // MARK: Storage

    /// Key of this object inside the Wallet-API `settings` JSON.
    static let settingsKey = "presencePrivacy"
    private static let lastSeenKey = "lastSeen"
    private static let onlineKey = "online"
    private static let exceptKey = "lastSeenExcept"

    var jsonValue: ClarivaJSONValue {
        var object: [String: ClarivaJSONValue] = [Self.lastSeenKey: .string(lastSeen.rawValue),
                                                  Self.onlineKey: .string(online.rawValue)]
        if lastSeen == .myContactsExcept, !lastSeenExcept.isEmpty {
            object[Self.exceptKey] = .array(lastSeenExcept.sorted().map { .string($0) })
        }
        return .object(object)
    }

    /// Parses a stored value; anything missing or unrecognised falls back to "Everyone".
    init(jsonValue: ClarivaJSONValue?) {
        guard let object = jsonValue?.objectValue else {
            self.init()
            return
        }
        self.init(lastSeen: object[Self.lastSeenKey]?.stringValue.flatMap(LastSeenAudience.init(rawValue:)) ?? .everyone,
                  online: object[Self.onlineKey]?.stringValue.flatMap(OnlineAudience.init(rawValue:)) ?? .everyone,
                  lastSeenExcept: Set(object[Self.exceptKey]?.arrayValue?.compactMap(\.stringValue) ?? []))
    }

    init(lastSeen: LastSeenAudience = .everyone, online: OnlineAudience = .everyone, lastSeenExcept: Set<String> = []) {
        self.lastSeen = lastSeen
        self.online = online
        self.lastSeenExcept = lastSeenExcept
    }

    /// Stable, non-reversible stand-in for "`ownerID` excludes `viewerID`". Salted with the owner so
    /// the same viewer gets a different token in every user's list. Byte-for-byte the Android token:
    /// the first 16 bytes of SHA-256("clariva-last-seen|owner|viewer"), lowercase hex.
    static func exceptToken(ownerID: String, viewerID: String) -> String {
        let digest = SHA256.hash(data: Data("clariva-last-seen|\(ownerID)|\(viewerID)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Designation (Android `WalletService` companion)

enum ClarivaDesignation {
    /// Longest designation a consultant can set; keeps the badge under their name on one line.
    static let maxLength = 40
    /// Shown for a consultant who hasn't set a designation.
    static let defaultConsultantDesignation = "Consultant"
    /// Key of the designation inside the Wallet-API `settings` JSON.
    static let settingsKey = "designation"

    /// The stored designation: a trimmed, non-empty JSON string, else nil.
    static func designation(from settings: [String: ClarivaJSONValue]?) -> String? {
        normalized(settings?[settingsKey]?.stringValue)
    }

    static func normalized(_ designation: String?) -> String? {
        guard let trimmed = designation?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// The badge for a user: their designation (or "Consultant") when they are a consultant, else nil.
    static func badge(isConsultant: Bool?, designation: String?) -> String? {
        guard isConsultant == true else { return nil }
        return designation ?? defaultConsultantDesignation
    }
}

// MARK: - Presence label (Android `DmPeerStatus.kt`)

/// A user's Matrix presence as reported by the homeserver.
struct UserPresence: Equatable {
    let isOnline: Bool
    /// Wall-clock time of the user's last activity, or nil when the server doesn't say.
    let lastActiveDate: Date?
}

enum ClarivaPresenceFormatter {
    static let onlineLabel = "online"

    /// The label for the partner's `presence`, or nil when either person's privacy choice hides it.
    /// "Online" is never downgraded to "last seen just now": if online is hidden, so is last seen,
    /// because an online audience always includes the last-seen audience.
    ///
    /// `peerPrivacy == nil` means the partner's choice isn't known yet: hidden (fail closed).
    static func visiblePresenceLabel(presence: UserPresence,
                                     myID: String,
                                     peerID: String,
                                     isContact: Bool,
                                     myPrivacy: PresencePrivacy,
                                     peerPrivacy: PresencePrivacy?,
                                     now: Date,
                                     calendar: Calendar = .current,
                                     locale: Locale = .current) -> String? {
        guard let peerPrivacy else { return nil }

        if presence.isOnline {
            let canSeeOnline = peerPrivacy.sharesOnline(ownerID: peerID, viewerID: myID, isContact: isContact) &&
                myPrivacy.sharesOnline(ownerID: myID, viewerID: peerID, isContact: isContact)
            return canSeeOnline ? onlineLabel : nil
        } else {
            let canSeeLastSeen = peerPrivacy.sharesLastSeen(ownerID: peerID, viewerID: myID, isContact: isContact) &&
                myPrivacy.sharesLastSeen(ownerID: myID, viewerID: peerID, isContact: isContact)
            return canSeeLastSeen ? formatLastSeen(presence.lastActiveDate, now: now, calendar: calendar, locale: locale) : nil
        }
    }

    /// Short enough for the space under the name next to the call / refund buttons:
    /// "last seen today at 10:30 AM", "last seen yesterday at …", "last seen Thu at …" within the past
    /// week, and "last seen 23/10/26, 10:30 AM" (locale date order) before that.
    static func formatLastSeen(_ lastActive: Date?, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let lastActive else { return nil }

        let time = format(lastActive, template: "jmm", calendar: calendar, locale: locale)
        let days = calendarDaysBetween(lastActive, now, calendar: calendar)
        switch days {
        case 0:
            return "last seen today at \(time)"
        case 1:
            return "last seen yesterday at \(time)"
        case ..<daysInWeek:
            return "last seen \(format(lastActive, template: "EEE", calendar: calendar, locale: locale)) at \(time)"
        default:
            return "last seen \(format(lastActive, template: "ddMMyy", calendar: calendar, locale: locale)), \(time)"
        }
    }

    private static let daysInWeek = 7

    /// Formats `date` with the locale's best pattern for `template` (e.g. "EEE" → "Thu", "jmm" → "10:30 AM").
    private static func format(_ date: Date, template: String, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// Whole calendar days from `from` to `to` in the calendar's time zone; never negative (clock skew).
    /// Counted between the starts of both days, so a 23 or 25 hour DST day still counts as one.
    private static func calendarDaysBetween(_ from: Date, _ to: Date, calendar: Calendar) -> Int {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
        return max(days, 0)
    }
}
