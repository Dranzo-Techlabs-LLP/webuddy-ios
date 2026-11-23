//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVKit
import CallKit
import Combine
import MatrixRustSDK
import SwiftUI

typealias CallScreenViewModelType = StateStoreViewModel<CallScreenViewState, CallScreenViewAction>

class CallScreenViewModel: CallScreenViewModelType, CallScreenViewModelProtocol {
    private let elementCallService: ElementCallServiceProtocol
    private let configuration: ElementCallConfiguration
    private let isPictureInPictureAllowed: Bool
    private let appSettings: AppSettings
    private let analyticsService: AnalyticsService
    
    private let widgetDriver: ElementCallWidgetDriverProtocol
    
    private let actionsSubject: PassthroughSubject<CallScreenViewModelAction, Never> = .init()
    var actions: AnyPublisher<CallScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    @CancellableTask
    private var timeoutTask: Task<Void, Never>?
    
    /// Set once the screen has been torn down, so late widget messages don't dismiss again.
    private var isStopped = false
    
    // Clariva: default audio route by call type (F8)
    
    /// Whether the call starts with the camera on (voice calls start with it off).
    private let isVideoCall: Bool
    /// WebKit only configures the audio session for the call once it starts capturing.
    private var hasMediaCaptureStarted = false
    private var didApplyDefaultAudioRoute = false
    @CancellableTask
    private var defaultAudioRouteTask: Task<Void, Never>?
    
    // Clariva: caller auto-hangup when the DM peer declines (F9)
    
    /// The room of a 1:1 DM call, set while waiting to learn this call's ring event.
    private var declineObservationRoomProxy: JoinedRoomProxyProtocol?
    private var observedRingEventID: String?
    private var ownRingDiscoveryCancellable: AnyCancellable?
    private var declineListenerHandle: TaskHandle?
    @CancellableTask
    private var peerDeclinedHangupTask: Task<Void, Never>?
        
    /// Designated initialiser
    /// - Parameters:
    ///   - elementCallService: service responsible for setting up CallKit
    ///   - roomProxy: The room in which the call should be created
    ///   - callBaseURL: Which Element Call instance should be used
    ///   - clientID: Something to identify the current client on the Element Call side
    init(elementCallService: ElementCallServiceProtocol,
         configuration: ElementCallConfiguration,
         allowPictureInPicture: Bool,
         appHooks: AppHooks,
         appSettings: AppSettings,
         analyticsService: AnalyticsService) {
        self.elementCallService = elementCallService
        self.configuration = configuration
        self.appSettings = appSettings
        self.analyticsService = analyticsService
        isPictureInPictureAllowed = allowPictureInPicture
        isVideoCall = configuration.isVideoCall
        
        var isGenericCallLink = false
        switch configuration.kind {
        case .genericCallLink(let url):
            widgetDriver = GenericCallLinkWidgetDriver(url: url)
            isGenericCallLink = true
        case .roomCall(let roomProxy, let clientProxy, _, _, _, _, _):
            guard let deviceID = clientProxy.deviceID else { fatalError("Missing device ID for the call.") }
            widgetDriver = roomProxy.elementCallWidgetDriver(deviceID: deviceID)
        }
        
        super.init(initialViewState: CallScreenViewState(script: CallScreenJavaScriptMessageName.allCasesInjectionScript,
                                                         isGenericCallLink: isGenericCallLink,
                                                         certificateValidator: appHooks.certificateValidatorHook))
        
        elementCallService.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case let .setAudioEnabled(enabled, roomID):
                    guard roomID == configuration.callRoomID else {
                        MXLog.error("Received mute request for a different room: \(roomID) != \(configuration.callRoomID)")
                        return
                    }
                    
                    Task {
                        await self.setAudioEnabled(enabled)
                    }
                default:
                    break
                }
            }
            .store(in: &cancellables)
        
        widgetDriver.messagePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] receivedMessage in
                guard let self else { return }
                
                Task {
                    await self.postJSONToWidget(receivedMessage)
                }
            }
            .store(in: &cancellables)
        
        widgetDriver.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .callEnded:
                    guard !isStopped else {
                        MXLog.info("Ignoring call ended, the call screen is already stopped.")
                        return
                    }
                    peerDeclinedHangupTask = nil
                    actionsSubject.send(.dismiss)
                case .mediaStateChanged(let audioEnabled, _):
                    elementCallService.setAudioEnabled(audioEnabled, roomID: configuration.callRoomID)
                case .rtcNotificationSent(let eventID):
                    observeDeclines(ringEventID: eventID)
                }
            }
            .store(in: &cancellables)
        
        NotificationCenter.default
            .publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] _ in
                Task {
                    await self?.handleAudioRouteChange()
                }
            }
            .store(in: &cancellables)
        
        setupCall()
    }
    
    override func process(viewAction: CallScreenViewAction) {
        switch viewAction {
        case .urlChanged(let url):
            guard let url else { return }
            MXLog.info("URL changed to: \(url)")
        case .pictureInPictureIsAvailable(let controller):
            actionsSubject.send(.pictureInPictureIsAvailable(controller))
        case .navigateBack:
            Task { await handleBackwardsNavigation() }
        case .pictureInPictureWillStop:
            actionsSubject.send(.pictureInPictureStopped)
        case .endCall:
            actionsSubject.send(.dismiss)
        case .mediaCapturePermissionGranted:
            Task { await updateOutputsListOnWeb() }
            scheduleDefaultAudioRoute()
        case .outputDeviceSelected(deviceID: let deviceID):
            handleOutputDeviceSelected(deviceID: deviceID)
        case .widgetAction(let message):
            Task { await handleWidgetAction(message: message) }
        }
    }
    
    func stop() {
        isStopped = true
        stopObservingDeclines()
        peerDeclinedHangupTask = nil
        defaultAudioRouteTask = nil
        
        Task {
            await hangup()
        }
        
        elementCallService.tearDownCallSession()
        UIDevice.current.isProximityMonitoringEnabled = false
    }
    
    // MARK: - Private

    private func handleWidgetAction(message: String) async {
        if timeoutTask != nil,
           let decodedMessage = try? DecodedWidgetMessage.decode(message: message),
           decodedMessage.hasLoaded {
            // This means that the call room was joined succesfully, we can stop the timeout task
            timeoutTask = nil
        }
        await widgetDriver.handleMessage(message)
    }
    
    private func setupCall() {
        switch configuration.kind {
        case .genericCallLink(let url):
            state.url = url
            // We need widget messaging to work before enabling CallKit, otherwise mute, hangup etc do nothing.
            
        case .roomCall(let roomProxy, _, let clientID, let elementCallBaseURL, let elementCallBaseURLOverride, let colorScheme, let startWithVideoMuted):
            Task { [weak self] in
                guard let self else { return }
                
                // Before Element Call can send this call's ring.
                prepareDeclineObservation(roomProxy: roomProxy)
                
                let baseURL = if let elementCallBaseURLOverride {
                    elementCallBaseURLOverride
                } else {
                    elementCallBaseURL
                }
                
                // We only set the analytics configuration if analytics are enabled
                let analyticsConfiguration: ElementCallAnalyticsConfiguration? = if analyticsService.isEnabled {
                    .init(posthogAPIHost: appSettings.elementCallPosthogAPIHost,
                          posthogAPIKey: appSettings.elementCallPosthogAPIKey,
                          sentryDSN: appSettings.elementCallPosthogSentryDSN)
                } else {
                    nil
                }
                let rageshakeURL: String? = if case let .url(baseURL) = appSettings.bugReportRageshakeURL.publisher.value {
                    baseURL.absoluteString
                } else {
                    nil
                }
                
                switch await widgetDriver.start(baseURL: baseURL,
                                                clientID: clientID,
                                                colorScheme: colorScheme,
                                                rageshakeURL: rageshakeURL,
                                                analyticsConfiguration: analyticsConfiguration,
                                                startWithVideoMuted: startWithVideoMuted) {
                case .success(let url):
                    state.url = url
                case .failure(let error):
                    MXLog.error("Failed starting ElementCall Widget Driver with error: \(error)")
                    state.bindings.alertInfo = .init(id: UUID(),
                                                     title: L10n.errorUnknown,
                                                     primaryButton: .init(title: L10n.actionOk) {
                                                         self.actionsSubject.send(.dismiss)
                                                     })
                    return
                }
                
                await elementCallService.setupCallSession(roomID: roomProxy.id,
                                                          roomDisplayName: roomProxy.infoPublisher.value.displayName ?? roomProxy.id)
            }
            
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                MXLog.error("Failed to join Element Call: Timeout")
                state.bindings.alertInfo = .init(id: UUID(),
                                                 title: L10n.commonError,
                                                 message: L10n.errorUnknown,
                                                 primaryButton: .init(title: L10n.actionDismiss) { [weak self] in self?.actionsSubject.send(.dismiss) })
                timeoutTask = nil
            }
        }
    }
    
    // This should always match the web app value
    private static let earpieceID = "earpiece-id"
    
    private func handleOutputDeviceSelected(deviceID: String) {
        let isEarpiece = deviceID == Self.earpieceID
        MXLog.info("Is earpiece: \(isEarpiece)")
        UIDevice.current.isProximityMonitoringEnabled = isEarpiece
    }
    
    private func handleBackwardsNavigation() async {
        guard state.url != nil,
              isPictureInPictureAllowed,
              let requestPictureInPictureHandler = state.bindings.requestPictureInPictureHandler else {
            actionsSubject.send(.dismiss)
            return
        }
        
        switch await requestPictureInPictureHandler() {
        case .success:
            actionsSubject.send(.pictureInPictureStarted)
        case .failure:
            actionsSubject.send(.dismiss)
        }
    }
    
    private func setAudioEnabled(_ enabled: Bool) async {
        let message = ElementCallWidgetMessage(direction: .toWidget,
                                               action: .mediaState,
                                               data: .init(audioEnabled: enabled),
                                               widgetId: widgetDriver.widgetID)
        await postMessageToWidget(message)
    }
    
    /// Asks Element Call to hang up. This must be a `toWidget` request: the injected listener
    /// forwards `fromWidget` requests to the SDK's widget driver, so they never reach Element Call
    /// (Android `CallScreenPresenter.sendHangupMessage` parity). Element Call then leaves the
    /// MatrixRTC session and replies with `io.element.close` (→ `.callEnded`).
    func hangup() async {
        let message = ElementCallWidgetMessage(direction: .toWidget,
                                               action: .hangup,
                                               widgetId: widgetDriver.widgetID)
        
        await postMessageToWidget(message)
    }
    
    private func postMessageToWidget(_ message: ElementCallWidgetMessage) async {
        let data: Data
        do {
            data = try JSONEncoder().encode(message)
        } catch {
            MXLog.error("Failed encoding widget message with error: \(error)")
            return
        }
        
        guard let json = String(data: data, encoding: .utf8) else {
            MXLog.error("Invalid data for widget message")
            return
        }
        
        await postJSONToWidget(json)
    }
    
    private func postJSONToWidget(_ json: String) async {
        do {
            let message = "postMessage(\(json), '*')"
            let result = try await state.bindings.javaScriptEvaluator?(message)
            MXLog.debug("Evaluated javascript: \(json) with result: \(String(describing: result))")
        } catch {
            MXLog.error("Received javascript evaluation error: \(error)")
        }
    }
    
    /// This function updates the list of available audio outputs on the web side
    /// however since we actually handle switching the audio output through the OS,
    /// this is only used to inform the webview when the speaker is selected,
    /// so that the option to use the earpiece can be displayed.
    private func updateOutputsListOnWeb() async {
        guard let currentOutput = AVAudioSession.sharedInstance().currentRoute.outputs.first else {
            return
        }
        
        let deviceList = if currentOutput.portType == .builtInSpeaker {
            // This allows the webview to display the earpiece option
            "{id: '\(currentOutput.uid)', name: '\(currentOutput.portName)', forEarpiece: true, isSpeaker: true}"
        } else {
            // Doesn't matter because the switch is handled through the OS
            "{id: 'dummy', name: 'dummy'}"
        }
        
        let javaScript = "window.controls.setAvailableOutputDevices([\(deviceList)])"
        do {
            let result = try await state.bindings.javaScriptEvaluator?(javaScript)
            MXLog.debug("Evaluated  with result: \(String(describing: result))")
        } catch {
            MXLog.error("Received javascript evaluation error: \(error)")
        }
    }
    
    // MARK: - Clariva: default audio route by call type (F8)
    
    private func handleAudioRouteChange() async {
        if hasMediaCaptureStarted {
            applyDefaultAudioRouteIfNeeded()
        }
        
        await updateOutputsListOnWeb()
    }
    
    /// Media capture was granted, so WebKit is about to configure the audio session for the call.
    /// Apply the default route on the next route change, or shortly after if none comes.
    private func scheduleDefaultAudioRoute() {
        guard !hasMediaCaptureStarted else { return }
        hasMediaCaptureStarted = true
        
        defaultAudioRouteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, !didApplyDefaultAudioRoute else { return }
            
            applyDefaultAudioRouteIfNeeded()
            await updateOutputsListOnWeb()
        }
    }
    
    /// Android `ccbfee0f5c` D2: a voice call defaults to the earpiece and a video call to the
    /// loudspeaker. Applied once, so that manual changes (Element Call's menu, the route picker)
    /// stick, and never over a connected Bluetooth, wired, USB or car device.
    ///
    /// TODO(device-test): WebKit owns the AVAudioSession during WebRTC calls. On a real device check
    /// that the override sticks for voice and video, that capture isn't interrupted by the voice
    /// fallback below (mode/option change), and that external devices keep precedence.
    private func applyDefaultAudioRouteIfNeeded() {
        // Never touch the session (or re-enable proximity monitoring) once the call has ended.
        guard !didApplyDefaultAudioRoute, !isStopped else { return }
        
        let session = AVAudioSession.sharedInstance()
        // Until WebKit has configured the session for the call, it would reset our override.
        guard session.category == .playAndRecord else {
            MXLog.info("Audio session not configured for the call yet (\(session.category.rawValue)), not applying the default route.")
            return
        }
        
        didApplyDefaultAudioRoute = true
        
        let externalOutputs: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .headphones, .usbAudio, .carAudio, .airPlay, .lineOut, .HDMI]
        let outputs = session.currentRoute.outputs
        if outputs.contains(where: { externalOutputs.contains($0.portType) }) {
            MXLog.info("Keeping the external audio route: \(outputs.map(\.portType.rawValue))")
            return
        }
        
        do {
            if isVideoCall {
                MXLog.info("Video call, defaulting the audio route to the loudspeaker.")
                try session.overrideOutputAudioPort(.speaker)
            } else {
                MXLog.info("Voice call, defaulting the audio route to the earpiece.")
                try session.overrideOutputAudioPort(.none)
                
                if session.currentRoute.outputs.first?.portType == .builtInSpeaker {
                    // WebKit may use the `.videoChat` mode and/or the `.defaultToSpeaker` option,
                    // both of which make the loudspeaker the default playAndRecord route.
                    var options = session.categoryOptions
                    options.remove(.defaultToSpeaker)
                    try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
                }
                
                UIDevice.current.isProximityMonitoringEnabled = session.currentRoute.outputs.first?.portType == .builtInReceiver
            }
        } catch {
            MXLog.error("Failed applying the default audio route with error: \(error)")
        }
    }
    
    // MARK: - Clariva: caller auto-hangup when the DM peer declines (F9)
    
    /// Element Call leaves the caller in "Waiting for media…" after the callee declines, which also
    /// keeps the room's call ongoing so both sides keep seeing Join. In a 1:1 DM (a group call must
    /// survive a decline), watch for the peer's decline of this call's ring and hang up.
    private func prepareDeclineObservation(roomProxy: JoinedRoomProxyProtocol) {
        guard roomProxy.isDirectOneToOneRoom else { return }
        
        declineObservationRoomProxy = roomProxy
        
        // Joining an ongoing call doesn't ring, so only a call we start needs the fallback.
        guard !roomProxy.infoPublisher.value.hasRoomCall else { return }
        
        Task { [weak self] in
            await self?.discoverOwnRingFromTimeline(roomProxy: roomProxy)
        }
    }
    
    /// Fallback for `ElementCallWidgetDriverAction.rtcNotificationSent`, using Android's algorithm:
    /// snapshot the own rings already in the live timeline, then take the first new own ring as this
    /// call's. Someone joining an existing call never authors a ring, so this never fires for them.
    private func discoverOwnRingFromTimeline(roomProxy: JoinedRoomProxyProtocol) async {
        // The live timeline's item provider only exists once the room is subscribed for updates.
        // The room screen has normally already done it, which makes this a no-op.
        await roomProxy.subscribeForUpdates()
        
        guard !isStopped, observedRingEventID == nil else { return }
        
        // Guards against older rings showing up when the timeline only loads after the baseline.
        let oldestAcceptedRingDate = Date.now.addingTimeInterval(-60)
        var baseline: Set<String>?
        
        ownRingDiscoveryCancellable = roomProxy.timeline.timelineItemProvider.updatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items, _ in
                let ownRings = CallScreenViewModel.ownRings(in: items)
                
                guard let knownRingIDs = baseline else {
                    baseline = Set(ownRings.map(\.eventID))
                    return
                }
                
                guard let newRing = ownRings.first(where: { !knownRingIDs.contains($0.eventID) && $0.date > oldestAcceptedRingDate }) else {
                    return
                }
                
                MXLog.info("Found this call's rtc notification in the timeline: \(newRing.eventID)")
                self?.observeDeclines(ringEventID: newRing.eventID)
            }
    }
    
    private func observeDeclines(ringEventID: String) {
        guard !isStopped, let roomProxy = declineObservationRoomProxy else { return }
        
        guard observedRingEventID == nil else {
            if observedRingEventID != ringEventID {
                MXLog.warning("Already observing declines for \(observedRingEventID ?? "nil"), ignoring \(ringEventID)")
            }
            return
        }
        
        observedRingEventID = ringEventID
        ownRingDiscoveryCancellable = nil
        
        let ownUserID = roomProxy.ownUserID
        let listener = SDKListener<String> { [weak self] declinerID in
            // Ignore our own declines (e.g. from another of our sessions), only the peer's count.
            guard declinerID != ownUserID else {
                MXLog.info("Ignoring own decline of the call.")
                return
            }
            
            Task { @MainActor in
                self?.hangUpAfterPeerDeclined(declinerID: declinerID)
            }
        }
        
        switch roomProxy.subscribeToCallDeclineEvents(rtcNotificationEventID: ringEventID, listener: listener) {
        case .success(let handle):
            MXLog.info("Observing declines of rtc notification \(ringEventID)")
            declineListenerHandle = handle
        case .failure(let error):
            MXLog.error("Failed observing declines of rtc notification \(ringEventID) with error: \(error)")
        }
    }
    
    /// Hangs up through Element Call so that it leaves the MatrixRTC session (clearing Join on both
    /// sides), then dismisses the screen if Element Call hasn't closed itself within 2 seconds.
    private func hangUpAfterPeerDeclined(declinerID: String) {
        guard !isStopped, peerDeclinedHangupTask == nil else { return }
        
        MXLog.info("The call was declined by \(declinerID), hanging up.")
        stopObservingDeclines()
        
        peerDeclinedHangupTask = Task { [weak self] in
            await self?.hangup()
            
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, !isStopped else { return }
            
            MXLog.info("Element Call didn't close after the hangup, dismissing the call screen.")
            actionsSubject.send(.dismiss)
        }
    }
    
    private func stopObservingDeclines() {
        ownRingDiscoveryCancellable = nil
        declineListenerHandle?.cancel()
        declineListenerHandle = nil
    }
    
    private struct OwnRing {
        let eventID: String
        let date: Date
    }
    
    private nonisolated static func ownRings(in items: [TimelineItemProxy]) -> [OwnRing] {
        items.compactMap { itemProxy -> OwnRing? in
            guard case let .event(eventItemProxy) = itemProxy,
                  eventItemProxy.item.isOwn,
                  case .rtcNotification = eventItemProxy.item.content,
                  case let .eventId(eventID) = eventItemProxy.item.eventOrTransactionId else {
                return nil
            }
            
            return OwnRing(eventID: eventID, date: Date(timeIntervalSince1970: TimeInterval(eventItemProxy.item.timestamp) / 1000))
        }
    }
}
