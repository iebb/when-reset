@preconcurrency import BackgroundTasks
import SwiftUI
@preconcurrency import UserNotifications
import UIKit

@MainActor
final class WhenResetAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

@MainActor
enum BackgroundRefreshScheduler {
    static let identifier = UsageHistoryStore.refreshTaskIdentifier

    static func scheduleNext(after interval: RefreshInterval) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        guard let delay = interval.timeInterval else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = .now.addingTimeInterval(delay)
        try? BGTaskScheduler.shared.submit(request)
    }
}

private struct ForegroundRefreshTaskID: Equatable {
    var isActive: Bool
    var interval: RefreshInterval
}

@main
struct WhenResetApp: App {
    @UIApplicationDelegateAdaptor(WhenResetAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView().environment(store)
                .task {
                    BackgroundRefreshScheduler.scheduleNext(after: store.refreshSettings.backgroundInterval)
                    await store.start()
                }
                .task(id: ForegroundRefreshTaskID(
                    isActive: scenePhase == .active,
                    interval: store.refreshSettings.inAppInterval
                )) {
                    guard scenePhase == .active,
                          let interval = store.refreshSettings.inAppInterval.timeInterval else { return }
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                        } catch {
                            return
                        }
                        guard scenePhase == .active else { return }
                        _ = await store.refreshAll(source: .background)
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background {
                        BackgroundRefreshScheduler.scheduleNext(
                            after: store.refreshSettings.backgroundInterval
                        )
                    }
                }
        }
        .backgroundTask(.appRefresh(BackgroundRefreshScheduler.identifier)) {
            await BackgroundRefreshScheduler.scheduleNext(after: store.refreshSettings.backgroundInterval)
            _ = await store.refreshAll(source: .background)
        }
    }
}
