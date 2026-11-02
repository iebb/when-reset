#if os(iOS)
import SwiftUI

enum AppLinks {
    static let sourceCode = URL(string: "https://github.com/iebb/when-reset")!
    static let issues = URL(string: "https://github.com/iebb/when-reset/issues")!
}

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section("About") {
                LabeledContent("App", value: "Blinky")
                Text("Fork of When Reset (iebb/when-reset).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link(destination: AppLinks.sourceCode) {
                    Label("Upstream source", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: AppLinks.issues) {
                    Label("Upstream issues", systemImage: "exclamationmark.bubble")
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
