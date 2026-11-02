import Foundation

/// How far ahead an advance reminder fires. A window shorter than the chosen
/// lead is not eligible — a 5-hour limit cannot be warned 12 hours before it ends.
enum ResetLead: Int, CaseIterable, Identifiable, Sendable {
    case twelve = 12
    case day = 24
    case twoDays = 48

    static let `default` = ResetLead.day

    var id: Int { rawValue }
    var interval: TimeInterval { TimeInterval(rawValue) * 3600 }

    var title: String {
        switch self {
        case .twelve: ForecastCopy.text("12 hours before")
        case .day: ForecastCopy.text("24 hours before")
        case .twoDays: ForecastCopy.text("48 hours before")
        }
    }

    static func resolved(_ hours: Int) -> ResetLead {
        ResetLead(rawValue: hours) ?? .default
    }
}

/// One advance reminder. `fireAt` nil means the lead has already started and
/// the notice should be delivered now; the reset itself is still ahead.
struct AdvanceReminder: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case predicted(when: Date)
        case regular(accountLabel: String, windowName: String, resetsAt: Date)
    }

    var identifier: String
    var fireAt: Date?
    var kind: Kind
}

/// Which reminders are due, with no memory and no notification centre.
///
/// A watch is not an input: only `scheduledFor` can schedule a predicted
/// reminder. A regular window needs a length the provider stated, and that
/// length has to be at least the lead. iOS schedules the predicted case.
/// Regular windows already have their own reset notification.
enum AdvanceReminderPlanner {
    struct Window: Equatable, Sendable {
        var accountID: String
        var accountLabel: String
        var windowID: String
        var windowName: String
        var resetsAt: Date
        /// Nil when the provider did not state a length. Those are skipped.
        var length: TimeInterval?
    }

    static func predicted(status: CodexResetStatus, lead: TimeInterval, now: Date) -> AdvanceReminder? {
        guard let when = status.explicitReset, when > now else { return nil }
        let trimmed = status.scheduled?.id.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let identity = trimmed.isEmpty ? "scheduled" : trimmed
        return reminder(
            identifier: "pulse.advance.predicted|\(identity)|\(Int(when.timeIntervalSince1970))",
            event: when,
            lead: lead,
            now: now,
            kind: .predicted(when: when)
        )
    }

    static func regular(windows: [Window], lead: TimeInterval, now: Date) -> [AdvanceReminder] {
        windows.compactMap { window in
            guard let length = window.length, length >= lead, window.resetsAt > now else { return nil }
            return reminder(
                identifier: "pulse.advance.regular|\(window.accountID)|\(window.windowID)|\(Int(window.resetsAt.timeIntervalSince1970))",
                event: window.resetsAt,
                lead: lead,
                now: now,
                kind: .regular(
                    accountLabel: window.accountLabel,
                    windowName: window.windowName,
                    resetsAt: window.resetsAt
                )
            )
        }
    }

    private static func reminder(
        identifier: String,
        event: Date,
        lead: TimeInterval,
        now: Date,
        kind: AdvanceReminder.Kind
    ) -> AdvanceReminder {
        let fire = event.addingTimeInterval(-lead)
        return AdvanceReminder(
            identifier: identifier,
            fireAt: fire > now ? fire : nil,
            kind: kind
        )
    }
}

/// What has already been handed to the system, so a relaunch does not say it
/// again and a changed time replaces the pending one.
struct AdvanceReminderBook: Equatable, Sendable {
    struct Memory: Codable, Equatable, Sendable {
        var delivered: [String] = []
        var pending: [String: Date] = [:]
    }

    struct Step: Equatable, Sendable {
        var schedule: [AdvanceReminder] = []
        var cancel: [String] = []
    }

    var memory = Memory()

    static let storageKey = "forecasts.predictedReminderBook.v1"

    mutating func reconcile(desired: [AdvanceReminder], enabled: Bool, now: Date) -> Step {
        var step = Step()

        for (id, fire) in memory.pending where fire <= now {
            deliver(id)
            memory.pending[id] = nil
        }

        guard enabled else {
            step.cancel = memory.pending.keys.sorted()
            memory.pending = [:]
            trim()
            return step
        }

        let wanted = Set(desired.map(\.identifier))
        for id in memory.pending.keys where !wanted.contains(id) {
            step.cancel.append(id)
            memory.pending[id] = nil
        }

        for reminder in desired {
            if memory.delivered.contains(reminder.identifier) { continue }
            if let existing = memory.pending[reminder.identifier] {
                let wantedFire = reminder.fireAt ?? now
                if abs(existing.timeIntervalSince(wantedFire)) <= 1 { continue }
                step.cancel.append(reminder.identifier)
                memory.pending[reminder.identifier] = nil
            }
            step.schedule.append(reminder)
            if let fire = reminder.fireAt, fire > now {
                memory.pending[reminder.identifier] = fire
            } else {
                deliver(reminder.identifier)
            }
        }

        step.cancel.sort()
        trim()
        return step
    }

    private mutating func deliver(_ id: String) {
        guard !memory.delivered.contains(id) else { return }
        memory.delivered.append(id)
    }

    private mutating func trim() {
        if memory.delivered.count > 400 {
            memory.delivered.removeFirst(memory.delivered.count - 400)
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> AdvanceReminderBook {
        guard let data = defaults.data(forKey: storageKey),
              let memory = try? JSONDecoder().decode(Memory.self, from: data) else {
            return AdvanceReminderBook()
        }
        return AdvanceReminderBook(memory: memory)
    }

    static func save(_ book: AdvanceReminderBook, to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(book.memory), forKey: storageKey)
    }
}
