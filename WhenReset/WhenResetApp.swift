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

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let raw = info[UpdateNotification.urlUserInfoKey] as? String,
              let url = URL(string: raw) else { return }
        await MainActor.run {
            UIApplication.shared.open(url)
        }
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

enum BackgroundRefreshScheduler {
    static let identifier = UsageHistoryStore.refreshTaskIdentifier
    /// Internal only. Not shown in Settings.
    static let lastRunKey = "blinky.lastBackgroundRefreshAt"
    static let lastScheduleErrorKey = "blinky.lastBackgroundScheduleError"

    static func scheduleNext(after interval: RefreshInterval) {
#if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        guard let delay = interval.timeInterval else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = .now.addingTimeInterval(delay)
        do {
            try BGTaskScheduler.shared.submit(request)
            UserDefaults.standard.removeObject(forKey: lastScheduleErrorKey)
        } catch {
            UserDefaults.standard.set(String(describing: error), forKey: lastScheduleErrorKey)
        }
#endif
    }

    static func noteRunStarted() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastRunKey)
    }
}

#if os(iOS)
@MainActor
enum BackgroundRefreshController {
    private static var didRegister = false
    private static var store: AppStore?

    /// Must run before `application(_:didFinishLaunchingWithOptions:)` returns.
    /// `App.init` is early enough. Do not also use `.backgroundTask`, which would register twice.
    static func register(store: AppStore) {
        self.store = store
        guard !didRegister else { return }
        didRegister = true
        let identifier = BackgroundRefreshScheduler.identifier
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let work = Task { @MainActor in
                await run(refreshTask)
            }
            refreshTask.expirationHandler = {
                work.cancel()
            }
        }
    }

    @MainActor
    private static func run(_ task: BGAppRefreshTask) async {
        BackgroundRefreshScheduler.noteRunStarted()
        if let store {
            BackgroundRefreshScheduler.scheduleNext(after: store.refreshSettings.backgroundInterval)
            await store.synchronizeAccountsFromICloudKeychain()
            let refreshed = await store.refreshAll(source: .background)
            task.setTaskCompleted(success: refreshed && !Task.isCancelled)
        } else {
            task.setTaskCompleted(success: false)
        }
    }
}
#endif

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
    @State private var interfaceLanguage = AppLanguage.current
    @State private var appearance = AppAppearance.current
    @State private var barStyle = UsageBarStyle.current
    @State private var interfaceStyle = InterfaceStyle.current
    @State private var percentBasis = QuotaPercentBasis.current

    init() {
        #if DEBUG
        ScreenshotLaunch.applyLanguage()
        ScreenshotLaunch.applyChrome()
        _interfaceLanguage = State(initialValue: AppLanguage.current)
        _appearance = State(initialValue: AppAppearance.current)
        _barStyle = State(initialValue: UsageBarStyle.current)
        _interfaceStyle = State(initialValue: InterfaceStyle.current)
        _percentBasis = State(initialValue: QuotaPercentBasis.current)
        #endif
        let store = AppStore()
        _store = State(initialValue: store)
        RemotePushCoordinator.shared.configure(store: store)
#if os(iOS)
        BackgroundRefreshController.register(store: store)
#endif
#if os(macOS)
        MacAppRuntime.shared.configure(store: store)
#endif
    }

    var body: some Scene {
#if os(iOS)
        WindowGroup {
            ContentView().environment(store)
                .environment(\.locale, interfaceLanguage.locale)
                .environment(\.usageBarStyle, barStyle)
                .environment(\.interfaceStyle, interfaceStyle)
                .environment(\.quotaPercentBasis, percentBasis)
                .preferredColorScheme(appearance.colorScheme)
                .onReceive(NotificationCenter.default.publisher(for: .blinkyLanguageChanged)) { note in
                    if let language = note.object as? AppLanguage { interfaceLanguage = language }
                }
                .onReceive(NotificationCenter.default.publisher(for: .blinkyAppearanceChanged)) { note in
                    if let appearance = note.object as? AppAppearance { self.appearance = appearance }
                }
                .onReceive(NotificationCenter.default.publisher(for: .blinkyUsageBarStyleChanged)) { note in
                    if let style = note.object as? UsageBarStyle { barStyle = style }
                }
                .onReceive(NotificationCenter.default.publisher(for: .blinkyInterfaceStyleChanged)) { note in
                    if let style = note.object as? InterfaceStyle { interfaceStyle = style }
                }
                .onReceive(NotificationCenter.default.publisher(for: .blinkyQuotaPercentBasisChanged)) { note in
                    if let basis = note.object as? QuotaPercentBasis { percentBasis = basis }
                }
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
#elseif os(macOS)
        Window("Blinky", id: "main") {
            MacContentView()
                .environment(store)
                .environment(\.locale, interfaceLanguage.locale)
                .environment(\.usageBarStyle, barStyle)
                .environment(\.interfaceStyle, interfaceStyle)
                .environment(\.quotaPercentBasis, percentBasis)
                .preferredColorScheme(appearance.colorScheme)
                .onReceive(NotificationCenter.default.publisher(for: .blinkyLanguageChanged)) { note in
                    if let language = note.object as? AppLanguage { interfaceLanguage = language }
                }
                .onReceive(NotificationCenter.default.publisher(for: .blinkyAppearanceChanged)) { note in
                    if let appearance = note.object as? AppAppearance { self.appearance = appearance }
                }
                .onReceive(NotificationCenter.default.publisher(for: .blinkyUsageBarStyleChanged)) { note in
                    if let style = note.object as? UsageBarStyle { barStyle = style }
                }
                .onReceive(NotificationCenter.default.publisher(for: .blinkyInterfaceStyleChanged)) { note in
                    if let style = note.object as? InterfaceStyle { interfaceStyle = style }
                }
                .onReceive(NotificationCenter.default.publisher(for: .blinkyQuotaPercentBasisChanged)) { note in
                    if let basis = note.object as? QuotaPercentBasis { percentBasis = basis }
                }
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    await store.synchronizeAccountsFromICloudKeychain()
                }
        }
        .defaultSize(width: 980, height: 680)

        MenuBarExtra("Blinky", systemImage: "clock.arrow.circlepath") {
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
