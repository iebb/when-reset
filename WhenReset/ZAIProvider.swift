import CryptoKit
import Foundation

enum ZAIProviderError: LocalizedError {
    case invalidAPIKey
    case invalidResponse
    case noResettableQuota
    case authorizationFailed
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            "Enter a valid Z.AI Coding Plan API key."
        case .invalidResponse:
            "Z.AI returned unreadable Coding Plan quota data."
        case .noResettableQuota:
            "Z.AI did not report any resettable Coding Plan limits for this key."
        case .authorizationFailed:
            "Z.AI rejected this API key. Check that it belongs to an active Coding Plan."
        case let .server(code, message):
            "Z.AI request failed (HTTP \(code)): \(message)"
        }
    }
}

struct ZAIProvider {
    static let quotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func link(apiKey rawAPIKey: String) async throws -> LinkedIdentity {
        let apiKey = rawAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiKey.count >= 12, !apiKey.contains(where: { $0.isWhitespace }) else {
            throw ZAIProviderError.invalidAPIKey
        }

        let account = MonitoredAccount(
            id: UUID(),
            providerID: .zai,
            displayName: "Z.AI account",
            workspaceID: "pending",
            plan: nil,
            addedAt: .now
        )
        let data = try await quotaData(apiKey: apiKey)
        let snapshot = try Self.parseUsage(account: account, data: data)
        let digest = SHA256.hash(data: Data(apiKey.utf8))
        let fingerprint = digest.prefix(8).map { String(format: "%02x", $0) }.joined()

        return LinkedIdentity(
            workspaceID: "zai-\(fingerprint)",
            displayName: "Z.AI account",
            plan: snapshot.plan ?? "Coding Plan",
            credentials: AccountCredentials(
                accessToken: apiKey,
                refreshToken: "",
                idToken: "",
                expiresAt: nil
            )
        )
    }

    func fetchUsage(account: MonitoredAccount, credentials: AccountCredentials) async throws -> UsageSnapshot {
        let data = try await quotaData(apiKey: credentials.accessToken)
        return try Self.parseUsage(account: account, data: data)
    }

    static func parseUsage(account: MonitoredAccount, data: Data, now: Date = .now) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = integer(root["code"]),
              code == 200,
              (root["success"] as? Bool) != false,
              let payload = root["data"] as? [String: Any],
              let rawLimits = payload["limits"] as? [[String: Any]] else {
            throw ZAIProviderError.invalidResponse
        }

        var fiveHour: UsageWindow?
        var weekly: UsageWindow?
        var additional: [UsageWindow] = []

        for (index, rawLimit) in rawLimits.enumerated() {
            guard let window = usageWindow(rawLimit, index: index, now: now) else { continue }
            switch window.windowMinutes {
            case 300 where fiveHour == nil:
                fiveHour = window
            case 10_080 where weekly == nil:
                weekly = window
            default:
                additional.append(window)
            }
        }

        guard fiveHour != nil || weekly != nil || !additional.isEmpty else {
            throw ZAIProviderError.noResettableQuota
        }

        let plan = string(payload["planName"])
            ?? string(payload["plan"])
            ?? string(payload["plan_type"])
            ?? string(payload["packageName"])
            ?? account.plan

        return UsageSnapshot(
            accountID: account.id,
            providerName: "Z.AI Coding Plan",
            accountName: account.displayName,
            plan: plan,
            primary: fiveHour,
            secondary: weekly,
            availableResetCount: 0,
            resetCredits: [],
            fetchedAt: now,
            extraWindows: additional.isEmpty ? nil : additional
        )
    }

    private func quotaData(apiKey: String) async throws -> Data {
        var request = URLRequest(url: Self.quotaURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("WhenReset/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300:
            return data
        case 401, 403:
            throw ZAIProviderError.authorizationFailed
        default:
            throw ZAIProviderError.server(code, Self.safeServerMessage(data))
        }
    }

    private static func usageWindow(_ raw: [String: Any], index: Int, now: Date) -> UsageWindow? {
        guard let type = string(raw["type"])?.uppercased(),
              type == "TOKENS_LIMIT" || type == "TIME_LIMIT",
              let reset = resetDate(raw["nextResetTime"] ?? raw["next_reset_time"]),
              reset > now else { return nil }

        let unit = integer(raw["unit"])
        let number = integer(raw["number"]) ?? 0
        let minutes = windowMinutes(unit: unit, number: number)
        let usedPercent = percentage(raw)

        if type == "TOKENS_LIMIT" {
            switch minutes {
            case 300:
                return UsageWindow(title: "5h limit", usedPercent: usedPercent, resetsAt: reset,
                                   windowMinutes: minutes, kind: .fiveHour, identifier: "zai:five_hour")
            case 10_080:
                return UsageWindow(title: "Weekly limit", usedPercent: usedPercent, resetsAt: reset,
                                   windowMinutes: minutes, kind: .weekly, identifier: "zai:weekly")
            default:
                let title = windowTitle(unit: unit, number: number) ?? "Coding limit"
                return UsageWindow(title: title, usedPercent: usedPercent, resetsAt: reset,
                                   windowMinutes: minutes, kind: .additional,
                                   identifier: "zai:coding:\(index)")
            }
        }

        return UsageWindow(
            title: "Monthly MCP limit",
            usedPercent: usedPercent,
            resetsAt: reset,
            windowMinutes: minutes,
            kind: .additional,
            identifier: "zai:mcp:\(index)"
        )
    }

    private static func percentage(_ raw: [String: Any]) -> Double {
        if let allowance = number(raw["usage"]), allowance > 0 {
            let fromRemaining = number(raw["remaining"]).map { allowance - $0 }
            let current = number(raw["currentValue"] ?? raw["current_value"])
            let used = [fromRemaining, current].compactMap { $0 }.max()
            if let used {
                return min(100, max(0, used / allowance * 100))
            }
        }
        return min(100, max(0, number(raw["percentage"]) ?? 0))
    }

    private static func windowMinutes(unit: Int?, number: Int) -> Int? {
        guard number > 0 else { return nil }
        return switch unit {
        case 1: number * 24 * 60
        case 3: number * 60
        case 5: number
        case 6: number * 7 * 24 * 60
        default: nil
        }
    }

    private static func windowTitle(unit: Int?, number: Int) -> String? {
        guard number > 0 else { return nil }
        return switch unit {
        case 1: "\(number)-day limit"
        case 3: "\(number)h limit"
        case 5: "\(number)-minute limit"
        case 6: number == 1 ? "Weekly limit" : "\(number)-week limit"
        default: nil
        }
    }

    private static func resetDate(_ value: Any?) -> Date? {
        guard let timestamp = number(value), timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp)
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

    private static func safeServerMessage(_ data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = string(root["msg"] ?? root["message"]) {
            return String(message.prefix(180))
        }
        return "The quota service is unavailable."
    }
}
