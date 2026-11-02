#if os(iOS)
import SwiftUI

struct WorkerSettingsView: View {
    @Environment(AppStore.self) private var store
    let onStageWorkerLink: (WorkerLinkDraft) -> Void
    @State private var pushServerSettings = PushServerSettings()
    @State private var pushServerAccessKey = ""
    @State private var showingWorkerLinkEntry = false
    @State private var showingRemoteWorkerAccounts = false
    @State private var stagedLinkFromEntry: WorkerLinkDraft?
    @State private var pushServerActionError: String?

    var body: some View {
        Form {
            Section {
                Picker("Server", selection: $pushServerSettings.mode) {
                    ForEach(PushServerMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                if pushServerSettings.mode == .custom {
                    Button("Scan or Paste Worker Link", systemImage: "qrcode.viewfinder") {
                        showingWorkerLinkEntry = true
                    }
                    TextField("https://push.example.com",
                              text: $pushServerSettings.customServerURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    SecureField("Server access key", text: $pushServerAccessKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Server monitoring",
                           selection: $pushServerSettings.serverMonitoringInterval) {
                        ForEach(RefreshInterval.serverMonitoringOptions, id: \.self) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                    Picker("Cloud history",
                           selection: $pushServerSettings.historyRetention) {
                        ForEach(CloudHistoryRetention.allCases, id: \.self) { retention in
                            Text(retention.title).tag(retention)
                        }
                    }
                }
                if pushServerSettings.mode != .disabled || canApplyPushServerSettings {
                    Button(pushServerActionTitle, action: applyPushServerAction)
                        .disabled(!canApplyPushServerSettings)
                }

                if pushServerSettings.mode != .disabled
                    || store.pushServerSettings.mode != .disabled
                    || store.pushServerStatus != .disabled {
                    LabeledContent("Status", value: store.pushServerStatus.title)
                    if case .failed = store.pushServerStatus {
                        Button("Retry") { store.retryPushRegistration() }
                    }
                    if store.canAccessRemoteWorkerAccounts {
                        Button("Add Accounts from Worker",
                               systemImage: "icloud.and.arrow.down") {
                            showingRemoteWorkerAccounts = true
                        }
                    }
                    if store.pushServerStatus == .registered {
                        Button("Send Test Refresh") {
                            Task { await store.requestTestPushRefresh() }
                        }
                    }
                }
            }
        }
        .navigationTitle("Self-hosted Worker")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { pushServerSettings = store.pushServerSettings }
        .onChange(of: store.pushServerSettings) { _, newValue in
            pushServerSettings = newValue
        }
        .sheet(isPresented: $showingWorkerLinkEntry) {
            WorkerLinkEntryView { payload in
                stagedLinkFromEntry = .pairing(payload)
                showingWorkerLinkEntry = false
            }
        }
        .sheet(isPresented: $showingRemoteWorkerAccounts) {
            RemoteWorkerAccountsView()
        }
        .onChange(of: showingWorkerLinkEntry) { _, isShowing in
            guard !isShowing, let draft = stagedLinkFromEntry else { return }
            stagedLinkFromEntry = nil
            onStageWorkerLink(draft)
        }
        .alert("Couldn’t update Worker", isPresented: Binding(
            get: { pushServerActionError != nil },
            set: { if !$0 { pushServerActionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pushServerActionError ?? String.localized("The Worker settings could not be updated."))
        }
    }

    private var canApplyPushServerSettings: Bool {
        let enteredKey = pushServerAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if pushServerSettings.mode == .disabled {
            return store.pushServerSettings.mode != .disabled
        }
        guard let proposedURL = try? PushServerConfiguration.normalizedServerOrigin(
            pushServerSettings.customServerURL
        ) else { return false }
        let currentURL = try? store.pushServerSettings.resolvedServerURL()
        if proposedURL == currentURL, enteredKey.isEmpty {
            return pushServerSettings.serverMonitoringInterval
                != store.pushServerSettings.serverMonitoringInterval
                || pushServerSettings.historyRetention
                    != store.pushServerSettings.historyRetention
        }
        return enteredKey.count >= 32
    }

    private var pushServerActionTitle: String {
        if pushServerSettings.mode == .disabled { return String.localized("Turn Off") }
        let enteredKey = pushServerAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let proposedURL = try? PushServerConfiguration.normalizedServerOrigin(
            pushServerSettings.customServerURL
        )
        let currentURL = try? store.pushServerSettings.resolvedServerURL()
        return proposedURL == currentURL && enteredKey.isEmpty
            ? String.localized("Apply Cloud Settings") : String.localized("Review & Link")
    }

    private func applyPushServerAction() {
        if pushServerSettings.mode == .disabled {
            store.disablePushServer()
            pushServerAccessKey = ""
            return
        }
        do {
            let serverURL = try PushServerConfiguration.normalizedServerOrigin(
                pushServerSettings.customServerURL
            )
            let accessKey = pushServerAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let currentURL = try? store.pushServerSettings.resolvedServerURL()
            if serverURL == currentURL, accessKey.isEmpty {
                store.updatePushServerPolicy(
                    interval: pushServerSettings.serverMonitoringInterval,
                    historyRetention: pushServerSettings.historyRetention
                )
            } else {
                guard accessKey.count >= 32 else { throw PushServerError.missingServerAccessKey }
                onStageWorkerLink(.manual(
                    id: UUID(),
                    serverURL: serverURL,
                    accessKey: accessKey
                ))
            }
            pushServerAccessKey = ""
        } catch {
            pushServerActionError = error.localizedDescription
        }
    }
}
#endif
