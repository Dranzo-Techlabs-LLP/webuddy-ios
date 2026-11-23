//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import GoogleSignIn
import UIKit

enum GoogleSignInResult: Equatable {
    case success(idToken: String)
    /// The user dismissed Google's sheet; callers leave the UI alone.
    case cancelled
    /// `message` is user-facing.
    case failure(String)
}

// sourcery: AutoMockable
@MainActor
protocol GoogleSignInServiceProtocol {
    /// Whether an iOS OAuth client ID is compiled into this build.
    var isConfigured: Bool { get }
    /// Shows Google's account chooser and returns an ID token whose audience is the Clariva server client.
    func requestIDToken(presenting viewController: UIViewController) async -> GoogleSignInResult
}

/// Google Sign-In for the Clariva API (`POST v1/auth/google`). Mirrors Android's `GoogleSignInLauncher`.
/// The token is verified server-side; the app never trusts it locally.
@MainActor
final class GoogleSignInService: GoogleSignInServiceProtocol {
    nonisolated static let notConfiguredMessage = "Google sign-in is not configured in this build."
    nonisolated static let genericFailureMessage = "Google sign-in failed. Please try again."
    nonisolated static let missingTokenMessage = "Google did not return an ID token."

    var isConfigured: Bool {
        ClarivaConfig.isGoogleSignInConfigured
    }

    func requestIDToken(presenting viewController: UIViewController) async -> GoogleSignInResult {
        guard isConfigured else {
            return .failure(Self.notConfiguredMessage)
        }
        // GIDSignIn raises an Objective-C exception when the reversed client ID isn't a registered
        // URL scheme, so check for it rather than crash a misconfigured build.
        guard Self.isRedirectSchemeRegistered else {
            MXLog.error("Google sign-in: the reversed iOS client ID is missing from CFBundleURLTypes.")
            return .failure(Self.notConfiguredMessage)
        }

        let signIn = GIDSignIn.sharedInstance
        signIn.configuration = GIDConfiguration(clientID: ClarivaConfig.googleIOSClientID,
                                                serverClientID: ClarivaConfig.googleServerClientID)
        // Never silently reuse a cached Google user: always show the account chooser
        // (Android parity with filterByAuthorizedAccounts = false / autoSelect = false).
        signIn.signOut()

        let presenter = Self.topMostViewController(from: viewController)

        return await withCheckedContinuation { continuation in
            signIn.signIn(withPresenting: presenter) { signInResult, error in
                if let error {
                    continuation.resume(returning: Self.result(for: error))
                    return
                }

                guard let idToken = signInResult?.user.idToken?.tokenString, !idToken.isEmpty else {
                    continuation.resume(returning: .failure(Self.missingTokenMessage))
                    return
                }

                continuation.resume(returning: .success(idToken: idToken))
            }
        }
    }

    /// Must be called early from the app's URL handling. Returns `true` when the URL was Google's redirect.
    static func handle(_ url: URL) -> Bool {
        guard ClarivaConfig.isGoogleSignInConfigured else {
            return false
        }
        return GIDSignIn.sharedInstance.handle(url)
    }

    // MARK: - Private

    nonisolated private static func result(for error: Error) -> GoogleSignInResult {
        let nsError = error as NSError
        // kGIDSignInErrorDomain / kGIDSignInErrorCodeCanceled (-5).
        if nsError.domain == "com.google.GIDSignIn", nsError.code == -5 {
            return .cancelled
        }

        MXLog.error("Google sign-in failed: \(error)")
        return .failure(genericFailureMessage)
    }

    /// `com.googleusercontent.apps.<id>` for a client ID of `<id>.apps.googleusercontent.com`.
    private static var reversedClientID: String {
        ClarivaConfig.googleIOSClientID
            .split(separator: ".")
            .reversed()
            .joined(separator: ".")
    }

    private static var isRedirectSchemeRegistered: Bool {
        guard let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
            return false
        }
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        return schemes.contains { $0.caseInsensitiveCompare(reversedClientID) == .orderedSame }
    }

    private static func topMostViewController(from viewController: UIViewController) -> UIViewController {
        var topMost = viewController
        while let presented = topMost.presentedViewController, !presented.isBeingDismissed {
            topMost = presented
        }
        return topMost
    }
}
