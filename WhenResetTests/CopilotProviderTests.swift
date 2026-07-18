import XCTest
@testable import WhenReset

final class CopilotProviderTests: XCTestCase {
    private func account() -> MonitoredAccount {
        MonitoredAccount(id: UUID(), providerID: .githubCopilot, displayName: "octocat",
                         workspaceID: "1", plan: nil, addedAt: .now)
    }

    func testCurrentQuotaSnapshotShapeParsesBothCopilotLanes() throws {
        let data = Data(#"""
        {
          "copilot_plan": "individual_pro",
          "quota_reset_date": "2026-08-01",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 300,
              "remaining": "225",
              "percent_remaining": "75",
              "quota_id": "premium_interactions"
            },
            "chat": {
              "entitlement": 50,
              "remaining": 5,
              "percent_remaining": 10,
              "quota_id": "chat"
            }
          }
        }
        """#.utf8)

        let snapshot = try CopilotProvider.parseUsage(account: account(), data: data)

        XCTAssertEqual(snapshot.providerName, "GitHub Copilot")
        XCTAssertEqual(snapshot.plan, "Individual Pro")
        XCTAssertEqual(snapshot.primary?.displayTitle, "Premium requests")
        XCTAssertEqual(snapshot.primary?.usedPercent, 25)
        XCTAssertEqual(snapshot.primary?.metricID, "copilot:premium")
        XCTAssertEqual(snapshot.secondary?.displayTitle, "Chat")
        XCTAssertEqual(snapshot.secondary?.usedPercent, 90)
        XCTAssertEqual(snapshot.secondary?.metricID, "copilot:chat")
        XCTAssertEqual(snapshot.primary?.resetsAt, snapshot.secondary?.resetsAt)
    }

    func testLegacyMonthlyQuotaShapeDerivesPercentages() throws {
        let data = Data(#"""
        {
          "copilot_plan": "individual",
          "quota_reset_date": "2026-08-01T00:00:00Z",
          "monthly_quotas": { "completions": 300, "chat": "50" },
          "limited_user_quotas": { "completions": 120, "chat": "50" }
        }
        """#.utf8)

        let snapshot = try CopilotProvider.parseUsage(account: account(), data: data)

        XCTAssertEqual(snapshot.primary?.usedPercent, 60)
        XCTAssertEqual(snapshot.secondary?.usedPercent, 0)
    }

    func testMeteredQuotaWithoutResetDateFailsInsteadOfInventingCountdown() {
        let data = Data(#"""
        {
          "copilot_plan": "individual",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 300,
              "remaining": 225,
              "percent_remaining": 75
            }
          }
        }
        """#.utf8)

        XCTAssertThrowsError(try CopilotProvider.parseUsage(account: account(), data: data)) { error in
            guard case CopilotProviderError.missingResetDate = error else {
                return XCTFail("Expected missingResetDate, got \(error)")
            }
        }
    }

    func testTokenBasedBillingCanProducePlanOnlySnapshot() throws {
        let data = Data(#"{"copilot_plan":"business","token_based_billing":true}"#.utf8)

        let snapshot = try CopilotProvider.parseUsage(account: account(), data: data)

        XCTAssertEqual(snapshot.plan, "Business")
        XCTAssertTrue(snapshot.usageWindows.isEmpty)
    }

    func testDateOnlyQuotaResetUsesUTC() throws {
        let parsed = try XCTUnwrap(CopilotProvider.parseQuotaResetDate("2026-08-01"))
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: try XCTUnwrap(TimeZone(secondsFromGMT: 0)), from: parsed)

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 1)
        XCTAssertEqual(components.hour, 0)
    }

    func testExpiringGitHubTokenRequiresRelinking() async {
        let credentials = AccountCredentials(accessToken: "token", refreshToken: "", idToken: "",
                                             expiresAt: .now.addingTimeInterval(60))

        do {
            _ = try await CopilotProvider().refreshedIfNeeded(credentials)
            XCTFail("Expected relinkRequired")
        } catch CopilotProviderError.relinkRequired {
            // Expected: this public device client has no supported secret-free refresh grant.
        } catch {
            XCTFail("Expected relinkRequired, got \(error)")
        }
    }

    func testGitHubProfileUsesFullNameAndRetainsPublicEmail() throws {
        let profile = try CopilotProvider.parseProfile(Data(#"""
        {
          "id": 123,
          "login": "octocat",
          "name": "The Octocat",
          "email": "octocat@example.com"
        }
        """#.utf8))

        XCTAssertEqual(profile.preferredName, "The Octocat")
        XCTAssertEqual(profile.email, "octocat@example.com")

        let fallback = try CopilotProvider.parseProfile(Data(#"""
        {
          "id": 123,
          "login": "octocat",
          "name": null,
          "email": null
        }
        """#.utf8))
        XCTAssertEqual(fallback.preferredName, "octocat")
        XCTAssertNil(fallback.email)
    }
}
