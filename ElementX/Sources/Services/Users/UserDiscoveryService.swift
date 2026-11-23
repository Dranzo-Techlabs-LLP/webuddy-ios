//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

final class UserDiscoveryService: UserDiscoveryServiceProtocol {
    private let clientProxy: ClientProxyProtocol
    
    init(clientProxy: ClientProxyProtocol) {
        self.clientProxy = clientProxy
    }

    func searchProfiles(with searchQuery: String) async -> Result<[UserProfileProxy], UserDiscoveryErrorType> {
        // Clariva (Android ccbfee0f5c): every step uses the trimmed query.
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        
        async let queriedProfile = profileIfPossible(with: query)
        async let derivedProfile = derivedProfileIfPossible(with: query)

        do {
            async let searchedUsers = clientProxy.searchUsers(searchTerm: query, limit: 10).get()
            let users = try await merge(queriedProfile: queriedProfile,
                                        derivedProfile: derivedProfile,
                                        searchResults: searchedUsers)
            return .success(filterAccountOwner(users))
        } catch {
            // we want to show the profile (if any) even if the search fails
            let queried = await queriedProfile
            let derived = await derivedProfile
            let fallbackProfiles = [queried, derived].compactMap { $0 }
            if !fallbackProfiles.isEmpty {
                return .success(filterAccountOwner(removingDuplicates(fallbackProfiles)))
            } else {
                return .failure(.failedSearchingUsers)
            }
        }
    }

    private func merge(queriedProfile: UserProfileProxy?,
                       derivedProfile: UserProfileProxy?,
                       searchResults: SearchUsersResultsProxy) -> [UserProfileProxy] {
        var results = searchResults.results
        
        // The derived `@localpart:<own server>` match goes on top, but only if the directory
        // search didn't already return it.
        if let derivedProfile, !results.contains(where: { $0.userID == derivedProfile.userID }) {
            results.insert(derivedProfile, at: 0)
        }
        
        guard let queriedProfile else {
            return results
        }

        let filteredSearchResult = results.filter {
            $0.userID != queriedProfile.userID
        }

        return [queriedProfile] + filteredSearchResult
    }
    
    private func removingDuplicates(_ profiles: [UserProfileProxy]) -> [UserProfileProxy] {
        var seenUserIDs = Set<String>()
        return profiles.filter { seenUserIDs.insert($0.userID).inserted }
    }
    
    private func profileIfPossible(with searchQuery: String) async -> UserProfileProxy? {
        guard searchQuery.isMatrixIdentifier, searchQuery != clientProxy.userID else {
            return nil
        }
        
        let getProfileResult = try? await clientProxy.profile(for: searchQuery).get()
        
        // fallback to a "local profile" if the profile api fails
        return getProfileResult ?? .init(userID: searchQuery)
    }
    
    /// Clariva (Android ccbfee0f5c): a bare username such as `mohamed.shimil4` is resolved to
    /// `@mohamed.shimil4:<own server>`. Unlike a full Matrix ID there is no placeholder fallback:
    /// the row is only shown when the profile actually resolves, so free-text searches never get
    /// phantom users.
    private func derivedProfileIfPossible(with query: String) async -> UserProfileProxy? {
        guard query.count >= 3,
              !query.isMatrixIdentifier,
              query.range(of: Self.localpartPattern, options: .regularExpression) != nil,
              let domain = ownServerName,
              !domain.isEmpty else {
            return nil
        }
        
        let candidate = "@\(query.lowercased()):\(domain)"
        guard candidate.isMatrixIdentifier, candidate != clientProxy.userID else {
            return nil
        }
        
        return try? await clientProxy.profile(for: candidate).get()
    }
    
    /// Same character set as Android's `LOCALPART_REGEX`.
    private static let localpartPattern = "^[a-zA-Z0-9._=/+-]+$"
    
    /// Taken from the session, never hard-coded.
    private var ownServerName: String? {
        if let serverName = clientProxy.userIDServerName, !serverName.isEmpty {
            return serverName
        }
        
        let components = clientProxy.userID.split(separator: ":", maxSplits: 1)
        return components.count == 2 ? String(components[1]) : nil
    }

    private func filterAccountOwner(_ profiles: [UserProfileProxy]) -> [UserProfileProxy] {
        let accountOwnerID = clientProxy.userID
        return profiles.filter { $0.userID != accountOwnerID }
    }
}

private extension String {
    var isMatrixIdentifier: Bool {
        MatrixEntityRegex.isMatrixUserIdentifier(self)
    }
}
