#if os(iOS)
import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var appearance = AppAppearance.current
    @State private var barStyle = UsageBarStyle.current

    private var appearanceSelection: Binding<AppAppearance> {
        Binding {
            appearance
        } set: { newValue in
            appearance = newValue
            AppAppearance.choose(newValue)
            Task { await store.reconcileLiveActivityAfterForegroundActivation() }
        }
    }

    private var barStyleSelection: Binding<UsageBarStyle> {
        Binding {
            barStyle
        } set: { newValue in
            barStyle = newValue
            UsageBarStyle.choose(newValue)
            Task { await store.reconcileLiveActivityAfterForegroundActivation() }
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Interface appearance", selection: appearanceSelection) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .accessibilityIdentifier("interface-appearance")
                Picker("Progress bars", selection: barStyleSelection) {
                    ForEach(UsageBarStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .accessibilityIdentifier("usage-bar-style")
            } footer: {
                Text("Segmented draws remaining allowance as ticks. Continuous draws one bar.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
