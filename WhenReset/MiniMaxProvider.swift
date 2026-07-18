import CryptoKit
import Foundation

enum MiniMaxProviderError: LocalizedError {
    case invalidAPIKey
    case invalidResponse
    case noResettableQuota
    case authorizationFailed
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            "Enter a valid MiniMax Token Plan Subscription Key."
        case .invalidResponse:
            "MiniMax returned unreadable Token Plan quota data."
        case .noResettableQuota:
            "MiniMax did not report a resettable coding quota for this key."
        case .authorizationFailed:
            "MiniMax rejected this key. Check that it is a Subscription Key for an active Token Plan."
        case let .server(code, message):
            "MiniMax request failed (HTTP \(code)): \(message)"
        }
    }
}

struct MiniMaxProvider {
    static let quotaURLs = [
        URL(string: "https://www.minimax.io/v1/token_plan/remains")!,
        URL(string: "https://www.minimaxi.com/v1/token_plan/remains")!,
    ]

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func link(apiKey rawAPIKey: String) async throws -> LinkedIdentity {
        let apiKey = rawAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiKey.count >= 8, !apiKey.contains(where: { $0.isWhitespace }) else {
            throw MiniMaxProviderError.invalidAPIKey
        }

        let account = MonitoredAccount(
            id: UUID(),
            providerID: .miniMax,
            displayName: "MiniMax account",
            workspaceID: "pending",
            plan: nil,
            addedAt: .now
        )
        let snapshot = try await snapshot(account: account, apiKey: apiKey)
        let digest = SHA256.hash(data: Data(apiKey.utf8))
        let fingerprint = digest.prefix(8).map { String(format: "%02x", $0) }.joined()

        return LinkedIdentity(
            workspaceID: "minimax-\(fingerprint)",
            displayName: "MiniMax account",
            plan: snapshot.plan ?? "Token Plan",
            credentials: AccountCredentials(
                accessToken: apiKey,
                refreshToken: "",
                idToken: "",
                expiresAt: nil
            )
        )
    }

    func fetchUsage(account: MonitoredAccount, credentials: AccountCredentials) async throws -> UsageSnapshot {
        try await snapshot(account: account, apiKey: credentials.accessToken)
    }

    static func parseUsage(account: MonitoredAccount, data: Data, now: Date = .now) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MiniMaxProviderError.invalidResponse
        }
        let payload = dictionary(root["data"]) ?? root
        try validateEnvelope(root: root, payload: payload)

        guard let rawModels = dictionaries(payload["model_remains"] ?? payload["modelRemains"]),
              !rawModels.isEmpty else {
            throw MiniMaxProviderError.invalidResponse
        }

        let candidates = rawModels
            .filter(isCodingModel)
            .sorted { modelPriority($0) < modelPriority($1) }

        var primary: UsageWindow?
        var secondary: UsageWindow?
        var selectedModel: [String: Any]?

        for model in candidates {
            if let window = quotaWindow(model, weekly: false, now: now) {
                primary = window
                selectedModel = model
                break
            }
        }

        if let selectedModel {
            secondary = quotaWindow(selectedModel, weekly: true, now: now)
        }
        if secondary == nil {
            for model in candidates {
                if let window = quotaWindow(model, weekly: true, now: now) {
                    secondary = window
                    break
                }
            }
        }

        guard primary != nil || secondary != nil else {
            throw MiniMaxProviderError.noResettableQuota
        }

        let plan = firstString(
            payload,
            keys: ["current_subscribe_title", "plan_name", "combo_title", "current_plan_title"]
        ) ?? firstString(root, keys: ["current_subscribe_title", "plan_name", "combo_title"])
            ?? account.plan
            ?? "Token Plan"

        return UsageSnapshot(
            accountID: account.id,
            providerName: "MiniMax Token Plan",
            accountName: account.displayName,
            plan: plan,
            primary: primary,
            secondary: secondary,
            availableResetCount: 0,
            resetCredits: [],
            fetchedAt: now
        )
    }

    private func snapshot(account: MonitoredAccount, apiKey: String) async throws -> UsageSnapshot {
        var mostRecentRetryableError: Error?

        for url in Self.quotaURLs {
            do {
                let data = try await quotaData(apiKey: apiKey, url: url)
                do {
                    return try Self.parseUsage(account: account, data: data)
                } catch let error as MiniMaxProviderError {
                    switch error {
                    case .authorizationFailed, .invalidResponse:
                        mostRecentRetryableError = error
                        continue
                    case .invalidAPIKey, .noResettableQuota, .server:
                        throw error
                    }
                }
            } catch let error as MiniMaxProviderError {
                switch error {
                case .authorizationFailed:
                    mostRecentRetryableError = error
                    continue
                case let .server(code, _) where code == 404 || code == 405:
                    mostRecentRetryableError = error
                    continue
                default:
                    throw error
                }
            }
        }

        throw mostRecentRetryableError ?? MiniMaxProviderError.authorizationFailed
    }

    private func quotaData(apiKey: String, url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("WhenReset/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300:
            return data
        case 401, 403:
            throw MiniMaxProviderError.authorizationFailed
        default:
            throw MiniMaxProviderError.server(code, Self.safeServerMessage(data))
        }
    }

    private static func validateEnvelope(root: [String: Any], payload: [String: Any]) throws {
        let base = dictionary(payload["base_resp"] ?? payload["baseResp"])
            ?? dictionary(root["base_resp"] ?? root["baseResp"])
        let status = integer(base?["status_code"] ?? base?["statusCode"])
        let message = string(base?["status_msg"] ?? base?["statusMessage"])
            ?? string(root["message"] ?? root["msg"])

        if let status, status != 0 {
            let normalized = message?.lowercased() ?? ""
            if status == 1004 || normalized.contains("key") || normalized.contains("auth")
                || normalized.contains("login") || normalized.contains("token") {
                throw MiniMaxProviderError.authorizationFailed
            }
            throw MiniMaxProviderError.server(status, message ?? "The quota service returned an error.")
        }

        if let code = integer(root["code"]), code == 401 || code == 403 {
            throw MiniMaxProviderError.authorizationFailed
        }
    }

    private static func quotaWindow(_ model: [String: Any], weekly: Bool, now: Date) -> UsageWindow? {
        let prefix = weekly ? "current_weekly" : "current_interval"
        let total = number(model["\(prefix)_total_count"])
        // MiniMax names this `usage_count`, but the remains endpoint reports the remaining count.
        let remaining = number(model["\(prefix)_usage_count"])
        let remainingPercent = number(model["\(prefix)_remaining_percent"])
        let status = integer(model["\(prefix)_status"])

        if status == 3, (total ?? 0) == 0, (remaining ?? 0) == 0,
           (remainingPercent ?? 100) >= 100 {
            return nil
        }

        let usedPercent: Double
        if let remainingPercent {
            usedPercent = 100 - remainingPercent
        } else if let total, total > 0, let remaining {
            usedPercent = (total - remaining) / total * 100
        } else {
            return nil
        }

        let reset = resetDate(
            endValue: model[weekly ? "weekly_end_time" : "end_time"],
            remainsValue: model[weekly ? "weekly_remains_time" : "remains_time"],
            expectedWindowSeconds: weekly ? 7 * 24 * 60 * 60 : 5 * 60 * 60,
            now: now
        )
        guard let reset, reset > now else { return nil }

        return UsageWindow(
            title: weekly ? "Weekly limit" : "5h limit",
            usedPercent: min(100, max(0, usedPercent)),
            resetsAt: reset,
            windowMinutes: weekly ? 10_080 : 300,
            kind: weekly ? .weekly : .fiveHour,
            identifier: weekly ? "minimax:weekly" : "minimax:five_hour"
        )
    }

    private static func resetDate(endValue: Any?, remainsValue: Any?, expectedWindowSeconds: Double,
                                  now: Date) -> Date? {
        if let rawEnd = number(endValue), rawEnd > 0 {
            let seconds = rawEnd > 10_000_000_000 ? rawEnd / 1_000 : rawEnd
            let date = Date(timeIntervalSince1970: seconds)
            if date > now { return date }
        }
        guard let rawRemaining = number(remainsValue), rawRemaining > 0 else { return nil }
        let seconds = rawRemaining > expectedWindowSeconds * 10 ? rawRemaining / 1_000 : rawRemaining
        return now.addingTimeInterval(seconds)
    }

    private static func isCodingModel(_ model: [String: Any]) -> Bool {
        guard let name = string(model["model_name"] ?? model["modelName"])?.lowercased() else {
            return true
        }
        return !["video", "image", "speech", "audio", "music"].contains { name.contains($0) }
    }

    private static func modelPriority(_ model: [String: Any]) -> Int {
        let name = string(model["model_name"] ?? model["modelName"])?.lowercased() ?? ""
        if name == "general" || name.contains("text generation") { return 0 }
        if name.contains("minimax") || name.contains("abab") { return 1 }
        return 2
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func dictionaries(_ value: Any?) -> [[String: Any]]? {
        value as? [[String: Any]]
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstString(_ dictionary: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { string(dictionary[$0]) }.first
    }

    private static func safeServerMessage(_ data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = string(root["msg"] ?? root["message"]) {
            return String(message.prefix(180))
        }
        return "The quota service is unavailable."
    }
}
