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

        XCTAssertEqual(snapshot.providerName, "z.ai")
        XCTAssertEqual(snapshot.accountProviderID, .zai)
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.primary?.metricID, "zai:five_hour")
        XCTAssertEqual(snapshot.primary?.windowMinutes, 300)
        XCTAssertEqual(snapshot.primary?.usedPercent, 25)
        XCTAssertEqual(snapshot.secondary?.metricID, "zai:weekly")
        XCTAssertEqual(snapshot.secondary?.windowMinutes, 10_080)
        XCTAssertEqual(snapshot.secondary?.usedPercent, 25)
        XCTAssertEqual(snapshot.extraWindows?.first?.displayTitle, "Monthly MCP limit")
        XCTAssertEqual(snapshot.extraWindows?.first?.metricID, "zai:mcp:5:1")
        XCTAssertEqual(snapshot.extraWindows?.first?.usedPercent, 40)
    }

    func testCreditLimitRowsBecomeFiveHourAndWeeklyWindows() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data(#"""
        {
          "code": 200,
          "success": true,
          "data": {
            "level": "max",
            "limits": [
              {
                "type": "CREDIT_LIMIT",
                "unit": 3,
                "number": 5,
                "usage": 28000,
                "currentValue": 2585,
                "percentage": 9,
                "nextResetTime": 1800000000000
              },
              {
                "type": "CREDIT_LIMIT",
                "unit": 6,
                "number": 1,
                "percentage": 41
              }
            ]
          }
        }
        """#.utf8)
        let account = MonitoredAccount(id: UUID(), providerID: .zhipu, displayName: "智谱",
                                       workspaceID: "zhipu-test", plan: nil, addedAt: now)
        let snapshot = try ZAIProvider.parseUsage(account: account, data: data, now: now)
        XCTAssertEqual(snapshot.providerName, "智谱")
        XCTAssertEqual(snapshot.plan, "Max")
        XCTAssertEqual(snapshot.primary?.metricID, "zai:five_hour")
        XCTAssertTrue(snapshot.primary?.reportsReset == true)
        XCTAssertEqual(snapshot.secondary?.metricID, "zai:weekly")
        XCTAssertEqual(snapshot.secondary?.reportsReset, false)
        XCTAssertEqual(snapshot.secondary?.usedPercent, 41)
    }

    func testWebAuthorizeURLStaysOnTheStorefront() throws {
        let mainland = Data(#"""
        {"code":0,"data":{"flow_id":"abc","authorize_url":"https://bigmodel.cn/login?appId=zcode","poll_interval_sec":2,"expires_at":1793596569}}
        """#.utf8)
        let link = try ZAIProvider.webLink(from: mainland, pollToken: "token", storefront: .mainland)
        XCTAssertEqual(link.verificationURL.host, "bigmodel.cn")
        let evil = Data(#"""
        {"code":0,"data":{"flow_id":"abc","authorize_url":"https://evil.example/login","expires_at":1793596569}}
        """#.utf8)
        XCTAssertThrowsError(try ZAIProvider.webLink(from: evil, pollToken: "token", storefront: .mainland))
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

    func testHTTPSuccessEnvelopeWithoutQuotaIsNotAccepted() {
        XCTAssertFalse(ZAIProvider.envelopeAccepted(Data(#"{"code":401,"success":false,"msg":"invalid api key"}"#.utf8)))
        XCTAssertFalse(ZAIProvider.envelopeAccepted(Data(#"{"code":200,"success":true}"#.utf8)))
        XCTAssertTrue(ZAIProvider.envelopeAccepted(Data(#"{"code":200,"success":true,"data":{"limits":[]}}"#.utf8)))
    }

    func testRegionSelectionPinsOneHostAndAutomaticTriesBothUntilPinned() {
        XCTAssertEqual(
            ZAIProvider.candidateURLs(provider: .zai, region: .global, pinnedHost: nil).map(\.host),
            ["api.z.ai"]
        )
        XCTAssertEqual(
            ZAIProvider.candidateURLs(provider: .zhipu, region: .mainland, pinnedHost: nil).map(\.host),
            ["open.bigmodel.cn"]
        )
        XCTAssertEqual(
            ZAIProvider.candidateURLs(region: .mainland, pinnedHost: nil).map(\.absoluteString),
            ["https://open.bigmodel.cn/api/monitor/usage/quota/limit"]
        )
        XCTAssertEqual(
            ZAIProvider.candidateURLs(region: .global, pinnedHost: nil).map(\.host),
            ["api.z.ai"]
        )
        XCTAssertEqual(
            ZAIProvider.candidateURLs(
                provider: .zhipu,
                region: .mainland,
                pinnedHost: "https://open.bigmodel.cn/api/monitor/usage/quota/limit"
            ).map(\.host),
            ["open.bigmodel.cn"]
        )
        XCTAssertEqual(
            ZAIProvider.candidateURLs(region: .automatic, pinnedHost: "https://evil.example/quota"),
            [ZAIProvider.globalQuotaURL]
        )
        XCTAssertEqual(ProviderID.zai.displayName, "z.ai")
        XCTAssertEqual(ProviderID.zhipu.displayName, "智谱")
        XCTAssertEqual(ProviderID.zai.logoAssetName, "ZAILogo")
    }
}
