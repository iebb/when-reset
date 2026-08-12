import XCTest
@testable import WhenReset

final class AdditionalProvidersTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testSyntheticBuildsRollingAndWeeklyWindows() throws {
        let data = Data(#"""
        {
          "data": {
            "plan": "Standard",
            "rollingFiveHourLimit": {
              "max": 100,
              "remaining": 75,
              "nextTickAt": "2030-01-01T01:00:00Z"
            },
            "weeklyTokenLimit": {
              "maxCredits": "$100.00",
              "remainingCredits": "$40.00",
              "nextRegenAt": "2030-01-07T00:00:00Z"
            }
          }
        }
        """#.utf8)
        let account = makeAccount(.synthetic, name: "Synthetic account")

        let snapshot = try SyntheticProvider.parseUsage(account: account, data: data, now: now)

        XCTAssertEqual(snapshot.plan, "Standard")
        XCTAssertEqual(snapshot.primary?.metricID, "synthetic:five_hour")
        XCTAssertEqual(snapshot.primary?.usedPercent, 25)
        XCTAssertEqual(snapshot.secondary?.metricID, "synthetic:weekly")
        XCTAssertEqual(snapshot.secondary?.usedPercent, 60)
    }

    func testWarpParsesRequestCreditWindow() throws {
        let data = Data(#"""
        {
          "data": {
            "user": {
              "__typename": "UserOutput",
              "user": {
                "requestLimitInfo": {
                  "isUnlimited": false,
                  "nextRefreshTime": "2030-02-01T00:00:00Z",
                  "requestLimit": 1000,
                  "requestsUsedSinceLastRefresh": 250
                }
              }
            }
          }
        }
        """#.utf8)
        let snapshot = try WarpProvider.parseUsage(
            account: makeAccount(.warp, name: "Warp account"),
            data: data,
            now: now
        )

        XCTAssertEqual(snapshot.primary?.metricID, "warp:monthly_credits")
        XCTAssertEqual(snapshot.primary?.usedPercent, 25)
        XCTAssertEqual(snapshot.primary?.kind, .additional)
    }

    func testOllamaSettingsHTMLBuildsSessionAndWeeklyWindows() throws {
        let html = #"""
        <span>Cloud Usage</span><span>Pro</span>
        <div id="header-email">person@example.com</div>
        <section>Session usage <b>23% used</b><time datetime="2030-03-01T01:00:00Z"></time></section>
        <section>Weekly usage <b>61% used</b><time datetime="2030-03-07T00:00:00Z"></time></section>
        """#
        let snapshot = try OllamaCloudProvider.parseUsage(
            account: makeAccount(.ollamaCloud, name: "Ollama Cloud account"),
            data: Data(html.utf8),
            now: now
        )

        XCTAssertEqual(snapshot.accountName, "person@example.com")
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.primary?.usedPercent, 23)
        XCTAssertEqual(snapshot.secondary?.usedPercent, 61)
    }

    func testAntigravityParsesModelQuotaBuckets() throws {
        let data = Data(#"""
        {
          "buckets": [
            {
              "modelId": "gemini-3-pro-5h",
              "remainingFraction": 0.25,
              "resetTime": "2030-04-01T05:00:00Z"
            },
            {
              "modelId": "claude-sonnet-weekly",
              "remaining": { "remainingFraction": 0.8 },
              "resetTime": "2030-04-07T00:00:00Z"
            }
          ]
        }
        """#.utf8)
        let snapshot = try AntigravityProvider.parseUsage(
            account: makeAccount(.antigravity, name: "Antigravity account"),
            data: data,
            now: now
        )

        XCTAssertEqual(snapshot.primary?.metricID, "antigravity:gemini:fiveHour")
        XCTAssertEqual(snapshot.primary?.usedPercent, 75)
        XCTAssertEqual(snapshot.secondary?.metricID, "antigravity:claude:weekly")
        XCTAssertEqual(snapshot.secondary?.usedPercent ?? -1, 20, accuracy: 0.001)
    }

    func testAntigravityCallbackRequiresExactLocalhostURLAndUniqueState() throws {
        let callback = try AntigravityProvider.callback(
            "http://localhost:51121/oauth-callback?code=sample-code&state=expected",
            expectedState: "expected"
        )

        XCTAssertEqual(callback.code, "sample-code")
        XCTAssertEqual(callback.state, "expected")
        XCTAssertThrowsError(try AntigravityProvider.callback(
            "http://localhost:51121/oauth-callback?code=one&state=expected&state=expected",
            expectedState: "expected"
        ))
        XCTAssertThrowsError(try AntigravityProvider.callback(
            "https://example.com/oauth-callback?code=one&state=expected",
            expectedState: "expected"
        ))
    }

    func testAntigravityAuthorizationUsesCallerSuppliedOAuthConfiguration() throws {
        let provider = AntigravityProvider()
        let link = try provider.beginLink(
            clientID: "example-client",
            clientSecret: "example-configuration-value"
        )
        let queryItems = URLComponents(
            url: link.authorizationURL,
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []

        XCTAssertEqual(queryItems.first { $0.name == "client_id" }?.value, "example-client")
        XCTAssertNil(queryItems.first { $0.name == "client_secret" })
        XCTAssertEqual(link.clientID, "example-client")
        XCTAssertEqual(link.clientSecret, "example-configuration-value")
        XCTAssertThrowsError(try provider.beginLink(clientID: "", clientSecret: "value"))
        XCTAssertThrowsError(try provider.beginLink(clientID: "value", clientSecret: ""))
    }

    func testCompatibleCanonicalWindows() throws {
        let data = Data(#"""
        {
          "plan": "Team",
          "windows": [
            {
              "id": "session",
              "title": "Session limit",
              "kind": "five_hour",
              "remaining_percent": 70,
              "resets_at": 1893459600,
              "window_minutes": 300
            },
            {
              "id": "week",
              "title": "Weekly limit",
              "used_percent": 45,
              "resets_at": 1893974400,
              "window_minutes": 10080
            }
          ]
        }
        """#.utf8)
        let snapshot = try CompatibleAPIProvider.parseUsage(
            account: makeAccount(.compatibleAPI, name: "My gateway"),
            data: data,
            now: now
        )

        XCTAssertEqual(snapshot.providerName, "My gateway")
        XCTAssertEqual(snapshot.plan, "Team")
        XCTAssertEqual(snapshot.primary?.usedPercent, 30)
        XCTAssertEqual(snapshot.secondary?.usedPercent, 45)
    }

    func testCompatibleParsesSub2APIStyleNestedLimits() throws {
        let data = Data(#"""
        {
          "data": {
            "group_name": "Claude pool",
            "rate_limits": {
              "five_hour": { "limit": 100, "used": 20, "reset_at": 1893459600 },
              "weekly": { "limit": 1000, "remaining": 600, "reset_at": 1893974400 }
            }
          }
        }
        """#.utf8)
        let snapshot = try CompatibleAPIProvider.parseUsage(
            account: makeAccount(.compatibleAPI, name: "Sub2API"),
            data: data,
            now: now
        )

        XCTAssertEqual(snapshot.plan, "Claude pool")
        XCTAssertEqual(snapshot.primary?.usedPercent, 20)
        XCTAssertEqual(snapshot.secondary?.usedPercent, 40)
    }

    func testCompatibleEndpointRequiresHTTPSExceptLoopback() throws {
        XCTAssertEqual(
            try CompatibleAPIProvider.normalizedEndpoint("https://quota.example/v1/usage").host,
            "quota.example"
        )
        XCTAssertEqual(
            try CompatibleAPIProvider.normalizedEndpoint("http://127.0.0.1:8080/v1/usage").port,
            8080
        )
        XCTAssertThrowsError(try CompatibleAPIProvider.normalizedEndpoint("http://quota.example/usage"))
        XCTAssertThrowsError(try CompatibleAPIProvider.normalizedEndpoint("https://user@quota.example/usage"))
        XCTAssertThrowsError(try CompatibleAPIProvider.normalizedEndpoint("https://quota.example/usage?target=x"))
    }

    func testOpenAIOrganizationCostsBuildBudgetBalance() throws {
        let data = Data(#"""
        {
          "object": "page",
          "data": [
            {"results": [{"amount": {"value": 1.25, "currency": "usd"}}]},
            {"results": [{"amount": {"value": 0.75, "currency": "usd"}}]}
          ]
        }
        """#.utf8)

        let snapshot = try OpenAIAPIProvider.parseUsage(
            account: makeAccount(.openAIAPI, name: "OpenAI API organization"),
            data: data,
            monthlyBudget: 10,
            now: now
        )

        XCTAssertEqual(snapshot.apiBalance?.spent, 2)
        XCTAssertEqual(snapshot.apiBalance?.remaining, 8)
        XCTAssertEqual(snapshot.apiBalance?.limit, 10)
        XCTAssertEqual(snapshot.apiBalance?.currencyCode, "USD")
        XCTAssertTrue(snapshot.usageWindows.isEmpty)
    }

    func testAnthropicOrganizationCostsConvertCentsToDollars() throws {
        let data = Data(#"""
        {
          "data": [
            {"results": [
              {"amount": "123", "currency": "USD"},
              {"amount": {"value": "77", "currency": "USD"}}
            ]}
          ]
        }
        """#.utf8)

        let snapshot = try AnthropicAPIProvider.parseUsage(
            account: makeAccount(.anthropicAPI, name: "Anthropic API organization"),
            data: data,
            monthlyBudget: nil,
            now: now
        )

        XCTAssertEqual(snapshot.apiBalance?.spent ?? -1, 2, accuracy: 0.001)
        XCTAssertNil(snapshot.apiBalance?.remaining)
        XCTAssertEqual(snapshot.apiBalance?.title, "API spend this month")
    }

    func testNewAPICompatibleBillingBuildsActualKeyBalance() throws {
        let subscription = Data(#"""
        {"hard_limit_usd": 50, "access_until": 1893456000}
        """#.utf8)
        let usage = Data(#"{"total_usage": 1250}"#.utf8)

        let snapshot = try NewAPIProvider.parseUsage(
            account: makeAccount(.newAPI, name: "My gateway"),
            subscriptionData: subscription,
            usageData: usage,
            now: now
        )

        XCTAssertEqual(snapshot.apiBalance?.spent ?? -1, 12.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.apiBalance?.remaining ?? -1, 37.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.apiBalance?.title, "API key balance")
        XCTAssertNotNil(snapshot.apiBalance?.accessExpiresAt)
    }

    func testNewAPIBaseURLRequiresHTTPSExceptLoopback() throws {
        XCTAssertEqual(
            try NewAPIProvider.normalizedBaseURL("https://api.example.com/v1/").absoluteString,
            "https://api.example.com/v1"
        )
        XCTAssertEqual(
            try NewAPIProvider.normalizedBaseURL("http://localhost:3000").port,
            3000
        )
        XCTAssertThrowsError(try NewAPIProvider.normalizedBaseURL("http://api.example.com"))
        XCTAssertThrowsError(try NewAPIProvider.normalizedBaseURL("https://key@api.example.com"))
    }

    func testOpenRouterParsesResettingAPIKeyLimit() throws {
        let data = Data(#"""
        {
          "data": {
            "creator_user_id": "user_stable",
            "is_free_tier": false,
            "label": "sk-or-v1-example",
            "limit": 100,
            "limit_remaining": 74.5,
            "limit_reset": "monthly",
            "usage": 25.5,
            "usage_monthly": 25.5,
            "expires_at": "2030-12-31T23:59:59Z"
          }
        }
        """#.utf8)
        let account = makeAccount(.openRouter, name: "OpenRouter account")

        let snapshot = try OpenRouterProvider.parseUsage(account: account, data: data, now: now)

        XCTAssertEqual(snapshot.apiBalance?.title, "Monthly API key limit")
        XCTAssertEqual(snapshot.apiBalance?.spent, 25.5)
        XCTAssertEqual(snapshot.apiBalance?.remaining, 74.5)
        XCTAssertEqual(snapshot.apiBalance?.limit, 100)
        XCTAssertEqual(snapshot.apiBalance?.kind, .budget)
        XCTAssertNotNil(snapshot.apiBalance?.periodEnd)
        XCTAssertNotNil(snapshot.apiBalance?.accessExpiresAt)
        XCTAssertTrue(snapshot.usageWindows.isEmpty)
    }

    func testOpenRouterStableIdentityUsesCreatorUserID() throws {
        let data = Data(#"""
        {"data":{"creator_user_id":"user_stable","usage":1,"limit":10}}
        """#.utf8)
        let credentials = AccountCredentials(
            accessToken: "sk-or-v1-example-value",
            refreshToken: "",
            idToken: ""
        )

        let identity = try OpenRouterProvider.linkedIdentity(
            data: data,
            credentials: credentials
        )

        XCTAssertEqual(identity.workspaceID, "openrouter-user-360ebab8c18fb2b3")
        XCTAssertFalse(identity.workspaceID.contains("user_stable"))
        XCTAssertEqual(identity.credentials, credentials)
    }

    func testOpenRouterRepresentsKeyWithoutSpendingLimitAsUnlimited() throws {
        let data = Data(#"""
        {"data":{"creator_user_id":"user_stable","usage":12.5,"limit":null,"limit_remaining":null}}
        """#.utf8)
        let snapshot = try OpenRouterProvider.parseUsage(
            account: makeAccount(.openRouter, name: "OpenRouter account"),
            data: data,
            now: now
        )

        XCTAssertTrue(snapshot.apiBalance?.isUnlimited == true)
        XCTAssertNil(snapshot.apiBalance?.limit)
        XCTAssertNil(snapshot.apiBalance?.remaining)
        XCTAssertEqual(snapshot.apiBalance?.spent, 12.5)
    }

    func testFireworksDiscoversOfficialAccountIdentity() throws {
        let data = Data(#"""
        {
          "accounts": [{
            "name": "accounts/team-alpha",
            "displayName": "Production AI",
            "email": "owner@example.com"
          }],
          "totalSize": 1
        }
        """#.utf8)
        let profile = try FireworksAIProvider.parseSingleAccount(data)
        let credentials = AccountCredentials(
            accessToken: "fireworks-example-key",
            refreshToken: "",
            idToken: "",
            projectID: profile.resourceName
        )
        let identity = FireworksAIProvider.linkedIdentity(
            profile: profile,
            credentials: credentials
        )

        XCTAssertEqual(profile.resourceName, "accounts/team-alpha")
        XCTAssertEqual(profile.displayName, "Production AI")
        XCTAssertEqual(identity.workspaceID, "accounts/team-alpha")
        XCTAssertEqual(identity.email, "owner@example.com")
    }

    func testFireworksRequiresAccountIDWhenKeyExposesMultipleAccounts() throws {
        let data = Data(#"""
        {"accounts":[{"name":"accounts/one"},{"name":"accounts/two"}]}
        """#.utf8)

        XCTAssertThrowsError(try FireworksAIProvider.parseSingleAccount(data)) { error in
            XCTAssertTrue(error.localizedDescription.contains("multiple Fireworks accounts"))
        }
        XCTAssertEqual(try FireworksAIProvider.normalizedAccountID("accounts/team-alpha"),
                       "team-alpha")
        XCTAssertThrowsError(try FireworksAIProvider.normalizedAccountID("../team-alpha"))
        XCTAssertThrowsError(try FireworksAIProvider.normalizedAccountID(".."))
        XCTAssertThrowsError(try FireworksAIProvider.normalizedAccountID(".team-alpha"))
        XCTAssertThrowsError(try FireworksAIProvider.normalizedAccountID("-team-alpha"))
    }

    func testFireworksParsesMonthlySpendingQuota() throws {
        let data = Data(#"""
        {
          "quotas": [{
            "name": "monthly-spend-usd",
            "value": "200",
            "maxValue": "5000",
            "usage": 72.25,
            "updateTime": "2030-01-01T00:00:00Z"
          }]
        }
        """#.utf8)
        let snapshot = try FireworksAIProvider.parseUsage(
            account: makeAccount(.fireworksAI, name: "Fireworks AI account"),
            data: data,
            now: now
        )

        XCTAssertEqual(snapshot.apiBalance?.title, "Monthly API budget")
        XCTAssertEqual(snapshot.apiBalance?.spent, 72.25)
        XCTAssertEqual(snapshot.apiBalance?.limit, 200)
        XCTAssertEqual(snapshot.apiBalance?.remaining, 127.75)
        XCTAssertEqual(snapshot.apiBalance?.kind, .budget)
    }

    func testDeepSeekParsesWalletBalanceWithoutInventingReset() throws {
        let data = Data(#"""
        {
          "is_available": true,
          "balance_infos": [
            {"currency":"CNY","total_balance":"110.00"},
            {"currency":"USD","total_balance":"42.75","granted_balance":"2.75"}
          ]
        }
        """#.utf8)
        let snapshot = try DeepSeekProvider.parseUsage(
            account: makeAccount(.deepSeek, name: "DeepSeek API account"),
            data: data,
            now: now
        )

        XCTAssertEqual(snapshot.apiBalance?.title, "API wallet balance")
        XCTAssertEqual(snapshot.apiBalance?.remaining, 42.75)
        XCTAssertEqual(snapshot.apiBalance?.currencyCode, "USD")
        XCTAssertEqual(snapshot.apiBalance?.kind, .wallet)
        XCTAssertNil(snapshot.apiBalance?.limit)
        XCTAssertNil(snapshot.apiBalance?.periodEnd)
        XCTAssertTrue(snapshot.usageWindows.isEmpty)
    }

    func testPoeParsesPointWalletWithoutCurrencyOrReset() throws {
        let data = Data(#"{"current_point_balance":295932027}"#.utf8)
        let snapshot = try PoeProvider.parseUsage(
            account: makeAccount(.poe, name: "Poe API account"),
            data: data,
            now: now
        )

        XCTAssertEqual(snapshot.apiBalance?.title, "API point balance")
        XCTAssertEqual(snapshot.apiBalance?.remaining, 295_932_027)
        XCTAssertEqual(snapshot.apiBalance?.kind, .wallet)
        XCTAssertEqual(snapshot.apiBalance?.unitLabel, "points")
        XCTAssertNil(snapshot.apiBalance?.limit)
        XCTAssertNil(snapshot.apiBalance?.periodEnd)
        XCTAssertTrue(snapshot.usageWindows.isEmpty)
    }

    func testGrokParsesCurrentWeeklyCreditPeriod() throws {
        let data = Data(#"""
        {
          "subscriptionTier": "supergrok_heavy",
          "config": {
            "creditUsagePercent": 42.5,
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2030-01-01T00:00:00Z",
              "end": "2030-01-08T00:00:00Z"
            }
          }
        }
        """#.utf8)

        let snapshot = try GrokProvider.parseUsage(
            account: makeAccount(.grok, name: "Grok account"),
            data: data,
            now: now
        )

        XCTAssertEqual(snapshot.plan, "SuperGrok Heavy")
        XCTAssertEqual(snapshot.primary?.metricID, "grok:weekly")
        XCTAssertEqual(snapshot.primary?.windowMinutes, 10_080)
        XCTAssertEqual(snapshot.primary?.kind, .weekly)
        XCTAssertEqual(snapshot.primary?.usedPercent ?? -1, 42.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.primary?.remainingPercent ?? -1, 57.5, accuracy: 0.001)
    }

    func testGrokFallsBackToLegacyMonthlyBillingShape() throws {
        let data = Data(#"""
        {
          "config": {
            "monthlyLimit": { "val": 2000 },
            "used": { "val": 500 },
            "billingPeriodStart": "2030-02-01T00:00:00Z",
            "billingPeriodEnd": "2030-03-01T00:00:00Z"
          }
        }
        """#.utf8)

        let snapshot = try GrokProvider.parseUsage(
            account: makeAccount(.grok, name: "Grok account"),
            data: data,
            now: now
        )

        XCTAssertEqual(snapshot.primary?.metricID, "grok:monthly")
        XCTAssertEqual(snapshot.primary?.kind, .additional)
        XCTAssertEqual(snapshot.primary?.remainingPercent ?? -1, 75, accuracy: 0.001)
    }

    func testGrokIdentityUsesOAuthSubjectAndTierWithoutTreatingTokenExpiryAsPlanExpiry() throws {
        let idToken = jwt(["sub": "user-123", "email": "person@example.com", "name": "Grok User"])
        let accessToken = jwt(["sub": "user-123", "tier": 5, "exp": 2_000_000_000])
        let identity = try GrokProvider.linkedIdentity(credentials: AccountCredentials(
            accessToken: accessToken,
            refreshToken: "refresh-token",
            idToken: idToken,
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        ))

        XCTAssertEqual(identity.workspaceID, "user-123")
        XCTAssertEqual(identity.displayName, "Grok User")
        XCTAssertEqual(identity.email, "person@example.com")
        XCTAssertEqual(identity.plan, "SuperGrok Heavy")
        XCTAssertNil(identity.planExpiresAt)
    }

    func testGrokEnrichesIdentityFromOfficialUserProfile() throws {
        let idToken = jwt(["sub": "token-user", "email": "old@example.com"])
        let credentials = AccountCredentials(
            accessToken: jwt(["sub": "token-user", "tier": 1]),
            refreshToken: "refresh-token",
            idToken: idToken,
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let data = Data(#"""
        {
          "userId": "live-user",
          "email": "person@example.com",
          "firstName": "Grok",
          "lastName": "Builder",
          "subscriptionTier": "supergrok_heavy"
        }
        """#.utf8)

        let identity = try GrokProvider.enrichedIdentity(credentials: credentials, data: data)

        XCTAssertEqual(identity.workspaceID, "live-user")
        XCTAssertEqual(identity.displayName, "Grok Builder")
        XCTAssertEqual(identity.profileName, "Grok Builder")
        XCTAssertEqual(identity.email, "person@example.com")
        XCTAssertEqual(identity.plan, "SuperGrok Heavy")
        XCTAssertNil(identity.planExpiresAt)
    }

    func testGrokDeviceLinkOnlyAcceptsOfficialHTTPSConfirmationHost() throws {
        let valid = Data(#"""
        {
          "device_code": "device-test",
          "user_code": "ABCD-EFGH",
          "verification_uri_complete": "https://accounts.x.ai/oauth2/device?user_code=ABCD-EFGH",
          "expires_in": 1800,
          "interval": 5
        }
        """#.utf8)
        XCTAssertEqual(try GrokProvider.deviceLink(from: valid, now: now).userCode, "ABCD-EFGH")

        let phishing = Data(#"""
        {
          "device_code": "device-test",
          "user_code": "ABCD-EFGH",
          "verification_uri": "https://accounts.x.ai.attacker.example/device",
          "expires_in": 1800
        }
        """#.utf8)
        XCTAssertThrowsError(try GrokProvider.deviceLink(from: phishing, now: now))
    }

    func testSensitiveAndUserSelectedProvidersRemainOnDevice() {
        XCTAssertTrue(ProviderID.grok.supportsOffDeviceMonitoring)
        XCTAssertTrue(ProviderID.synthetic.supportsOffDeviceMonitoring)
        XCTAssertTrue(ProviderID.warp.supportsOffDeviceMonitoring)
        XCTAssertFalse(ProviderID.ollamaCloud.supportsOffDeviceMonitoring)
        XCTAssertFalse(ProviderID.antigravity.supportsOffDeviceMonitoring)
        XCTAssertFalse(ProviderID.compatibleAPI.supportsOffDeviceMonitoring)
        XCTAssertTrue(ProviderID.openAIAPI.supportsOffDeviceMonitoring)
        XCTAssertTrue(ProviderID.anthropicAPI.supportsOffDeviceMonitoring)
        XCTAssertFalse(ProviderID.newAPI.supportsOffDeviceMonitoring)
        XCTAssertTrue(ProviderID.openRouter.supportsOffDeviceMonitoring)
        XCTAssertTrue(ProviderID.fireworksAI.supportsOffDeviceMonitoring)
        XCTAssertTrue(ProviderID.deepSeek.supportsOffDeviceMonitoring)
        XCTAssertTrue(ProviderID.poe.supportsOffDeviceMonitoring)
    }

    func testOlderCredentialPayloadStillDecodes() throws {
        let data = Data(#"{"accessToken":"a","refreshToken":"r","idToken":"i"}"#.utf8)
        let credentials = try JSONDecoder().decode(AccountCredentials.self, from: data)

        XCTAssertNil(credentials.endpointURL)
        XCTAssertNil(credentials.projectID)
        XCTAssertNil(credentials.accountLabel)
        XCTAssertNil(credentials.oauthClientID)
        XCTAssertNil(credentials.oauthClientSecret)
        XCTAssertNil(credentials.monthlyBudget)
        XCTAssertNil(credentials.currencyCode)
    }

    func testOlderBalancePayloadStillDecodesWithoutSemanticKind() throws {
        let data = Data(#"""
        {"title":"API spend","currencyCode":"USD","spent":3,"isUnlimited":false}
        """#.utf8)
        let balance = try JSONDecoder().decode(APIBalance.self, from: data)

        XCTAssertNil(balance.kind)
        XCTAssertNil(balance.unitLabel)
    }

    private func makeAccount(_ provider: ProviderID, name: String) -> MonitoredAccount {
        MonitoredAccount(
            id: UUID(),
            providerID: provider,
            displayName: name,
            workspaceID: "test",
            plan: nil,
            addedAt: now
        )
    }

    private func jwt(_ claims: [String: Any]) -> String {
        func segment(_ value: Any) -> String {
            let data = try! JSONSerialization.data(withJSONObject: value)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = segment(["alg": "none"])
        return "\(header).\(segment(claims)).signature"
    }
}
