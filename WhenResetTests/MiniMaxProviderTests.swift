import XCTest
@testable import WhenReset

final class MiniMaxProviderTests: XCTestCase {
    func testCountBasedResponseBuildsFiveHourAndWeeklyWindows() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data(#"""
        {
          "base_resp": { "status_code": 0 },
          "current_subscribe_title": "Max",
          "model_remains": [{
            "model_name": "MiniMax-M3",
            "current_interval_total_count": 1000,
            "current_interval_usage_count": 250,
            "end_time": 1700018000000,
            "current_weekly_total_count": 6000,
            "current_weekly_usage_count": 4500,
            "weekly_end_time": 1700604800000
          }]
        }
        """#.utf8)
        let account = MonitoredAccount(id: UUID(), providerID: .miniMax, displayName: "MiniMax account",
                                       workspaceID: "minimax-test", plan: nil, addedAt: now)

        let snapshot = try MiniMaxProvider.parseUsage(account: account, data: data, now: now)

        XCTAssertEqual(snapshot.providerName, "MiniMax Token Plan")
        XCTAssertEqual(snapshot.plan, "Max")
        XCTAssertEqual(snapshot.primary?.metricID, "minimax:five_hour")
        XCTAssertEqual(snapshot.primary?.windowMinutes, 300)
        XCTAssertEqual(snapshot.primary?.usedPercent, 75)
        XCTAssertEqual(snapshot.secondary?.metricID, "minimax:weekly")
        XCTAssertEqual(snapshot.secondary?.windowMinutes, 10_080)
        XCTAssertEqual(snapshot.secondary?.usedPercent, 25)
    }

    func testRemainingPercentAndMillisecondCountdownsAreParsed() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data(#"""
        {
          "data": {
            "model_remains": [{
              "model_name": "general",
              "current_interval_status": 1,
              "current_interval_remaining_percent": "96",
              "remains_time": 16659830,
              "current_weekly_status": 1,
              "current_weekly_remaining_percent": 99,
              "weekly_remains_time": 567459830
            }]
          },
          "base_resp": { "status_code": 0, "status_msg": "success" }
        }
        """#.utf8)
        let account = MonitoredAccount(id: UUID(), providerID: .miniMax, displayName: "MiniMax account",
                                       workspaceID: "minimax-test", plan: nil, addedAt: now)

        let snapshot = try MiniMaxProvider.parseUsage(account: account, data: data, now: now)

        XCTAssertEqual(snapshot.plan, "Token Plan")
        let primary = try XCTUnwrap(snapshot.primary)
        let secondary = try XCTUnwrap(snapshot.secondary)
        XCTAssertEqual(primary.usedPercent, 4)
        XCTAssertEqual(primary.resetsAt.timeIntervalSince(now), 16_659.83, accuracy: 0.01)
        XCTAssertEqual(secondary.usedPercent, 1)
        XCTAssertEqual(secondary.resetsAt.timeIntervalSince(now), 567_459.83, accuracy: 0.01)
    }

    func testUnavailableMultimodalPlaceholdersAreIgnored() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data(#"""
        {
          "base_resp": { "status_code": 0 },
          "model_remains": [{
            "model_name": "video",
            "current_interval_status": 3,
            "current_interval_total_count": 0,
            "current_interval_usage_count": 0,
            "current_interval_remaining_percent": 100,
            "end_time": 1700018000000
          }]
        }
        """#.utf8)
        let account = MonitoredAccount(id: UUID(), providerID: .miniMax, displayName: "MiniMax account",
                                       workspaceID: "minimax-test", plan: nil, addedAt: now)

        XCTAssertThrowsError(try MiniMaxProvider.parseUsage(account: account, data: data, now: now)) { error in
            guard case MiniMaxProviderError.noResettableQuota = error else {
                return XCTFail("Expected noResettableQuota, got \(error)")
            }
        }
    }

    func testInvalidKeyEnvelopeRequiresAuthentication() {
        let data = Data(#"{"base_resp":{"status_code":1004,"status_msg":"invalid api key"}}"#.utf8)
        let account = MonitoredAccount(id: UUID(), providerID: .miniMax, displayName: "MiniMax account",
                                       workspaceID: "minimax-test", plan: nil, addedAt: .now)

        XCTAssertThrowsError(try MiniMaxProvider.parseUsage(account: account, data: data)) { error in
            guard case MiniMaxProviderError.authorizationFailed = error else {
                return XCTFail("Expected authorizationFailed, got \(error)")
            }
        }
    }

    func testGlobalAndMainlandChinaQuotaEndpointsAreConfigured() {
        XCTAssertEqual(MiniMaxProvider.quotaURLs.compactMap(\.host), ["www.minimax.io", "www.minimaxi.com"])
        XCTAssertTrue(MiniMaxProvider.quotaURLs.allSatisfy { $0.path == "/v1/token_plan/remains" })
    }
}
