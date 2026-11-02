import Foundation
import Observation

/// Cached Codex Resets status, and the poll that keeps it current.
///
/// One in-flight request. Opening a ChatGPT card, or turning the predicted
/// reminder on, wakes the wait once the floor has passed. A failure leaves
/// the last status in place. The Mac hover poke and the on-disk schema file
/// in Application Support are not here: the cache is `UserDefaults`.
@MainActor
@Observable
final class CodexResetStore {
    static let shared = CodexResetStore()

    private(set) var status: CodexResetStatus?
    private var etag: String?
    private var maxAge: TimeInterval?
    private var fetchedAt = Date.distantPast
    private var freshUntil = Date.distantPast
    private var sleepFor: TimeInterval = CodexResetSchedule.default
    private var quiet = CodexResetQuiet.State()
    private var refetchingForecastTiming = false
    private var inFlight = false
    /// A refill asked for a new document while a request was already running.
    private var needsRefresh = false
    private var poll: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var lastWindows: [UUID: [ForecastWindow]] = [:]

    private init() {
        guard let disk = CodexResetDisk.load() else { return }
        status = disk.status
        let plan = CodexResetLoadPlan.make(disk: disk, now: Date())
        etag = plan.etag
        maxAge = plan.maxAge
        fetchedAt = disk.fetchedAt
        refetchingForecastTiming = plan.refetchingForecastTiming
        sleepFor = plan.sleepFor
        freshUntil = plan.freshUntil
    }

    func display(at now: Date = .now) -> CodexResetStatus? {
        CodexResetQuiet.displayed(status, quiet: quiet, now: now)
    }

    func ensurePolling() {
        guard poll == nil else { return }
        poll = Task { @MainActor [weak self] in
            await self?.run()
        }
    }

    func wake() {
        ensurePolling()
        sleeper?.cancel()
    }

    func refreshIfDue(force: Bool = false) async {
        if force { needsRefresh = true }
        if inFlight { return }
        if !force, !needsRefresh, Date() < freshUntil { return }
        inFlight = true
        defer { inFlight = false }
        repeat {
            needsRefresh = false
            await performFetch()
        } while needsRefresh
    }

    private func performFetch() async {
        let previousMaxAge = maxAge
        let reply = await CodexResetClient.fetch(etag: refetchingForecastTiming ? nil : etag)
        switch reply.payload {
        case .parsed(let status):
            self.status = status
            refetchingForecastTiming = false
            if let etag = reply.etag { self.etag = etag }
            if let maxAge = reply.maxAge { self.maxAge = maxAge }
            save()
            await remindersDidChange()
        case .notModified:
            if refetchingForecastTiming {
                etag = nil
                break
            }
            if let etag = reply.etag { self.etag = etag }
            if let maxAge = reply.maxAge { self.maxAge = maxAge }
            save()
        case .failed:
            break
        }
        let failed = reply.payload == .failed
        fetchedAt = Date()
        var wait = CodexResetSchedule.delay(
            maxAge: reply.maxAge ?? (failed ? nil : previousMaxAge),
            retryAfter: reply.retryAfter,
            failed: failed
        )
        if reply.retryAfter == nil {
            wait = CodexResetSchedule.paced(wait, status: status)
        }
        sleepFor = wait
        freshUntil = fetchedAt.addingTimeInterval(wait)
    }

    /// The primary ChatGPT weekly window refilled. The countdown still on
    /// the card is a forecast of a reset the account has already received.
    func noteUsage(_ windows: [ForecastWindow], accountID: UUID) {
        let previous = lastWindows[accountID]
        lastWindows[accountID] = windows
        guard let previous, CodexResetSchedule.weeklyQuotaRestored(previous: previous, current: windows) else {
            return
        }
        noteQuotaRestored()
    }

    func noteQuotaRestored() {
        if let status, !status.predictionKey.isEmpty {
            quiet = CodexResetQuiet.State(
                key: status.predictionKey,
                until: Date().addingTimeInterval(CodexResetSchedule.floor)
            )
        }
        freshUntil = .distantPast
        wake()
        Task { await refreshIfDue(force: true) }
    }

    func remindersDidChange() async {
        let settings = ForecastSettingsStore.shared.settings
        await ForecastReminderScheduler.reconcile(
            status: display(),
            enabled: settings.remindsBeforePredictedReset,
            lead: settings.predictedLead
        )
    }

    private func run() async {
        while !Task.isCancelled {
            let settings = ForecastSettingsStore.shared.settings
            let interested = settings.showsPredictedReset || settings.remindsBeforePredictedReset
            if interested {
                await refreshIfDue()
            }
            let wait = interested ? max(sleepFor, 1) : CodexResetSchedule.ceiling
            let sleep = Task { try? await Task.sleep(for: .seconds(wait)) }
            sleeper = sleep
            await sleep.value
            if Task.isCancelled { return }
        }
    }

    private func save() {
        guard let status else { return }
        CodexResetDisk.save(CodexResetDisk(
            status: status,
            etag: etag,
            fetchedAt: Date(),
            maxAge: maxAge
        ))
    }
}
