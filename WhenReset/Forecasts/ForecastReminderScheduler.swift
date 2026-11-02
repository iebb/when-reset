import Foundation
import UserNotifications

/// Hands a predicted Codex reminder to the system notification centre.
///
/// Only an explicit `scheduledFor` is scheduled. A watch with no instant
/// stays on the card and does not notify. Regular window reminders stay
/// with the existing scheduled-reset notification.
@MainActor
enum ForecastReminderScheduler {
    private static let identifierPrefix = "pulse.advance.predicted"

    static func authorizeIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined
                || settings.authorizationStatus == .provisional else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    static func reconcile(status: CodexResetStatus?, enabled: Bool, lead: TimeInterval) async {
        let center = UNUserNotificationCenter.current()
        let authorization = await center.notificationSettings()
        let allowed: Bool
        switch authorization.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            allowed = true
        case .denied, .notDetermined:
            allowed = false
        @unknown default:
            allowed = false
        }
        if !allowed && enabled { return }

        var book = AdvanceReminderBook.load()
        let desired: [AdvanceReminder]
        if enabled, allowed, let status {
            desired = AdvanceReminderPlanner.predicted(status: status, lead: lead, now: Date()).map { [$0] } ?? []
        } else {
            desired = []
        }
        let step = book.reconcile(desired: desired, enabled: enabled && allowed, now: Date())
        AdvanceReminderBook.save(book)

        let pending = await center.pendingNotificationRequests()
        let wanted = Set(book.memory.pending.keys)
        let stale = pending.map(\.identifier).filter {
            $0.hasPrefix(identifierPrefix) && !wanted.contains($0)
        }
        let cancel = Array(Set(stale + step.cancel))
        if !cancel.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: cancel)
        }
        guard allowed else { return }

        let soundOn = authorization.soundSetting == .enabled
        for reminder in step.schedule {
            guard case .predicted(let when) = reminder.kind else { continue }
            let content = UNMutableNotificationContent()
            content.title = ForecastCopy.text("Predicted reset")
            let stamp = CodexResetPresentation.predictionStamp(date: when)
            content.body = ForecastCopy.format("An announced Codex reset is set for %@.", stamp)
            content.threadIdentifier = "forecast-predicted"
            if soundOn { content.sound = .default }
            let trigger: UNNotificationTrigger?
            if let fire = reminder.fireAt, fire.timeIntervalSinceNow > 1 {
                trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)
            } else {
                trigger = nil
            }
            let request = UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }
}
