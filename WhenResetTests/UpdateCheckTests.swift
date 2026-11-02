import XCTest
@testable import WhenReset

final class UpdateCheckTests: XCTestCase {
    func testSandboxReceiptIsTestFlightEvenWhenStoreKitSaysProduction() {
        let path = "/var/mobile/Containers/Data/Application/ABC/StoreKit/sandboxReceipt"
        XCTAssertEqual(
            InstallChannelDetector.channel(receiptPath: path, storeKitEnvironment: .production, isSimulator: false),
            .testFlight
        )
        XCTAssertEqual(
            InstallChannelDetector.channel(
                receiptPath: "/tmp/nested/sandboxReceipt/extra",
                storeKitEnvironment: nil,
                isSimulator: false
            ),
            .testFlight
        )
    }

    func testStoreKitSandboxOrTestFlightIsTestFlightWithoutAReceipt() {
        XCTAssertEqual(
            InstallChannelDetector.channel(receiptPath: nil, storeKitEnvironment: .sandbox, isSimulator: false),
            .testFlight
        )
        XCTAssertEqual(
            InstallChannelDetector.channel(receiptPath: nil, storeKitEnvironment: .testFlight, isSimulator: true),
            .testFlight
        )
    }

    func testProductionReceiptOrEnvironmentIsAppStore() {
        let receipt = "/var/mobile/Containers/Data/Application/ABC/StoreKit/receipt"
        XCTAssertEqual(
            InstallChannelDetector.channel(receiptPath: receipt, storeKitEnvironment: nil, isSimulator: false),
            .appStore
        )
        XCTAssertEqual(
            InstallChannelDetector.channel(receiptPath: nil, storeKitEnvironment: .production, isSimulator: false),
            .appStore
        )
        XCTAssertEqual(
            InstallChannelDetector.channel(receiptPath: receipt, storeKitEnvironment: nil, isSimulator: true),
            .appStore
        )
    }

    func testMissingStoreSignalsAreDevelopment() {
        XCTAssertEqual(
            InstallChannelDetector.channel(receiptPath: nil, storeKitEnvironment: nil, isSimulator: true),
            .development
        )
        XCTAssertEqual(
            InstallChannelDetector.channel(receiptPath: nil, storeKitEnvironment: nil, isSimulator: false),
            .development
        )
        XCTAssertEqual(
            InstallChannelDetector.channel(receiptPath: nil, storeKitEnvironment: .xcode, isSimulator: false),
            .development
        )
        XCTAssertEqual(
            InstallChannelDetector.channel(receiptPath: "/tmp/not-a-receipt", storeKitEnvironment: nil, isSimulator: false),
            .development
        )
    }

    func testMarketingVersionsCompareAsSemver() {
        XCTAssertFalse(isNewer("1.8", "30", than: "1.8.0", "30"))
        XCTAssertTrue(isNewer("1.8.1", nil, than: "1.8.0", "99"))
        XCTAssertTrue(isNewer("1.10.0", "1", than: "1.9.0", "99"))
        XCTAssertFalse(isNewer("1.9", "1", than: "1.10", "1"))
        XCTAssertTrue(isNewer("1.9", "1", than: "1.8", "99"))
        XCTAssertFalse(isNewer("1.8", "99", than: "1.9", "1"))
        XCTAssertFalse(isNewer("1.02", nil, than: "1.2", nil))
    }

    func testPrereleaseHasLowerPrecedenceThanTheRelease() {
        XCTAssertTrue(isNewer("1.0.0", nil, than: "1.0.0-beta", nil))
        XCTAssertFalse(isNewer("1.0.0-beta", nil, than: "1.0.0", nil))
        XCTAssertTrue(isNewer("1.0.0-alpha.1", nil, than: "1.0.0-alpha", nil))
        XCTAssertTrue(isNewer("1.0.0-beta", nil, than: "1.0.0-alpha", nil))
        XCTAssertTrue(isNewer("1.0.0-beta.11", nil, than: "1.0.0-beta.2", nil))
        XCTAssertTrue(isNewer("1.0.0-alpha", nil, than: "1.0.0-1", nil))
        XCTAssertTrue(isNewer("1.0.0", "1", than: "1.0.0+9", "0"))
    }

    func testSameMarketingVersionUsesNumericBuild() {
        XCTAssertTrue(isNewer("1.8.0", "31", than: "1.8.0", "30"))
        XCTAssertTrue(isNewer("1.8", "10", than: "1.8.0", "9"))
        XCTAssertFalse(isNewer("1.8.0", "30", than: "1.8.0", "30"))
        XCTAssertFalse(isNewer("1.8.0", "29", than: "1.8.0", "30"))
        XCTAssertFalse(isNewer("1.8.0", nil, than: "1.8.0", "30"))
        XCTAssertTrue(isNewer("1.8.0", "5", than: "1.8.0", nil))
        XCTAssertFalse(isNewer("not-a-version", "99", than: "1.8.0", "1"))
    }

    func testFeedParserReadsIOSVersionAndBuild() throws {
        let parsed = try UpdateFeedParser.parse(Data("""
        {
          "ios": {
            "version": " 1.8.1 ",
            "build": " 31 ",
            "updatedAt": "2026-11-02T08:00:00Z"
          }
        }
        """.utf8))
        XCTAssertEqual(parsed, ReleaseIdentity(marketingVersion: "1.8.1", build: "31"))

        let withoutDate = try UpdateFeedParser.parse(Data("""
        {"ios":{"version":"1.8","build":"30"}}
        """.utf8))
        XCTAssertEqual(withoutDate.build, "30")
    }

    func testFeedParserRejectsMalformedPayloads() {
        XCTAssertThrowsError(try UpdateFeedParser.parse(Data("[]".utf8))) { error in
            XCTAssertEqual(error as? UpdateParseError, .invalidJSON)
        }
        XCTAssertThrowsError(try UpdateFeedParser.parse(Data(#"{"macos":{"version":"1"}}"#.utf8))) { error in
            XCTAssertEqual(error as? UpdateParseError, .invalidJSON)
        }
        XCTAssertThrowsError(try UpdateFeedParser.parse(Data(#"{"ios":{"version":"1.0","build":31}}"#.utf8))) { error in
            XCTAssertEqual(error as? UpdateParseError, .invalidJSON)
        }
        XCTAssertThrowsError(try UpdateFeedParser.parse(Data(#"{"ios":{"version":" ","build":"4"}}"#.utf8))) { error in
            XCTAssertEqual(error as? UpdateParseError, .missingVersion)
        }
    }

    func testAppStoreLookupParserReadsVersionAndOptionalBuild() throws {
        let listing = try AppStoreLookupParser.parse(Data("""
        {
          "resultCount": 2,
          "results": [
            {"version": "0.1.0", "trackId": 1, "trackName": "Other"},
            {
              "version": "2.0.0",
              "build": "8",
              "trackId": 6829609877,
              "bundleId": "com.harrisliangsu.whenreset",
              "currentVersionReleaseDate": "2026-10-01T00:00:00Z"
            }
          ]
        }
        """.utf8))
        XCTAssertEqual(listing, ReleaseIdentity(marketingVersion: "2.0.0", build: "8"))

        let versionOnly = try AppStoreLookupParser.parse(Data("""
        {"resultCount":1,"results":[{"version":"1.9","trackId":6829609877}]}
        """.utf8))
        XCTAssertEqual(versionOnly, ReleaseIdentity(marketingVersion: "1.9", build: nil))
    }

    func testAppStoreLookupParserDistinguishesEmptyAndInvalidPayloads() {
        XCTAssertThrowsError(try AppStoreLookupParser.parse(Data("not-json".utf8))) { error in
            XCTAssertEqual(error as? UpdateParseError, .invalidJSON)
        }
        XCTAssertThrowsError(try AppStoreLookupParser.parse(Data(#"{"resultCount":0,"results":[]}"#.utf8))) { error in
            XCTAssertEqual(error as? UpdateParseError, .notListed)
        }
        XCTAssertThrowsError(try AppStoreLookupParser.parse(Data(#"{"resultCount":1,"results":[{"trackId":6829609877}]}"#.utf8))) { error in
            XCTAssertEqual(error as? UpdateParseError, .missingVersion)
        }
    }

    func testCheckerUsesTheChannelSourceAndClassifiesFailures() async throws {
        let local = ReleaseIdentity(marketingVersion: "1.8.0", build: "30")
        let feed = Data(#"{"ios":{"version":"1.8.0","build":"31","updatedAt":"2026-11-02T00:00:00Z"}}"#.utf8)
        let newer = try await UpdateChecker(
            transport: ExpectedURLTransport(expected: UpdateFeedSource.url, status: 200, body: feed)
        ).check(source: .testFlightFeed, local: local).get()
        XCTAssertEqual(newer, .available(ReleaseIdentity(marketingVersion: "1.8.0", build: "31")))

        let listing = Data(#"{"resultCount":1,"results":[{"version":"1.8.0","trackId":6829609877}]}"#.utf8)
        let current = try await UpdateChecker(
            transport: ExpectedURLTransport(expected: UpdateLinks.lookup, status: 200, body: listing)
        ).check(source: .appStoreLookup, local: local).get()
        XCTAssertEqual(current, .upToDate)

        let offline = await UpdateChecker(
            transport: StubTransport(error: URLError(.notConnectedToInternet))
        ).check(source: .appStoreLookup, local: local)
        XCTAssertEqual(offline, .failure(.network))

        let server = await UpdateChecker(
            transport: StubTransport(status: 500, body: listing)
        ).check(source: .appStoreLookup, local: local)
        XCTAssertEqual(server, .failure(.network))

        let unreadable = await UpdateChecker(
            transport: StubTransport(status: 200, body: Data("nope".utf8))
        ).check(source: .testFlightFeed, local: local)
        XCTAssertEqual(unreadable, .failure(.parse))
    }

    func testSourcesAndStoreLinks() {
        XCTAssertEqual(UpdateSource.forChannel(.appStore), .appStoreLookup)
        XCTAssertEqual(UpdateSource.forChannel(.testFlight), .testFlightFeed)
        XCTAssertEqual(UpdateSource.forChannel(.development), .testFlightFeed)
        XCTAssertEqual(UpdateLinks.lookup.absoluteString, "https://itunes.apple.com/lookup?id=6829609877")
        XCTAssertEqual(UpdateLinks.appStore.absoluteString, "https://apps.apple.com/app/id6829609877")
        XCTAssertEqual(UpdateLinks.testFlight.absoluteString, "https://beta.itunes.apple.com/v1/app/6829609877")
        XCTAssertEqual(
            UpdateFeedSource.url.absoluteString,
            "https://raw.githubusercontent.com/harrisliangsu/blinky-ios/master/update-check.json"
        )
        XCTAssertEqual(UpdateLinks.openURL(for: .appStore), UpdateLinks.appStore)
        XCTAssertEqual(UpdateLinks.openURL(for: .testFlight), UpdateLinks.testFlight)
        XCTAssertNil(UpdateLinks.openURL(for: .development))
        for url in [UpdateLinks.appStore, UpdateLinks.testFlight, UpdateLinks.lookup, UpdateFeedSource.url] {
            XCTAssertEqual(url.scheme, "https")
            XCTAssertFalse(url.path.lowercased().hasSuffix(".ipa"))
            XCTAssertFalse(url.path.lowercased().hasSuffix(".zip"))
        }
    }

    func testSoftCheckIntervalAndReminderSetting() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let interval = UpdateCheckPolicy.minimumInterval
        XCTAssertTrue(UpdateCheckPolicy.shouldSoftCheck(mode: .notify, lastCheckAt: nil, now: start))
        XCTAssertFalse(UpdateCheckPolicy.shouldSoftCheck(mode: .manual, lastCheckAt: nil, now: start))
        XCTAssertFalse(UpdateCheckPolicy.shouldSoftCheck(
            mode: .notify,
            lastCheckAt: start,
            now: start.addingTimeInterval(interval - 1)
        ))
        XCTAssertTrue(UpdateCheckPolicy.shouldSoftCheck(
            mode: .notify,
            lastCheckAt: start,
            now: start.addingTimeInterval(interval)
        ))

        let available = UpdateAvailability.available(ReleaseIdentity(marketingVersion: "1.8.0", build: "31"))
        XCTAssertNil(UpdateCheckPolicy.pendingRelease(
            scheduledCheck: false,
            remindWhenAvailable: true,
            availability: available,
            lastRemindedIdentity: nil
        ))
        XCTAssertNil(UpdateCheckPolicy.pendingRelease(
            scheduledCheck: true,
            remindWhenAvailable: false,
            availability: available,
            lastRemindedIdentity: nil
        ))
        XCTAssertNil(UpdateCheckPolicy.pendingRelease(
            scheduledCheck: true,
            remindWhenAvailable: true,
            availability: .upToDate,
            lastRemindedIdentity: nil
        ))
        XCTAssertEqual(
            UpdateCheckPolicy.pendingRelease(
                scheduledCheck: true,
                remindWhenAvailable: true,
                availability: available,
                lastRemindedIdentity: nil
            ),
            ReleaseIdentity(marketingVersion: "1.8.0", build: "31")
        )
        XCTAssertNil(UpdateCheckPolicy.pendingRelease(
            scheduledCheck: true,
            remindWhenAvailable: true,
            availability: available,
            lastRemindedIdentity: "1.8.0|31"
        ))
        XCTAssertNotNil(UpdateCheckPolicy.pendingRelease(
            scheduledCheck: true,
            remindWhenAvailable: true,
            availability: .available(ReleaseIdentity(marketingVersion: "1.8.0", build: "32")),
            lastRemindedIdentity: "1.8.0|31"
        ))
    }

    func testPreferencesDefaultToNotifyAndRoundTrip() throws {
        let defaults = try makeDefaults()
        XCTAssertEqual(UpdateCheckPreferences.load(from: defaults.defaults), UpdateCheckPreferences())
        defaults.defaults.set(Data("{}".utf8), forKey: UpdateCheckPreferences.storageKey)
        XCTAssertEqual(UpdateCheckPreferences.load(from: defaults.defaults).mode, .notify)
        XCTAssertTrue(UpdateCheckPreferences.load(from: defaults.defaults).remindWhenAvailable)

        var preferences = UpdateCheckPreferences(
            mode: .manual,
            remindWhenAvailable: false,
            lastCheckAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .available(version: "1.2.0", build: "9"),
            lastRemindedIdentity: "1.2.0|9"
        )
        preferences.save(to: defaults.defaults)
        XCTAssertEqual(UpdateCheckPreferences.load(from: defaults.defaults), preferences)

        defaults.defaults.set(Data("not-json".utf8), forKey: UpdateCheckPreferences.storageKey)
        XCTAssertEqual(UpdateCheckPreferences.load(from: defaults.defaults), UpdateCheckPreferences())
    }

    @MainActor
    func testManualCheckShowsAvailabilityWithoutAReminder() async throws {
        let defaults = try makeDefaults()
        let body = Data(#"{"ios":{"version":"99999.0.0","build":"1","updatedAt":"2026-11-02T00:00:00Z"}}"#.utf8)
        let controller = UpdateCheckController(
            defaults: defaults.defaults,
            checker: UpdateChecker(transport: StubTransport(status: 200, body: body))
        )
        await controller.checkNow()
        XCTAssertEqual(controller.phase, .available(version: "99999.0.0", build: "1"))
        XCTAssertNil(controller.banner)
        XCTAssertNil(controller.preferences.lastRemindedIdentity)
        XCTAssertEqual(controller.preferences.status, .available(version: "99999.0.0", build: "1"))
        XCTAssertNotNil(controller.preferences.lastCheckAt)
        XCTAssertTrue(controller.showsAboutBadge)
        controller.setRemind(false)
        XCTAssertFalse(controller.showsAboutBadge)
    }

    private func isNewer(_ remoteVersion: String, _ remoteBuild: String?, than localVersion: String, _ localBuild: String?) -> Bool {
        VersionComparison.isRemoteNewer(
            local: ReleaseIdentity(marketingVersion: localVersion, build: localBuild),
            remote: ReleaseIdentity(marketingVersion: remoteVersion, build: remoteBuild)
        )
    }

    private func makeDefaults() throws -> (defaults: UserDefaults, name: String) {
        let name = "com.harrisliangsu.whenreset.tests.update-check.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }
}

private struct StubTransport: UpdateCheckTransport {
    var status: Int = 200
    var body: Data = Data()
    var error: URLError?

    func data(for request: URLRequest) async throws -> (Data, Int) {
        if let error { throw error }
        return (body, status)
    }
}

private struct ExpectedURLTransport: UpdateCheckTransport {
    var expected: URL
    var status: Int
    var body: Data

    func data(for request: URLRequest) async throws -> (Data, Int) {
        guard request.url == expected, request.cachePolicy == .reloadIgnoringLocalCacheData else {
            throw URLError(.badURL)
        }
        return (body, status)
    }
}
