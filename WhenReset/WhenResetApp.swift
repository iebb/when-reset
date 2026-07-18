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
    static let preferredInterval: TimeInterval = 15 * 60

    static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = .now.addingTimeInterval(preferredInterval)
        try? BGTaskScheduler.shared.submit(request)
    }
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
                    BackgroundRefreshScheduler.scheduleNext()
                    await store.start()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background {
                        BackgroundRefreshScheduler.scheduleNext()
                    }
                }
        }
        .backgroundTask(.appRefresh(BackgroundRefreshScheduler.identifier)) {
            await BackgroundRefreshScheduler.scheduleNext()
            _ = await store.refreshAll(source: .background)
        }
    }
}
