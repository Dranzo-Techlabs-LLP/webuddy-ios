//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine

@MainActor
protocol RoomScreenViewModelProtocol {
    var actions: AnyPublisher<RoomScreenViewModelAction, Never> { get }
    var context: RoomScreenViewModel.Context { get }
    
    func stop()
    
    func timelineHasScrolled(direction: ScrollDirection)
    func setSelectedPinnedEventID(_ eventID: String)
    func displayMediaPreview(_ mediaPreviewViewModel: TimelineMediaPreviewViewModel)
    /// Clariva: the "Start a new session?" warning shown before a send that starts a new hold.
    /// `onContinue` is only called when the user chooses to send.
    func presentNewSessionWarning(onContinue: @escaping (_ neverRemindAgain: Bool) -> Void)
}
