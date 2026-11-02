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
            Section("Content") {
                Toggle("Show percentage remaining", isOn: $settings.showRemainingPercentage)
                Toggle("Show banked resets", isOn: $settings.showBankedResets)
                ForEach(store.accounts) { account in
                    Toggle(account.resolvedDisplayName, isOn: liveActivityInclusion(account.id))
                }
            }
        }
        .navigationTitle("Live Activity")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { settings = store.liveActivitySettings }
        .onChange(of: settings) { _, newValue in
            store.setLiveActivitySettings(newValue)
        }
    }

    private func liveActivityInclusion(_ id: UUID) -> Binding<Bool> {
        Binding {
            settings.includes(id)
        } set: { included in
            var ids = settings.includedAccountIDs ?? store.accounts.map(\.id)
            if included {
                if !ids.contains(id) { ids.append(id) }
            } else {
                ids.removeAll { $0 == id }
            }
            settings.includedAccountIDs = ids
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
