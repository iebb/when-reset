#if os(iOS)
import SwiftUI

struct LanguageSettingsView: View {
    @State private var language = AppLanguage.current

    private var languageSelection: Binding<AppLanguage> {
        Binding {
            language
        } set: { newValue in
            language = newValue
            AppLanguage.choose(newValue)
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Interface language", selection: languageSelection) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .accessibilityIdentifier("interface-language")
            } footer: {
                Text("English and Simplified Chinese follow the system language until you choose one here.")
            }
            .blinkySettingsSection()
        }
        .blinkySettingsCanvas()
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
