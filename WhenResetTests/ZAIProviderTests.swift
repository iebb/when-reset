import XCTest
@testable import WhenReset

final class ZAIProviderTests: XCTestCase {
    func testQuotaResponseBuildsFiveHourWeeklyAndMonthlyWindows() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data(#"""
        {
          "code": 200,
          "success": true,
          "data": {
            "planName": "Pro",
            "limits": [
              {
                "type": "TOKENS_LIMIT",
                "unit": 3,
                "number": 5,
                "usage": 400,
                "currentValue": 100,
                "remaining": 300,
                "percentage": 1,
                "nextResetTime": 1800000000000
              },
              {
                "type": "TOKENS_LIMIT",
                "unit": 6,
                "number": 1,
                "usage": "2000",
                "currentValue": "500",
                "remaining": "1500",
                "percentage": 1,
                "nextResetTime": "1800604800000"
              },
              {
                "type": "TIME_LIMIT",
                "unit": 5,
                "number": 1,
                "percentage": 40,
                "nextResetTime": 1802592000000
              }
            ]
          }
        }
        """#.utf8)
        let account = MonitoredAccount(id: UUID(), providerID: .zai, displayName: "Z.AI account",
                                       workspaceID: "zai-test", plan: nil, addedAt: now)

        let snapshot = try ZAIProvider.parseUsage(account: account, data: data, now: now)

        XCTAssertEqual(snapshot.providerName, "Z.AI Coding Plan")
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.primary?.metricID, "zai:five_hour")
        XCTAssertEqual(snapshot.primary?.windowMinutes, 300)
        XCTAssertEqual(snapshot.primary?.usedPercent, 25)
        XCTAssertEqual(snapshot.secondary?.metricID, "zai:weekly")
        XCTAssertEqual(snapshot.secondary?.windowMinutes, 10_080)
        XCTAssertEqual(snapshot.secondary?.usedPercent, 25)
        XCTAssertEqual(snapshot.extraWindows?.first?.displayTitle, "Monthly MCP limit")
        XCTAssertEqual(snapshot.extraWindows?.first?.usedPercent, 40)
    }

    func testQuotaWithoutFutureResetIsRejected() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let data = Data(#"""
        {
          "code": 200,
          "success": true,
          "data": {
            "limits": [{
              "type": "TOKENS_LIMIT",
              "unit": 3,
              "number": 5,
              "percentage": 10,
              "nextResetTime": 1000
            }]
          }
        }
        """#.utf8)
        let account = MonitoredAccount(id: UUID(), providerID: .zai, displayName: "Z.AI account",
                                       workspaceID: "zai-test", plan: nil, addedAt: now)

        XCTAssertThrowsError(try ZAIProvider.parseUsage(account: account, data: data, now: now)) { error in
            guard case ZAIProviderError.noResettableQuota = error else {
                return XCTFail("Expected noResettableQuota, got \(error)")
            }
        }
    }

    func testInvalidEnvelopeIsRejected() {
        let data = Data(#"{"code":401,"success":false,"data":null}"#.utf8)
        let account = MonitoredAccount(id: UUID(), providerID: .zai, displayName: "Z.AI account",
                                       workspaceID: "zai-test", plan: nil, addedAt: .now)

        XCTAssertThrowsError(try ZAIProvider.parseUsage(account: account, data: data))
    }
}
