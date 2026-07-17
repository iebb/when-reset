import Foundation

struct DeviceLink: Sendable {
    let verificationURL: URL
    let userCode: String
    let deviceAuthID: String
    let interval: Duration
}

struct LinkedIdentity: Sendable {
    let workspaceID: String
    let displayName: String
    let plan: String?
    let credentials: AccountCredentials
}

enum ProviderError: LocalizedError {
    case invalidResponse, missingAccount, server(Int, String)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The provider returned an unreadable response."
        case .missingAccount: "The linked token did not include a ChatGPT workspace."
        case let .server(code, message): "Server error \(code): \(message)"
        }
    }
}

struct ChatGPTProvider {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let session = URLSession.shared

    func refreshedIfNeeded(_ credentials: AccountCredentials) async throws -> AccountCredentials {
        let expiration = (decodeJWT(credentials.accessToken)["exp"] as? NSNumber)?.doubleValue
        guard expiration == nil || Date(timeIntervalSince1970: expiration!).timeIntervalSinceNow < 5 * 60 else { return credentials }
        var components = URLComponents()
        components.queryItems = [
            .init(name: "client_id", value: Self.clientID),
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: credentials.refreshToken)
        ]
        let data = try await request(URL(string: "https://auth.openai.com/oauth/token")!, method: "POST",
                                     body: Data((components.percentEncodedQuery ?? "").utf8),
                                     contentType: "application/x-www-form-urlencoded")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let access = json?["access_token"] as? String else { throw ProviderError.invalidResponse }
        return AccountCredentials(accessToken: access,
                                  refreshToken: (json?["refresh_token"] as? String) ?? credentials.refreshToken,
                                  idToken: (json?["id_token"] as? String) ?? credentials.idToken)
    }

    func beginLink() async throws -> DeviceLink {
        let body = try JSONSerialization.data(withJSONObject: ["client_id": Self.clientID])
        let data = try await request(URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!, method: "POST", body: body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = json?["device_auth_id"] as? String,
              let code = (json?["user_code"] ?? json?["usercode"]) as? String else { throw ProviderError.invalidResponse }
        let seconds = Double(json?["interval"] as? String ?? "5") ?? 5
        return DeviceLink(verificationURL: URL(string: "https://auth.openai.com/codex/device")!, userCode: code, deviceAuthID: id, interval: .seconds(seconds))
    }

    func finishLink(_ link: DeviceLink) async throws -> LinkedIdentity {
        let deadline = Date.now.addingTimeInterval(15 * 60)
        while Date.now < deadline {
            let body = try JSONSerialization.data(withJSONObject: ["device_auth_id": link.deviceAuthID, "user_code": link.userCode])
            do {
                let data = try await request(URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!, method: "POST", body: body, pendingCodes: [403, 404])
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let code = json?["authorization_code"] as? String,
                      let verifier = json?["code_verifier"] as? String else { throw ProviderError.invalidResponse }
                return try await exchange(code: code, verifier: verifier)
            } catch ProviderError.server(let code, _) where code == 403 || code == 404 {
                try await Task.sleep(for: link.interval)
            } catch let error as URLError where Self.isTransientPollingError(error.code) {
                try Task.checkCancellation()
                try await Task.sleep(for: link.interval)
            }
        }
        throw ProviderError.server(408, "Linking timed out")
    }

    private static func isTransientPollingError(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed:
            true
        default:
            false
        }
    }

    private func exchange(code: String, verifier: String) async throws -> LinkedIdentity {
        let redirect = "https://auth.openai.com/deviceauth/callback"
        var components = URLComponents()
        components.queryItems = [
            .init(name: "grant_type", value: "authorization_code"), .init(name: "code", value: code),
            .init(name: "redirect_uri", value: redirect), .init(name: "client_id", value: Self.clientID),
            .init(name: "code_verifier", value: verifier)
        ]
        let body = Data((components.percentEncodedQuery ?? "").utf8)
        let data = try await request(URL(string: "https://auth.openai.com/oauth/token")!, method: "POST", body: body, contentType: "application/x-www-form-urlencoded")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let access = json?["access_token"] as? String, let refresh = json?["refresh_token"] as? String,
              let idToken = json?["id_token"] as? String else { throw ProviderError.invalidResponse }
        return try linkedIdentity(accessToken: access, refreshToken: refresh, idToken: idToken)
    }

    func linkedIdentity(accessToken: String, refreshToken: String, idToken: String) throws -> LinkedIdentity {
        let claims = decodeJWT(idToken)
        let profile = claims["https://api.openai.com/profile"] as? [String: Any]
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        let workspace = (auth?["chatgpt_account_id"] as? String) ?? (claims["chatgpt_account_id"] as? String)
        guard let workspace, !workspace.isEmpty else { throw ProviderError.missingAccount }
        let name = (profile?["name"] as? String)
            ?? (profile?["email"] as? String)
            ?? (claims["email"] as? String)
            ?? "ChatGPT account"
        return LinkedIdentity(workspaceID: workspace, displayName: name, plan: auth?["chatgpt_plan_type"] as? String,
                              credentials: .init(accessToken: accessToken, refreshToken: refreshToken, idToken: idToken))
    }

    func fetchUsage(account: MonitoredAccount, credentials: AccountCredentials) async throws -> UsageSnapshot {
        async let usageData = authenticatedGet("https://chatgpt.com/backend-api/wham/usage", account: account, token: credentials.accessToken)
        async let creditData = authenticatedGet("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", account: account, token: credentials.accessToken)
        return try parse(account: account, usage: await usageData, credits: await creditData)
    }

    private func authenticatedGet(_ url: String, account: MonitoredAccount, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(account.workspaceID, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue("WhenReset/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw ProviderError.server(code, String(data: data, encoding: .utf8) ?? "") }
        return data
    }

    func parse(account: MonitoredAccount, usage: Data, credits: Data) throws -> UsageSnapshot {
        let root = try JSONSerialization.jsonObject(with: usage) as? [String: Any] ?? [:]
        let limit = root["rate_limit"] as? [String: Any] ?? root
        let details = (try? JSONSerialization.jsonObject(with: credits)) as? [String: Any] ?? [:]
        let creditObjects = details["credits"] as? [[String: Any]] ?? []
        let parsedCredits = creditObjects.map { item in
            ResetCredit(id: (item["id"] as? String) ?? UUID().uuidString,
                        expiresAt: Self.date(item["expires_at"] ?? item["expiresAt"]),
                        status: item["status"] as? String,
                        grantedAt: Self.date(item["granted_at"] ?? item["grantedAt"]))
        }.filter(\.isAvailable)
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        let usageCredit = root["rate_limit_reset_credits"] as? [String: Any]
        let count = (details["available_count"] as? NSNumber)?.intValue
            ?? (usageCredit?["available_count"] as? NSNumber)?.intValue
            ?? parsedCredits.count
        let additionalLimits = root["additional_rate_limits"] as? [[String: Any]] ?? []
        let extraWindows = additionalLimits.flatMap { item -> [UsageWindow] in
            let rateLimit = item["rate_limit"] as? [String: Any] ?? [:]
            let title = (item["limit_name"] as? String) ?? "Additional limit"
            let feature = (item["metered_feature"] as? String) ?? title
            return [
                Self.window(rateLimit["primary_window"] ?? rateLimit["primary"], title: title,
                            kind: .additional, identifier: "additional:\(feature):primary"),
                Self.window(rateLimit["secondary_window"] ?? rateLimit["secondary"], title: title,
                            kind: .additional, identifier: "additional:\(feature):secondary")
            ].compactMap { $0 }
        }
        return UsageSnapshot(accountID: account.id, providerName: account.providerID.displayName,
                             accountName: account.displayName, plan: root["plan_type"] as? String ?? account.plan,
                             primary: Self.window(limit["primary_window"] ?? limit["primary"]),
                             secondary: Self.window(limit["secondary_window"] ?? limit["secondary"]),
                             availableResetCount: count, resetCredits: parsedCredits, fetchedAt: .now,
                             extraWindows: extraWindows)
    }

    static func window(_ value: Any?, title fallbackTitle: String = "Usage limit",
                       kind suppliedKind: UsageWindowKind? = nil, identifier: String? = nil) -> UsageWindow? {
        guard let json = value as? [String: Any] else { return nil }
        let used = (json["used_percent"] as? NSNumber)?.doubleValue ?? (json["usedPercent"] as? NSNumber)?.doubleValue
        let reset = date(json["reset_at"] ?? json["resets_at"] ?? json["resetsAt"])
            ?? (json["reset_after_seconds"] as? NSNumber).map { Date.now.addingTimeInterval($0.doubleValue) }
        guard let used, let reset else { return nil }
        let mins = (json["limit_window_seconds"] as? NSNumber).map { $0.intValue / 60 }
            ?? (json["window_minutes"] as? NSNumber)?.intValue
            ?? (json["windowDurationMins"] as? NSNumber)?.intValue
        let title = (json["limit_name"] as? String) ?? fallbackTitle
        let kind = suppliedKind ?? {
            switch mins {
            case 300: return UsageWindowKind.fiveHour
            case 10_080: return UsageWindowKind.weekly
            default: return nil
            }
        }()
        return UsageWindow(title: title, usedPercent: used, resetsAt: reset, windowMinutes: mins,
                           kind: kind, identifier: identifier)
    }

    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        if let string = value as? String {
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractionalFormatter.date(from: string)
                ?? ISO8601DateFormatter().date(from: string)
                ?? Double(string).map(Date.init(timeIntervalSince1970:))
        }
        return nil
    }

    private func decodeJWT(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return [:] }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    private func request(_ url: URL, method: String, body: Data, contentType: String = "application/json", pendingCodes: Set<Int> = []) async throws -> Data {
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw ProviderError.server(code, String(data: data, encoding: .utf8) ?? "") }
        return data
    }
}
