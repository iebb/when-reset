import CryptoKit
import Foundation

struct KimiDeviceLink: Sendable {
    let verificationURL: URL
    let userCode: String
    let deviceCode: String
    let interval: Duration
    let expiresAt: Date

    var displayLink: DeviceLink {
        DeviceLink(verificationURL: verificationURL, userCode: userCode,
                   deviceAuthID: deviceCode, interval: interval)
    }
}

enum KimiProviderError: LocalizedError {
    case invalidResponse
    case authorizationExpired
    case authorizationDenied(String?)
    case missingRefreshToken
    case reauthenticationRequired
    case missingUsageWindows
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Kimi returned an unreadable response."
        case .authorizationExpired:
            "The Kimi sign-in code expired. Start linking again."
        case let .authorizationDenied(message):
            message.map { "Kimi authorization was denied: \($0)" }
                ?? "Kimi authorization was denied."
        case .missingRefreshToken:
            "Kimi did not return a refresh token. Link the account again."
        case .reauthenticationRequired:
            "The Kimi session expired or was revoked. Link the account again."
        case .missingUsageWindows:
            "Kimi did not return any usage windows with reset times."
        case let .server(code, message):
            "Kimi server error \(code): \(message)"
        }
    }
}

struct KimiProvider {
    // Public-client identifier used by the official kimi-code RFC 8628 flow.
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    static let deviceAuthorizationURL = URL(string: "https://auth.kimi.com/api/oauth/device_authorization")!
    static let tokenURL = URL(string: "https://auth.kimi.com/api/oauth/token")!
    static let usageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func beginLink() async throws -> KimiDeviceLink {
        let response = try await postForm(Self.deviceAuthorizationURL, values: [
            ("client_id", Self.clientID),
        ])
        guard response.statusCode == 200 else {
            throw Self.serverError(response, fallback: "Device authorization failed.")
        }
        return try Self.deviceLink(from: response.data)
    }

    func finishLink(_ link: KimiDeviceLink) async throws -> LinkedIdentity {
        var interval = link.interval
        while Date.now < link.expiresAt {
            try Task.checkCancellation()
            do {
                let response = try await postForm(Self.tokenURL, values: [
                    ("client_id", Self.clientID),
                    ("device_code", link.deviceCode),
                    ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                ])

                if response.statusCode == 200 {
                    let credentials = try Self.credentials(from: response.data)
                    return Self.linkedIdentity(credentials: credentials)
                }

                let errorCode = Self.oauthErrorCode(in: response.data)
                switch errorCode {
                case "authorization_pending":
                    try await Self.sleep(interval, before: link.expiresAt)
                case "slow_down":
                    interval += .seconds(5)
                    try await Self.sleep(interval, before: link.expiresAt)
                case "expired_token":
                    throw KimiProviderError.authorizationExpired
                case "access_denied":
                    throw KimiProviderError.authorizationDenied(Self.serverMessage(in: response.data))
                default:
                    if Self.retryableStatusCodes.contains(response.statusCode) {
                        try await Self.sleep(response.retryAfter ?? interval, before: link.expiresAt)
                    } else {
                        throw Self.serverError(response, fallback: "Device authorization failed.")
                    }
                }
            } catch let error as URLError where Self.isTransient(error.code) {
                try Task.checkCancellation()
                try await Self.sleep(interval, before: link.expiresAt)
            }
        }
        throw KimiProviderError.authorizationExpired
    }

    func refreshedIfNeeded(_ credentials: AccountCredentials) async throws -> AccountCredentials {
        let tokenClaims = Self.jwtClaims(credentials.idToken.isEmpty ? credentials.accessToken : credentials.idToken)
        let tokenExpiration = Self.number(tokenClaims["exp"])
            .map { Date(timeIntervalSince1970: $0) }
        guard let expiration = credentials.expiresAt ?? tokenExpiration,
              expiration.timeIntervalSinceNow < 5 * 60 else {
            return credentials
        }
        guard !credentials.refreshToken.isEmpty else {
            throw KimiProviderError.missingRefreshToken
        }

        var mostRecentError: Error?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let response = try await postForm(Self.tokenURL, values: [
                    ("client_id", Self.clientID),
                    ("grant_type", "refresh_token"),
                    ("refresh_token", credentials.refreshToken),
                ])
                if response.statusCode == 200 {
                    return try Self.credentials(from: response.data, previousIDToken: credentials.idToken)
                }

                let errorCode = Self.oauthErrorCode(in: response.data)
                if response.statusCode == 401 || response.statusCode == 403 || errorCode == "invalid_grant" {
                    throw KimiProviderError.reauthenticationRequired
                }
                guard Self.retryableStatusCodes.contains(response.statusCode), attempt < 2 else {
                    throw Self.serverError(response, fallback: "Token refresh failed.")
                }
                mostRecentError = Self.serverError(response, fallback: "Token refresh failed.")
                try await Task.sleep(for: response.retryAfter ?? .seconds(attempt == 0 ? 1 : 2))
            } catch let error as URLError where Self.isTransient(error.code) {
                mostRecentError = error
                guard attempt < 2 else { throw error }
                try Task.checkCancellation()
                try await Task.sleep(for: .seconds(attempt == 0 ? 1 : 2))
            }
        }
        throw mostRecentError ?? KimiProviderError.invalidResponse
    }

    func fetchUsage(account: MonitoredAccount, credentials: AccountCredentials) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.usageURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let response = try await send(request)
        if response.statusCode == 401 {
            throw KimiProviderError.reauthenticationRequired
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.serverError(response, fallback: "Usage request failed.")
        }
        return try parse(account: account, data: response.data)
    }

    func parse(account: MonitoredAccount, data: Data, now: Date = .now) throws -> UsageSnapshot {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw KimiProviderError.invalidResponse
        }

        let summary = root["usage"] as? [String: Any]
        var weekly = summary.flatMap {
            Self.usageWindow(detail: $0, title: "Weekly limit", minutes: 10_080,
                             kind: .weekly, identifier: "weekly", now: now)
        }
        var fiveHour: UsageWindow?
        var extraWindows: [UsageWindow] = []
        let limits = root["limits"] as? [[String: Any]] ?? []

        for (index, item) in limits.enumerated() {
            let detail = item["detail"] as? [String: Any] ?? item
            let window = item["window"] as? [String: Any] ?? [:]
            let minutes = Self.windowMinutes(window: window, item: item, detail: detail)
            let fallbackTitle = Self.windowTitle(item: item, detail: detail, minutes: minutes, index: index)

            if minutes == 300, fiveHour == nil {
                fiveHour = Self.usageWindow(detail: detail, title: "5h limit", minutes: 300,
                                            kind: .fiveHour, identifier: "five_hour", now: now)
            } else if minutes == 10_080, weekly == nil {
                weekly = Self.usageWindow(detail: detail, title: "Weekly limit", minutes: 10_080,
                                          kind: .weekly, identifier: "weekly", now: now)
            } else if let additional = Self.usageWindow(
                detail: detail,
                title: fallbackTitle,
                minutes: minutes,
                kind: .additional,
                identifier: "kimi:\(Self.identifier(fallbackTitle)):\(index)",
                now: now
            ) {
                extraWindows.append(additional)
            }
        }

        guard fiveHour != nil || weekly != nil || !extraWindows.isEmpty else {
            throw KimiProviderError.missingUsageWindows
        }
        let plan = Self.string(root["plan"])
            ?? Self.string(root["subscription_type"])
            ?? Self.string(root["tier"])
            ?? account.plan
        return UsageSnapshot(
            accountID: account.id,
            providerName: "Kimi Code",
            accountName: account.displayName,
            plan: plan,
            primary: fiveHour,
            secondary: weekly,
            availableResetCount: 0,
            resetCredits: [],
            fetchedAt: now,
            extraWindows: extraWindows.isEmpty ? nil : extraWindows
        )
    }

    static func deviceLink(from data: Data, now: Date = .now) throws -> KimiDeviceLink {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              let deviceCode = string(json["device_code"]), !deviceCode.isEmpty,
              let userCode = string(json["user_code"]), !userCode.isEmpty,
              let verificationString = string(json["verification_uri_complete"])
                ?? string(json["verification_uri"]),
              let verificationURL = URL(string: verificationString),
              verificationURL.scheme?.lowercased() == "https" else {
            throw KimiProviderError.invalidResponse
        }
        let expiresIn = max(1, number(json["expires_in"]) ?? 15 * 60)
        let pollInterval = max(1, number(json["interval"]) ?? 5)
        return KimiDeviceLink(
            verificationURL: verificationURL,
            userCode: userCode,
            deviceCode: deviceCode,
            interval: .seconds(pollInterval),
            expiresAt: now.addingTimeInterval(expiresIn)
        )
    }

    static func credentials(from data: Data, previousIDToken: String = "", now: Date = .now) throws -> AccountCredentials {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              let accessToken = string(json["access_token"]), !accessToken.isEmpty,
              let refreshToken = string(json["refresh_token"]), !refreshToken.isEmpty,
              let expiresIn = number(json["expires_in"]), expiresIn > 0 else {
            throw KimiProviderError.invalidResponse
        }
        return AccountCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: string(json["id_token"]) ?? previousIDToken,
            expiresAt: now.addingTimeInterval(expiresIn)
        )
    }

    static func linkedIdentity(credentials: AccountCredentials) -> LinkedIdentity {
        let idTokenClaims = jwtClaims(credentials.idToken)
        let accessTokenClaims = jwtClaims(credentials.accessToken)
        let claims = idTokenClaims.isEmpty ? accessTokenClaims : idTokenClaims
        let workspaceID = string(claims["sub"])
            ?? string(claims["user_id"])
            ?? string(claims["uid"])
            ?? credentialFingerprint(credentials)
        let email = string(claims["email"])
        let profileName = string(claims["name"])
            ?? string(claims["preferred_username"])
            ?? string(claims["nickname"])
        let displayName = profileName
            ?? email
            ?? "Kimi Code account"
        let plan = string(claims["plan"])
            ?? string(claims["subscription_type"])
            ?? string(claims["tier"])
        return LinkedIdentity(
            workspaceID: workspaceID,
            displayName: displayName,
            profileName: profileName,
            email: email,
            plan: plan,
            planExpiresAt: nil,
            trialExpiresAt: nil,
            credentials: credentials
        )
    }

    private static func usageWindow(detail: [String: Any], title: String, minutes: Int?,
                                    kind: UsageWindowKind, identifier: String,
                                    now: Date) -> UsageWindow? {
        guard let limit = number(detail["limit"]), limit > 0 else { return nil }
        let used = number(detail["used"])
            ?? number(detail["remaining"]).map { limit - $0 }
        guard let used else { return nil }
        let reset = date(
            detail["resetTime"] ?? detail["resetAt"] ?? detail["reset_time"] ?? detail["reset_at"],
            now: now
        ) ?? relativeReset(detail: detail, now: now)
        guard let reset else { return nil }
        let usedPercent = min(100, max(0, used / limit * 100))
        return UsageWindow(title: title, usedPercent: usedPercent, resetsAt: reset,
                           windowMinutes: minutes, kind: kind, identifier: identifier)
    }

    private static func relativeReset(detail: [String: Any], now: Date) -> Date? {
        for key in ["reset_in", "resetIn", "ttl"] {
            if let seconds = number(detail[key]), seconds > 0 {
                return now.addingTimeInterval(seconds)
            }
        }
        return nil
    }

    private static func windowMinutes(window: [String: Any], item: [String: Any],
                                      detail: [String: Any]) -> Int? {
        guard let durationValue = number(window["duration"] ?? item["duration"] ?? detail["duration"]),
              durationValue > 0 else { return nil }
        let duration = Int(durationValue.rounded(.towardZero))
        let unit = (string(window["timeUnit"] ?? item["timeUnit"] ?? detail["timeUnit"]) ?? "")
            .uppercased()
        if unit.contains("MINUTE") { return duration }
        if unit.contains("HOUR") { return duration * 60 }
        if unit.contains("DAY") { return duration * 24 * 60 }
        if unit.contains("SECOND") { return max(1, Int((durationValue / 60).rounded())) }
        return nil
    }

    private static func windowTitle(item: [String: Any], detail: [String: Any],
                                    minutes: Int?, index: Int) -> String {
        for key in ["name", "title", "scope"] {
            if let title = string(item[key] ?? detail[key]), !title.isEmpty { return title }
        }
        if let minutes {
            if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))d limit" }
            if minutes % 60 == 0 { return "\(minutes / 60)h limit" }
            return "\(minutes)m limit"
        }
        return "Limit \(index + 1)"
    }

    private static func date(_ value: Any?, now: Date) -> Date? {
        if let seconds = number(value) {
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1_000 : seconds)
        }
        guard let raw = string(value), !raw.isEmpty else { return nil }
        if let numeric = Double(raw) {
            return Date(timeIntervalSince1970: numeric > 100_000_000_000 ? numeric / 1_000 : numeric)
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: raw) { return parsed }
        if let trimmed = trimFractionalSeconds(raw), let parsed = fractional.date(from: trimmed) {
            return parsed
        }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static func trimFractionalSeconds(_ value: String) -> String? {
        guard let dot = value.firstIndex(of: ".") else { return nil }
        let suffix = value[value.index(after: dot)...]
        guard let timezoneStart = suffix.firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else {
            return nil
        }
        let fraction = suffix[..<timezoneStart]
        guard !fraction.isEmpty else { return nil }
        return String(value[...dot]) + fraction.prefix(3) + value[timezoneStart...]
    }

    private static func identifier(_ value: String) -> String {
        let transformed = value.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }
        return String(transformed).split(separator: "_").joined(separator: "_")
    }

    private static func jwtClaims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              !parts[2].isEmpty,
              let headerData = base64URLDecoded(parts[0]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              string(header["alg"]) != nil,
              let payloadData = base64URLDecoded(parts[1]),
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return [:]
        }
        return claims
    }

    private static func base64URLDecoded(_ value: Substring) -> Data? {
        var payload = String(value)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        return Data(base64Encoded: payload)
    }

    private static func credentialFingerprint(_ credentials: AccountCredentials) -> String {
        let source: String
        if !credentials.refreshToken.isEmpty {
            source = "refresh:\(credentials.refreshToken)"
        } else if !credentials.accessToken.isEmpty {
            source = "access:\(credentials.accessToken)"
        } else {
            source = "id:\(credentials.idToken)"
        }
        let digest = SHA256.hash(data: Data(source.utf8))
        return "kimi-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func postForm(_ url: URL, values: [(String, String)]) async throws -> HTTPResponse {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.0, value: $0.1) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KimiProviderError.invalidResponse
        }
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
            .flatMap(Double.init)
            .map { Duration.seconds(min(60, max(1, $0))) }
        return HTTPResponse(data: data, statusCode: http.statusCode, retryAfter: retryAfter)
    }

    private static func sleep(_ duration: Duration, before deadline: Date) async throws {
        guard Date.now < deadline else { throw KimiProviderError.authorizationExpired }
        try await Task.sleep(for: duration)
        try Task.checkCancellation()
    }

    private static func serverError(_ response: HTTPResponse, fallback: String) -> KimiProviderError {
        .server(response.statusCode, serverMessage(in: response.data) ?? fallback)
    }

    private static func oauthErrorCode(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return string(json["error"])
    }

    private static func serverMessage(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let nestedError = json["error"] as? [String: Any]
        let candidate = string(json["error_description"])
            ?? string(json["message"])
            ?? string(nestedError?["message"])
            ?? string(nestedError?["description"])
            ?? string(json["error"])
        guard let candidate else { return nil }
        let cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(500))
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber, !(value is Bool) { return value.stringValue }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if value is Bool { return nil }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func isTransient(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed:
            true
        default:
            false
        }
    }

    private static let retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 504]

    private static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "WhenReset/\(version)"
    }
}

private struct HTTPResponse {
    let data: Data
    let statusCode: Int
    let retryAfter: Duration?
}
