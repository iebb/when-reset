import Foundation

enum SharedSnapshotStore {
    static let suiteName = "group.ad.neko.when"
    private static let snapshotsKey = "usageSnapshots.v1"

    static func load() -> [UsageSnapshot] {
        guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: snapshotsKey) else { return [] }
        return (try? JSONDecoder().decode([UsageSnapshot].self, from: data)) ?? []
    }

    static func save(_ snapshots: [UsageSnapshot]) {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        UserDefaults(suiteName: suiteName)?.set(data, forKey: snapshotsKey)
    }
}

enum UsageRefreshSource: String, Codable, Hashable, Sendable {
    case launch
    case manual
    case accountLink
    case background
    case demo
}

struct UsageHistoryPoint: Codable, Hashable, Identifiable, Sendable {
    var accountID: UUID
    var providerID: ProviderID
    var metricID: String
    var metricTitle: String
    var kind: UsageWindowKind?
    var windowMinutes: Int?
    var remainingPercent: Double
    var recordedAt: Date
    var resetsAt: Date
    var secondsUntilReset: TimeInterval
    var source: UsageRefreshSource
    var plan: String? = nil

    var id: String {
        "\(accountID.uuidString):\(metricID):\(Int64(recordedAt.timeIntervalSince1970 * 1_000))"
    }
}

struct UsageNotificationEvent: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case quotaReset
        case probableEarlyReset
        case probableEarlyWeeklyReset
        case newBankedReset
    }

    var id: String
    var accountID: UUID
    var kind: Kind
    var title: String
    var body: String
    var createdAt: Date
    fileprivate var deduplicationKey: String
}

struct UsageHistoryLoadResult: Sendable {
    var points: [UsageHistoryPoint]
    var pendingNotifications: [UsageNotificationEvent]
}

struct UsageHistoryRecordResult: Sendable {
    var points: [UsageHistoryPoint]
    var pendingNotifications: [UsageNotificationEvent]
}

private struct BankedCreditObservation: Codable, Hashable, Sendable {
    var id: String
    var expiresAt: Date?
    var grantedAt: Date?
}

private struct SeenBankedCredit: Codable, Hashable, Sendable {
    var lastSeenAt: Date
    var expiresAt: Date?
}

private struct PendingWeeklyRecovery: Codable, Hashable, Sendable {
    var previousRemainingPercent: Double
    var currentRemainingPercent: Double
    var previousResetAt: Date
    var observedAt: Date
}

private struct PendingCreditConsumption: Codable, Hashable, Sendable {
    var creditIDs: [String]
    var observedAt: Date
}

private struct UsageAlertDetectorState: Codable, Hashable, Sendable {
    var sourceIdentity: String
    var lastObservedAt: Date
    var metricObservations: [String: UsageHistoryPoint]
    var weeklyObservation: UsageHistoryPoint?
    var creditBaselineEstablished: Bool
    var availableCredits: [String: BankedCreditObservation]
    var seenCredits: [String: SeenBankedCredit]
    var lastAvailableResetCount: Int?
    var pendingWeeklyRecovery: PendingWeeklyRecovery?
    var pendingCreditConsumption: PendingCreditConsumption?

    init(sourceIdentity: String, lastObservedAt: Date, points: [UsageHistoryPoint],
         weeklyObservation: UsageHistoryPoint?,
         credits: [BankedCreditObservation], availableResetCount: Int) {
        self.sourceIdentity = sourceIdentity
        self.lastObservedAt = lastObservedAt
        metricObservations = Dictionary(
            points.map { ($0.metricID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        self.weeklyObservation = weeklyObservation
        creditBaselineEstablished = !credits.isEmpty || availableResetCount == 0
        availableCredits = Dictionary(
            credits.map { ($0.id, $0) },
            uniquingKeysWith: { existing, candidate in
                (candidate.expiresAt ?? .distantPast) > (existing.expiresAt ?? .distantPast)
                    ? candidate : existing
            }
        )
        seenCredits = Dictionary(
            credits.map {
                ($0.id, SeenBankedCredit(lastSeenAt: lastObservedAt, expiresAt: $0.expiresAt))
            },
            uniquingKeysWith: { existing, candidate in
                (candidate.expiresAt ?? .distantPast) > (existing.expiresAt ?? .distantPast)
                    ? candidate : existing
            }
        )
        lastAvailableResetCount = availableResetCount
        pendingWeeklyRecovery = nil
        pendingCreditConsumption = nil
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sourceIdentity = try values.decode(String.self, forKey: .sourceIdentity)
        lastObservedAt = try values.decode(Date.self, forKey: .lastObservedAt)
        weeklyObservation = try values.decodeIfPresent(UsageHistoryPoint.self,
                                                       forKey: .weeklyObservation)
        metricObservations = try values.decodeIfPresent(
            [String: UsageHistoryPoint].self,
            forKey: .metricObservations
        ) ?? weeklyObservation.map { [$0.metricID: $0] } ?? [:]
        creditBaselineEstablished = try values.decodeIfPresent(
            Bool.self,
            forKey: .creditBaselineEstablished
        ) ?? false
        availableCredits = try values.decodeIfPresent(
            [String: BankedCreditObservation].self,
            forKey: .availableCredits
        ) ?? [:]
        seenCredits = try values.decodeIfPresent(
            [String: SeenBankedCredit].self,
            forKey: .seenCredits
        ) ?? [:]
        lastAvailableResetCount = try values.decodeIfPresent(Int.self,
                                                             forKey: .lastAvailableResetCount)
        pendingWeeklyRecovery = try values.decodeIfPresent(
            PendingWeeklyRecovery.self,
            forKey: .pendingWeeklyRecovery
        )
        pendingCreditConsumption = try values.decodeIfPresent(
            PendingCreditConsumption.self,
            forKey: .pendingCreditConsumption
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sourceIdentity, lastObservedAt, metricObservations, weeklyObservation
        case creditBaselineEstablished, availableCredits, seenCredits, lastAvailableResetCount
        case pendingWeeklyRecovery, pendingCreditConsumption
    }
}

private struct UsageHistoryArchive: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion = currentSchemaVersion
    var points: [UsageHistoryPoint] = []
    var detectorStates: [UUID: UsageAlertDetectorState] = [:]
    var pendingNotifications: [UsageNotificationEvent] = []
    var deliveredNotificationIDs: [String: Date] = [:]
    var notificationDeduplicationKeys: [String: Date] = [:]
}

enum UsageHistoryStoreError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "Usage history was created by a newer app version (schema \(version))."
        }
    }
}

actor UsageHistoryStore {
    static let retentionInterval: TimeInterval = 35 * 24 * 60 * 60
    static let pendingNotificationLifetime: TimeInterval = 24 * 60 * 60
    static let refreshTaskIdentifier = "ad.neko.when.refresh"

    private let fileURL: URL
    private var cachedArchive: UsageHistoryArchive?

    init(fileURL: URL = UsageHistoryStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func load(now: Date = .now) throws -> UsageHistoryLoadResult {
        var archive = try loadedArchive()
        prune(&archive, now: now)
        cachedArchive = archive
        return .init(points: archive.points, pendingNotifications: archive.pendingNotifications)
    }

    func record(snapshot: UsageSnapshot, account: MonitoredAccount,
                source: UsageRefreshSource, notificationsEnabled: Bool = true,
                now: Date = .now) throws -> UsageHistoryRecordResult {
        var archive = try loadedArchive()
        prune(&archive, now: now)

        let observationSource: UsageRefreshSource = account.isDemo ? .demo : source
        let recordedPlan = normalizedPlan(snapshot.plan) ?? normalizedPlan(account.plan)
        let mappedPoints = snapshot.usageWindows.map { window in
            UsageHistoryPoint(
                accountID: account.id,
                providerID: account.providerID,
                metricID: window.metricID,
                metricTitle: window.displayTitle,
                kind: window.kind,
                windowMinutes: window.windowMinutes,
                remainingPercent: max(0, min(100, window.remainingPercent)),
                recordedAt: snapshot.fetchedAt,
                resetsAt: window.resetsAt,
                secondsUntilReset: max(0, window.resetsAt.timeIntervalSince(snapshot.fetchedAt)),
                source: observationSource,
                plan: recordedPlan
            )
        }
        let newPoints = Dictionary(
            mappedPoints.map { ($0.metricID, $0) },
            uniquingKeysWith: { _, latest in latest }
        ).values.sorted { $0.metricID < $1.metricID }

        for point in newPoints {
            archive.points.removeAll { existing in
                existing.accountID == point.accountID
                    && existing.metricID == point.metricID
                    && observationMilliseconds(existing.recordedAt) == observationMilliseconds(point.recordedAt)
            }
            archive.points.append(point)
        }
        archive.points.sort {
            if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
            if $0.accountID != $1.accountID { return $0.accountID.uuidString < $1.accountID.uuidString }
            return $0.metricID < $1.metricID
        }

        if !account.isDemo {
            updateResetDetector(
                snapshot: snapshot,
                account: account,
                points: newPoints,
                notificationsEnabled: notificationsEnabled,
                archive: &archive
            )
        }

        try persist(archive)
        cachedArchive = archive
        return .init(points: archive.points, pendingNotifications: archive.pendingNotifications)
    }

    func markNotificationsDelivered(_ ids: Set<String>, now: Date = .now) throws {
        guard !ids.isEmpty else { return }
        var archive = try loadedArchive()
        archive.pendingNotifications.removeAll { event in
            guard ids.contains(event.id) else { return false }
            archive.deliveredNotificationIDs[event.id] = now
            return true
        }
        prune(&archive, now: now)
        try persist(archive)
        cachedArchive = archive
    }

    func discardPendingNotifications(accountID: UUID, now: Date = .now) throws {
        let ids = Set(try loadedArchive().pendingNotifications
            .filter { $0.accountID == accountID }
            .map(\.id))
        try markNotificationsDelivered(ids, now: now)
    }

    func remove(accountID: UUID, now: Date = .now) throws -> [UsageHistoryPoint] {
        var archive = try loadedArchive()
        archive.points.removeAll { $0.accountID == accountID }
        archive.detectorStates.removeValue(forKey: accountID)
        archive.pendingNotifications.removeAll { $0.accountID == accountID }
        prune(&archive, now: now)
        try persist(archive)
        cachedArchive = archive
        return archive.points
    }

    private func updateResetDetector(snapshot: UsageSnapshot, account: MonitoredAccount,
                                     points: [UsageHistoryPoint], notificationsEnabled: Bool,
                                     archive: inout UsageHistoryArchive) {
        let observedAt = snapshot.fetchedAt
        let sourceIdentity = "\(account.providerID.rawValue):\(account.workspaceID)"
        let weekly = points.first { point in
            point.kind == .weekly || point.windowMinutes == 10_080 || point.metricID == "weekly"
        }
        let creditObservations = snapshot.availableResetCredits
            .filter { ($0.expiresAt ?? .distantFuture) > observedAt }
            .map {
                BankedCreditObservation(id: $0.id, expiresAt: $0.expiresAt, grantedAt: $0.grantedAt)
            }
        let credits = Dictionary(
            creditObservations.map { ($0.id, $0) },
            uniquingKeysWith: { existing, candidate in
                (candidate.expiresAt ?? .distantPast) > (existing.expiresAt ?? .distantPast)
                    ? candidate : existing
            }
        ).values.sorted { $0.id < $1.id }

        guard var state = archive.detectorStates[account.id],
              state.sourceIdentity == sourceIdentity else {
            archive.detectorStates[account.id] = UsageAlertDetectorState(
                sourceIdentity: sourceIdentity,
                lastObservedAt: observedAt,
                points: points,
                weeklyObservation: weekly,
                credits: credits,
                availableResetCount: snapshot.availableResetCount
            )
            return
        }
        guard observedAt > state.lastObservedAt else { return }

        let accountName = account.resolvedDisplayName
        detectQuotaResets(
            previousPoints: state.metricObservations,
            currentPoints: points,
            account: account,
            sourceIdentity: sourceIdentity,
            observedAt: observedAt,
            notificationsEnabled: notificationsEnabled,
            archive: &archive
        )

        guard account.providerID == .chatGPT else {
            updateMetricObservations(points, state: &state)
            state.lastObservedAt = observedAt
            archive.detectorStates[account.id] = state
            return
        }

        let currentCreditMap = Dictionary(
            credits.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let hadCreditIdentityBaseline = state.creditBaselineEstablished
        let newlySeen = credits.filter { state.seenCredits[$0.id] == nil }
        if hadCreditIdentityBaseline, !newlySeen.isEmpty {
            let count = newlySeen.count
            enqueue(
                kind: .newBankedReset,
                accountID: account.id,
                title: count == 1 ? "New banked reset available" : "New banked resets available",
                body: count == 1
                    ? "A new banked reset was added to \(accountName)."
                    : "\(count) new banked resets were added to \(accountName).",
                createdAt: observedAt,
                deduplicationKey: "new-credit:\(sourceIdentity):\(newlySeen.map(\.id).sorted().joined(separator: ","))",
                notificationsEnabled: notificationsEnabled,
                archive: &archive
            )
        } else if credits.isEmpty,
                  let previousCount = state.lastAvailableResetCount,
                  snapshot.availableResetCount > previousCount {
            enqueue(
                kind: .newBankedReset,
                accountID: account.id,
                title: "Banked resets increased",
                body: "\(accountName) now has \(snapshot.availableResetCount) banked resets available.",
                createdAt: observedAt,
                deduplicationKey: "credit-count:\(sourceIdentity):\(previousCount):\(snapshot.availableResetCount):\(observationMilliseconds(observedAt))",
                notificationsEnabled: notificationsEnabled,
                archive: &archive
            )
        } else if !hadCreditIdentityBaseline, !credits.isEmpty {
            if let previousCount = state.lastAvailableResetCount,
               snapshot.availableResetCount > previousCount {
                enqueue(
                    kind: .newBankedReset,
                    accountID: account.id,
                    title: "Banked resets increased",
                    body: "\(accountName) now has \(snapshot.availableResetCount) banked resets available.",
                    createdAt: observedAt,
                    deduplicationKey: "credit-baseline-count:\(sourceIdentity):\(previousCount):\(snapshot.availableResetCount):\(observationMilliseconds(observedAt))",
                    notificationsEnabled: notificationsEnabled,
                    archive: &archive
                )
            }
            state.creditBaselineEstablished = true
        }

        for credit in credits {
            state.seenCredits[credit.id] = SeenBankedCredit(lastSeenAt: observedAt,
                                                            expiresAt: credit.expiresAt)
        }

        let disappearedUnexpiredCredits = state.availableCredits.values.filter { previous in
            currentCreditMap[previous.id] == nil
                && (previous.expiresAt ?? .distantPast) > observedAt.addingTimeInterval(5 * 60)
        }
        let recentPendingRecovery = state.pendingWeeklyRecovery.flatMap { pending in
            observedAt.timeIntervalSince(pending.observedAt) <= 60 * 60 ? pending : nil
        }
        let recentPendingConsumption = state.pendingCreditConsumption.flatMap { pending in
            observedAt.timeIntervalSince(pending.observedAt) <= 60 * 60 ? pending : nil
        }

        var currentRecovery: PendingWeeklyRecovery?
        if let previous = state.weeklyObservation, let weekly,
           weekly.recordedAt > previous.recordedAt,
           canonicalPlan(previous.plan) == canonicalPlan(weekly.plan) {
            let recovery = weekly.remainingPercent - previous.remainingPercent
            let scheduledResetIsStillDistant = previous.resetsAt > observedAt.addingTimeInterval(15 * 60)
            if recovery >= 1, scheduledResetIsStillDistant {
                currentRecovery = PendingWeeklyRecovery(
                    previousRemainingPercent: previous.remainingPercent,
                    currentRemainingPercent: weekly.remainingPercent,
                    previousResetAt: previous.resetsAt,
                    observedAt: observedAt
                )
            }
        }

        let correlatedRecovery: PendingWeeklyRecovery?
        if let currentRecovery,
           !disappearedUnexpiredCredits.isEmpty || recentPendingConsumption != nil {
            correlatedRecovery = currentRecovery
        } else if !disappearedUnexpiredCredits.isEmpty, let recentPendingRecovery {
            correlatedRecovery = recentPendingRecovery
        } else if let currentRecovery,
                  currentRecovery.currentRemainingPercent - currentRecovery.previousRemainingPercent >= 10 {
            correlatedRecovery = currentRecovery
        } else {
            correlatedRecovery = nil
        }

        if let recovery = correlatedRecovery {
            let previousValue = Int(recovery.previousRemainingPercent.rounded())
            let currentValue = Int(recovery.currentRemainingPercent.rounded())
            enqueue(
                kind: .probableEarlyWeeklyReset,
                accountID: account.id,
                title: "Weekly limit reset early",
                body: "\(accountName)’s weekly allowance increased from \(previousValue)% to \(currentValue)% before its scheduled reset. A banked reset was probably applied.",
                createdAt: observedAt,
                deduplicationKey: "early-weekly:\(sourceIdentity):\(cycleBucket(recovery.previousResetAt))",
                notificationsEnabled: notificationsEnabled,
                archive: &archive
            )
            state.pendingWeeklyRecovery = nil
            state.pendingCreditConsumption = nil
        } else {
            state.pendingWeeklyRecovery = currentRecovery ?? recentPendingRecovery
            if !disappearedUnexpiredCredits.isEmpty {
                state.pendingCreditConsumption = PendingCreditConsumption(
                    creditIDs: disappearedUnexpiredCredits.map(\.id).sorted(),
                    observedAt: observedAt
                )
            } else {
                state.pendingCreditConsumption = recentPendingConsumption
            }
        }

        if let weekly, state.weeklyObservation == nil || weekly.recordedAt > state.weeklyObservation!.recordedAt {
            state.weeklyObservation = weekly
        }
        updateMetricObservations(points, state: &state)
        state.availableCredits = currentCreditMap
        state.lastAvailableResetCount = snapshot.availableResetCount
        state.lastObservedAt = observedAt
        archive.detectorStates[account.id] = state
    }

    private func detectQuotaResets(previousPoints: [String: UsageHistoryPoint],
                                   currentPoints: [UsageHistoryPoint],
                                   account: MonitoredAccount, sourceIdentity: String,
                                   observedAt: Date, notificationsEnabled: Bool,
                                   archive: inout UsageHistoryArchive) {
        var scheduledResets: [(previous: UsageHistoryPoint, current: UsageHistoryPoint)] = []
        var probableEarlyResets: [(previous: UsageHistoryPoint, current: UsageHistoryPoint)] = []

        for current in currentPoints {
            guard let previous = previousPoints[current.metricID],
                  current.recordedAt > previous.recordedAt else { continue }

            if previous.kind != current.kind || previous.windowMinutes != current.windowMinutes {
                continue
            }
            if canonicalPlan(previous.plan) != canonicalPlan(current.plan) {
                continue
            }

            let windowDuration = TimeInterval(previous.windowMinutes ?? 120) * 60
            let targetAdvanceThreshold = max(30 * 60, windowDuration * 0.25)
            let resetCycleAdvanced = current.resetsAt.timeIntervalSince(previous.resetsAt)
                >= targetAdvanceThreshold
            let scheduledBoundaryReached = previous.resetsAt
                <= observedAt.addingTimeInterval(15 * 60)
            let increase = current.remainingPercent - previous.remainingPercent
            if scheduledBoundaryReached, resetCycleAdvanced || increase >= 5 {
                scheduledResets.append((previous, current))
                continue
            }

            let resetWasNotDue = previous.resetsAt > observedAt.addingTimeInterval(15 * 60)
            let isChatGPTWeekly = account.providerID == .chatGPT
                && (current.kind == .weekly || current.windowMinutes == 10_080
                    || current.metricID == "weekly")
            guard !isChatGPTWeekly, resetWasNotDue, increase >= 5,
                  resetCycleAdvanced || current.remainingPercent >= 95 else { continue }
            probableEarlyResets.append((previous, current))
        }

        if !scheduledResets.isEmpty {
            let titles = scheduledResets.map { $0.current.metricTitle }
            let values = scheduledResets.map {
                "\($0.current.metricTitle) \(Int($0.current.remainingPercent.rounded()))%"
            }
            let cycleIDs = scheduledResets.map {
                "\($0.current.metricID):\(cycleBucket($0.previous.resetsAt))"
            }.sorted()
            enqueue(
                kind: .quotaReset,
                accountID: account.id,
                title: titles.count == 1 ? "\(titles[0]) reset" : "Usage limits reset",
                body: titles.count == 1
                    ? "\(account.resolvedDisplayName)’s \(titles[0]) started a new period with \(Int(scheduledResets[0].current.remainingPercent.rounded()))% remaining."
                    : "\(account.resolvedDisplayName)’s usage limits started new periods: \(values.joined(separator: ", ")).",
                createdAt: observedAt,
                deduplicationKey: "quota-reset:\(sourceIdentity):\(cycleIDs.joined(separator: ","))",
                notificationsEnabled: notificationsEnabled,
                archive: &archive
            )
        }

        if !probableEarlyResets.isEmpty {
            let titles = probableEarlyResets.map { $0.current.metricTitle }
            let changes = probableEarlyResets.map {
                "\($0.current.metricTitle) \(Int($0.previous.remainingPercent.rounded()))%→\(Int($0.current.remainingPercent.rounded()))%"
            }
            let cycleIDs = probableEarlyResets.map {
                "\($0.current.metricID):\(cycleBucket($0.previous.resetsAt))"
            }.sorted()
            enqueue(
                kind: .probableEarlyReset,
                accountID: account.id,
                title: titles.count == 1 ? "\(titles[0]) probably reset" : "Usage limits probably reset",
                body: "\(account.resolvedDisplayName)’s remaining allowance increased before the scheduled reset: \(changes.joined(separator: ", ")). A reset was probably applied.",
                createdAt: observedAt,
                deduplicationKey: "early-quota-reset:\(sourceIdentity):\(cycleIDs.joined(separator: ","))",
                notificationsEnabled: notificationsEnabled,
                archive: &archive
            )
        }
    }

    private func updateMetricObservations(_ points: [UsageHistoryPoint],
                                          state: inout UsageAlertDetectorState) {
        for point in points {
            if let existing = state.metricObservations[point.metricID],
               point.recordedAt <= existing.recordedAt { continue }
            state.metricObservations[point.metricID] = point
        }
    }

    private func enqueue(kind: UsageNotificationEvent.Kind, accountID: UUID,
                         title: String, body: String, createdAt: Date,
                         deduplicationKey: String, notificationsEnabled: Bool,
                         archive: inout UsageHistoryArchive) {
        guard notificationsEnabled else { return }
        guard archive.notificationDeduplicationKeys[deduplicationKey] == nil else { return }
        let event = UsageNotificationEvent(
            id: UUID().uuidString,
            accountID: accountID,
            kind: kind,
            title: title,
            body: body,
            createdAt: createdAt,
            deduplicationKey: deduplicationKey
        )
        archive.notificationDeduplicationKeys[deduplicationKey] = createdAt
        archive.pendingNotifications.append(event)
    }

    private func loadedArchive() throws -> UsageHistoryArchive {
        if let cachedArchive { return cachedArchive }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = UsageHistoryArchive()
            cachedArchive = empty
            return empty
        }
        do {
            let data = try Data(contentsOf: fileURL)
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = (object["schemaVersion"] as? NSNumber)?.intValue,
               version > UsageHistoryArchive.currentSchemaVersion {
                throw UsageHistoryStoreError.unsupportedSchema(version)
            }
            var decoded = try JSONDecoder().decode(UsageHistoryArchive.self, from: data)
            guard decoded.schemaVersion <= UsageHistoryArchive.currentSchemaVersion else {
                throw UsageHistoryStoreError.unsupportedSchema(decoded.schemaVersion)
            }
            if decoded.schemaVersion < UsageHistoryArchive.currentSchemaVersion {
                decoded.schemaVersion = UsageHistoryArchive.currentSchemaVersion
                try persist(decoded)
            }
            cachedArchive = decoded
            return decoded
        } catch let error as UsageHistoryStoreError {
            throw error
        } catch {
            let stamp = Int(Date.now.timeIntervalSince1970)
            let backupURL = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
            let empty = UsageHistoryArchive()
            cachedArchive = empty
            return empty
        }
    }

    private func persist(_ archive: UsageHistoryArchive) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var currentArchive = archive
        currentArchive.schemaVersion = UsageHistoryArchive.currentSchemaVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(currentArchive)
        try data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
    }

    private func prune(_ archive: inout UsageHistoryArchive, now: Date) {
        let historyCutoff = now.addingTimeInterval(-Self.retentionInterval)
        let pendingCutoff = now.addingTimeInterval(-Self.pendingNotificationLifetime)
        archive.points.removeAll { $0.recordedAt < historyCutoff }
        archive.pendingNotifications.removeAll { $0.createdAt < pendingCutoff }
        archive.deliveredNotificationIDs = archive.deliveredNotificationIDs.filter { $0.value >= historyCutoff }
        archive.notificationDeduplicationKeys = archive.notificationDeduplicationKeys.filter {
            $0.value >= historyCutoff
        }
        for accountID in archive.detectorStates.keys {
            guard var state = archive.detectorStates[accountID] else { continue }
            state.metricObservations = state.metricObservations.filter {
                $0.value.recordedAt >= historyCutoff
            }
            if let weekly = state.weeklyObservation, weekly.recordedAt < historyCutoff {
                state.weeklyObservation = nil
            }
            state.seenCredits = state.seenCredits.filter { _, seen in
                seen.lastSeenAt >= historyCutoff || (seen.expiresAt ?? .distantPast) >= historyCutoff
            }
            if let pending = state.pendingWeeklyRecovery,
               now.timeIntervalSince(pending.observedAt) > 60 * 60 {
                state.pendingWeeklyRecovery = nil
            }
            if let pending = state.pendingCreditConsumption,
               now.timeIntervalSince(pending.observedAt) > 60 * 60 {
                state.pendingCreditConsumption = nil
            }
            archive.detectorStates[accountID] = state
        }
    }

    private func observationMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private func cycleBucket(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / (5 * 60)).rounded())
    }

    private func normalizedPlan(_ plan: String?) -> String? {
        guard let normalized = plan?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else { return nil }
        return String(normalized.prefix(128))
    }

    private func canonicalPlan(_ plan: String?) -> String? {
        normalizedPlan(plan)?.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        if let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: SharedSnapshotStore.suiteName
        ) {
            return container
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("usage-history-v1.json", isDirectory: false)
        }
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("WhenReset", isDirectory: true)
            .appendingPathComponent("usage-history-v1.json", isDirectory: false)
    }
}
