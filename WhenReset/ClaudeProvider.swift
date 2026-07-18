import CryptoKit
import Foundation
import Security

struct ClaudeOAuthLink: Sendable {
    let authorizationURL: URL
    let codeVerifier: String
    let state: String
}

enum ClaudeOAuthError: LocalizedError {
    case invalidAuthorizationCode
    case stateMismatch
    case missingRefreshToken

    var errorDescription: String? {
        switch self {
        case .invalidAuthorizationCode:
            "Paste the authorization code shown after signing in to Claude."
        case .stateMismatch:
            "Claude returned a code for a different sign-in attempt. Start the link again."
        case .missingRefreshToken:
            "Claude did not return a refresh token. Link the account again."
        }
    }
}

struct ClaudeProvider {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    static let requestedScope = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    private static let authorizationURL = URL(string: "https://claude.com/cai/oauth/authorize")!
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private let session = URLSession.shared

    func beginLink() throws -> ClaudeOAuthLink {
        let verifier = Self.randomBase64URL(byteCount: 64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomBase64URL(byteCount: 32)
        var components = URLComponents(url: Self.authorizationURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: Self.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "scope", value: Self.requestedScope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state)
        ]
        guard let url = components.url else { throw ProviderError.invalidResponse }
        return ClaudeOAuthLink(authorizationURL: url, codeVerifier: verifier, state: state)
    }

    func finishLink(_ link: ClaudeOAuthLink, pastedCode: String) async throws -> LinkedIdentity {
        let parsed = try Self.parseAuthorizationCode(pastedCode)
        if let returnedState = parsed.state, returnedState != link.state {
            throw ClaudeOAuthError.stateMismatch
        }
        let response = try await tokenRequest([
            "grant_type": "authorization_code",
            "code": parsed.code,
            "redirect_uri": Self.redirectURI,
            "client_id": Self.clientID,
            "code_verifier": link.codeVerifier,
            "state": parsed.state ?? link.state
        ])
        guard let refreshToken = response.refreshToken, !refreshToken.isEmpty else {
            throw ClaudeOAuthError.missingRefreshToken
        }
        let name = response.account?.displayName
            ?? response.account?.emailAddress
            ?? response.organization?.name
            ?? "Claude account"
        let workspaceID = response.account?.uuid ?? response.organization?.uuid ?? UUID().uuidString
        let credentials = AccountCredentials(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            idToken: "",
            expiresAt: response.expirationDate
        )
        return LinkedIdentity(workspaceID: workspaceID, displayName: name,
                              email: response.account?.emailAddress,
                              plan: response.subscriptionType, credentials: credentials)
    }

    func refreshedIfNeeded(_ credentials: AccountCredentials) async throws -> AccountCredentials {
        guard let expiresAt = credentials.expiresAt,
              expiresAt.timeIntervalSinceNow < 5 * 60 else { return credentials }
        guard !credentials.refreshToken.isEmpty else { throw ClaudeOAuthError.missingRefreshToken }
        let response = try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "client_id": Self.clientID
        ])
        return AccountCredentials(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? credentials.refreshToken,
            idToken: credentials.idToken,
            expiresAt: response.expirationDate
        )
    }

    func fetchUsage(account: MonitoredAccount, credentials: AccountCredentials) async throws -> UsageSnapshot {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw ProviderError.server(code, String(data: data, encoding: .utf8) ?? "")
        }
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return UsageSnapshot(
            accountID: account.id,
            providerName: "Claude",
            accountName: account.displayName,
            plan: account.plan,
            primary: window(root["five_hour"], title: "5h limit", minutes: 300),
            secondary: window(root["seven_day"], title: "Weekly limit", minutes: 10_080),
            availableResetCount: 0,
            resetCredits: [],
            fetchedAt: .now
        )
    }

    private func tokenRequest(_ body: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw ProviderError.server(code, Self.safeServerMessage(data))
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func window(_ value: Any?, title: String, minutes: Int) -> UsageWindow? {
        guard let object = value as? [String: Any],
              let used = (object["utilization"] as? NSNumber)?.doubleValue,
              let reset = ChatGPTProvider.date(object["resets_at"]) else { return nil }
        let kind: UsageWindowKind = minutes == 300 ? .fiveHour : .weekly
        return UsageWindow(title: title, usedPercent: used, resetsAt: reset, windowMinutes: minutes,
                           kind: kind, identifier: minutes == 300 ? "five_hour" : "weekly")
    }

    private static func parseAuthorizationCode(_ input: String) throws -> (code: String, state: String?) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil,
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
           !code.isEmpty {
            return (code, components.queryItems?.first(where: { $0.name == "state" })?.value)
        }
        let pieces = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = pieces.first, !first.isEmpty else { throw ClaudeOAuthError.invalidAuthorizationCode }
        let code = String(first).removingPercentEncoding ?? String(first)
        let state = pieces.count == 2 ? (String(pieces[1]).removingPercentEncoding ?? String(pieces[1])) : nil
        return (code, state?.isEmpty == true ? nil : state)
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func safeServerMessage(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Claude OAuth request failed."
        }
        if let description = json["error_description"] as? String { return description }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let error = json["error"] as? String { return error }
        return "Claude OAuth request failed."
    }
}

private struct TokenResponse: Decodable {
    struct Account: Decodable {
        var uuid: String?
        var emailAddress: String?
        var displayName: String?

        enum CodingKeys: String, CodingKey {
            case uuid
            case emailAddress = "email_address"
            case displayName = "display_name"
        }
    }

    struct Organization: Decodable {
        var uuid: String?
        var name: String?
    }

    var accessToken: String
    var refreshToken: String?
    var expiresIn: TimeInterval?
    var expiresAt: TimeInterval?
    var subscriptionType: String?
    var account: Account?
    var organization: Organization?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
        case subscriptionType = "subscription_type"
        case account, organization
    }

    var expirationDate: Date {
        if let expiresAt {
            return Date(timeIntervalSince1970: expiresAt > 10_000_000_000 ? expiresAt / 1_000 : expiresAt)
        }
        return .now.addingTimeInterval(expiresIn ?? 8 * 60 * 60)
    }
}
