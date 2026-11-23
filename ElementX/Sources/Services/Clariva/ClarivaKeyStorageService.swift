//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Gives a freshly signed-in device access to the account's key backup, with no user action.
/// Mirrors Android's `ClarivaAuthPresenter.unlockKeyStorage`.
///
/// Clariva users never verify devices, so without this every message sent before the device
/// existed would stay undecryptable. The backend derives a stable per-account passphrase
/// (`recoveryPassphrase` from `v1/auth/matrix-session`):
/// - the first device creates secret storage + key backup locked with it;
/// - later devices `recover` with it, which yields the backup key **and** the cross-signing keys,
///   so the device self-signs and the "unverified" shields disappear.
///
/// PRIVACY: the server knows this passphrase, so it can decrypt backed-up history. That is the
/// accepted cost of "history on any device, no prompts".
///
/// Never fatal and never awaited by the UI: a failure only means no history access on this device.
/// The passphrase is kept in `ClarivaRecoveryPassphraseStore` until `unlock` reports `.finished`, so
/// an interrupted unlock (crash, kill, offline, slow first sync) resumes on the next launch.
enum ClarivaKeyStorageService {
    enum UnlockOutcome: Equatable {
        /// Key storage is unlocked, or can never be unlocked with this passphrase: forget it.
        case finished
        /// Transient problem: keep the passphrase and try again on the next launch.
        case retryLater
    }
    
    /// How long to wait for the SDK to report a settled recovery state (it stays `.unknown`
    /// until the first sync). Bounded so a slow/offline first sync doesn't hang around forever;
    /// unlocking is retried on the next sign-in.
    static let recoveryStateTimeout: Duration = .seconds(20)

    @discardableResult
    static func unlock(secureBackupController: SecureBackupControllerProtocol,
                       passphrase: String?,
                       timeout: Duration = ClarivaKeyStorageService.recoveryStateTimeout) async -> UnlockOutcome {
        guard let passphrase, !passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            MXLog.warning("No recovery passphrase from the API; history will be unavailable on this device")
            return .finished
        }

        // Recovery must not be touched while the SDK is still working out what state it is in,
        // or enable/recover would race the initial sync.
        guard let state = await settledRecoveryState(secureBackupController.recoveryState, timeout: timeout) else {
            MXLog.warning("Recovery state still settling; key storage unlock will be retried on the next launch")
            return .retryLater
        }

        switch state {
        case .disabled:
            // First device for this account: create secret storage locked with the server passphrase.
            MXLog.info("Setting up key storage for the first time")
            switch await secureBackupController.enableRecovery(passphrase: passphrase) {
            case .success:
                break
            case .failure(.backupExistsOnServer):
                // An ORPHANED backup created before key storage existed (e.g. auto-enabled backups).
                // Its key isn't in secret storage so no other device can read it, and the SDK refuses
                // to overwrite it. Safe to replace: this branch only runs while secret storage doesn't
                // exist, and any device still holding room keys re-uploads them to the new backup.
                MXLog.warning("Replacing an orphaned key backup that predates key storage")
                guard case .success = await secureBackupController.disable() else {
                    MXLog.warning("Could not unlock key storage (failed removing the orphaned backup); will retry on the next launch")
                    return .retryLater
                }
                guard case .success = await secureBackupController.enableRecovery(passphrase: passphrase) else {
                    MXLog.warning("Could not unlock key storage (failed enabling recovery after replacing the backup); will retry on the next launch")
                    return .retryLater
                }
            case .failure(let error):
                MXLog.warning("Could not unlock key storage (\(error)); will retry on the next launch")
                return .retryLater
            }
        case .enabled, .incomplete:
            // Secret storage already exists - unlock it to obtain the backup and cross-signing keys.
            MXLog.info("Unlocking existing key storage")
            switch await secureBackupController.recover(passphrase: passphrase) {
            case .success:
                break
            case .failure(.secretStorageNotOpenable):
                // Created WITHOUT a passphrase (only the upstream "Set up recovery" screen does this).
                // This device can neither open nor reset it; it has to be cleared server-side.
                MXLog.warning("Key storage was created without a passphrase and cannot be opened or reset from this device; history stays unavailable until it is cleared server-side")
                return .finished
            case .failure(let error):
                MXLog.warning("Could not unlock key storage (\(error)); will retry on the next launch")
                return .retryLater
            }
        case .unknown, .settingUp:
            MXLog.info("Key storage in state \(state); will retry on the next launch")
            return .retryLater
        }

        MXLog.info("Key storage ready; historical messages should be available")
        return .finished
    }

    // MARK: - Private

    /// The first recovery state that isn't `.unknown`/`.settingUp`, or nil after `timeout`.
    private static func settledRecoveryState(_ recoveryState: CurrentValuePublisher<SecureBackupRecoveryState, Never>,
                                             timeout: Duration) async -> SecureBackupRecoveryState? {
        if ClarivaKeyStorageService.isSettled(recoveryState.value) {
            return recoveryState.value
        }

        return await withTaskGroup(of: SecureBackupRecoveryState?.self) { group in
            group.addTask {
                for await state in recoveryState.values where ClarivaKeyStorageService.isSettled(state) {
                    return state
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func isSettled(_ state: SecureBackupRecoveryState) -> Bool {
        switch state {
        case .unknown, .settingUp:
            false
        case .disabled, .enabled, .incomplete:
            true
        }
    }
}
