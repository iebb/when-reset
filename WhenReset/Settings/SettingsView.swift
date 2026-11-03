#if os(iOS)
import SwiftUI

struct SettingsView: View {
    let onStageWorkerLink: (WorkerLinkDraft) -> Void
    @Environment(UpdateCheckController.self) private var updates
    @Environment(\.interfaceStyle) private var interfaceStyle

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    moduleLink("Appearance", systemImage: "circle.lefthalf.filled", identifier: "settings-module-appearance") {
                        AppearanceSettingsView()
                    }
                    moduleLink("Forecasts", systemImage: "chart.line.uptrend.xyaxis", identifier: "settings-module-forecasts") {
                        ForecastSettingsView()
                    }
                    moduleLink("Token activity", systemImage: "square.grid.3x3", identifier: "settings-module-token-activity") {
                        TokenActivitySettingsView()
                    }
                    moduleLink("Language", systemImage: "globe", identifier: "settings-module-language") {
                        LanguageSettingsView()
                    }
                    moduleLink("Notifications", systemImage: "bell.badge", identifier: "settings-module-notifications") {
                        NotificationSettingsView()
                    }
                    moduleLink("Refresh", systemImage: "arrow.clockwise", identifier: "settings-module-refresh") {
                        RefreshSettingsView()
                    }
                    moduleLink("Live Activity", systemImage: "iphone", identifier: "settings-module-live-activity") {
                        LiveActivitySettingsView()
                    }
                    moduleLink("Self-hosted Worker", systemImage: "server.rack", identifier: "settings-module-worker") {
                        WorkerSettingsView(onStageWorkerLink: onStageWorkerLink)
                    }
                }
                .blinkySettingsSection()
                Section {
                    moduleLink("About", systemImage: "info.circle", identifier: "settings-module-about") {
                        AboutSettingsView()
                    }
                    .badge(updates.showsAboutBadge ? 1 : 0)
                }
                .blinkySettingsSection()
            }
            .blinkySettingsCanvas()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
        }
        .blinkyScreenBackdrop(interfaceStyle)
    }

    private func moduleLink<Destination: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        identifier: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            Label(title, systemImage: systemImage)
        }
        .accessibilityIdentifier(identifier)
    }
}
#endif
