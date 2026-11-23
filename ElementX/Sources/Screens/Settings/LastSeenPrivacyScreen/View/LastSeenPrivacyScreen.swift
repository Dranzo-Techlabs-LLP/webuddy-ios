//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// WhatsApp-style "Last seen and online" privacy screen (Android ee053dc156 `LastSeenPrivacyView`).
struct LastSeenPrivacyScreen: View {
    @Bindable var context: LastSeenPrivacyScreenViewModel.Context

    var body: some View {
        Form {
            lastSeenSection
            onlineSection
        }
        .compoundList()
        .navigationTitle("Last seen and online")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $context.alertInfo)
        .sheet(item: $context.exceptionsPicker) { _ in
            NavigationStack {
                LastSeenExceptionsPicker(context: context)
            }
        }
    }

    // MARK: - Private

    private var lastSeenSection: some View {
        Section {
            ForEach(LastSeenAudience.allCases, id: \.self) { audience in
                let isSelected = context.viewState.privacy.lastSeen == audience
                ListRow(label: .plain(title: audience.title,
                                      description: audience == .myContactsExcept && isSelected ? context.viewState.excludedSummary : nil),
                        kind: .selection(isSelected: isSelected) {
                            context.send(viewAction: .setLastSeenAudience(audience))
                        })
            }
        } header: {
            Text("Who can see my last seen")
                .compoundListSectionHeader()
        }
    }

    private var onlineSection: some View {
        Section {
            ForEach(OnlineAudience.allCases, id: \.self) { audience in
                ListRow(label: .plain(title: audience.title),
                        kind: .selection(isSelected: context.viewState.privacy.online == audience) {
                            context.send(viewAction: .setOnlineAudience(audience))
                        })
            }
        } header: {
            Text("Who can see when I'm online")
                .compoundListSectionHeader()
        } footer: {
            Text("If you don't share when you were last seen or online, you won't be able to see when other people were last seen or online.")
                .compoundListSectionFooter()
        }
    }
}

/// "My contacts except...": pick who must not see the last seen. Cancel (or swiping the sheet away)
/// closes it without saving.
private struct LastSeenExceptionsPicker: View {
    @Bindable var context: LastSeenPrivacyScreenViewModel.Context

    private var excludedUserIDs: Set<String> {
        context.viewState.bindings.exceptionsPicker?.excludedUserIDs ?? []
    }

    var body: some View {
        Form {
            if let contacts = context.viewState.contacts {
                if contacts.isEmpty {
                    Section {
                        ListRow(label: .description("You don't have any chats yet. People you chat with will appear here."),
                                kind: .label)
                    }
                } else {
                    Section {
                        ForEach(contacts, id: \.userID) { contact in
                            ListRow(label: .avatar(title: contact.displayName ?? contact.userID,
                                                   description: contact.displayName != nil ? contact.userID : nil,
                                                   icon: avatar(for: contact)),
                                    kind: .multiSelection(isSelected: excludedUserIDs.contains(contact.userID)) {
                                        context.send(viewAction: .toggleException(userID: contact.userID))
                                    })
                        }
                    } header: {
                        Text("Selected contacts won't see your last seen. Everyone else you chat with will.")
                            .compoundListSectionHeader()
                    }
                }
            } else {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .compoundList()
        .navigationTitle("Hide my last seen from")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.actionCancel) {
                    context.send(viewAction: .cancelExceptions)
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    context.send(viewAction: .saveExceptions)
                }
                .disabled(context.viewState.contacts == nil)
            }
        }
    }

    private func avatar(for contact: UserProfileProxy) -> LoadableAvatarImage {
        LoadableAvatarImage(url: contact.avatarURL,
                            name: contact.displayName,
                            contentID: contact.userID,
                            avatarSize: .user(on: .startChat),
                            mediaProvider: context.mediaProvider)
    }
}

// MARK: - Previews

struct LastSeenPrivacyScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = makeViewModel()

    static var previews: some View {
        NavigationStack {
            LastSeenPrivacyScreen(context: viewModel.context)
        }
    }

    static func makeViewModel() -> LastSeenPrivacyScreenViewModel {
        let userSession = UserSessionMock(.init(clientProxy: ClientProxyMock(.init(userID: "@userid:example.com"))))
        return LastSeenPrivacyScreenViewModel(userSession: userSession,
                                              profileService: .offline,
                                              userIndicatorController: UserIndicatorControllerMock(),
                                              contactsLoader: { [.mockAlice, .mockBob] })
    }
}
