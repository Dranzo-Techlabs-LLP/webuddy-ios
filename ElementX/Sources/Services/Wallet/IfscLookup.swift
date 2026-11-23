//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// The bank branch an IFSC belongs to; `branch` and `city` are title-cased for display.
struct IfscBranch: Equatable {
    let bank: String
    let branch: String
    let city: String?

    /// e.g. "State Bank of India · Hajiganj, Patna".
    var summary: String {
        let place = [branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : branch, city]
            .compactMap { $0 }
            .joined(separator: ", ")
        return "\(bank) · \(place)"
    }
}

/// What the payout forms know about the IFSC being typed. Mirrors Android `IfscStatus`.
enum IfscStatus: Equatable {
    /// Empty or not yet a well-formed code: nothing to look up.
    case none
    case checking
    case found(IfscBranch)
    /// Well-formed, but no such branch: blocks saving.
    case notFound
    /// The directory could not be reached; saving is allowed and the API checks again.
    case unavailable

    /// Wrong, or still being checked: hold off saving. An unreachable directory does not block.
    var blocksSave: Bool {
        switch self {
        case .notFound, .checking:
            true
        case .none, .found, .unavailable:
            false
        }
    }

    /// Shown under the IFSC field (after any format error).
    var message: String? {
        switch self {
        case .none:
            nil
        case .checking:
            "Checking IFSC…"
        case .found(let branch):
            branch.summary
        case .notFound:
            "No bank branch found for this IFSC. Please check the code."
        case .unavailable:
            "Couldn't verify this IFSC right now. It will be checked when you save."
        }
    }
}

@MainActor
protocol IfscLookupProtocol {
    func lookup(_ rawIFSC: String) async -> IfscStatus
}

/// Looks IFSCs up while a consultant types them, so a mistyped code is caught before it becomes a
/// failed payout, and the bank and branch fill themselves in. Uses Razorpay's public IFSC directory:
/// 200 with the branch, or 404 for a code that does not exist. Mirrors Android `IfscLookup`.
@MainActor
final class IfscLookup: IfscLookupProtocol {
    /// App-wide, like Android's `@SingleIn(AppScope)`, so the cache is shared by every form.
    static let shared = IfscLookup()

    nonisolated static let baseURL: URL = "https://ifsc.razorpay.com/"
    /// Long enough that pasting or fast typing triggers one lookup, not one per key.
    nonisolated static let debounce: Duration = .milliseconds(300)

    private enum Answer {
        case found(IfscBranch)
        case notFound
    }

    private let baseURL: URL
    private let session: URLSession
    private let timeout: TimeInterval
    /// Only definite answers are cached; an unreachable directory is retried.
    private var cache: [String: Answer] = [:]

    init(baseURL: URL = IfscLookup.baseURL, session: URLSession = .shared, timeout: TimeInterval = ClarivaConfig.requestTimeout) {
        self.baseURL = baseURL
        self.session = session
        self.timeout = timeout
    }

    func lookup(_ rawIFSC: String) async -> IfscStatus {
        let ifsc = BankAccountRules.normalizedIFSC(rawIFSC)
        guard BankAccountRules.isValidIFSC(ifsc) else { return .none }

        switch cache[ifsc] {
        case .found(let branch):
            return .found(branch)
        case .notFound:
            return .notFound
        case .none:
            break
        }

        // A well-formed IFSC is [A-Z0-9] only, so it is safe as a path segment.
        var request = URLRequest(url: baseURL.appendingPathComponent(ifsc), timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            MXLog.warning("IFSC lookup unavailable: \(error)")
            return .unavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return .unavailable
        }
        if httpResponse.statusCode == 404 {
            cache[ifsc] = .notFound
            return .notFound
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            MXLog.warning("IFSC lookup failed with HTTP \(httpResponse.statusCode)")
            return .unavailable
        }
        guard let branch = Self.branch(from: data) else {
            return .unavailable
        }
        cache[ifsc] = .found(branch)
        return .found(branch)
    }

    // MARK: - Parsing

    private struct Response: Decodable {
        let bank: String?
        let branch: String?
        let city: String?

        enum CodingKeys: String, CodingKey {
            case bank = "BANK"
            case branch = "BRANCH"
            case city = "CITY"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            bank = try? container.decodeIfPresent(String.self, forKey: .bank)
            branch = try? container.decodeIfPresent(String.self, forKey: .branch)
            city = try? container.decodeIfPresent(String.self, forKey: .city)
        }
    }

    /// nil when the payload has no bank (treated as "unavailable", never as "not found").
    nonisolated static func branch(from data: Data) -> IfscBranch? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let bank = response.bank,
              !bank.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let city = response.city.map(titleCase)
        return IfscBranch(bank: bank,
                          branch: titleCase(response.branch ?? ""),
                          city: city?.isEmpty == false ? city : nil)
    }

    /// Android `titleCase`: lower-case, then upper-case the first letter of every space-separated word.
    nonisolated static func titleCase(_ value: String) -> String {
        value.lowercased()
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { word in word.prefix(1).uppercased() + word.dropFirst() }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
