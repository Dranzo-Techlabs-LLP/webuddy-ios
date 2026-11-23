//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct MyQRCodeScreen: View {
    let context: MyQRCodeScreenViewModel.Context

    @Environment(\.scenePhase) private var scenePhase
    /// The brightness to restore once the code isn't shown any more.
    @State private var originalBrightness: CGFloat?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                if let qrImage = context.viewState.qrImage, let link = context.viewState.link {
                    Image(uiImage: qrImage)
                        .interpolation(.none) // to stop it getting blurred
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        // Always on white with a quiet zone so that it scans in dark mode too.
                        .padding(12)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("My QR code")

                    ShareLink(item: link) {
                        Text("Share link")
                    }
                    .buttonStyle(.compound(.primary))
                } else {
                    Text("QR code is not available.")
                        .font(.compound.bodyLG)
                        .foregroundStyle(.compound.textPrimary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
        .navigationTitle("My QR code")
        .navigationBarTitleDisplayMode(.inline)
        // Android `ForceMaxBrightness`: the screen is at full brightness while the code is shown.
        .onAppear { setMaxBrightness() }
        .onDisappear { restoreBrightness() }
        .onChange(of: scenePhase) { _, newValue in
            if newValue == .active {
                setMaxBrightness()
            } else {
                restoreBrightness()
            }
        }
    }

    // MARK: - Private

    private var header: some View {
        HStack(spacing: 12) {
            LoadableAvatarImage(url: context.viewState.avatarURL,
                                name: context.viewState.displayName,
                                contentID: context.viewState.userID,
                                avatarSize: .user(on: .settings),
                                mediaProvider: context.mediaProvider)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                if let displayName = context.viewState.displayName, !displayName.isEmpty {
                    Text(displayName)
                        .font(.compound.headingSMSemibold)
                        .foregroundStyle(.compound.textPrimary)
                    Text(context.viewState.userID)
                        .font(.compound.bodyMD)
                        .foregroundStyle(.compound.textSecondary)
                } else {
                    Text(context.viewState.userID)
                        .font(.compound.headingSMSemibold)
                        .foregroundStyle(.compound.textPrimary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func setMaxBrightness() {
        guard !ProcessInfo.isRunningTests, originalBrightness == nil else { return }
        originalBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 1.0
    }

    private func restoreBrightness() {
        guard let originalBrightness else { return }
        UIScreen.main.brightness = originalBrightness
        self.originalBrightness = nil
    }
}

// MARK: - Previews

struct MyQRCodeScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = MyQRCodeScreenViewModel(userSession: UserSessionMock(.init(clientProxy: ClientProxyMock(.init(userID: "@alice:clarivahub.com")))))

    static var previews: some View {
        NavigationStack {
            MyQRCodeScreen(context: viewModel.context)
        }
    }
}
