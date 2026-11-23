//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatrixRustSDK
import SwiftUI

struct ElementCallWidgetMessage: Codable {
    enum Direction: String, Codable {
        case fromWidget
        case toWidget
    }
    
    enum Action: String, Codable {
        case hangup = "im.vector.hangup"
        case close = "io.element.close"
        case mediaState = "io.element.device_mute"
    }
    
    struct Data: Codable {
        var audioEnabled: Bool?
        var videoEnabled: Bool?
        
        enum CodingKeys: String, CodingKey {
            case audioEnabled = "audio_enabled"
            case videoEnabled = "video_enabled"
        }
    }
    
    let direction: Direction
    let action: Action
    var data: Data = .init()
    
    let widgetId: String
    var requestId = "widgetapi-\(UUID())"
    
    enum CodingKeys: String, CodingKey {
        case direction = "api"
        case action
        case data
        case widgetId
        case requestId
    }
}

final class ElementCallWidgetDriver: WidgetCapabilitiesProvider, ElementCallWidgetDriverProtocol {
    private let room: RoomProtocol
    private let deviceID: String
    
    private var widgetDriver: WidgetDriverAndHandle?
    
    let widgetID = UUID().uuidString
    let messagePublisher = PassthroughSubject<String, Never>()
    
    private let actionsSubject: PassthroughSubject<ElementCallWidgetDriverAction, Never> = .init()
    var actions: AnyPublisher<ElementCallWidgetDriverAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(room: RoomProtocol, deviceID: String) {
        self.room = room
        self.deviceID = deviceID
    }
    
    func start(baseURL: URL,
               clientID: String,
               colorScheme: ColorScheme,
               rageshakeURL: String?,
               analyticsConfiguration: ElementCallAnalyticsConfiguration?,
               startWithVideoMuted: Bool) async -> Result<URL, ElementCallWidgetDriverError> {
        guard let room = room as? Room else {
            return .failure(.roomInvalid)
        }
        
        async let useEncryption = (try? room.latestEncryptionState() == .encrypted) ?? false
        let intent = await room.joinCallIntent(startWithVideoMuted: startWithVideoMuted)
        MXLog.info("Starting/joining call with intent: \(intent)")
        
        let widgetSettings: WidgetSettings
        do {
            widgetSettings = try await newVirtualElementCallWidget(props: .init(elementCallUrl: baseURL.absoluteString,
                                                                                widgetId: widgetID,
                                                                                parentUrl: nil,
                                                                                fontScale: nil,
                                                                                font: nil,
                                                                                encryption: useEncryption ? .perParticipantKeys : .unencrypted,
                                                                                posthogUserId: nil,
                                                                                posthogApiHost: analyticsConfiguration?.posthogAPIHost,
                                                                                posthogApiKey: analyticsConfiguration?.posthogAPIKey,
                                                                                rageshakeSubmitUrl: rageshakeURL,
                                                                                sentryDsn: analyticsConfiguration?.sentryDSN,
                                                                                sentryEnvironment: nil),
                                                                   config: .init(intent: intent))
        } catch {
            MXLog.error("Failed to build widget settings: \(error)")
            return .failure(.failedBuildingWidgetSettings)
        }
        
        let languageTag = "\(Locale.current.language.languageCode ?? "en")-\(Locale.current.language.region ?? "US")"
        let theme = colorScheme == .light ? "light" : "dark"
        
        let urlString: String
        do {
            urlString = try await generateWebviewUrl(widgetSettings: widgetSettings, room: room,
                                                     props: .init(clientId: clientID,
                                                                  languageTag: languageTag,
                                                                  theme: theme))
        } catch {
            MXLog.error("Failed to generate web view URL: \(error)")
            return .failure(.failedBuildingCallURL)
        }
        
        guard let url = URL(string: urlString) else {
            return .failure(.failedParsingCallURL)
        }
        
        let widgetDriver: WidgetDriverAndHandle
        do {
            widgetDriver = try makeWidgetDriver(settings: widgetSettings)
        } catch {
            MXLog.error("Failed to build widget driver: \(error)")
            return .failure(.failedBuildingWidgetDriver)
        }
        
        self.widgetDriver = widgetDriver
        
        Task.detached { [weak self, widgetDriver, messagePublisher] in
            MXLog.debug("Started message receiving loop")
            
            defer {
                MXLog.debug("Stopped message receiving loop")
            }
            
            while true {
                guard let receivedMessage = await widgetDriver.handle.recv() else {
                    return
                }
                
                messagePublisher.send(receivedMessage)
                MXLog.debug("Received message: \(receivedMessage)")
                
                self?.handleMessageIfNeeded(receivedMessage)
                self?.handleSendEventResponseIfNeeded(receivedMessage)
            }
        }
        
        Task.detached { [widgetDriver] in
            MXLog.debug("Started widget driver")
            
            defer {
                MXLog.debug("Stopped widget driver")
            }
            
            await widgetDriver.driver.run(room: room, capabilitiesProvider: self)
        }
        
        return .success(url)
    }
    
    @discardableResult
    func handleMessage(_ message: String) async -> Result<Bool, ElementCallWidgetDriverError> {
        guard let widgetDriver else {
            return .failure(.driverNotSetup)
        }
        
        let result = await widgetDriver.handle.send(msg: message)
        MXLog.debug("Sent message: \(message) with result: \(result)")
        
        handleMessageIfNeeded(message)
        
        return .success(result)
    }
    
    // MARK: - WidgetCapabilitiesProvider
    
    func acquireCapabilities(capabilities: WidgetCapabilities) -> WidgetCapabilities {
        getElementCallRequiredPermissions(ownUserId: room.ownUserId(), ownDeviceId: deviceID)
    }
    
    // MARK: - Private
    
    func handleMessageIfNeeded(_ message: String) {
        guard let data = message.data(using: .utf8) else {
            return
        }
        
        do {
            let widgetMessage = try JSONDecoder().decode(ElementCallWidgetMessage.self, from: data)
            if widgetMessage.direction == .fromWidget {
                switch widgetMessage.action {
                case .hangup:
                    break
                case .close:
                    actionsSubject.send(.callEnded)
                case .mediaState:
                    guard let audioEnabled = widgetMessage.data.audioEnabled,
                          let videoEnabled = widgetMessage.data.videoEnabled else {
                        MXLog.error("Media state change messages should contain info data")
                        return
                    }
                    
                    actionsSubject.send(.mediaStateChanged(audioEnabled: audioEnabled, videoEnabled: videoEnabled))
                }
            }
        } catch {
            // Not all actions are supported
            MXLog.verbose("Failed processing widget message with error: \(error)")
        }
    }
    
    // MARK: - Clariva: own ring event (F9)
    
    /// The event types Element Call uses for the ring sent when starting a call (MSC4075).
    private static let rtcNotificationEventTypes: Set<String> = ["m.rtc.notification", "org.matrix.msc4075.rtc.notification"]
    
    /// Element Call sends the call's ring itself, through the widget API, so the app is never handed
    /// its event ID. The SDK's reply to that `send_event` request echoes the request (including its
    /// `data.type`) and adds `response.event_id`, so capture it from there.
    ///
    /// Expected shape (verify against the `Received message:` debug logs on a device):
    /// `{"api":"fromWidget","action":"send_event","data":{"type":"org.matrix.msc4075.rtc.notification",…},"response":{"room_id":"!…","event_id":"$…"},…}`
    private func handleSendEventResponseIfNeeded(_ message: String) {
        guard message.contains("send_event"),
              let data = message.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(WidgetSendEventResponse.self, from: data),
              decoded.api == ElementCallWidgetMessage.Direction.fromWidget.rawValue,
              decoded.action == "send_event",
              let eventType = decoded.data?.type,
              Self.rtcNotificationEventTypes.contains(eventType) else {
            return
        }
        
        guard let eventID = decoded.response?.eventID else {
            MXLog.warning("Element Call's rtc notification wasn't sent: \(message)")
            return
        }
        
        MXLog.info("Element Call sent rtc notification \(eventID) (\(eventType))")
        actionsSubject.send(.rtcNotificationSent(eventID: eventID))
    }
}

/// The SDK's reply to a widget `send_event` request. Every field is optional so that unrelated
/// messages simply fail the checks above instead of throwing.
private struct WidgetSendEventResponse: Decodable {
    struct RequestData: Decodable {
        let type: String?
    }
    
    struct ResponseData: Decodable {
        let eventID: String?
        
        enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
        }
    }
    
    let api: String?
    let action: String?
    let data: RequestData?
    let response: ResponseData?
}
