#if os(iOS)
import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var appearance = AppAppearance.current
    @State private var barStyle = UsageBarStyle.current
    @State private var interfaceStyle = InterfaceStyle.current

    private var appearanceSelection: Binding<AppAppearance> {
        Binding {
            appearance
        } set: { newValue in
            appearance = newValue
            AppAppearance.choose(newValue)
            Task { await store.reconcileLiveActivityAfterForegroundActivation() }
        }
    }

    private var interfaceStyleSelection: Binding<InterfaceStyle> {
        Binding {
            interfaceStyle
        } set: { newValue in
            interfaceStyle = newValue
            InterfaceStyle.choose(newValue)
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
            } footer: {
                Text("Follows the system until you choose light or dark.")
            }
            Section {
                Picker("Interface style", selection: interfaceStyleSelection) {
                    ForEach(InterfaceStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .accessibilityIdentifier("interface-style")
            } footer: {
                Text("Classic is a plain list. Screen Time sets the meter apart from the extra lines. Liquid Glass uses the system glass.")
            }
            Section {
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
