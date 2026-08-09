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

    func testSensitiveAndUserSelectedProvidersRemainOnDevice() {
        XCTAssertTrue(ProviderID.synthetic.supportsOffDeviceMonitoring)
        XCTAssertTrue(ProviderID.warp.supportsOffDeviceMonitoring)
        XCTAssertFalse(ProviderID.ollamaCloud.supportsOffDeviceMonitoring)
        XCTAssertFalse(ProviderID.antigravity.supportsOffDeviceMonitoring)
        XCTAssertFalse(ProviderID.compatibleAPI.supportsOffDeviceMonitoring)
    }

    func testOlderCredentialPayloadStillDecodes() throws {
        let data = Data(#"{"accessToken":"a","refreshToken":"r","idToken":"i"}"#.utf8)
        let credentials = try JSONDecoder().decode(AccountCredentials.self, from: data)

        XCTAssertNil(credentials.endpointURL)
        XCTAssertNil(credentials.projectID)
        XCTAssertNil(credentials.accountLabel)
        XCTAssertNil(credentials.oauthClientID)
        XCTAssertNil(credentials.oauthClientSecret)
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
}
