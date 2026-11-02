#if os(iOS)
import SwiftUI

enum AppLinks {
    static let sourceCode = URL(string: "https://github.com/harrisliangsu/blinky-ios")!
    static let issues = URL(string: "https://github.com/harrisliangsu/blinky-ios/issues")!
}

struct AboutSettingsView: View {
    @Environment(UpdateCheckController.self) private var updates

    var body: some View {
        let installed = InstalledBuild.current()
        Form {
            Section {
                LabeledContent("App", value: "Blinky")
                LabeledContent("Version", value: installed.marketingVersion)
                LabeledContent("Build", value: installed.build ?? "–")
                LabeledContent("Channel", value: updates.channel.title)
                LabeledContent("Status", value: statusValue)
                    .accessibilityIdentifier("about-update-status")
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let title = storeButtonTitle, let url = UpdateLinks.openURL(for: updates.channel) {
                    Button(title) { updates.open(url) }
                        .accessibilityIdentifier("about-open-update")
                }
                Button {
                    Task { await updates.checkNow() }
                } label: {
                    HStack {
                        if updates.phase == .checking {
                            ProgressView()
                        }
                        if updates.phase == .checking {
                            Text("Checking…")
                        } else {
                            Text("Check for Updates")
                        }
                    }
                }
                .disabled(updates.phase == .checking)
                .accessibilityIdentifier("about-check-updates")
            } header: {
                Text("About")
            } footer: {
                Text("Fork of When Reset (iebb/when-reset).")
            }

            Section {
                Picker("Update discovery", selection: mode) {
                    Text("Notify first").tag(UpdateDiscoveryMode.notify)
                    Text("Manual only").tag(UpdateDiscoveryMode.manual)
                }
                .pickerStyle(.inline)
                .accessibilityIdentifier("about-update-mode")
                Toggle("Remind when an update is available", isOn: remind)
                    .accessibilityIdentifier("about-remind-updates")
            } footer: {
                Text(discoveryFooter)
            }

            Section {
                Link(destination: AppLinks.sourceCode) {
                    Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: AppLinks.issues) {
                    Label("Issues", systemImage: "exclamationmark.bubble")
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var mode: Binding<UpdateDiscoveryMode> {
        Binding {
            updates.preferences.mode
        } set: { updates.setMode($0) }
    }

    private var remind: Binding<Bool> {
        Binding {
            updates.preferences.remindWhenAvailable
        } set: { updates.setRemind($0) }
    }

    private var storeButtonTitle: LocalizedStringKey? {
        switch updates.channel {
        case .appStore: "Open App Store"
        case .testFlight: "Open TestFlight"
        case .development: nil
        }
    }

    private var statusValue: String {
        switch updates.phase {
        case .idle:
            String.localized("Not checked yet")
        case .checking:
            String.localized("Checking…")
        case .upToDate:
            String.localized("Up to date")
        case .available:
            String.localized("Update available")
        case .failed(.network):
            String.localized("Network error")
        case .failed(.parse):
            String.localized("Couldn’t read update")
        }
    }

    private var detail: String? {
        switch updates.phase {
        case .available(let version, let build):
            UpdateCopy.available(version: version, build: build)
        case .upToDate:
            String.localized("You’re on the latest version.")
        case .failed(.network):
            String.localized("Couldn’t check for updates. Check your connection and try again.")
        case .failed(.parse):
            String.localized("Couldn’t read the update information.")
        case .idle, .checking:
            nil
        }
    }

    private var discoveryFooter: String {
        let cadence = updates.preferences.mode == .notify
            ? String.localized("Blinky checks about once a day and tells you when a newer version is available. It never downloads or installs the update.")
            : String.localized("Blinky checks only when you tap Check for Updates.")
        let install = String.localized("Updates are installed from the App Store or TestFlight. Blinky only compares versions and opens the store.")
        let remind = String.localized("When this is on, Blinky reminds you once for each new version. If notifications are already allowed, it posts a notification. Otherwise it shows a banner.")
        let development = updates.channel == .development
            ? String.localized("Development builds compare with the TestFlight feed. Install updates from Xcode.")
            : nil
        return [cadence, install, remind, development].compactMap { $0 }.joined(separator: " ")
    }
}
#endif
