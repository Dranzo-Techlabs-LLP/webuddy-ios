//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct ScanUserQRCodeScreen: View {
    @ObservedObject var context: ScanUserQRCodeScreenViewModel.Context

    @Environment(\.scenePhase) private var scenePhase
    @State private var qrFrame = CGRect.zero

    var body: some View {
        FullscreenDialog(topPadding: 24) {
            VStack(spacing: 40) {
                TitleAndIcon(title: "Scan QR code",
                             icon: \.qrCode,
                             iconStyle: .default)

                scanner
            }
        } bottomContent: {
            buttons
        }
        .background()
        .backgroundStyle(.compound.bgSubtleSecondary)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Android requests the camera permission automatically, once.
            context.send(viewAction: .startScan)
        }
        .onChange(of: scenePhase) { _, newValue in
            // Coming back from the Settings app after granting access.
            if newValue == .active, context.viewState.scanState == .noPermission {
                context.send(viewAction: .startScan)
            }
        }
    }

    // MARK: - Private

    private var scanner: some View {
        scannerContent
            .aspectRatio(1.0, contentMode: .fill)
            .frame(maxWidth: 312)
            .readFrame($qrFrame)
            .background(.compound.bgCanvasDefault)
            .overlay(
                QRScannerViewOverlay(length: qrFrame.height)
            )
    }

    @ViewBuilder
    private var scannerContent: some View {
        if context.viewState.showsCamera {
            QRCodeScannerView(result: $context.qrResult,
                              isScanning: context.viewState.isScanning,
                              prefersTextPayload: true)
        } else {
            Color.clear
                .overlay {
                    if context.viewState.scanState == .noPermission {
                        Text("Camera access is required to scan a QR code.")
                            .font(.compound.bodyMD)
                            .foregroundStyle(.compound.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(16)
                    }
                }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch context.viewState.scanState {
        case .invalid:
            VStack(spacing: 16) {
                Button("Try again") {
                    context.send(viewAction: .tryAgain)
                }
                .buttonStyle(.compound(.primary))

                Text("Not a valid user QR code.")
                    .font(.compound.bodySMSemibold)
                    .foregroundStyle(.compound.textCriticalPrimary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        case .noPermission:
            Button("Grant camera access") {
                context.send(viewAction: .grantCameraAccess)
            }
            .buttonStyle(.compound(.primary))
        case .initial, .scanning, .scanned:
            // To keep the spacing consistent between states
            Button("") { }
                .buttonStyle(.compound(.primary))
                .hidden()
        }
    }
}

// MARK: - Previews

struct ScanUserQRCodeScreen_Previews: PreviewProvider, TestablePreview {
    static let noPermissionViewModel = makeViewModel(isAuthorized: false)

    static var previews: some View {
        NavigationStack {
            ScanUserQRCodeScreen(context: noPermissionViewModel.context)
        }
        .snapshotPreferences(expect: noPermissionViewModel.context.$viewState.map { $0.scanState == .noPermission })
    }

    static func makeViewModel(isAuthorized: Bool) -> ScanUserQRCodeScreenViewModel {
        let appMediator = AppMediatorMock()
        appMediator.requestAuthorizationIfNeededReturnValue = isAuthorized
        return ScanUserQRCodeScreenViewModel(appMediator: appMediator)
    }
}
