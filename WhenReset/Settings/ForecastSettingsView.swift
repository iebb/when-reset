#if os(iOS)
import SwiftUI

struct ForecastSettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form {
            ForecastSettingsSection(accounts: store.accounts)
                .blinkySettingsSection()
        }
        .blinkySettingsCanvas()
        .navigationTitle("Forecasts")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
