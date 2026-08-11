#if os(iOS)
@preconcurrency import BackgroundTasks
import UIKit
#elseif os(macOS)
import AppKit
#endif
import SwiftUI
@preconcurrency import UserNotifications

#if os(iOS)
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

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        RemotePushCoordinator.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        RemotePushCoordinator.shared.didFailToRegister(error)
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task {
            completionHandler(await RemotePushCoordinator.shared.handle(userInfo: userInfo))
        }
    }
}
#elseif os(macOS)
@MainActor
final class WhenResetMacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        MacAppRuntime.shared.applicationDidFinishLaunching()
    }

    func applicationWillTerminate(_ notification: Notification) {
        MacAppRuntime.shared.applicationWillTerminate()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func application(_ application: NSApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        RemotePushCoordinator.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: NSApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        RemotePushCoordinator.shared.didFailToRegister(error)
    }

    func application(_ application: NSApplication,
                     didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { _ = await RemotePushCoordinator.shared.handle(userInfo: userInfo) }
    }
}

@MainActor
private final class MacAppRuntime {
    static let shared = MacAppRuntime()

    private weak var store: AppStore?
    private var isApplicationRunning = false
    private var task: Task<Void, Never>?

    func configure(store: AppStore) {
        self.store = store
        startIfReady()
    }

    func applicationDidFinishLaunching() {
        isApplicationRunning = true
        startIfReady()
    }

    func applicationWillTerminate() {
        task?.cancel()
        task = nil
    }

    private func startIfReady() {
        guard isApplicationRunning, task == nil, let store else { return }
        task = Task { [weak store] in
            guard let store else { return }
            await store.start()
            await store.synchronizeAccountsFromICloudKeychain()

            var refreshPolicy = PeriodicRefreshPolicy(startingAt: .now)
            var keychainSyncPolicy = PeriodicRefreshPolicy(startingAt: .now)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }

                let now = Date.now
                if keychainSyncPolicy.shouldRefresh(at: now, interval: .fiveMinutes) {
                    await store.synchronizeAccountsFromICloudKeychain()
                }
                if let latestFetch = store.snapshots.values.map(\.fetchedAt).max(),
                   latestFetch <= now {
                    refreshPolicy.recordRefresh(at: latestFetch)
                }
                if refreshPolicy.shouldRefresh(
                    at: now,
                    interval: store.refreshSettings.inAppInterval
                ) {
                    _ = await store.refreshAll(source: .background)
                }
            }
        }
    }
}
#endif

@MainActor
enum BackgroundRefreshScheduler {
    static let identifier = UsageHistoryStore.refreshTaskIdentifier

    static func scheduleNext(after interval: RefreshInterval) {
#if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        guard let delay = interval.timeInterval else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = .now.addingTimeInterval(delay)
        try? BGTaskScheduler.shared.submit(request)
#endif
    }
}

#if os(iOS)
private struct ForegroundRefreshTaskID: Equatable {
    var isActive: Bool
    var interval: RefreshInterval
}
#endif

@main
struct WhenResetApp: App {
#if os(iOS)
    @UIApplicationDelegateAdaptor(WhenResetAppDelegate.self) private var appDelegate
#elseif os(macOS)
    @NSApplicationDelegateAdaptor(WhenResetMacAppDelegate.self) private var appDelegate
#endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: AppStore

    init() {
        let store = AppStore()
        _store = State(initialValue: store)
        RemotePushCoordinator.shared.configure(store: store)
#if os(macOS)
        MacAppRuntime.shared.configure(store: store)
#endif
    }

    var body: some Scene {
#if os(iOS)
        WindowGroup {
            ContentView().environment(store)
                .task { await startStore() }
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    await store.synchronizeAccountsFromICloudKeychain()
                }
                .task(id: ForegroundRefreshTaskID(
                    isActive: scenePhase == .active,
                    interval: store.refreshSettings.inAppInterval
                )) {
                    await runPeriodicRefresh(while: scenePhase == .active)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background {
                        BackgroundRefreshScheduler.scheduleNext(
                            after: store.refreshSettings.backgroundInterval
                        )
                    } else if newPhase == .active {
                        Task { await store.reconcileLiveActivityAfterForegroundActivation() }
                    }
                }
        }
        .backgroundTask(.appRefresh(BackgroundRefreshScheduler.identifier)) {
            await BackgroundRefreshScheduler.scheduleNext(after: store.refreshSettings.backgroundInterval)
            _ = await store.refreshAll(source: .background)
        }
#elseif os(macOS)
        Window("When Reset", id: "main") {
            MacContentView()
                .environment(store)
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    await store.synchronizeAccountsFromICloudKeychain()
                }
        }
        .defaultSize(width: 980, height: 680)

        MenuBarExtra("When Reset", systemImage: "clock.arrow.circlepath") {
            MacMenuBarView()
                .environment(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            MacSettingsView()
                .environment(store)
                .frame(width: 560, height: 430)
        }
#endif
    }

#if os(iOS)
    private func startStore() async {
        BackgroundRefreshScheduler.scheduleNext(after: store.refreshSettings.backgroundInterval)
        await store.start()
    }

    private func runPeriodicRefresh(while isActive: Bool) async {
        guard isActive,
              let interval = store.refreshSettings.inAppInterval.timeInterval else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            guard isActive else { return }
            _ = await store.refreshAll(source: .background)
        }
    }
#endif
}
