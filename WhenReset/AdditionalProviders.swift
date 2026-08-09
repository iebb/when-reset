import CryptoKit
import Foundation
import Security

enum AdditionalProviderError: LocalizedError {
    case invalidCredential(String, String)
    case authorizationFailed(String)
    case missingRefreshToken(String)
    case invalidResponse(String)
    case noResettableQuota(String)
    case invalidEndpoint
    case stateMismatch
    case responseTooLarge(String)
    case server(String, Int)

    var errorDescription: String? {
        switch self {
        case let .invalidCredential(_, guidance):
            guidance
        case let .authorizationFailed(provider):
            "\(provider) rejected this credential. Link the account again."
        case let .missingRefreshToken(provider):
            "\(provider) did not return a refresh token. Link the account again."
        case let .invalidResponse(provider):
            "\(provider) returned unreadable quota data."
        case let .noResettableQuota(provider):
            "\(provider) did not report any resettable quota windows."
        case .invalidEndpoint:
            "Enter a valid HTTPS usage endpoint. Loopback HTTP is allowed for local development."
        case .stateMismatch:
            "Google returned a callback for a different Antigravity sign-in attempt. Start again."
        case let .responseTooLarge(provider):
            "\(provider) returned more quota data than When Reset can safely process."
        case let .server(provider, code):
            "\(provider) request failed (HTTP \(code))."
        }
    }

    var requiresReauthentication: Bool {
        switch self {
        case .invalidCredential, .authorizationFailed, .missingRefreshToken:
            true
        case let .server(_, code):
            code == 401 || code == 403
        default:
            false
        }
    }
}

private enum AdditionalProviderParsing {
    static let maximumResponseBytes = 1_048_576

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func dictionaries(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }

    static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        guard let text = string(value) else { return nil }
        let normalized = text
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "%", with: "")
        return Double(normalized)
    }

    static func integer(_ value: Any?) -> Int? {
        number(value).map { Int($0) }
    }

    static func date(_ value: Any?) -> Date? {
        if let number = number(value), number > 0 {
            return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1_000 : number)
        }
        guard let text = string(value) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    static func firstString(_ root: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { string(root[$0]) }.first
    }

    static func firstNumber(_ root: [String: Any], keys: [String]) -> Double? {
        keys.lazy.compactMap { number(root[$0]) }.first
    }

    static func firstDate(_ root: [String: Any], keys: [String]) -> Date? {
        keys.lazy.compactMap { date(root[$0]) }.first
    }

    static func fingerprint(_ values: String...) -> String {
        let digest = SHA256.hash(data: Data(values.joined(separator: "\u{0}").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func bounded(_ data: Data, provider: String) throws -> Data {
        guard data.count <= maximumResponseBytes else {
            throw AdditionalProviderError.responseTooLarge(provider)
        }
        return data
    }

    static func json(_ data: Data, provider: String) throws -> [String: Any] {
        let bounded = try bounded(data, provider: provider)
        guard let root = try? JSONSerialization.jsonObject(with: bounded) as? [String: Any] else {
            throw AdditionalProviderError.invalidResponse(provider)
        }
        return root
    }

    static func identifier(_ value: String) -> String {
        let mapped = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "_"
        }
        return String(mapped)
            .replacingOccurrences(of: #"_+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    static func percentUsed(_ root: [String: Any]) -> Double? {
        if let used = firstNumber(root, keys: [
            "usedPercent", "used_percent", "percentUsed", "percent_used", "usagePercent",
            "usage_percent", "percentage", "percent",
        ]) {
            return min(100, max(0, used))
        }
        if let remaining = firstNumber(root, keys: [
            "remainingPercent", "remaining_percent", "percentRemaining", "percent_remaining",
        ]) {
            return min(100, max(0, 100 - remaining))
        }
        let limit = firstNumber(root, keys: [
            "limit", "max", "total", "capacity", "allowance", "requestLimit", "maxCredits",
        ])
        let used = firstNumber(root, keys: [
            "used", "usage", "consumed", "spent", "requestsUsed", "usedCredits",
        ])
        let remaining = firstNumber(root, keys: [
            "remaining", "left", "available", "requestsRemaining", "remainingCredits",
        ])
        guard let limit, limit > 0 else { return nil }
        if let used { return min(100, max(0, used / limit * 100)) }
        if let remaining { return min(100, max(0, (limit - remaining) / limit * 100)) }
        return nil
    }
}

private final class AdditionalProviderRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private enum AdditionalProviderNetworking {
    private static let redirectBlocker = AdditionalProviderRedirectBlocker()

    static func data(
        for request: URLRequest,
        session: URLSession,
        provider: String
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request, delegate: redirectBlocker)
        let maximum = AdditionalProviderParsing.maximumResponseBytes
        let declared = response.expectedContentLength
        if declared > Int64(maximum) {
            bytes.task.cancel()
            throw AdditionalProviderError.responseTooLarge(provider)
        }

        var data = Data()
        if declared > 0 { data.reserveCapacity(Int(declared)) }
        for try await byte in bytes {
            guard data.count < maximum else {
                bytes.task.cancel()
                throw AdditionalProviderError.responseTooLarge(provider)
            }
            data.append(byte)
        }
        return (data, response)
    }
}

// MARK: - Synthetic

struct SyntheticProvider {
    static let quotaURL = URL(string: "https://api.synthetic.new/v2/quotas")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func link(apiKey rawAPIKey: String) async throws -> LinkedIdentity {
        let apiKey = rawAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiKey.count >= 8, !apiKey.contains(where: { $0.isWhitespace }) else {
            throw AdditionalProviderError.invalidCredential(
                "Synthetic", "Enter a valid Synthetic API key."
            )
        }
        let account = pendingAccount(providerID: .synthetic, name: "Synthetic account")
        let snapshot = try await fetchUsage(
            account: account,
            credentials: AccountCredentials(accessToken: apiKey, refreshToken: "", idToken: "")
        )
        return LinkedIdentity(
            workspaceID: "synthetic-\(AdditionalProviderParsing.fingerprint(apiKey))",
            displayName: "Synthetic account",
            plan: snapshot.plan,
            credentials: AccountCredentials(accessToken: apiKey, refreshToken: "", idToken: "")
        )
    }

    func fetchUsage(account: MonitoredAccount, credentials: AccountCredentials) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.quotaURL)
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("WhenReset/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await AdditionalProviderNetworking.data(
            for: request, session: session, provider: "Synthetic"
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw AdditionalProviderError.authorizationFailed("Synthetic") }
        guard (200..<300).contains(status) else { throw AdditionalProviderError.server("Synthetic", status) }
        return try Self.parseUsage(account: account, data: data)
    }

    static func parseUsage(account: MonitoredAccount, data: Data, now: Date = .now) throws -> UsageSnapshot {
        let root = try AdditionalProviderParsing.json(data, provider: "Synthetic")
        let payload = AdditionalProviderParsing.dictionary(root["data"]) ?? root
        let rolling = AdditionalProviderParsing.dictionary(payload["rollingFiveHourLimit"])
            .flatMap { quotaWindow($0, title: "5h limit", minutes: 300, kind: .fiveHour,
                                   identifier: "synthetic:five_hour", now: now) }
        let weekly = AdditionalProviderParsing.dictionary(payload["weeklyTokenLimit"])
            .flatMap { quotaWindow($0, title: "Weekly limit", minutes: 10_080, kind: .weekly,
                                   identifier: "synthetic:weekly", now: now) }
        guard rolling != nil || weekly != nil else {
            throw AdditionalProviderError.noResettableQuota("Synthetic")
        }
        let plan = AdditionalProviderParsing.firstString(payload, keys: [
            "plan", "planName", "plan_name", "subscription", "tier",
        ]) ?? account.plan
        return UsageSnapshot(
            accountID: account.id,
            providerName: "Synthetic",
            accountName: account.displayName,
            plan: plan,
            primary: rolling,
            secondary: weekly,
            availableResetCount: 0,
            resetCredits: [],
            fetchedAt: now
        )
    }

    private static func quotaWindow(
        _ root: [String: Any],
        title: String,
        minutes: Int,
        kind: UsageWindowKind,
        identifier: String,
        now: Date
    ) -> UsageWindow? {
        guard let usedPercent = AdditionalProviderParsing.percentUsed(root),
              let reset = AdditionalProviderParsing.firstDate(root, keys: [
                  "resetAt", "reset_at", "resetsAt", "resets_at", "nextTickAt", "next_tick_at",
                  "nextRegenAt", "next_regen_at", "periodEnd", "period_end",
              ]), reset > now else { return nil }
        return UsageWindow(
            title: title,
            usedPercent: usedPercent,
            resetsAt: reset,
            windowMinutes: minutes,
            kind: kind,
            identifier: identifier
        )
    }
}

// MARK: - Warp

struct WarpProvider {
    static let quotaURL = URL(string: "https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo")!
    private static let graphQLQuery = """
    query GetRequestLimitInfo($requestContext: RequestContext!) {
      user(requestContext: $requestContext) {
        __typename
        ... on UserOutput {
          user { requestLimitInfo { isUnlimited nextRefreshTime requestLimit requestsUsedSinceLastRefresh } }
        }
      }
    }
    """
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func link(apiKey rawAPIKey: String) async throws -> LinkedIdentity {
        let apiKey = rawAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiKey.count >= 8, !apiKey.contains(where: { $0.isWhitespace }) else {
            throw AdditionalProviderError.invalidCredential("Warp", "Enter a valid Warp API key.")
        }
        let account = pendingAccount(providerID: .warp, name: "Warp account")
        let snapshot = try await fetchUsage(
            account: account,
            credentials: AccountCredentials(accessToken: apiKey, refreshToken: "", idToken: "")
        )
        return LinkedIdentity(
            workspaceID: "warp-\(AdditionalProviderParsing.fingerprint(apiKey))",
            displayName: "Warp account",
            plan: snapshot.plan,
            credentials: AccountCredentials(accessToken: apiKey, refreshToken: "", idToken: "")
        )
    }

    func fetchUsage(account: MonitoredAccount, credentials: AccountCredentials) async throws -> UsageSnapshot {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let body: [String: Any] = [
            "query": Self.graphQLQuery,
            "operationName": "GetRequestLimitInfo",
            "variables": [
                "requestContext": [
                    "clientContext": [:] as [String: Any],
                    "osContext": ["category": "macOS", "name": "macOS", "version": osVersion],
                ],
            ],
        ]
        var request = URLRequest(url: Self.quotaURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("warp-app", forHTTPHeaderField: "x-warp-client-id")
        request.setValue("macOS", forHTTPHeaderField: "x-warp-os-category")
        request.setValue("macOS", forHTTPHeaderField: "x-warp-os-name")
        request.setValue(osVersion, forHTTPHeaderField: "x-warp-os-version")
        request.setValue("Warp/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await AdditionalProviderNetworking.data(
            for: request, session: session, provider: "Warp"
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw AdditionalProviderError.authorizationFailed("Warp") }
        guard (200..<300).contains(status) else { throw AdditionalProviderError.server("Warp", status) }
        return try Self.parseUsage(account: account, data: data)
    }

    static func parseUsage(account: MonitoredAccount, data: Data, now: Date = .now) throws -> UsageSnapshot {
        let root = try AdditionalProviderParsing.json(data, provider: "Warp")
        if let errors = root["errors"] as? [Any], !errors.isEmpty {
            throw AdditionalProviderError.invalidResponse("Warp")
        }
        guard let data = AdditionalProviderParsing.dictionary(root["data"]),
              let userOutput = AdditionalProviderParsing.dictionary(data["user"]),
              let user = AdditionalProviderParsing.dictionary(userOutput["user"]),
              let limit = AdditionalProviderParsing.dictionary(user["requestLimitInfo"]),
              limit["isUnlimited"] as? Bool != true,
              let maximum = AdditionalProviderParsing.number(limit["requestLimit"]), maximum > 0,
              let used = AdditionalProviderParsing.number(limit["requestsUsedSinceLastRefresh"]),
              let reset = AdditionalProviderParsing.date(limit["nextRefreshTime"]), reset > now else {
            throw AdditionalProviderError.noResettableQuota("Warp")
        }
        let primary = UsageWindow(
            title: "Monthly credits",
            usedPercent: min(100, max(0, used / maximum * 100)),
            resetsAt: reset,
            windowMinutes: nil,
            kind: .additional,
            identifier: "warp:monthly_credits"
        )
        return UsageSnapshot(
            accountID: account.id,
            providerName: "Warp",
            accountName: account.displayName,
            plan: account.plan ?? "Warp",
            primary: primary,
            secondary: nil,
            availableResetCount: 0,
            resetCredits: [],
            fetchedAt: now
        )
    }
}

// MARK: - Ollama Cloud

struct OllamaCloudProvider {
    static let settingsURL = URL(string: "https://ollama.com/settings")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func link(cookie rawCookie: String) async throws -> LinkedIdentity {
        let cookie = try Self.normalizedCookie(rawCookie)
        let account = pendingAccount(providerID: .ollamaCloud, name: "Ollama Cloud account")
        let snapshot = try await fetchUsage(
            account: account,
            credentials: AccountCredentials(accessToken: cookie, refreshToken: "", idToken: "")
        )
        return LinkedIdentity(
            workspaceID: "ollama-\(AdditionalProviderParsing.fingerprint(cookie))",
            displayName: snapshot.accountName,
            email: snapshot.accountName.contains("@") ? snapshot.accountName : nil,
            plan: snapshot.plan,
            credentials: AccountCredentials(accessToken: cookie, refreshToken: "", idToken: "")
        )
    }

    func fetchUsage(account: MonitoredAccount, credentials: AccountCredentials) async throws -> UsageSnapshot {
        let cookie = try Self.normalizedCookie(credentials.accessToken)
        var request = URLRequest(url: Self.settingsURL)
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("WhenReset/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await AdditionalProviderNetworking.data(
            for: request, session: session, provider: "Ollama Cloud"
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw AdditionalProviderError.authorizationFailed("Ollama Cloud") }
        guard (200..<300).contains(status) else { throw AdditionalProviderError.server("Ollama Cloud", status) }
        guard let finalURL = response.url,
              finalURL.host == "ollama.com" || finalURL.host?.hasSuffix(".ollama.com") == true,
              !finalURL.path.lowercased().contains("signin") else {
            throw AdditionalProviderError.authorizationFailed("Ollama Cloud")
        }
        return try Self.parseUsage(account: account, data: data)
    }

    static func parseUsage(account: MonitoredAccount, data: Data, now: Date = .now) throws -> UsageSnapshot {
        let bounded = try AdditionalProviderParsing.bounded(data, provider: "Ollama Cloud")
        guard let html = String(data: bounded, encoding: .utf8), !html.isEmpty else {
            throw AdditionalProviderError.invalidResponse("Ollama Cloud")
        }
        let session = usageBlock(label: "Session usage", html: html, minutes: 300,
                                 kind: .fiveHour, id: "ollama:session", now: now)
        let weekly = usageBlock(label: "Weekly usage", html: html, minutes: 10_080,
                                kind: .weekly, id: "ollama:weekly", now: now)
        guard session != nil || weekly != nil else {
            if html.localizedCaseInsensitiveContains("sign in") {
                throw AdditionalProviderError.authorizationFailed("Ollama Cloud")
            }
            throw AdditionalProviderError.noResettableQuota("Ollama Cloud")
        }
        let plan = capture(
            #"Cloud Usage\s*</span>\s*<span[^>]*>([^<]+)</span>"#,
            in: html
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? account.plan
        let email = capture(#"id=[\"']header-email[\"'][^>]*>([^<]+)<"#, in: html)
        return UsageSnapshot(
            accountID: account.id,
            providerName: "Ollama Cloud",
            accountName: email?.contains("@") == true ? email! : account.displayName,
            plan: plan,
            primary: session,
            secondary: weekly,
            availableResetCount: 0,
            resetCredits: [],
            fetchedAt: now
        )
    }

    private static func normalizedCookie(_ value: String) throws -> String {
        var cookie = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if cookie.lowercased().hasPrefix("cookie:") {
            cookie = String(cookie.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespaces)
        }
        guard cookie.count >= 8, cookie.count <= 16_384, cookie.contains("="),
              cookie.rangeOfCharacter(from: .newlines) == nil else {
            throw AdditionalProviderError.invalidCredential(
                "Ollama Cloud", "Paste the Cookie request header from a signed-in ollama.com session."
            )
        }
        return cookie
    }

    private static func usageBlock(
        label: String,
        html: String,
        minutes: Int,
        kind: UsageWindowKind,
        id: String,
        now: Date
    ) -> UsageWindow? {
        guard let labelRange = html.range(of: label, options: .caseInsensitive) else { return nil }
        let tail = String(html[labelRange.upperBound...].prefix(4_000))
        let percentText = capture(#"([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#, in: tail)
            ?? capture(#"width:\s*([0-9]+(?:\.[0-9]+)?)%"#, in: tail)
        guard let percentText, let percent = Double(percentText),
              let dateText = capture(#"(20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:.+-]+Z?)"#, in: tail),
              let reset = AdditionalProviderParsing.date(dateText), reset > now else { return nil }
        return UsageWindow(
            title: label.replacingOccurrences(of: " usage", with: " limit"),
            usedPercent: min(100, max(0, percent)),
            resetsAt: reset,
            windowMinutes: minutes,
            kind: kind,
            identifier: id
        )
    }

    private static func capture(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
}

// MARK: - Antigravity

struct AntigravityOAuthLink: Sendable {
    let authorizationURL: URL
    let codeVerifier: String
    let state: String
    let clientID: String
    let clientSecret: String
}

struct AntigravityProvider {
    private static let redirectURI = "http://localhost:51121/oauth-callback"
    private static let authURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let userInfoURL = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!
    private static let baseURL = "https://cloudcode-pa.googleapis.com"
    private static let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/experimentsandconfigs",
    ]
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func beginLink(clientID rawClientID: String, clientSecret rawClientSecret: String) throws -> AntigravityOAuthLink {
        let clientID = try Self.oauthConfigurationValue(
            rawClientID,
            field: "client ID",
            secret: false
        )
        let clientSecret = try Self.oauthConfigurationValue(
            rawClientSecret,
            field: "client secret",
            secret: true
        )
        let verifier = try Self.randomBase64URL(byteCount: 64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = try Self.randomBase64URL(byteCount: 32)
        var components = URLComponents(url: Self.authURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        guard let url = components.url else { throw AdditionalProviderError.invalidResponse("Antigravity") }
        return AntigravityOAuthLink(
            authorizationURL: url,
            codeVerifier: verifier,
            state: state,
            clientID: clientID,
            clientSecret: clientSecret
        )
    }

    func finishLink(_ link: AntigravityOAuthLink, callback rawCallback: String) async throws -> LinkedIdentity {
        let callback = try Self.callback(rawCallback, expectedState: link.state)
        var components = URLComponents()
        components.queryItems = [
            .init(name: "client_id", value: link.clientID),
            .init(name: "client_secret", value: link.clientSecret),
            .init(name: "code", value: callback.code),
            .init(name: "code_verifier", value: link.codeVerifier),
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
        ]
        let tokenRoot = try await requestJSON(
            Self.tokenURL,
            method: "POST",
            body: Data((components.percentEncodedQuery ?? "").utf8),
            contentType: "application/x-www-form-urlencoded",
            provider: "Antigravity"
        )
        guard let accessToken = AdditionalProviderParsing.string(tokenRoot["access_token"]),
              let refreshToken = AdditionalProviderParsing.string(tokenRoot["refresh_token"]) else {
            throw AdditionalProviderError.missingRefreshToken("Antigravity")
        }
        let expiresIn = AdditionalProviderParsing.number(tokenRoot["expires_in"]) ?? 3_600
        var credentials = AccountCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: AdditionalProviderParsing.string(tokenRoot["id_token"]) ?? "",
            expiresAt: .now.addingTimeInterval(expiresIn),
            oauthClientID: link.clientID,
            oauthClientSecret: link.clientSecret
        )
        let userInfo = try? await authorizedJSON(
            Self.userInfoURL, accessToken: accessToken, method: "GET", body: nil
        )
        let email = userInfo.flatMap { AdditionalProviderParsing.string($0["email"]) }
        let name = userInfo.flatMap { AdditionalProviderParsing.string($0["name"]) }
        let codeAssist = try? await loadCodeAssist(accessToken: accessToken)
        credentials.projectID = codeAssist?.projectID
        let workspace = codeAssist?.projectID
            ?? email.map { "google-\(AdditionalProviderParsing.fingerprint($0))" }
            ?? "google-\(AdditionalProviderParsing.fingerprint(accessToken))"
        return LinkedIdentity(
            workspaceID: workspace,
            displayName: name ?? email ?? "Antigravity account",
            profileName: name,
            email: email,
            plan: codeAssist?.plan ?? "Antigravity",
            credentials: credentials
        )
    }

    func refreshedIfNeeded(_ credentials: AccountCredentials) async throws -> AccountCredentials {
        if let expiresAt = credentials.expiresAt, expiresAt.timeIntervalSinceNow >= 5 * 60 {
            return credentials
        }
        guard !credentials.refreshToken.isEmpty else {
            throw AdditionalProviderError.missingRefreshToken("Antigravity")
        }
        guard let clientID = credentials.oauthClientID,
              let clientSecret = credentials.oauthClientSecret else {
            throw AdditionalProviderError.authorizationFailed("Antigravity")
        }
        var components = URLComponents()
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "client_secret", value: clientSecret),
            .init(name: "refresh_token", value: credentials.refreshToken),
            .init(name: "grant_type", value: "refresh_token"),
        ]
        let root = try await requestJSON(
            Self.tokenURL,
            method: "POST",
            body: Data((components.percentEncodedQuery ?? "").utf8),
            contentType: "application/x-www-form-urlencoded",
            provider: "Antigravity"
        )
        guard let accessToken = AdditionalProviderParsing.string(root["access_token"]) else {
            throw AdditionalProviderError.authorizationFailed("Antigravity")
        }
        var refreshed = credentials
        refreshed.accessToken = accessToken
        refreshed.refreshToken = AdditionalProviderParsing.string(root["refresh_token"])
            ?? credentials.refreshToken
        refreshed.idToken = AdditionalProviderParsing.string(root["id_token"])
            ?? credentials.idToken
        refreshed.expiresAt = .now.addingTimeInterval(
            AdditionalProviderParsing.number(root["expires_in"]) ?? 3_600
        )
        return refreshed
    }

    func fetchUsage(account: MonitoredAccount, credentials: AccountCredentials) async throws -> UsageSnapshot {
        let body: [String: Any] = credentials.projectID.map { ["project": $0] } ?? [:]
        var mostRecentError: Error?
        for operation in ["retrieveUserQuota", "fetchAvailableModels"] {
            do {
                let data = try await authorizedData(
                    URL(string: "\(Self.baseURL)/v1internal:\(operation)")!,
                    accessToken: credentials.accessToken,
                    body: body
                )
                return try Self.parseUsage(account: account, data: data)
            } catch let error as AdditionalProviderError {
                if error.requiresReauthentication { throw error }
                mostRecentError = error
            } catch {
                mostRecentError = error
            }
        }
        throw mostRecentError ?? AdditionalProviderError.noResettableQuota("Antigravity")
    }

    static func parseUsage(account: MonitoredAccount, data: Data, now: Date = .now) throws -> UsageSnapshot {
        let root = try AdditionalProviderParsing.json(data, provider: "Antigravity")
        var entries: [(id: String, title: String, remaining: Double, reset: Date)] = []
        collectQuotaEntries(root, inheritedName: nil, into: &entries, depth: 0)
        var seen: Set<String> = []
        var windows: [UsageWindow] = []
        for entry in entries where entry.reset > now {
            let normalized = "\(entry.id) \(entry.title)".lowercased()
            let minutes: Int?
            let kind: UsageWindowKind
            if normalized.contains("weekly") || normalized.contains("7d") || normalized.contains("week") {
                minutes = 10_080
                kind = .weekly
            } else if normalized.contains("5h") || normalized.contains("five hour")
                        || normalized.contains("five-hour") {
                minutes = 300
                kind = .fiveHour
            } else {
                minutes = nil
                kind = .additional
            }
            let family: String
            if normalized.contains("claude") { family = "Claude" }
            else if normalized.contains("gpt") { family = "GPT" }
            else if normalized.contains("gemini") { family = "Gemini" }
            else { family = entry.title }
            let suffix = kind == .weekly ? " weekly" : kind == .fiveHour ? " 5h" : ""
            let title = family.lowercased().contains(suffix.trimmingCharacters(in: .whitespaces))
                ? family : "\(family)\(suffix) limit"
            let id = "antigravity:\(AdditionalProviderParsing.identifier(family)):\(kind.rawValue)"
            guard seen.insert(id).inserted else { continue }
            windows.append(UsageWindow(
                title: title,
                usedPercent: min(100, max(0, 100 - entry.remaining * 100)),
                resetsAt: entry.reset,
                windowMinutes: minutes,
                kind: kind,
                identifier: id
            ))
        }
        guard !windows.isEmpty else { throw AdditionalProviderError.noResettableQuota("Antigravity") }
        let primary = windows.first { $0.kind == .fiveHour }
        let secondary = windows.first { $0.kind == .weekly }
        let extra = windows.filter { $0 != primary && $0 != secondary }
        return UsageSnapshot(
            accountID: account.id,
            providerName: "Antigravity",
            accountName: account.displayName,
            plan: account.plan,
            primary: primary,
            secondary: secondary,
            availableResetCount: 0,
            resetCredits: [],
            fetchedAt: now,
            extraWindows: extra.isEmpty ? nil : Array(extra.prefix(8))
        )
    }

    private func loadCodeAssist(accessToken: String) async throws -> (projectID: String?, plan: String?) {
        let body: [String: Any] = [
            "metadata": [
                "ideType": "ANTIGRAVITY",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            ],
        ]
        let root = try await authorizedJSON(
            URL(string: "\(Self.baseURL)/v1internal:loadCodeAssist")!,
            accessToken: accessToken,
            method: "POST",
            body: body
        )
        let project = Self.findString(root, matching: ["projectid", "project_id", "project"], depth: 0)
        let plan = Self.findString(root, matching: ["plan", "tier", "subscription"], depth: 0)
        return (project, plan)
    }

    private func authorizedJSON(
        _ url: URL,
        accessToken: String,
        method: String,
        body: [String: Any]?
    ) async throws -> [String: Any] {
        let data = try await authorizedData(url, accessToken: accessToken, body: body, method: method)
        return try AdditionalProviderParsing.json(data, provider: "Antigravity")
    }

    private func authorizedData(
        _ url: URL,
        accessToken: String,
        body: [String: Any]?,
        method: String = "POST"
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("google-cloud-sdk vscode_cloudshelleditor/0.1", forHTTPHeaderField: "X-Goog-Api-Client")
        request.setValue(
            #"{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}"#,
            forHTTPHeaderField: "Client-Metadata"
        )
        request.setValue("antigravity/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await AdditionalProviderNetworking.data(
            for: request, session: session, provider: "Antigravity"
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw AdditionalProviderError.authorizationFailed("Antigravity") }
        guard (200..<300).contains(status) else { throw AdditionalProviderError.server("Antigravity", status) }
        return try AdditionalProviderParsing.bounded(data, provider: "Antigravity")
    }

    private func requestJSON(
        _ url: URL,
        method: String,
        body: Data,
        contentType: String,
        provider: String
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await AdditionalProviderNetworking.data(
            for: request, session: session, provider: provider
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 401 || status == 403 {
            throw AdditionalProviderError.authorizationFailed(provider)
        }
        guard (200..<300).contains(status) else { throw AdditionalProviderError.server(provider, status) }
        return try AdditionalProviderParsing.json(data, provider: provider)
    }

    static func callback(_ raw: String, expectedState: String) throws -> (code: String, state: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "http",
              components.host?.lowercased() == "localhost",
              components.port == 51_121,
              components.path == "/oauth-callback",
              components.fragment == nil else {
            throw AdditionalProviderError.invalidCredential(
                "Antigravity", "Paste the complete localhost callback URL from Google."
            )
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] where item.name == "code" || item.name == "state" {
            guard let value = item.value, !value.isEmpty, values[item.name] == nil else {
                throw AdditionalProviderError.invalidCredential(
                    "Antigravity", "Paste the complete localhost callback URL from Google."
                )
            }
            values[item.name] = value
        }
        let code = values["code"]
        let state = values["state"]
        guard let code, !code.isEmpty else {
            throw AdditionalProviderError.invalidCredential(
                "Antigravity", "Paste the complete localhost callback URL from Google."
            )
        }
        guard state == expectedState else { throw AdditionalProviderError.stateMismatch }
        return (code, expectedState)
    }

    private static func collectQuotaEntries(
        _ root: [String: Any],
        inheritedName: String?,
        into entries: inout [(id: String, title: String, remaining: Double, reset: Date)],
        depth: Int
    ) {
        guard depth <= 6 else { return }
        let id = AdditionalProviderParsing.firstString(root, keys: [
            "bucketId", "bucket_id", "modelId", "model_id", "id", "name",
        ]) ?? inheritedName
        let title = AdditionalProviderParsing.firstString(root, keys: [
            "displayName", "display_name", "label", "title", "name",
        ]) ?? id
        let remainingRoot = AdditionalProviderParsing.dictionary(root["remaining"])
        let remaining = AdditionalProviderParsing.firstNumber(root, keys: [
            "remainingFraction", "remaining_fraction",
        ]) ?? remainingRoot.flatMap {
            AdditionalProviderParsing.firstNumber($0, keys: ["remainingFraction", "remaining_fraction", "value"])
        }
        let reset = AdditionalProviderParsing.firstDate(root, keys: [
            "resetTime", "reset_time", "resetAt", "reset_at", "resetsAt", "resets_at",
        ])
        if root["disabled"] as? Bool != true, let id, let title, let remaining, let reset {
            entries.append((id, title, min(1, max(0, remaining)), reset))
        }
        for (key, value) in root {
            if let child = value as? [String: Any] {
                collectQuotaEntries(child, inheritedName: key, into: &entries, depth: depth + 1)
            } else if let children = value as? [[String: Any]] {
                for child in children {
                    collectQuotaEntries(child, inheritedName: key, into: &entries, depth: depth + 1)
                }
            }
        }
    }

    private static func findString(
        _ root: [String: Any], matching keys: Set<String>, depth: Int
    ) -> String? {
        guard depth <= 5 else { return nil }
        for (key, value) in root where keys.contains(key.lowercased()) {
            if let text = AdditionalProviderParsing.string(value) { return text }
            if let object = value as? [String: Any],
               let text = AdditionalProviderParsing.firstString(object, keys: ["id", "name", "displayName"]) {
                return text
            }
        }
        for value in root.values {
            if let child = value as? [String: Any],
               let match = findString(child, matching: keys, depth: depth + 1) { return match }
        }
        return nil
    }

    private static func randomBase64URL(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw AdditionalProviderError.invalidResponse("Antigravity")
        }
        return base64URL(Data(bytes))
    }

    private static func oauthConfigurationValue(
        _ rawValue: String,
        field: String,
        secret: Bool
    ) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 512,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            let guidance = secret
                ? "Enter the client secret from your installed-app OAuth configuration."
                : "Enter the client ID from your installed-app OAuth configuration."
            throw AdditionalProviderError.invalidCredential("Antigravity", guidance)
        }
        return value
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Compatible usage API

struct CompatibleAPIProvider {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func link(endpoint rawEndpoint: String, apiKey rawAPIKey: String, name rawName: String) async throws -> LinkedIdentity {
        let endpoint = try Self.normalizedEndpoint(rawEndpoint)
        let apiKey = rawAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiKey.count >= 4, apiKey.count <= 16_384,
              apiKey.rangeOfCharacter(from: .newlines) == nil else {
            throw AdditionalProviderError.invalidCredential(
                "Compatible API", "Enter the bearer API key for this usage endpoint."
            )
        }
        guard !name.isEmpty, name.count <= 64 else {
            throw AdditionalProviderError.invalidCredential(
                "Compatible API", "Enter a short name for this provider."
            )
        }
        let credentials = AccountCredentials(
            accessToken: apiKey,
            refreshToken: "",
            idToken: "",
            endpointURL: endpoint.absoluteString,
            accountLabel: name
        )
        let account = pendingAccount(providerID: .compatibleAPI, name: name)
        let snapshot = try await fetchUsage(account: account, credentials: credentials)
        return LinkedIdentity(
            workspaceID: "compatible-\(AdditionalProviderParsing.fingerprint(endpoint.absoluteString, apiKey))",
            displayName: name,
            plan: snapshot.plan,
            credentials: credentials
        )
    }

    func fetchUsage(account: MonitoredAccount, credentials: AccountCredentials) async throws -> UsageSnapshot {
        guard let rawEndpoint = credentials.endpointURL else {
            throw AdditionalProviderError.invalidEndpoint
        }
        let endpoint = try Self.normalizedEndpoint(rawEndpoint)
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("WhenReset/1.0", forHTTPHeaderField: "User-Agent")
        let provider = credentials.accountLabel ?? "Compatible API"
        let (data, response) = try await AdditionalProviderNetworking.data(
            for: request, session: session, provider: provider
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw AdditionalProviderError.authorizationFailed(provider)
        }
        guard (200..<300).contains(status) else {
            throw AdditionalProviderError.server(provider, status)
        }
        guard response.url == endpoint else { throw AdditionalProviderError.invalidEndpoint }
        return try Self.parseUsage(account: account, data: data)
    }

    static func normalizedEndpoint(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 2_048,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw AdditionalProviderError.invalidEndpoint
        }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw AdditionalProviderError.invalidEndpoint
        }
        components.scheme = scheme
        components.host = host
        guard let url = components.url else { throw AdditionalProviderError.invalidEndpoint }
        return url
    }

    static func parseUsage(account: MonitoredAccount, data: Data, now: Date = .now) throws -> UsageSnapshot {
        let root = try AdditionalProviderParsing.json(data, provider: account.displayName)
        let payload = AdditionalProviderParsing.dictionary(root["data"]) ?? root
        var candidates: [(name: String, value: [String: Any])] = []
        collectWindowCandidates(payload, inheritedName: nil, into: &candidates, depth: 0)
        var windows: [UsageWindow] = []
        var seen: Set<String> = []
        for candidate in candidates {
            guard let window = compatibleWindow(candidate.value, fallbackName: candidate.name, now: now),
                  seen.insert(window.metricID).inserted else { continue }
            windows.append(window)
        }
        guard !windows.isEmpty else {
            throw AdditionalProviderError.noResettableQuota(account.displayName)
        }
        windows.sort {
            if $0.displayOrder != $1.displayOrder { return $0.displayOrder < $1.displayOrder }
            return $0.resetsAt < $1.resetsAt
        }
        let primary = windows.first { $0.kind == .fiveHour }
        let secondary = windows.first { $0.kind == .weekly }
        let extra = windows.filter { $0 != primary && $0 != secondary }
        let plan = AdditionalProviderParsing.firstString(payload, keys: [
            "plan", "planName", "plan_name", "subscription", "tier", "groupName", "group_name",
        ]) ?? account.plan
        return UsageSnapshot(
            accountID: account.id,
            providerName: account.displayName,
            accountName: account.displayName,
            plan: plan,
            primary: primary,
            secondary: secondary,
            availableResetCount: 0,
            resetCredits: [],
            fetchedAt: now,
            extraWindows: extra.isEmpty ? nil : Array(extra.prefix(20))
        )
    }

    private static func collectWindowCandidates(
        _ root: [String: Any],
        inheritedName: String?,
        into result: inout [(name: String, value: [String: Any])],
        depth: Int
    ) {
        guard depth <= 6 else { return }
        let hasPercent = AdditionalProviderParsing.percentUsed(root) != nil
        let hasReset = AdditionalProviderParsing.firstDate(root, keys: [
            "resetAt", "reset_at", "resetsAt", "resets_at", "resetTime", "reset_time",
            "nextResetAt", "next_reset_at", "periodEnd", "period_end", "expiresAt", "expires_at",
        ]) != nil
        if hasPercent, hasReset {
            result.append((inheritedName ?? "limit", root))
        }
        for (key, value) in root {
            if let child = value as? [String: Any] {
                collectWindowCandidates(child, inheritedName: key, into: &result, depth: depth + 1)
            } else if let children = value as? [[String: Any]] {
                for child in children {
                    collectWindowCandidates(child, inheritedName: key, into: &result, depth: depth + 1)
                }
            }
        }
    }

    private static func compatibleWindow(
        _ root: [String: Any], fallbackName: String, now: Date
    ) -> UsageWindow? {
        guard let percent = AdditionalProviderParsing.percentUsed(root),
              let reset = AdditionalProviderParsing.firstDate(root, keys: [
                  "resetAt", "reset_at", "resetsAt", "resets_at", "resetTime", "reset_time",
                  "nextResetAt", "next_reset_at", "periodEnd", "period_end", "expiresAt", "expires_at",
              ]), reset > now else { return nil }
        let title = AdditionalProviderParsing.firstString(root, keys: [
            "title", "displayName", "display_name", "name", "label", "scope", "id",
        ]) ?? fallbackName.replacingOccurrences(of: "_", with: " ").capitalized
        let rawKind = AdditionalProviderParsing.firstString(root, keys: ["kind", "type", "window"])
            ?? fallbackName
        let normalized = "\(rawKind) \(title)".lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let explicitMinutes = AdditionalProviderParsing.integer(root["windowMinutes"] ?? root["window_minutes"])
        let minutes: Int?
        let kind: UsageWindowKind
        if explicitMinutes == 300 || normalized.contains("5h") || normalized.contains("five hour") {
            minutes = 300
            kind = .fiveHour
        } else if explicitMinutes == 10_080 || normalized.contains("weekly") || normalized.contains("7d") {
            minutes = 10_080
            kind = .weekly
        } else {
            minutes = explicitMinutes
            kind = .additional
        }
        let rawID = AdditionalProviderParsing.firstString(root, keys: ["id", "metricID", "metric_id"])
            ?? fallbackName
        return UsageWindow(
            title: title,
            usedPercent: percent,
            resetsAt: reset,
            windowMinutes: minutes,
            kind: kind,
            identifier: "compatible:\(AdditionalProviderParsing.identifier(rawID))"
        )
    }
}

private func pendingAccount(providerID: ProviderID, name: String) -> MonitoredAccount {
    MonitoredAccount(
        id: UUID(),
        providerID: providerID,
        displayName: name,
        workspaceID: "pending",
        plan: nil,
        addedAt: .now
    )
}
