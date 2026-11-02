#if os(iOS)
import SwiftUI

struct RefreshSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var refreshSettings = GlobalRefreshSettings()

    var body: some View {
        Form {
            Section {
                Picker("In app", selection: $refreshSettings.inAppInterval) {
                    ForEach(RefreshInterval.inAppOptions, id: \.self) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                Picker("Background & Live Activity",
                       selection: $refreshSettings.backgroundInterval) {
                    ForEach(RefreshInterval.backgroundOptions, id: \.self) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
            } footer: {
                Text("The in-app interval runs while Blinky is open. Background refresh and Live Activity use the second interval.")
            }
        }
        .navigationTitle("Refresh")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshSettings = store.refreshSettings }
        .onChange(of: refreshSettings) { _, newValue in
            store.setRefreshSettings(newValue)
        }
    }
}
#endif
