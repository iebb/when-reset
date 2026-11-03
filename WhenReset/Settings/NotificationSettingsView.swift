#if os(iOS)
import SwiftUI
import UIKit
import UserNotifications

enum NotificationPermissionPresentation: Equatable {
    case needsRequest
    case provisional
    case allowed
    case denied
    case ephemeral

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .needsRequest
        case .provisional: self = .provisional
        case .authorized: self = .allowed
        case .denied: self = .denied
        case .ephemeral: self = .ephemeral
        @unknown default: self = .allowed
        }
    }
}

struct NotificationSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var notificationSettings = GlobalNotificationSettings()
    @State private var authorization: UNAuthorizationStatus = .notDetermined

    private var permission: NotificationPermissionPresentation {
        NotificationPermissionPresentation(authorization)
    }

    private var configurableAccounts: [MonitoredAccount] {
        store.accounts.filter { !$0.isDemo }
    }

    var body: some View {
        Form {
            Section {
                switch permission {
                case .needsRequest:
                    Button("Allow Notifications") { Task { await allowNotifications() } }
                case .provisional:
                    LabeledContent("Status", value: String.localized("Quiet alerts"))
                    Button("Allow Alerts and Sounds") { Task { await allowNotifications() } }
                case .allowed:
                    LabeledContent("Status", value: String.localized("Allowed"))
                case .denied:
                    LabeledContent("Status", value: String.localized("Off"))
                    Button("Open Settings") { openSystemSettings() }
                case .ephemeral:
                    LabeledContent("Status", value: String.localized("Allowed for this session"))
                }
            } header: {
                Text("Permission")
            } footer: {
                Text(permissionFooter)
            }
            .blinkySettingsSection()

            Section {
                Toggle("Unexpected or early resets",
                       isOn: $notificationSettings.notifyAboutUnexpectedResets)
                Toggle("Scheduled reset times",
                       isOn: $notificationSettings.notifyAtScheduledReset)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Unexpected or early resets include an early quota change and an early weekly reset. Scheduled reset times alert when that time arrives. Each account also needs its own switch on.")
            }
            .blinkySettingsSection()

            Section {
                Text("Detected quota resets and new banked resets use each account’s Notify About Detected Resets switch. Turning off unexpected resets does not turn those alerts off.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Detected resets")
            }
            .blinkySettingsSection()

            ForEach(configurableAccounts) { account in
                Section {
                    Toggle("Notify About Detected Resets",
                           isOn: accountSetting(account, \.notifyAboutResets))
                    Toggle("Notify at Scheduled Reset Time",
                           isOn: accountSetting(account, \.notifyAtScheduledReset))
                } header: {
                    Text(account.resolvedDisplayName)
                }
                .blinkySettingsSection()
            }
        }
        .blinkySettingsCanvas()
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { notificationSettings = store.notificationSettings }
        .onChange(of: notificationSettings) { _, newValue in
            store.setNotificationSettings(newValue)
        }
        .task { await refreshAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshAuthorization() }
        }
    }

    private var permissionFooter: String {
        switch permission {
        case .needsRequest:
            String.localized("Allow notifications to deliver reset alerts.")
        case .provisional:
            String.localized("Quiet alerts are on. Allow alerts and sounds to show reset notifications on the Lock Screen and in Notification Center.")
        case .allowed:
            String.localized("Notifications are allowed.")
        case .denied:
            String.localized("Notifications are off for Blinky. Turn them on in Settings to deliver reset alerts.")
        case .ephemeral:
            String.localized("Notifications are allowed for this session.")
        }
    }

    private func allowNotifications() async {
        await UsageNotificationService.requestProminentAuthorization()
        await refreshAuthorization()
    }

    private func refreshAuthorization() async {
        authorization = await UsageNotificationService.authorizationStatus()
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func accountSetting(
        _ account: MonitoredAccount,
        _ keyPath: WritableKeyPath<AccountMonitorSettings, Bool>
    ) -> Binding<Bool> {
        Binding {
            store.settings(for: account)[keyPath: keyPath]
        } set: { isOn in
            var settings = store.settings(for: account)
            guard settings[keyPath: keyPath] != isOn else { return }
            settings[keyPath: keyPath] = isOn
            store.setSettings(settings, for: account)
        }
    }
}
#endif
