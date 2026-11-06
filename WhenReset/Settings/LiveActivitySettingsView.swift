#if os(iOS)
import SwiftUI

struct LiveActivitySettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var settings = GlobalLiveActivitySettings()

    var body: some View {
        Form {
            Section {
                Picker("Behavior", selection: $settings.mode) {
                    ForEach(LiveActivityMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Show Live Activity")
            } footer: {
                Text(modeExplanation)
            }
            .blinkySettingsSection()
            Section("Content") {
                Toggle("Show percentage remaining", isOn: $settings.showRemainingPercentage)
                Toggle("Show banked resets", isOn: $settings.showBankedResets)
            }
            .blinkySettingsSection()
        }
        .blinkySettingsCanvas()
        .navigationTitle("Live Activity")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            var current = store.liveActivitySettings
            // Inclusion follows the Usage list. Drop any saved per-account list.
            current.includedAccountIDs = nil
            settings = current
        }
        .onChange(of: settings) { _, newValue in
            var stored = newValue
            stored.includedAccountIDs = nil
            store.setLiveActivitySettings(stored)
        }
    }

    private var modeExplanation: String {
        switch settings.mode {
        case .automatic:
            String.localized("Starts after a refresh finds that any included quota matches its account rule.")
        case .always:
            String.localized("Shows whenever at least one included quota or banked reset is available.")
        case .disabled:
            String.localized("Ends the current Live Activity and prevents Blinky from starting another one.")
        }
    }
}
#endif
