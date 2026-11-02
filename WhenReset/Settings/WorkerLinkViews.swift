#if os(iOS)
import SwiftUI

struct WorkerLinkEntryView: View {
    @Environment(\.dismiss) private var dismiss
    let onLink: (WorkerLinkPayload) -> Void
    @State private var pastedLink = ""
    @State private var parseError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        WorkerQRScannerView { value in
                            stage(value)
                        }
                    } label: {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    }
                    .disabled(!WorkerQRScannerView.isAvailable)
                } footer: {
                    if !WorkerQRScannerView.isAvailable {
                        Text("Camera scanning is unavailable on this device. Paste the link below.")
                    }
                }

                Section("Paste Worker Link") {
                    TextField("whenreset://link-worker?…", text: $pastedLink, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(3...6)
                    Button("Review Pasted Link") { stage(pastedLink) }
                        .disabled(pastedLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Link Worker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Invalid Worker link", isPresented: Binding(
                get: { parseError != nil },
                set: { if !$0 { parseError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(parseError ?? "Generate a new link from your Worker.")
            }
        }
    }

    private func stage(_ value: String) {
        do {
            let payload = try WorkerLinkPayload.parse(value)
            onLink(payload)
        } catch {
            parseError = error.localizedDescription
        }
    }
}

struct WorkerLinkReviewView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let draft: WorkerLinkDraft
    @State private var metadata: WorkerLinkMetadata?
    @State private var validationError: String?
    @State private var selectedAccountIDs: Set<UUID> = []
    @State private var interval = RefreshInterval.fiveMinutes
    @State private var historyRetention = CloudHistoryRetention.thirtyFiveDays
    @State private var trustsWorker = false
    @State private var isValidating = true
    @State private var isCommitting = false
    @State private var confirmingFinalLink = false

    private var accounts: [MonitoredAccount] {
        store.accounts.filter { !$0.isDemo }
    }

    private var host: String {
        metadata?.serverURL.host ?? draft.serverURL.host ?? draft.serverURL.absoluteString
    }

    private var currentWorkerURL: URL? {
        try? store.pushServerSettings.resolvedServerURL()
    }

    private var replacesCurrentWorker: Bool {
        guard let currentWorkerURL else { return false }
        return currentWorkerURL != draft.serverURL
    }

    var body: some View {
        NavigationStack {
            Form {
                if isValidating {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Verifying Worker…")
                        }
                    }
                } else if let validationError {
                    Section {
                        Label(validationError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Button("Try Again") { Task { await validateWorker() } }
                    }
                } else if let metadata {
                    Section("Worker") {
                        LabeledContent("Name", value: metadata.displayName)
                        LabeledContent("Address") {
                            Text(metadata.serverURL.absoluteString)
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                        if let expiresAt = metadata.expiresAt {
                            LabeledContent("Link expires") {
                                Text(expiresAt, style: .relative)
                            }
                        }
                        if replacesCurrentWorker, let currentWorkerURL {
                            Label(
                                "\(currentWorkerURL.host ?? currentWorkerURL.absoluteString) will be disconnected before this Worker is linked.",
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                            .foregroundStyle(.orange)
                        }
                        Picker("Server monitoring", selection: $interval) {
                            ForEach(RefreshInterval.serverMonitoringOptions, id: \.self) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        Picker("Cloud history", selection: $historyRetention) {
                            ForEach(CloudHistoryRetention.allCases, id: \.self) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    }

                    Section("Data sent after confirmation") {
                        Label("This device’s APNs token for silent refresh hints",
                              systemImage: "bell.badge")
                        Label("Provider and workspace identifiers, plan, and quota descriptors for selected accounts",
                              systemImage: "list.bullet.rectangle")
                        Label("Selected quota history is retained by the Worker for \(historyRetention.title)",
                              systemImage: "clock.arrow.circlepath")
                    }

                    if !accounts.isEmpty {
                        Section {
                            ForEach(accounts) { account in
                                if account.providerID.supportsOffDeviceMonitoring {
                                    Toggle(isOn: accountSelection(account.id)) {
                                        accountUploadLabel(account)
                                    }
                                } else {
                                    HStack(alignment: .top, spacing: 12) {
                                        ProviderIcon(providerID: account.providerID,
                                                     symbolName: account.customSymbolName)
                                            .frame(width: 26, height: 26)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(account.resolvedDisplayName)
                                            Text("Credentials remain on this device")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "lock.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } header: {
                            Text("Accounts to monitor")
                        } footer: {
                            Text("All accounts are off by default. GitHub Copilot is unavailable for off-device monitoring under App Review Guideline 5.1.1(v).")
                        }
                    }

                    Section {
                        Text("The Worker encrypts credentials stored in D1, but whoever controls \(host) can decrypt and use them. Continue only if this is your own Worker.")
                            .foregroundStyle(.orange)
                        Toggle("I trust this self-hosted Worker", isOn: $trustsWorker)
                    } header: {
                        Text("Trust confirmation")
                    }

                    Section {
                        Button(finalButtonTitle) { confirmingFinalLink = true }
                            .disabled(!trustsWorker || isCommitting)
                    }
                }
            }
            .navigationTitle("Review Worker Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                interval = store.pushServerSettings.serverMonitoringInterval
                historyRetention = store.pushServerSettings.historyRetention
                await validateWorker()
            }
            .confirmationDialog(
                selectedAccountIDs.isEmpty
                    ? "Link this Worker?"
                    : "Upload credentials for \(selectedAccountIDs.count) account\(selectedAccountIDs.count == 1 ? "" : "s")?",
                isPresented: $confirmingFinalLink,
                titleVisibility: .visible
            ) {
                Button(finalButtonTitle) { commitLink() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(finalConfirmationMessage)
            }
        }
    }

    private var finalButtonTitle: String {
        selectedAccountIDs.isEmpty
            ? "Link Worker"
            : "Link Worker & Upload \(selectedAccountIDs.count) Account\(selectedAccountIDs.count == 1 ? "" : "s")"
    }

    private var finalConfirmationMessage: String {
        if selectedAccountIDs.isEmpty {
            return "Blinky will send this device’s APNs token to \(host). No provider credentials will be uploaded."
        }
        return "Blinky will send this device’s APNs token and the selected access tokens, refresh tokens, ID tokens, or API keys to \(host)."
    }

    private func accountSelection(_ id: UUID) -> Binding<Bool> {
        Binding {
            selectedAccountIDs.contains(id)
        } set: { selected in
            if selected { selectedAccountIDs.insert(id) }
            else { selectedAccountIDs.remove(id) }
        }
    }

    private func accountUploadLabel(_ account: MonitoredAccount) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ProviderIcon(providerID: account.providerID, symbolName: account.customSymbolName)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.resolvedDisplayName)
                Text(credentialCategories(for: account.providerID))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func credentialCategories(for providerID: ProviderID) -> String {
        switch providerID {
        case .chatGPT, .claude, .grok, .kimi:
            "Access token, refresh token, and ID token when available"
        case .zai, .zhipu, .miniMax, .synthetic, .warp, .openRouter, .fireworksAI,
             .deepSeek, .poe:
            "API key"
        case .openAIAPI, .anthropicAPI:
            "Organization Admin API key"
        case .githubCopilot:
            "Credentials remain on this device"
        case .ollamaCloud:
            "Browser session remains on this device"
        case .antigravity:
            "Google OAuth tokens remain on this device"
        case .compatibleAPI:
            "Endpoint and API key remain on this device"
        case .newAPI:
            "Endpoint and API key remain on this device"
        }
    }

    private func validateWorker() async {
        isValidating = true
        validationError = nil
        do {
            metadata = try await PushServerClient.validate(draft)
        } catch {
            metadata = nil
            validationError = error.localizedDescription
        }
        isValidating = false
    }

    private func commitLink() {
        guard metadata != nil else { return }
        isCommitting = true
        do {
            try store.confirmPushServerLink(
                draft,
                monitoringAccountIDs: selectedAccountIDs,
                interval: interval,
                historyRetention: historyRetention,
                userConfirmedCredentialUpload: true
            )
            dismiss()
        } catch {
            isCommitting = false
            validationError = error.localizedDescription
        }
    }
}

struct RemoteWorkerAccountsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onlyAccountsMissingLocally: Bool
    @State private var accounts: [RemoteWorkerAccountCandidate] = []
    @State private var selectedIDs: Set<String> = []
    @State private var isLoading = true
    @State private var isImporting = false
    @State private var discoveryError: String?
    @State private var importError: String?

    init(onlyAccountsMissingLocally: Bool = false) {
        self.onlyAccountsMissingLocally = onlyAccountsMissingLocally
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Provider credentials stay encrypted on the Worker.",
                          systemImage: "lock.shield.fill")
                    Label("Imported accounts refresh only from the Worker. Local provider refresh is unavailable.",
                          systemImage: "cloud.fill")
                } header: {
                    Text("Remote-only accounts")
                }

                Section("Available accounts") {
                    if isLoading {
                        HStack {
                            ProgressView()
                            Text("Loading Worker accounts…")
                        }
                    } else if let discoveryError {
                        ContentUnavailableView {
                            Label("Couldn’t Load Worker Accounts",
                                  systemImage: "exclamationmark.icloud.fill")
                        } description: {
                            Text(discoveryError)
                        } actions: {
                            Button("Try Again") { Task { await loadAccounts() } }
                        }
                    } else if accounts.isEmpty {
                        ContentUnavailableView(
                            "No Accounts Available",
                            systemImage: "icloud.slash",
                            description: Text("All monitorable Worker accounts are already on this device.")
                        )
                    } else {
                        ForEach(accounts) { account in
                            Toggle(isOn: selectionBinding(account.id)) {
                                HStack(spacing: 12) {
                                    ProviderIcon(providerID: account.providerID)
                                        .frame(width: 28, height: 28)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(account.displayName)
                                        Text(account.providerID.sectionTitle(plan: account.plan))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        sessionStatus(account)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(onlyAccountsMissingLocally ? "Import from Worker" : "Add from Worker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Check sessions", systemImage: "arrow.clockwise") {
                        Task { await loadAccounts() }
                    }
                    .disabled(isLoading || isImporting)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { importSelection() }
                        .disabled(selectedIDs.isEmpty || isImporting)
                }
            }
            .refreshable { await loadAccounts() }
            .task { await loadAccounts() }
            .alert("Couldn’t Finish Worker Import", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "The Worker accounts could not be imported.")
            }
        }
    }

    private func selectionBinding(_ id: String) -> Binding<Bool> {
        Binding {
            selectedIDs.contains(id)
        } set: { selected in
            if selected { selectedIDs.insert(id) }
            else { selectedIDs.remove(id) }
        }
    }

    @ViewBuilder
    private func sessionStatus(_ account: RemoteWorkerAccountCandidate) -> some View {
        let status = account.sessionStatus ?? .unchecked
        HStack(spacing: 5) {
            Image(systemName: status.systemImageName)
            Text(status.label)
            if let checkedAt = account.sessionCheckedAt {
                Text("· \(checkedAt, style: .relative)")
            }
        }
        .font(.caption2)
        .foregroundStyle(sessionColor(status))
    }

    private func sessionColor(_ status: WorkerSessionStatus) -> Color {
        switch status {
        case .active: .green
        case .expired: .red
        case .error: .orange
        case .unchecked: .secondary
        }
    }

    @MainActor
    private func loadAccounts() async {
        isLoading = true
        discoveryError = nil
        do {
            accounts = try await (onlyAccountsMissingLocally
                ? store.remoteWorkerAccountsMissingLocally()
                : store.availableRemoteWorkerAccounts())
            selectedIDs.formIntersection(accounts.map(\.id))
        } catch {
            accounts = []
            discoveryError = error.localizedDescription
        }
        isLoading = false
    }

    private func importSelection() {
        let selected = accounts.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        isImporting = true
        Task { @MainActor in
            do {
                _ = try await store.importRemoteWorkerAccounts(selected)
                dismiss()
            } catch {
                importError = error.localizedDescription
                isImporting = false
                await loadAccounts()
            }
        }
    }
}
#endif
