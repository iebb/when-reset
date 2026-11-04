#if os(iOS)
import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var appearance = AppAppearance.current
    @State private var barStyle = UsageBarStyle.current
    @State private var interfaceStyle = InterfaceStyle.current
    @State private var percentBasis = QuotaPercentBasis.current

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

    private var percentBasisSelection: Binding<QuotaPercentBasis> {
        Binding {
            percentBasis
        } set: { newValue in
            percentBasis = newValue
            QuotaPercentBasis.choose(newValue)
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
            } footer: {
                Text("Follows the system until you choose light or dark.")
            }
            .blinkySettingsSection()
            Section {
                Picker("Interface style", selection: interfaceStyleSelection) {
                    ForEach(InterfaceStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .accessibilityIdentifier("interface-style")
            } footer: {
                Text("Classic is a plain grouped list. Screen Time uses a rounded percent and block bars. Liquid Glass is one glass card.")
            }
            .blinkySettingsSection()
            Section {
                Picker("Percentages", selection: percentBasisSelection) {
                    ForEach(QuotaPercentBasis.allCases) { basis in
                        Text(basis.title).tag(basis)
                    }
                }
                .accessibilityIdentifier("quota-percent-basis")
            } footer: {
                Text("Remaining shows what is left. Used shows what is already spent. Widgets show the number only. The bar fills the same way.")
            }
            .blinkySettingsSection()
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
            .blinkySettingsSection()
        }
        .blinkySettingsCanvas()
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
