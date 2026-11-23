//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias SettingsScreenViewModelType = StateStoreViewModelV2<SettingsScreenViewState, SettingsScreenViewAction>

class SettingsScreenViewModel: SettingsScreenViewModelType, SettingsScreenViewModelProtocol {
    private let appSettings: AppSettings
    private let userID: String
    
    private var actionsSubject: PassthroughSubject<SettingsScreenViewModelAction, Never> = .init()
    
    var actions: AnyPublisher<SettingsScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(userSession: UserSessionProtocol, appSettings: AppSettings, isBugReportServiceEnabled: Bool) {
        self.appSettings = appSettings
        userID = userSession.clientProxy.userID
        
        super.init(initialViewState: .init(deviceID: userSession.clientProxy.deviceID,
                                           userID: userSession.clientProxy.userID,
                                           showLinkNewDeviceButton: appSettings.linkNewDeviceEnabled,
                                           showAccountDeactivation: userSession.clientProxy.canDeactivateAccount,
                                           showDeveloperOptions: appSettings.developerOptionsEnabled,
                                           showAnalyticsSettings: appSettings.canPromptForAnalytics,
                                           isBugReportServiceEnabled: isBugReportServiceEnabled),
                   mediaProvider: userSession.mediaProvider)
        
        appSettings.$developerOptionsEnabled
            .weakAssign(to: \.state.showDeveloperOptions, on: self)
            .store(in: &cancellables)
        
        appSettings.$linkNewDeviceEnabled
            .weakAssign(to: \.state.showLinkNewDeviceButton, on: self)
            .store(in: &cancellables)
        
        userSession.clientProxy.userAvatarURLPublisher
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.userAvatarURL, on: self)
            .store(in: &cancellables)
        
        userSession.clientProxy.userDisplayNamePublisher
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.userDisplayName, on: self)
            .store(in: &cancellables)
        
        userSession.sessionSecurityStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                
                // Clariva (Android 015e5d3504): the Encryption/recovery settings are hidden. Key
                // storage is unlocked at sign-in with a server-derived passphrase; setting up a new
                // recovery key from here would lock every other device out of the chat history.
                state.showSecuritySectionBadge = false
                state.securitySectionMode = .none
            }
            .store(in: &cancellables)
        
        userSession.clientProxy.ignoredUsersPublisher
            .receive(on: DispatchQueue.main)
            .map {
                guard let blockedUsers = $0 else {
                    return false
                }
                
                return !blockedUsers.isEmpty
            }
            .weakAssign(to: \.state.showBlockedUsers, on: self)
            .store(in: &cancellables)
        
        // Clariva (Android 165e2616fd): "Billing and Payments" is only shown to consultants.
        if let wallet = ServiceLocator.shared.wallet {
            wallet.$isCurrentUserConsultant
                .map { $0 == true }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .weakAssign(to: \.state.showBillingAndPayments, on: self)
                .store(in: &cancellables)
            
            if wallet.isCurrentUserConsultant == nil {
                let userID = userSession.clientProxy.userID
                Task { await wallet.refreshBalance(userId: userID) }
            }
            
            // Clariva (Android ee053dc156): so is "Designation", the title shown beside their name.
            wallet.$isCurrentUserConsultant
                .map { $0 == true }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .weakAssign(to: \.state.showDesignation, on: self)
                .store(in: &cancellables)
        }
        
        if let profiles = ServiceLocator.shared.clarivaProfile {
            profiles.$currentUserDesignation
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .weakAssign(to: \.state.designation, on: self)
                .store(in: &cancellables)
            
            let userID = userSession.clientProxy.userID
            Task { await profiles.refreshCurrentUser(userID: userID) }
        }
        
        Task {
            await userSession.clientProxy.loadUserAvatarURL()
            await userSession.clientProxy.loadUserDisplayName()
            await state.accountProfileURL = userSession.clientProxy.accountURL(action: .profile)
            await state.accountSessionsListURL = userSession.clientProxy.accountURL(action: .sessionsList)
        }
    }
    
    override func process(viewAction: SettingsScreenViewAction) {
        switch viewAction {
        case .close:
            actionsSubject.send(.close)
        case .userDetails:
            actionsSubject.send(.userDetails)
        case .linkNewDevice:
            actionsSubject.send(.linkNewDevice)
        case let .manageAccount(url):
            actionsSubject.send(.manageAccount(url: url))
        case .analytics:
            actionsSubject.send(.analytics)
        case .appLock:
            actionsSubject.send(.appLock)
        case .reportBug:
            actionsSubject.send(.reportBug)
        case .about:
            actionsSubject.send(.about)
        case .blockedUsers:
            actionsSubject.send(.blockedUsers)
        case .logout:
            actionsSubject.send(.logout)
        case .secureBackup:
            actionsSubject.send(.secureBackup)
        case .notifications:
            actionsSubject.send(.notifications)
        case .advancedSettings:
            actionsSubject.send(.advancedSettings)
        case .labs:
            actionsSubject.send(.labs)
        case .enableDeveloperOptions:
            appSettings.developerOptionsEnabled.toggle()
        case .developerOptions:
            actionsSubject.send(.developerOptions)
        case .deactivateAccount:
            actionsSubject.send(.deactivateAccount)
        case .myQRCode:
            actionsSubject.send(.myQRCode)
        case .billingAndPayments:
            actionsSubject.send(.billingAndPayments)
        case .lastSeenPrivacy:
            actionsSubject.send(.lastSeenPrivacy)
        case .editDesignation:
            presentDesignationEditor(text: state.designation ?? "")
        }
    }
    
    // MARK: - Clariva designation (Android `PreferencesRootView.DesignationItem`)
    
    private func presentDesignationEditor(text: String) {
        var draft = text
        let binding = Binding<String>(get: { draft }, set: { draft = $0 })
        state.bindings.alertInfo = AlertInfo(id: .editDesignation,
                                             title: "Designation",
                                             message: "Shown under your name in chats. Leave it empty to show \"\(ClarivaDesignation.defaultConsultantDesignation)\".",
                                             primaryButton: .init(title: L10n.actionCancel, role: .cancel, action: nil),
                                             secondaryButton: .init(title: "Save") { [weak self] in
                                                 self?.saveDesignation(draft)
                                             },
                                             textFields: [.init(placeholder: "e.g. Cardiologist",
                                                                text: binding,
                                                                autoCapitalization: .words,
                                                                autoCorrectionDisabled: false)])
    }
    
    private func saveDesignation(_ designation: String) {
        guard designation.trimmingCharacters(in: .whitespacesAndNewlines).count <= ClarivaDesignation.maxLength else {
            // Android keeps the dialog open with this error; an alert can't, so it reopens with the text.
            state.bindings.alertInfo = AlertInfo(id: .designationError,
                                                 title: "Designation",
                                                 message: "Use at most \(ClarivaDesignation.maxLength) characters.",
                                                 primaryButton: .init(title: L10n.actionOk) { [weak self] in
                                                     self?.presentDesignationEditor(text: designation)
                                                 })
            return
        }
        guard let profiles = ServiceLocator.shared.clarivaProfile else { return }
        
        let userIndicatorController = ServiceLocator.shared.userIndicatorController
        let indicatorID = "\(Self.self)-Designation"
        userIndicatorController?.submitIndicator(UserIndicator(id: indicatorID,
                                                               type: .modal(progress: .indeterminate, interactiveDismissDisabled: true, allowsInteraction: false),
                                                               title: L10n.commonSaving,
                                                               persistent: true))
        let userID = userID
        Task { [weak self] in
            let result = await profiles.updateDesignation(userID: userID, designation: designation)
            userIndicatorController?.retractIndicatorWithId(indicatorID)
            if case .failure = result {
                self?.state.bindings.alertInfo = AlertInfo(id: .designationError,
                                                           title: L10n.commonError,
                                                           message: "Couldn't save your designation. Please try again.")
            }
        }
    }
}
