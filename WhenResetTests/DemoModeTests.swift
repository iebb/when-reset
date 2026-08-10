import XCTest
import UIKit
@testable import WhenReset

final class DemoModeTests: XCTestCase {
    private struct LiveWorkerFixture: Decodable {
        var serverURL: URL
        var deviceID: UUID
        var deviceSecret: String
        var accountID: UUID
        var providerID: ProviderID
    }

    private struct LiveRemoteWorkerFixture: Decodable {
        var serverURL: URL
        var deviceID: UUID
        var deviceSecret: String
    }

    func testDemoSnapshotContainsCompleteNativeReviewContent() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let account = MonitoredAccount(
            id: UUID(),
            providerID: .chatGPT,
            displayName: "Demo account",
            workspaceID: MonitoredAccount.demoWorkspaceID,
            plan: "Pro · Demo",
            addedAt: now
        )
        var generator = SeededGenerator(seed: 42)

        let snapshot = DemoUsageFactory.snapshot(for: account, at: now, using: &generator)

        XCTAssertTrue(account.isDemo)
        XCTAssertEqual(snapshot.accountID, account.id)
        XCTAssertEqual(snapshot.providerName, "Your AI Provider")
        XCTAssertEqual(account.providerDisplayName, "Your AI Provider")
        XCTAssertFalse(snapshot.providerName.localizedCaseInsensitiveContains("ChatGPT"))
        XCTAssertEqual(snapshot.usageWindows.map(\.displayTitle), ["5h limit", "Weekly limit", "Monthly coding limit"])
        XCTAssertTrue(snapshot.usageWindows.allSatisfy { (0...100).contains($0.usedPercent) })
        XCTAssertTrue((2...4).contains(snapshot.availableResetCount))
        XCTAssertEqual(snapshot.availableResetCredits.count, snapshot.availableResetCount)
        XCTAssertTrue(snapshot.availableResetCredits.allSatisfy { ($0.expiresAt ?? .distantPast) > now })
        XCTAssertLessThanOrEqual(try XCTUnwrap(snapshot.primary?.resetsAt).timeIntervalSince(now), 4 * 3_600)
    }

    func testDemoHistoryShowsBothDailyAndWeeklyChartRanges() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let account = MonitoredAccount(
            id: UUID(), providerID: .chatGPT, displayName: "Demo workspace",
            workspaceID: MonitoredAccount.demoWorkspaceID, plan: "Demo plan", addedAt: now
        )

        let snapshots = DemoUsageFactory.historySnapshots(for: account, endingAt: now)

        XCTAssertGreaterThanOrEqual(snapshots.count, 20)
        XCTAssertTrue(snapshots.contains { $0.fetchedAt >= now.addingTimeInterval(-24 * 3_600) })
        XCTAssertTrue(snapshots.contains { $0.fetchedAt <= now.addingTimeInterval(-6 * 24 * 3_600) })
        XCTAssertTrue(snapshots.allSatisfy { $0.providerName == DemoUsageFactory.providerName })
    }

    func testChinaRegionOnlyExcludesNewChatGPTAccountAddition() {
        let china = Locale(identifier: "zh-Hans-CN")
        let unitedStates = Locale(identifier: "en-US")

        XCTAssertFalse(ProviderAvailability.allowsAccountAddition(.chatGPT, locale: china))
        XCTAssertFalse(ProviderAvailability.availableProviders(locale: china).contains(.chatGPT))
        XCTAssertEqual(
            ProviderAvailability.providerChoices(locale: china, relinkingProvider: .chatGPT),
            [.chatGPT]
        )
        XCTAssertFalse(
            ProviderAvailability.allowsLinkStart(.chatGPT, locale: china, isRelinking: false)
        )
        XCTAssertTrue(
            ProviderAvailability.allowsLinkStart(.chatGPT, locale: china, isRelinking: true)
        )
        XCTAssertTrue(ProviderAvailability.allowsAccountAddition(.chatGPT, locale: unitedStates))
        XCTAssertTrue(ProviderAvailability.availableProviders(locale: china).contains(.claude))
    }

    func testDefaultLiveActivityStartsAutomaticallyWithinFourHours() {
        let settings = GlobalLiveActivitySettings()
        XCTAssertEqual(settings.mode, .automatic)
        XCTAssertTrue(settings.showRemainingPercentage)
        XCTAssertTrue(settings.showBankedResets)
        XCTAssertFalse(GlobalNotificationSettings().notifyAtScheduledReset)
        XCTAssertEqual(AccountMonitorSettings().defaultLiveActivityRule.remainingHours, 4)
        XCTAssertTrue(AccountMonitorSettings().notifyAtScheduledReset)
    }

    func testAutomaticRefreshesDoNotPresentFetchFailureAlerts() {
        XCTAssertFalse(UsageRefreshSource.launch.presentsFetchFailureAlerts)
        XCTAssertFalse(UsageRefreshSource.background.presentsFetchFailureAlerts)
        XCTAssertFalse(UsageRefreshSource.server.presentsFetchFailureAlerts)
        XCTAssertFalse(UsageRefreshSource.demo.presentsFetchFailureAlerts)
        XCTAssertTrue(UsageRefreshSource.manual.presentsFetchFailureAlerts)
        XCTAssertTrue(UsageRefreshSource.accountLink.presentsFetchFailureAlerts)
    }

    func testProviderFailuresNeverExposeUpstreamResponseBodies() {
        let failure = AccountRefreshFailure(error: ProviderError.server(
            429,
            #"{"detail":{"type":"connector_rate_limit","message":"private upstream body"}}"#
        ))

        XCTAssertEqual(failure.kind, .update)
        XCTAssertTrue(failure.message.contains("temporarily rate-limited"))
        XCTAssertFalse(failure.message.contains("connector_rate_limit"))
        XCTAssertFalse(failure.message.contains("private upstream body"))
    }

    func testRemovedRemoteWorkerAccountUsesSafeAccountLevelFailure() {
        let failure = AccountRefreshFailure(error: PushServerError.remoteAccountUnavailable)

        XCTAssertEqual(failure.kind, .update)
        XCTAssertEqual(
            failure.message,
            "This account is no longer available on the self-hosted Worker."
        )
        XCTAssertFalse(failure.requiresRelink)
    }

    func testServerMonitoredAccountsNeverUseTheLocalProviderRoute() {
        XCTAssertEqual(
            AccountRefreshRoute(isDemo: false, serverMonitoringEnabled: true),
            .server
        )
        XCTAssertEqual(
            AccountRefreshRoute(isDemo: false, serverMonitoringEnabled: false),
            .provider
        )
        XCTAssertEqual(
            AccountRefreshRoute(isDemo: true, serverMonitoringEnabled: true),
            .demo
        )
        XCTAssertEqual(
            AccountRefreshRoute(
                isDemo: false,
                serverMonitoringEnabled: false,
                remoteOnly: true
            ),
            .server
        )
    }

    func testKnownLocalMetadataRepairsAnOlderWorkerRow() {
        let account = MonitoredAccount(
            id: UUID(), providerID: .chatGPT, displayName: "Work",
            workspaceID: "workspace", plan: "Pro", addedAt: .now,
            profileName: "Provider Person", email: "person@example.com",
            planExpiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let emptyWorkerMetadata = ProviderAccountDetails(
            plan: "Pro",
            replacesMissingFields: true
        )

        XCTAssertTrue(WorkerMetadataPolicy.shouldUpload(
            local: account,
            remote: emptyWorkerMetadata
        ))
        XCTAssertFalse(WorkerMetadataPolicy.shouldUpload(
            local: account,
            remote: WorkerMetadataPolicy.authoritativeDetails(from: account)
        ))
        XCTAssertFalse(WorkerMetadataPolicy.shouldUpload(local: account, remote: nil))
    }

    func testRemoteOnlyAccountMetadataRoundTripsWithoutProviderCredentials() throws {
        let account = MonitoredAccount(
            id: UUID(),
            providerID: .chatGPT,
            displayName: "Worker account",
            workspaceID: MonitoredAccount.remoteWorkspacePrefix + "opaque-reference",
            plan: "Pro",
            addedAt: .now,
            remoteWorkerAccountID: "opaque-reference",
            remoteWorkerServerURL: "https://worker.example"
        )

        let decoded = try JSONDecoder().decode(
            MonitoredAccount.self,
            from: JSONEncoder().encode(account)
        )

        XCTAssertTrue(decoded.isRemoteOnly)
        XCTAssertEqual(decoded.remoteWorkerAccountID, "opaque-reference")
        XCTAssertEqual(decoded.remoteWorkerServerURL, "https://worker.example")
    }

    @MainActor
    func testDeployedWorkerReturnsRealDataWithoutLocalProviderCredentials() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixtureData: Data
        if let encodedFixture = environment["WHENRESET_LIVE_WORKER_FIXTURE_BASE64"],
           let decodedFixture = Data(base64Encoded: encodedFixture) {
            fixtureData = decodedFixture
        } else if let fixturePath = environment["WHENRESET_LIVE_WORKER_FIXTURE"] {
            fixtureData = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        } else {
            throw XCTSkip("Live Worker fixture is not configured")
        }
        let fixture = try JSONDecoder().decode(
            LiveWorkerFixture.self,
            from: fixtureData
        )
        let account = MonitoredAccount(
            id: fixture.accountID,
            providerID: fixture.providerID,
            displayName: "Live Worker QA",
            workspaceID: "worker-qa",
            plan: nil,
            addedAt: .now
        )
        var accountSettings = AccountMonitorSettings()
        accountSettings.monitorOnSelfHostedServer = true
        accountSettings.selfHostedServerConsentURL = fixture.serverURL.absoluteString
        accountSettings.selfHostedServerConsentRevision = 1
        let serverSettings = PushServerSettings(
            mode: .custom,
            customServerURL: fixture.serverURL.absoluteString,
            serverMonitoringInterval: .fiveMinutes
        )

        KeychainStore.delete(for: fixture.accountID)
        try KeychainStore.saveAccount(account)
        try KeychainStore.savePushRegistration(.init(
            deviceID: fixture.deviceID,
            deviceSecret: fixture.deviceSecret,
            serverURL: fixture.serverURL
        ))
        UserDefaults.standard.set(
            try JSONEncoder().encode([account]),
            forKey: "accounts.v1"
        )
        UserDefaults.standard.set(true, forKey: "accounts.iCloudKeychainMigrated.v1")
        UserDefaults.standard.set(
            try JSONEncoder().encode([fixture.accountID: accountSettings]),
            forKey: "monitorSettings.v1"
        )
        UserDefaults.standard.set(
            try JSONEncoder().encode(serverSettings),
            forKey: "pushServerSettings.v1"
        )

        let store = AppStore()
        guard let loadedAccount = store.accounts.first(where: { $0.id == fixture.accountID }) else {
            return XCTFail("The live Worker QA account was not restored")
        }
        XCTAssertTrue(store.isServerMonitoringEnabled(for: loadedAccount))
        XCTAssertThrowsError(try KeychainStore.load(for: fixture.accountID))

        let succeeded = await store.refresh(loadedAccount, source: .manual, publishChanges: true)

        XCTAssertTrue(succeeded)
        XCTAssertNotNil(store.snapshots[fixture.accountID])
        XCTAssertFalse(store.usageHistory.filter { $0.accountID == fixture.accountID }.isEmpty)
        XCTAssertNil(store.refreshFailures[fixture.accountID])
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testDeployedWorkerImportsRemoteAccountsWithoutProviderCredentials() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixture: LiveRemoteWorkerFixture
        if let encodedFixture = environment["WHENRESET_LIVE_REMOTE_WORKER_FIXTURE_BASE64"],
           let fixtureData = Data(base64Encoded: encodedFixture) {
            fixture = try JSONDecoder().decode(LiveRemoteWorkerFixture.self, from: fixtureData)
        } else if let rawURL = environment["WHENRESET_LIVE_REMOTE_WORKER_URL"],
                  let serverURL = URL(string: rawURL),
                  let registration = try? KeychainStore.loadPushRegistration(for: serverURL) {
            fixture = LiveRemoteWorkerFixture(
                serverURL: serverURL,
                deviceID: registration.deviceID,
                deviceSecret: registration.deviceSecret
            )
        } else if environment["WHENRESET_USE_PERSISTENT_REMOTE_WORKER"] == "1",
                  let settingsData = UserDefaults.standard.data(forKey: "pushServerSettings.v1"),
                  let settings = try? JSONDecoder().decode(
                    PushServerSettings.self,
                    from: settingsData
                  ),
                  let serverURL = try settings.resolvedServerURL(),
                  let registration = try? KeychainStore.loadPushRegistration(for: serverURL) {
            fixture = LiveRemoteWorkerFixture(
                serverURL: serverURL,
                deviceID: registration.deviceID,
                deviceSecret: registration.deviceSecret
            )
        } else {
            throw XCTSkip("Live remote Worker fixture is not configured")
        }
        let serverSettings = PushServerSettings(
            mode: .custom,
            customServerURL: fixture.serverURL.absoluteString,
            serverMonitoringInterval: .tenMinutes
        )
        try KeychainStore.savePushRegistration(.init(
            deviceID: fixture.deviceID,
            deviceSecret: fixture.deviceSecret,
            serverURL: fixture.serverURL
        ))
        UserDefaults.standard.set(
            try JSONEncoder().encode(serverSettings),
            forKey: "pushServerSettings.v1"
        )

        let store = AppStore()
        let existing = store.accounts.filter {
            $0.isRemoteOnly && $0.remoteWorkerServerURL == fixture.serverURL.absoluteString
        }
        let imported: [MonitoredAccount]
        if existing.isEmpty {
            let candidates = try await store.availableRemoteWorkerAccounts()
            XCTAssertFalse(candidates.isEmpty)
            imported = try await store.importRemoteWorkerAccounts(candidates)
        } else {
            imported = existing
        }
        XCTAssertFalse(imported.isEmpty)

        for account in imported {
            XCTAssertTrue(account.isRemoteOnly)
            XCTAssertTrue(store.isServerMonitoringEnabled(for: account))
            XCTAssertThrowsError(try KeychainStore.load(for: account.id))
            let firstRefresh = await store.refresh(
                account,
                source: .manual,
                publishChanges: true
            )
            XCTAssertTrue(firstRefresh)
            do {
                _ = try await PushServerClient.syncAccount(
                    settings: serverSettings,
                    account: account,
                    since: .now.addingTimeInterval(-3_600)
                )
            } catch {
                XCTFail("Direct Worker sync failed safely: \(String(describing: error))")
            }
            let secondRefresh = await store.refresh(
                account,
                source: .manual,
                publishChanges: true
            )
            XCTAssertTrue(firstRefresh)
            XCTAssertTrue(secondRefresh)
            XCTAssertNotNil(store.snapshots[account.id])
            XCTAssertNil(store.refreshFailures[account.id])
        }
        XCTAssertNil(store.errorMessage)
    }

    func testMultipleLiveActivityPinsRoundTrip() throws {
        var settings = AccountMonitorSettings()
        settings.pinnedLiveActivityMetricIDs = ["weekly", AccountMonitorSettings.bankedResetMetricID]

        let decoded = try JSONDecoder().decode(
            AccountMonitorSettings.self,
            from: JSONEncoder().encode(settings)
        )

        XCTAssertEqual(decoded.pinnedLiveActivityMetricIDs, settings.pinnedLiveActivityMetricIDs)
    }

    func testProviderSectionTitleIncludesAvailablePlan() {
        XCTAssertEqual(ProviderID.chatGPT.sectionTitle(plan: "pro"), "ChatGPT Pro")
        XCTAssertEqual(ProviderID.chatGPT.sectionTitle(plan: "pro_20x"), "ChatGPT Pro 20x")
        XCTAssertEqual(ProviderID.chatGPT.sectionTitle(plan: nil), "ChatGPT")
        XCTAssertEqual(ProviderID.claude.sectionTitle(plan: "max"), "Claude Max")
        XCTAssertEqual(ProviderID.githubCopilot.sectionTitle(plan: "Individual Pro"), "GitHub Copilot Individual Pro")
    }

    func testCustomAccountPresentationFallsBackToProviderIdentity() throws {
        var account = MonitoredAccount(id: UUID(), providerID: .chatGPT, displayName: "person@example.com",
                                       workspaceID: "workspace", plan: "pro_20x", addedAt: .now)
        XCTAssertEqual(account.resolvedDisplayName, "person@example.com")

        account.customDisplayName = "Work account"
        account.customSymbolName = "briefcase.fill"
        account.profileName = "Provider Person"
        account.email = "person@example.com"
        account.planExpiresAt = Date(timeIntervalSince1970: 2_000_000_000)
        account.trialExpiresAt = Date(timeIntervalSince1970: 1_900_000_000)
        XCTAssertEqual(account.resolvedDisplayName, "Work account")

        let decoded = try JSONDecoder().decode(MonitoredAccount.self,
                                               from: JSONEncoder().encode(account))
        XCTAssertEqual(decoded.customDisplayName, "Work account")
        XCTAssertEqual(decoded.customSymbolName, "briefcase.fill")
        XCTAssertEqual(decoded.profileName, "Provider Person")
        XCTAssertEqual(decoded.email, "person@example.com")
        XCTAssertEqual(decoded.planExpiresAt, account.planExpiresAt)
        XCTAssertEqual(decoded.trialExpiresAt, account.trialExpiresAt)
    }

    func testLegacyAccountWithoutProfileDetailsDecodes() throws {
        struct LegacyAccount: Encodable {
            var id: UUID
            var providerID: ProviderID
            var displayName: String
            var workspaceID: String
            var plan: String?
            var addedAt: Date
            var customDisplayName: String?
            var customSymbolName: String?
        }

        let legacy = LegacyAccount(
            id: UUID(), providerID: .chatGPT, displayName: "Legacy Person",
            workspaceID: "legacy", plan: "plus", addedAt: .now,
            customDisplayName: nil, customSymbolName: nil
        )
        let decoded = try JSONDecoder().decode(MonitoredAccount.self,
                                               from: JSONEncoder().encode(legacy))

        XCTAssertEqual(decoded.displayName, "Legacy Person")
        XCTAssertNil(decoded.profileName)
        XCTAssertNil(decoded.email)
        XCTAssertNil(decoded.planExpiresAt)
        XCTAssertNil(decoded.trialExpiresAt)
    }

    func testAuthoritativeProviderDetailsReplaceIncorrectStoredMetadata() {
        var account = MonitoredAccount(
            id: UUID(), providerID: .chatGPT, displayName: "Old fallback",
            workspaceID: "workspace", plan: "wrong", addedAt: .now,
            profileName: "Wrong Name", email: "wrong@example.com",
            planExpiresAt: Date(timeIntervalSince1970: 2_000),
            trialExpiresAt: Date(timeIntervalSince1970: 3_000)
        )

        account.mergeProviderDetails(.init(
            profileName: "Ada Lovelace",
            displayName: "Ada Lovelace",
            email: "ada@example.com",
            plan: "pro_20x",
            planExpiresAt: Date(timeIntervalSince1970: 4_000),
            replacesMissingFields: true
        ))

        XCTAssertEqual(account.displayName, "Ada Lovelace")
        XCTAssertEqual(account.profileName, "Ada Lovelace")
        XCTAssertEqual(account.email, "ada@example.com")
        XCTAssertEqual(account.plan, "pro_20x")
        XCTAssertEqual(account.planExpiresAt, Date(timeIntervalSince1970: 4_000))
        XCTAssertNil(account.trialExpiresAt)
    }

    func testAuthoritativeMissingProviderFieldsClearStaleValues() {
        var account = MonitoredAccount(
            id: UUID(), providerID: .kimi, displayName: "Old",
            workspaceID: "workspace", plan: "old", addedAt: .now,
            profileName: "Wrong", email: "wrong@example.com",
            planExpiresAt: Date(timeIntervalSince1970: 2_000)
        )

        account.mergeProviderDetails(.init(
            displayName: "Kimi Code account",
            replacesMissingFields: true
        ))

        XCTAssertEqual(account.displayName, "Kimi Code account")
        XCTAssertNil(account.profileName)
        XCTAssertNil(account.email)
        XCTAssertNil(account.plan)
        XCTAssertNil(account.planExpiresAt)
    }

    func testFullSFSymbolCatalogIsBundled() throws {
        let data = try XCTUnwrap(NSDataAsset(name: "SFSymbolNames")?.data)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let symbols = try XCTUnwrap(root["symbols"] as? [[String: Any]])
        let names = Set(symbols.compactMap { $0["name"] as? String })

        XCTAssertGreaterThan(symbols.count, 9_000)
        XCTAssertEqual(names.count, symbols.count)
        XCTAssertTrue(names.isSuperset(of: ["clock", "person.crop.circle", "sparkles"]))
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return state
    }
}
