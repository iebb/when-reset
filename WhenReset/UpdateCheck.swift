import Foundation
import Observation
import StoreKit
import UserNotifications
#if os(iOS)
import UIKit
#endif

/// Soft update check for Blinky on iPhone and iPad.
///
/// The app compares the installed marketing version and build, then opens the
/// App Store or TestFlight. It never downloads or installs a binary.
///
/// App Store installs use iTunes Lookup, which only knows the public App Store
/// version. TestFlight installs read `update-check.json` from `master`:
/// `https://raw.githubusercontent.com/harrisliangsu/blinky-ios/master/update-check.json`
/// That branch is the durable one the upload workflow updates after a TestFlight
/// build is accepted. A pre-release binary reports a failed check until the file
/// is on `master`, rather than following a temporary branch such as
/// `cursor/ios-overhaul-verify`.

enum InstallChannel: String, Equatable, Sendable, CaseIterable {
    case testFlight
    case appStore
    case development

    var title: String {
        switch self {
        case .testFlight: String.localized("TestFlight")
        case .appStore: String.localized("App Store")
        case .development: String.localized("Development")
        }
    }
}

enum StoreKitEnvironmentHint: String, Equatable, Sendable {
    case production
    case sandbox
    case xcode
    case testFlight
}

extension StoreKitEnvironmentHint {
    init?(_ environment: AppStore.Environment) {
        if environment == .production {
            self = .production
        } else if environment == .sandbox {
            self = .sandbox
        } else if environment == .xcode {
            self = .xcode
        } else if environment.rawValue.range(of: "testflight", options: .caseInsensitive) != nil {
            self = .testFlight
        } else {
            return nil
        }
    }
}

enum InstallChannelDetector {
    /// `sandboxReceipt` in the receipt path, or a StoreKit sandbox / TestFlight
    /// environment, is TestFlight. A production receipt or production environment
    /// is the App Store. Simulator and Xcode installs fall through to development
    /// only when neither of those signals is present.
    static func channel(
        receiptPath: String?,
        storeKitEnvironment: StoreKitEnvironmentHint?,
        isSimulator: Bool
    ) -> InstallChannel {
        let path = receiptPath ?? ""
        if path.contains("sandboxReceipt")
            || storeKitEnvironment == .sandbox
            || storeKitEnvironment == .testFlight {
            return .testFlight
        }
        if storeKitEnvironment == .production || isProductionReceipt(path) {
            return .appStore
        }
        if isSimulator || storeKitEnvironment == .xcode || storeKitEnvironment == nil {
            return .development
        }
        return .development
    }

    private static func isProductionReceipt(_ path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent == "receipt"
    }
}

@MainActor
enum InstallChannelProbe {
    static func receiptChannel(bundle: Bundle = .main) -> InstallChannel {
        InstallChannelDetector.channel(
            receiptPath: bundle.appStoreReceiptURL?.path,
            storeKitEnvironment: nil,
            isSimulator: isSimulator
        )
    }

    static func current(bundle: Bundle = .main) async -> InstallChannel {
        InstallChannelDetector.channel(
            receiptPath: bundle.appStoreReceiptURL?.path,
            storeKitEnvironment: await storeKitEnvironment(),
            isSimulator: isSimulator
        )
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    private static func storeKitEnvironment() async -> StoreKitEnvironmentHint? {
        do {
            let result = try await AppTransaction.shared
            switch result {
            case .verified(let transaction):
                return StoreKitEnvironmentHint(transaction.environment)
            case .unverified(let transaction, _):
                return StoreKitEnvironmentHint(transaction.environment)
            @unknown default:
                return nil
            }
        } catch {
            return nil
        }
    }
}

struct ReleaseIdentity: Equatable, Sendable {
    var marketingVersion: String
    var build: String?
}

enum InstalledBuild {
    static func current(bundle: Bundle = .main) -> ReleaseIdentity {
        ReleaseIdentity(
            marketingVersion: string("CFBundleShortVersionString", bundle: bundle) ?? "0",
            build: string("CFBundleVersion", bundle: bundle)
        )
    }

    private static func string(_ key: String, bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum VersionComparison {
    static func isRemoteNewer(local: ReleaseIdentity, remote: ReleaseIdentity) -> Bool {
        switch marketingOrder(local: local.marketingVersion, remote: remote.marketingVersion) {
        case .remoteNewer:
            return true
        case .localNewer:
            return false
        case .same:
            return buildIsNewer(remote: remote.build, than: local.build)
        }
    }

    private enum MarketingOrder {
        case remoteNewer
        case localNewer
        case same
    }

    private static func marketingOrder(local: String, remote: String) -> MarketingOrder {
        switch (ParsedMarketing.parse(local), ParsedMarketing.parse(remote)) {
        case let (parsedLocal?, parsedRemote?):
            if parsedLocal == parsedRemote { return .same }
            return parsedLocal < parsedRemote ? .remoteNewer : .localNewer
        case (nil, nil):
            let lhs = local.trimmingCharacters(in: .whitespacesAndNewlines)
            let rhs = remote.trimmingCharacters(in: .whitespacesAndNewlines)
            return lhs == rhs ? .same : .localNewer
        case (_?, nil):
            return .localNewer
        case (nil, _?):
            return .remoteNewer
        }
    }

    static func buildIsNewer(remote: String?, than local: String?) -> Bool {
        guard let remoteBuild = normalized(remote) else { return false }
        guard let localBuild = normalized(local) else { return true }
        if remoteBuild == localBuild { return false }
        let order = remoteBuild.compare(
            localBuild,
            options: .numeric,
            locale: Locale(identifier: "en_US_POSIX")
        )
        return order == .orderedDescending
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct ParsedMarketing: Comparable {
    var core: [Int]
    var prerelease: [Identifier]

    struct Identifier: Comparable {
        enum Value: Equatable {
            case number(Int)
            case text(String)
        }

        var value: Value

        static func < (lhs: Self, rhs: Self) -> Bool {
            switch (lhs.value, rhs.value) {
            case let (.number(left), .number(right)):
                return left < right
            case let (.text(left), .text(right)):
                return left < right
            case (.number, .text):
                return true
            case (.text, .number):
                return false
            }
        }
    }

    static func == (lhs: ParsedMarketing, rhs: ParsedMarketing) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    static func < (lhs: ParsedMarketing, rhs: ParsedMarketing) -> Bool {
        let count = max(lhs.core.count, rhs.core.count)
        for index in 0..<count {
            let left = index < lhs.core.count ? lhs.core[index] : 0
            let right = index < rhs.core.count ? rhs.core[index] : 0
            if left != right { return left < right }
        }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        let shared = min(lhs.prerelease.count, rhs.prerelease.count)
        for index in 0..<shared where lhs.prerelease[index] != rhs.prerelease[index] {
            return lhs.prerelease[index] < rhs.prerelease[index]
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    static func parse(_ raw: String) -> ParsedMarketing? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let plus = text.firstIndex(of: "+") {
            text = String(text[..<plus])
        }
        guard !text.isEmpty else { return nil }
        let pieces = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let coreSource = pieces.first, !coreSource.isEmpty else { return nil }
        var core: [Int] = []
        for part in coreSource.split(separator: ".", omittingEmptySubsequences: false) {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let number = Int(part) else { return nil }
            core.append(number)
        }
        guard !core.isEmpty else { return nil }
        var prerelease: [Identifier] = []
        if pieces.count == 2 {
            guard !pieces[1].isEmpty else { return nil }
            for identifier in pieces[1].split(separator: ".", omittingEmptySubsequences: false) {
                guard !identifier.isEmpty else { return nil }
                if identifier.allSatisfy(\.isNumber), let number = Int(identifier) {
                    prerelease.append(Identifier(value: .number(number)))
                } else {
                    prerelease.append(Identifier(value: .text(String(identifier))))
                }
            }
        }
        return ParsedMarketing(core: core, prerelease: prerelease)
    }
}

enum UpdateLinks {
    static let appID = 6_829_609_877

    static var lookup: URL {
        URL(string: "https://itunes.apple.com/lookup?id=\(appID)")!
    }

    static var appStore: URL {
        URL(string: "https://apps.apple.com/app/id\(appID)")!
    }

    static var testFlight: URL {
        URL(string: "https://beta.itunes.apple.com/v1/app/\(appID)")!
    }

    static func openURL(for channel: InstallChannel) -> URL? {
        switch channel {
        case .appStore: appStore
        case .testFlight: testFlight
        case .development: nil
        }
    }
}

enum UpdateFeedSource {
    static let repository = "harrisliangsu/blinky-ios"
    static let branch = "master"

    static var url: URL {
        URL(string: "https://raw.githubusercontent.com/\(repository)/\(branch)/update-check.json")!
    }
}

enum UpdateSource: Equatable, Sendable {
    case appStoreLookup
    case testFlightFeed

    var url: URL {
        switch self {
        case .appStoreLookup: UpdateLinks.lookup
        case .testFlightFeed: UpdateFeedSource.url
        }
    }

    static func forChannel(_ channel: InstallChannel) -> UpdateSource {
        switch channel {
        case .appStore: .appStoreLookup
        case .testFlight, .development: .testFlightFeed
        }
    }
}

enum UpdateParseError: Error, Equatable, Sendable {
    case invalidJSON
    case missingVersion
    case notListed
}

enum UpdateFeedParser {
    static func parse(_ data: Data) throws -> ReleaseIdentity {
        let document: FeedDocument
        do {
            document = try JSONDecoder().decode(FeedDocument.self, from: data)
        } catch {
            throw UpdateParseError.invalidJSON
        }
        let version = document.ios.version.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = document.ios.build.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, !build.isEmpty else { throw UpdateParseError.missingVersion }
        return ReleaseIdentity(marketingVersion: version, build: build)
    }

    private struct FeedDocument: Decodable {
        var ios: Entry

        struct Entry: Decodable {
            var version: String
            var build: String
            var updatedAt: String?
        }
    }
}

enum AppStoreLookupParser {
    static func parse(_ data: Data) throws -> ReleaseIdentity {
        let document: LookupDocument
        do {
            document = try JSONDecoder().decode(LookupDocument.self, from: data)
        } catch {
            throw UpdateParseError.invalidJSON
        }
        if let resultCount = document.resultCount, resultCount == 0 {
            throw UpdateParseError.notListed
        }
        guard !document.results.isEmpty else { throw UpdateParseError.notListed }
        let entry = document.results.first { $0.trackId == UpdateLinks.appID } ?? document.results[0]
        let version = entry.version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !version.isEmpty else { throw UpdateParseError.missingVersion }
        let build = entry.build?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReleaseIdentity(marketingVersion: version, build: build?.isEmpty == false ? build : nil)
    }

    private struct LookupDocument: Decodable {
        var resultCount: Int?
        var results: [Entry]

        struct Entry: Decodable {
            var version: String?
            var build: String?
            var trackId: Int?
        }
    }
}

enum UpdateCheckFailure: Error, Equatable, Sendable {
    case network
    case parse
}

enum UpdateAvailability: Equatable, Sendable {
    case upToDate
    case available(ReleaseIdentity)
}

protocol UpdateCheckTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, Int)
}

struct URLSessionTransport: UpdateCheckTransport {
    var session: URLSession = UpdateCheckSession.shared

    func data(for request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http.statusCode)
    }
}

enum UpdateCheckSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
}

enum UpdateRequest {
    static func make(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("Blinky-iOS", forHTTPHeaderField: "User-Agent")
        return request
    }
}

struct UpdateChecker: Sendable {
    var transport: any UpdateCheckTransport

    static let live = UpdateChecker(transport: URLSessionTransport())

    func check(source: UpdateSource, local: ReleaseIdentity) async -> Result<UpdateAvailability, UpdateCheckFailure> {
        do {
            let (data, status) = try await transport.data(for: UpdateRequest.make(url: source.url))
            guard (200..<300).contains(status) else { return .failure(.network) }
            let remote = try parse(data, source: source)
            if VersionComparison.isRemoteNewer(local: local, remote: remote) {
                return .success(.available(remote))
            }
            return .success(.upToDate)
        } catch is UpdateParseError {
            return .failure(.parse)
        } catch is DecodingError {
            return .failure(.parse)
        } catch {
            return .failure(.network)
        }
    }

    private func parse(_ data: Data, source: UpdateSource) throws -> ReleaseIdentity {
        switch source {
        case .appStoreLookup:
            return try AppStoreLookupParser.parse(data)
        case .testFlightFeed:
            return try UpdateFeedParser.parse(data)
        }
    }
}

enum UpdateDiscoveryMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case notify
    case manual

    var id: String { rawValue }
}

enum UpdateCheckPhase: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(version: String, build: String?)
    case failed(UpdateCheckFailure)
}

enum StoredUpdateStatus: Codable, Equatable, Sendable {
    case upToDate
    case available(version: String, build: String?)
    case failedNetwork
    case failedParse

    var phase: UpdateCheckPhase {
        switch self {
        case .upToDate: .upToDate
        case .available(let version, let build): .available(version: version, build: build)
        case .failedNetwork: .failed(.network)
        case .failedParse: .failed(.parse)
        }
    }
}

enum UpdateIdentity {
    static func key(for release: ReleaseIdentity) -> String {
        key(version: release.marketingVersion, build: release.build)
    }

    static func key(version: String, build: String?) -> String {
        "\(version)|\(build ?? "")"
    }
}

enum UpdateCheckPolicy {
    static let minimumInterval: TimeInterval = 24 * 60 * 60

    static func shouldSoftCheck(
        mode: UpdateDiscoveryMode,
        lastCheckAt: Date?,
        now: Date,
        interval: TimeInterval = minimumInterval
    ) -> Bool {
        guard mode == .notify else { return false }
        guard let lastCheckAt else { return true }
        return now.timeIntervalSince(lastCheckAt) >= interval
    }

    /// A scheduled check reminds once per remote version and build. Manual checks
    /// and a turned-off remind setting produce no banner or notification.
    static func pendingRelease(
        scheduledCheck: Bool,
        remindWhenAvailable: Bool,
        availability: UpdateAvailability,
        lastRemindedIdentity: String?
    ) -> ReleaseIdentity? {
        guard scheduledCheck, remindWhenAvailable else { return nil }
        guard case .available(let remote) = availability else { return nil }
        guard UpdateIdentity.key(for: remote) != lastRemindedIdentity else { return nil }
        return remote
    }
}

struct UpdateCheckPreferences: Codable, Equatable, Sendable {
    var mode: UpdateDiscoveryMode
    var remindWhenAvailable: Bool
    var lastCheckAt: Date?
    var status: StoredUpdateStatus?
    var lastRemindedIdentity: String?

    static let storageKey = "settings.updateCheck"

    private enum CodingKeys: String, CodingKey {
        case mode
        case remindWhenAvailable
        case lastCheckAt
        case status
        case lastRemindedIdentity
    }

    init(
        mode: UpdateDiscoveryMode = .notify,
        remindWhenAvailable: Bool = true,
        lastCheckAt: Date? = nil,
        status: StoredUpdateStatus? = nil,
        lastRemindedIdentity: String? = nil
    ) {
        self.mode = mode
        self.remindWhenAvailable = remindWhenAvailable
        self.lastCheckAt = lastCheckAt
        self.status = status
        self.lastRemindedIdentity = lastRemindedIdentity
    }

    static func load(from defaults: UserDefaults) -> UpdateCheckPreferences {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(UpdateCheckPreferences.self, from: data) else {
            return UpdateCheckPreferences()
        }
        return decoded
    }

    func save(to defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(self), forKey: storageKey)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(remindWhenAvailable, forKey: .remindWhenAvailable)
        try container.encodeIfPresent(lastCheckAt, forKey: .lastCheckAt)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(lastRemindedIdentity, forKey: .lastRemindedIdentity)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(UpdateDiscoveryMode.self, forKey: .mode) ?? .notify
        remindWhenAvailable = try container.decodeIfPresent(Bool.self, forKey: .remindWhenAvailable) ?? true
        lastCheckAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckAt)
        status = try container.decodeIfPresent(StoredUpdateStatus.self, forKey: .status)
        lastRemindedIdentity = try container.decodeIfPresent(String.self, forKey: .lastRemindedIdentity)
    }
}

enum UpdateNotification {
    static let identifierPrefix = "blinky.update."
    static let urlUserInfoKey = "blinkyUpdateURL"
}

enum UpdateCopy {
    static func available(version: String, build: String?) -> String {
        if let build, !build.isEmpty {
            return UsageNotificationCopy.format("Version %@ (%@) is available.", version, build)
        }
        return UsageNotificationCopy.format("Version %@ is available.", version)
    }
}

struct UpdateBanner: Equatable, Identifiable, Sendable {
    var version: String
    var build: String?
    var openURL: URL?

    var id: String { UpdateIdentity.key(version: version, build: build) }
}

@MainActor
enum UpdateNotifier {
    static func post(release: ReleaseIdentity, channel: InstallChannel) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
        let content = UNMutableNotificationContent()
        content.title = String.localized("Blinky update available")
        content.body = UpdateCopy.available(version: release.marketingVersion, build: release.build)
        content.threadIdentifier = "blinky-update"
        if let url = UpdateLinks.openURL(for: channel) {
            content.userInfo = [UpdateNotification.urlUserInfoKey: url.absoluteString]
        }
        if settings.soundSetting == .enabled {
            content.sound = .default
        }
        let request = UNNotificationRequest(
            identifier: UpdateNotification.identifierPrefix + UpdateIdentity.key(for: release),
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }
}

@MainActor
@Observable
final class UpdateCheckController {
    private(set) var channel: InstallChannel = .development
    private(set) var phase: UpdateCheckPhase = .idle
    private(set) var preferences: UpdateCheckPreferences
    private(set) var banner: UpdateBanner?
    private var isChecking = false
    private let checker: UpdateChecker
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, checker: UpdateChecker = .live) {
        self.defaults = defaults
        self.checker = checker
        let loaded = UpdateCheckPreferences.load(from: defaults)
        preferences = loaded
        if let status = loaded.status {
            phase = status.phase
        }
    }

    var showsAboutBadge: Bool {
        guard preferences.remindWhenAvailable else { return false }
        if case .available = phase { return true }
        return false
    }

    var skipsAutomaticChecks: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        #if DEBUG
        if ScreenshotLaunch.isActive { return true }
        #endif
        return false
    }

    func prepare() async {
        channel = InstallChannelProbe.receiptChannel()
        guard !skipsAutomaticChecks else { return }
        channel = await InstallChannelProbe.current()
        await softCheckIfNeeded()
    }

    func softCheckIfNeeded() async {
        guard !skipsAutomaticChecks else { return }
        guard UpdateCheckPolicy.shouldSoftCheck(
            mode: preferences.mode,
            lastCheckAt: preferences.lastCheckAt,
            now: Date()
        ) else { return }
        await runCheck(scheduled: true)
    }

    func checkNow() async {
        await runCheck(scheduled: false)
    }

    func setMode(_ mode: UpdateDiscoveryMode) {
        preferences.mode = mode
        preferences.save(to: defaults)
        guard mode == .notify else { return }
        Task { await softCheckIfNeeded() }
    }

    func setRemind(_ enabled: Bool) {
        preferences.remindWhenAvailable = enabled
        preferences.save(to: defaults)
        guard enabled, case .available(let version, let build) = phase else {
            if !enabled { banner = nil }
            return
        }
        let remote = ReleaseIdentity(marketingVersion: version, build: build)
        Task {
            await deliverReminder(for: remote, scheduled: preferences.mode == .notify)
            preferences.save(to: defaults)
        }
    }

    func dismissBanner() {
        if let banner {
            preferences.lastRemindedIdentity = banner.id
            preferences.save(to: defaults)
        }
        banner = nil
    }

    func open(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #endif
    }

    private func runCheck(scheduled: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        phase = .checking
        let result = await checker.check(
            source: UpdateSource.forChannel(channel),
            local: InstalledBuild.current()
        )
        preferences.lastCheckAt = Date()
        switch result {
        case .success(.upToDate):
            phase = .upToDate
            preferences.status = .upToDate
            banner = nil
        case .success(.available(let remote)):
            phase = .available(version: remote.marketingVersion, build: remote.build)
            preferences.status = .available(version: remote.marketingVersion, build: remote.build)
            await deliverReminder(for: remote, scheduled: scheduled)
        case .failure(let failure):
            phase = .failed(failure)
            preferences.status = failure == .network ? .failedNetwork : .failedParse
            banner = nil
        }
        preferences.save(to: defaults)
    }

    private func deliverReminder(for remote: ReleaseIdentity, scheduled: Bool) async {
        guard UpdateCheckPolicy.pendingRelease(
            scheduledCheck: scheduled,
            remindWhenAvailable: preferences.remindWhenAvailable,
            availability: .available(remote),
            lastRemindedIdentity: preferences.lastRemindedIdentity
        ) != nil else { return }

        let identity = UpdateIdentity.key(for: remote)
        preferences.lastRemindedIdentity = identity
        if await notificationsAlreadyAuthorized(),
           await UpdateNotifier.post(release: remote, channel: channel) {
            banner = nil
            return
        }
        banner = UpdateBanner(
            version: remote.marketingVersion,
            build: remote.build,
            openURL: UpdateLinks.openURL(for: channel)
        )
    }

    private func notificationsAlreadyAuthorized() async -> Bool {
        switch await UsageNotificationService.authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }
}
