//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import Combine
import MatrixRustSDK
import SwiftUI

typealias ScanUserQRCodeScreenViewModelType = StateStoreViewModel<ScanUserQRCodeScreenViewState, ScanUserQRCodeScreenViewAction>

/// Start chat → "Scan QR code" (Android `ScanUserQrCodePresenter`): scans another user's
/// "My QR code" (or any Matrix user link) and hands the user ID over to open their profile.
class ScanUserQRCodeScreenViewModel: ScanUserQRCodeScreenViewModelType, ScanUserQRCodeScreenViewModelProtocol {
    private let appMediator: AppMediatorProtocol

    private let actionsSubject: PassthroughSubject<ScanUserQRCodeScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<ScanUserQRCodeScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(appMediator: AppMediatorProtocol) {
        self.appMediator = appMediator

        super.init(initialViewState: ScanUserQRCodeScreenViewState())

        context.$viewState
            // Not using compactMap before removeDuplicates: after an invalid scan the result is
            // cleared so that scanning the same code again still goes through.
            .map(\.bindings.qrResult)
            .removeDuplicates()
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                self?.handleScan(data)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public

    override func process(viewAction: ScanUserQRCodeScreenViewAction) {
        switch viewAction {
        case .startScan:
            Task { await startScanIfPossible() }
        case .tryAgain:
            state.bindings.qrResult = nil
            state.scanState = .scanning
        case .grantCameraAccess:
            // iOS can't prompt again after a denial, the user has to go through the Settings app.
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                Task { await startScanIfPossible() }
            } else {
                appMediator.openAppSettings()
            }
        }
    }

    /// Resolves the text of a scanned code to a Matrix user ID: the Clariva user link first
    /// (`https://clarivahub.com/u/<mxid>`), then any Matrix permalink (matrix.to, `matrix:` URIs).
    static func userID(fromScannedText text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let userID = ClarivaUserLink.userID(from: text) {
            return userID
        }

        if let entity = parseMatrixEntityFrom(uri: text), case .user(let userID) = entity.id {
            return userID
        }

        return nil
    }

    // MARK: - Private

    private func startScanIfPossible() async {
        guard state.scanState == .initial || state.scanState == .noPermission else { return }

        state.bindings.qrResult = nil
        state.scanState = await appMediator.requestAuthorizationIfNeeded() ? .scanning : .noPermission
    }

    private func handleScan(_ data: Data) {
        // The capture delegate fires for every frame, only handle the first hit.
        guard state.scanState == .scanning else { return }

        let text = String(decoding: data, as: UTF8.self)

        guard let userID = Self.userID(fromScannedText: text) else {
            MXLog.info("Scanned a QR code that isn't a user link.")
            state.scanState = .invalid
            return
        }

        state.scanState = .scanned
        actionsSubject.send(.userScanned(userID: userID))
    }
}
