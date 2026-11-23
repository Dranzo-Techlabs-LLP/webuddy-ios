//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

/// Bills a DM call like a message — the same idempotent 24 h `(client, consultant)` hold — but only
/// once the other party actually joins the RTC session within the billing window. An unanswered or
/// rung-out call costs nothing. Mirrors Android `MessagesFlowNode.chargeForCallWhenAnswered`
/// (2c94374a07 → 165e2616fd).
///
/// App-lifetime: the call screen (and PiP) outlives the room screen that armed the watcher.
/// Armed from `RoomScreenViewModel` for every call started or joined from the chat screen; never
/// from the CallKit answer path, matching Android.
@MainActor
final class CallBillingWatcher {
    static let shared = CallBillingWatcher()

    private static let billingWindow: DispatchQueue.SchedulerTimeType.Stride = .seconds(120)

    private struct Watch {
        let id: UUID
        let task: Task<Void, Never>
    }

    /// One watch per room; re-arming (e.g. tapping Join again) restarts the window.
    private var watches: [String: Watch] = [:]

    private init() { }

    func arm(roomProxy: JoinedRoomProxyProtocol) {
        let wallet: WalletService? = ServiceLocator.shared.wallet
        guard let wallet else { return }

        // Non-DM rooms never bill. Consultants never initiate holds (WalletService no-ops anyway).
        guard wallet.isCurrentUserConsultant != true,
              let partnerID = roomProxy.walletPartnerUserID else {
            return
        }

        let roomID = roomProxy.id
        let ownUserID = roomProxy.ownUserID

        // Keep room info flowing even if the room screen goes away while the call is up.
        roomProxy.subscribeToRoomInfoUpdates()

        watches[roomID]?.task.cancel()

        let watchID = UUID()
        let task = Task { [weak self] in
            // `first(where:)` sits before `timeout` so the window is measured from arming, not reset
            // by unrelated room info updates. On timeout the publisher just finishes.
            let answeredPublisher = roomProxy.infoPublisher
                .first { $0.activeRoomCallParticipants.contains(partnerID) }
                .map { _ in true }
                .timeout(Self.billingWindow, scheduler: DispatchQueue.main)

            var answered = false
            for await value in answeredPublisher.values {
                answered = value
                break
            }

            defer { self?.removeWatch(roomID: roomID, watchID: watchID) }

            guard !Task.isCancelled else { return }

            guard answered else {
                MXLog.info("[Wallet] Call to \(partnerID) was not answered within the billing window; not charging")
                return
            }

            MXLog.info("[Wallet] Call to \(partnerID) was answered; initiating hold")
            let didInitiateHold = await wallet.initiateHold(clientId: ownUserID, consultantId: partnerID)
            if !didInitiateHold {
                MXLog.warning("[Wallet] Failed to initiate hold for the call to \(partnerID)")
            }
            await wallet.refreshBalance(userId: ownUserID)
        }

        watches[roomID] = Watch(id: watchID, task: task)
    }

    private func removeWatch(roomID: String, watchID: UUID) {
        guard watches[roomID]?.id == watchID else { return }
        watches[roomID] = nil
    }
}
