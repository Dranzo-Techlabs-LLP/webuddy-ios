//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// The room screen's `RoomHeaderView`, plus the DM partner's consultant designation badge beside
/// their name and their "online" / "last seen …" on its own line, WhatsApp-style, so it gets the
/// full title width (Android ee053dc156 `MessagesViewTopBar.RoomAvatarAndNameRow`).
struct RoomScreenHeaderView: View {
    let roomName: String
    let roomAvatar: RoomAvatar
    var dmRecipientVerificationState: UserIdentityVerificationState?
    /// DM only: the partner's designation when they are a consultant.
    var peerBadge: String?
    /// DM only: "online" / "last seen …".
    var peerPresence: String?

    let mediaProvider: MediaProviderProtocol?

    var body: some View {
        if #available(iOS 26.0, *) {
            // On iOS 26+ the toolbarRole(.editor) leading aligns the header.
            content
        } else {
            // Same as `RoomHeaderView`: take up as much space as possible, leading aligned.
            content
                .frame(idealWidth: .greatestFiniteMagnitude, maxWidth: .infinity, alignment: .leading)
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            RoomAvatarImage(avatar: roomAvatar,
                            avatarSize: .room(on: .timeline),
                            mediaProvider: mediaProvider)
                .accessibilityIdentifier(A11yIdentifiers.roomScreen.avatar)
                .accessibilityHidden(true)

            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        // The name gives way first; the badge keeps its (capped) width.
                        Text(roomName)
                            .lineLimit(1)
                            .font(.compound.bodyLGSemibold)
                            .accessibilityIdentifier(A11yIdentifiers.roomScreen.name)

                        if let peerBadge {
                            DesignationBadge(text: peerBadge)
                                .layoutPriority(1)
                        }
                    }

                    if let peerPresence {
                        Text(peerPresence)
                            .lineLimit(1)
                            .font(.compound.bodyXS)
                            .foregroundStyle(peerPresence == ClarivaPresenceFormatter.onlineLabel ? Color.compound.textSuccessPrimary : Color.compound.textSecondary)
                    }
                }

                if let dmRecipientVerificationState {
                    VerificationBadge(verificationState: dmRecipientVerificationState)
                }
            }
        }
    }
}

// MARK: - Previews

struct RoomScreenHeaderView_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 8) {
            makeHeader()
            makeHeader(peerBadge: ClarivaDesignation.defaultConsultantDesignation, peerPresence: ClarivaPresenceFormatter.onlineLabel)
            makeHeader(peerBadge: "Senior Interventional Cardiologist", peerPresence: "last seen yesterday at 10:45 PM")
            makeHeader(peerPresence: "last seen 23/10/26, 10:30 AM")
        }
        .previewLayout(.sizeThatFits)
    }

    static func makeHeader(peerBadge: String? = nil, peerPresence: String? = nil) -> some View {
        RoomScreenHeaderView(roomName: "Dr. Alice Margatroid",
                             roomAvatar: .room(id: "1", name: "Dr. Alice Margatroid", avatarURL: .mockMXCAvatar),
                             dmRecipientVerificationState: .notVerified,
                             peerBadge: peerBadge,
                             peerPresence: peerPresence,
                             mediaProvider: MediaProviderMock(configuration: .init()))
            .padding()
    }
}
