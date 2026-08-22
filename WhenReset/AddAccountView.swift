#if os(iOS)
import SwiftUI

struct AddAccountView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    let relinkingAccount: MonitoredAccount?
    @State private var completionTask: Task<Void, Never>?
    @State private var selectedProvider: ProviderID?
    @State private var claudeCode = ""
    @State private var zaiAPIKey = ""
    @State private var miniMaxAPIKey = ""
    @State private var syntheticAPIKey = ""
    @State private var ollamaCookie = ""
    @State private var warpAPIKey = ""
    @State private var antigravityClientID = ""
    @State private var antigravityClientSecret = ""
    @State private var antigravityCallback = ""
    @State private var compatibleName = ""
    @State private var compatibleEndpoint = ""
    @State private var compatibleAPIKey = ""
    @State private var openAIAPIKey = ""
    @State private var openAIMonthlyBudget = ""
    @State private var anthropicAPIKey = ""
    @State private var anthropicMonthlyBudget = ""
    @State private var newAPIName = ""
    @State private var newAPIBaseURL = ""
    @State private var newAPIKey = ""
    @State private var mainstreamAPIKey = ""
    @State private var fireworksAccountID = ""
    @State private var isAddingDemo = false
    @State private var showingRemoteWorkerAccounts = false
    @State private var remoteWorkerAccountsMissingLocally: [RemoteWorkerAccountCandidate] = []
    @State private var isLoadingRemoteWorkerAccounts = true
    @State private var remoteWorkerDiscoveryError: String?
    @State private var didRequestDismiss = false

    init(relinkingAccount: MonitoredAccount? = nil) {
        self.relinkingAccount = relinkingAccount
        _selectedProvider = State(initialValue: relinkingAccount?.providerID)
        let savedCredentials = relinkingAccount.flatMap { try? KeychainStore.load(for: $0.id) }
        _antigravityClientID = State(initialValue: savedCredentials?.oauthClientID ?? "")
        _antigravityClientSecret = State(initialValue: savedCredentials?.oauthClientSecret ?? "")
        let savedBudget = savedCredentials?.monthlyBudget.map { String(format: "%.2f", $0) } ?? ""
        if relinkingAccount?.providerID == .openAIAPI {
            _openAIMonthlyBudget = State(initialValue: savedBudget)
        }
        if relinkingAccount?.providerID == .anthropicAPI {
            _anthropicMonthlyBudget = State(initialValue: savedBudget)
        }
        if relinkingAccount?.providerID == .newAPI {
            _newAPIName = State(initialValue: savedCredentials?.accountLabel
                                ?? relinkingAccount?.displayName ?? "")
            _newAPIBaseURL = State(initialValue: savedCredentials?.endpointURL ?? "")
        }
        if relinkingAccount?.providerID == .fireworksAI {
            let remoteResource = relinkingAccount?.workspaceID.hasPrefix("accounts/") == true
                ? relinkingAccount?.workspaceID : nil
            let resource = savedCredentials?.projectID ?? remoteResource ?? ""
            _fireworksAccountID = State(initialValue: resource.replacingOccurrences(
                of: "accounts/", with: ""
            ))
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let account = relinkingAccount,
                   store.accountLinkProgress.applies(to: account.id) {
                    workerRelinkStatusView(account)
                } else if let link = store.deviceLink {
                    linkView(link)
                } else if let claudeLink = store.claudeLink {
                    claudeCodeView(claudeLink)
                } else if let antigravityLink = store.antigravityLink {
                    antigravityCodeView(antigravityLink)
                } else {
                    providerView
                }
            }
            .navigationTitle(relinkingAccount == nil ? "Add account" : "Sign in again")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { cancel() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel")
                }
            }
            .onDisappear {
                completionTask?.cancel()
                store.cancelLink()
            }
            .sheet(isPresented: $showingRemoteWorkerAccounts, onDismiss: {
                Task { await loadRemoteWorkerAccountsMissingLocally() }
            }) {
                RemoteWorkerAccountsView(onlyAccountsMissingLocally: true)
            }
            .task(id: remoteWorkerImportRefreshID) {
                await loadRemoteWorkerAccountsMissingLocally()
            }
            .alert("Couldn’t link account", isPresented: .init(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(store.errorMessage ?? "Unknown error") }
        }
    }

    private var providerView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if relinkingAccount == nil, store.canAccessRemoteWorkerAccounts {
                    workerImportCard
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(relinkingAccount == nil ? "Connect an account" : "Reconnect \(relinkingAccount?.providerDisplayName ?? "account")")
                        .font(.title2.bold())
                    Text(relinkingAccount == nil
                         ? "Choose a provider to securely import its usage, balance, or reset schedule."
                         : relinkingAccount?.isRemoteOnly == true
                            ? "Sign in again to send a replacement credential directly to the Worker. It is not stored on this device and can never be downloaded from the Worker."
                            : "Sign in again to resume updates. Your saved usage and monitor settings stay in place until reconnection succeeds.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                if !availableProviders.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(relinkingAccount == nil ? "Connect a provider" : "Account provider")
                            .font(.title3.bold())

                        ForEach(availableProviders, id: \.self) { provider in
                            VStack(spacing: 0) {
                                Button {
                                    withAnimation(.snappy) {
                                        if relinkingAccount == nil {
                                            selectedProvider = selectedProvider == provider ? nil : provider
                                        } else {
                                            selectedProvider = provider
                                        }
                                    }
                                } label: {
                                    ProviderCard(provider: provider, selected: selectedProvider == provider)
                                }
                                .buttonStyle(.plain)

                                if selectedProvider == provider {
                                    Divider().padding(.horizontal, 16)
                                    providerLinker(provider)
                                        .padding(16)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
                            .overlay {
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(selectedProvider == provider ? Color.accentColor : Color(.separator).opacity(0.35),
                                            lineWidth: selectedProvider == provider ? 2 : 1)
                            }
                        }
                    }
                }

                if store.accounts.isEmpty, relinkingAccount == nil {
                    demoCard
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 22)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var availableProviders: [ProviderID] {
        ProviderAvailability.providerChoices(
            locale: locale,
            relinkingProvider: relinkingAccount?.providerID
        )
    }

    private var remoteWorkerImportRefreshID: String {
        let accountIDs = store.accounts.map(\.id.uuidString).sorted().joined(separator: ",")
        return "\(store.pushServerSettings.mode.rawValue)|\(store.pushServerSettings.customServerURL)|\(store.canAccessRemoteWorkerAccounts)|\(store.pushServerStatus.title)|\(accountIDs)"
    }

    private var workerImportCard: some View {
        let count = remoteWorkerAccountsMissingLocally.count
        return Button {
            showingRemoteWorkerAccounts = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "icloud.and.arrow.down.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.11), in: .rect(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import from Worker")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(workerImportDescription(count: count))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if isLoadingRemoteWorkerAccounts {
                    ProgressView()
                } else {
                    Image(systemName: remoteWorkerDiscoveryError == nil
                          ? "chevron.right" : "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(remoteWorkerDiscoveryError == nil
                                         ? Color.secondary : Color.orange)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("import-worker-accounts-button")
    }

    @MainActor
    private func loadRemoteWorkerAccountsMissingLocally() async {
        guard relinkingAccount == nil, store.canAccessRemoteWorkerAccounts else {
            remoteWorkerAccountsMissingLocally = []
            remoteWorkerDiscoveryError = nil
            isLoadingRemoteWorkerAccounts = false
            return
        }
        isLoadingRemoteWorkerAccounts = true
        remoteWorkerDiscoveryError = nil
        do {
            let candidates = try await store.remoteWorkerAccountsMissingLocally()
            guard !Task.isCancelled else { return }
            remoteWorkerAccountsMissingLocally = candidates
        } catch {
            guard !Task.isCancelled else { return }
            remoteWorkerAccountsMissingLocally = []
            remoteWorkerDiscoveryError = error.localizedDescription
        }
        isLoadingRemoteWorkerAccounts = false
    }

    private func workerImportDescription(count: Int) -> String {
        if isLoadingRemoteWorkerAccounts {
            return "Checking the linked Worker for accounts…"
        }
        if let remoteWorkerDiscoveryError {
            return "Couldn’t check the linked Worker: \(remoteWorkerDiscoveryError)"
        }
        if count == 0 {
            return "No additional accounts found. Open to check Worker sessions or try again."
        }
        return count == 1
            ? "1 account on the linked Worker is not on this device."
            : "\(count) accounts on the linked Worker are not on this device."
    }

    private var demoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Color.accentColor.gradient, in: .rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your AI Provider")
                        .font(.headline)
                    Text("A credential-free demo with limits, charts, widgets, and Live Activity.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                isAddingDemo = true
                completionTask = Task {
                    await store.addDemoAccount()
                    isAddingDemo = false
                    dismiss()
                }
            } label: {
                HStack {
                    if isAddingDemo { ProgressView().tint(.white) }
                    Text(isAddingDemo ? "Preparing demo…" : "Open Your AI Provider")
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.large)
            .disabled(isAddingDemo || store.isLinking)
        }
        .padding(18)
        .background(Color.accentColor.opacity(0.10), in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func providerLinker(_ provider: ProviderID) -> some View {
        switch provider {
        case .chatGPT, .grok, .kimi, .githubCopilot:
            deviceLinker(provider)
        case .claude:
            claudeLinker
        case .zai:
            zaiLinker
        case .miniMax:
            miniMaxLinker
        case .synthetic:
            syntheticLinker
        case .ollamaCloud:
            ollamaCloudLinker
        case .warp:
            warpLinker
        case .antigravity:
            antigravityLinker
        case .compatibleAPI:
            compatibleAPILinker
        case .openAIAPI:
            openAIAPILinker
        case .anthropicAPI:
            anthropicAPILinker
        case .newAPI:
            newAPILinker
        case .openRouter, .fireworksAI, .deepSeek, .poe:
            mainstreamAPILinker(provider)
        }
    }

    private func deviceLinker(_ provider: ProviderID) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(deviceLinkDescription(provider))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                startDeviceLink(provider)
            } label: {
                Label("Continue with \(provider.displayName)", systemImage: "arrow.right")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.large)
            .disabled(store.isLinking)
            if store.isLinking { ProgressView("Starting secure link…") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deviceLinkDescription(_ provider: ProviderID) -> String {
        switch provider {
        case .chatGPT:
            "Uses the same secure device-link flow as Codex. Your token is stored only in this device’s Keychain."
        case .grok:
            "Uses xAI’s Grok Build device authorization flow. When Reset requests only identity, offline access, and Grok CLI API access; tokens are stored in Keychain."
        case .kimi:
            "Uses Kimi Code’s device authorization flow. This integration relies on Kimi’s public first-party client and is experimental."
        case .githubCopilot:
            "Uses GitHub device authorization. Exact Copilot quotas come from an undocumented endpoint and may change."
        case .claude, .zai, .miniMax, .synthetic, .ollamaCloud, .warp,
             .antigravity, .compatibleAPI, .openAIAPI, .anthropicAPI, .newAPI,
             .openRouter, .fireworksAI, .deepSeek, .poe:
            ""
        }
    }

    private var claudeLinker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in with Claude using the same PKCE OAuth flow as Claude Code. Access and refresh tokens are stored only in this device’s Keychain.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button {
                store.beginClaudeLink()
                if let url = store.claudeLink?.authorizationURL { openURL(url) }
            } label: {
                Label("Continue with Claude", systemImage: "arrow.right")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.large)
            .disabled(store.isLinking)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var zaiLinker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter the plan-specific API key from your Z.AI account. It is used only to read Coding Plan quota data and is stored in this device’s Keychain.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            SecureField("Z.AI Coding Plan API key", text: $zaiAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .padding(14)
                .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 14))

            Button {
                completionTask = Task {
                    if await store.addZAIAccount(apiKey: zaiAPIKey, replacing: relinkingAccount) { dismiss() }
                }
            } label: {
                Label("Connect Z.AI Coding Plan", systemImage: "key.fill")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.large)
            .disabled(zaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isLinking)
            if store.isLinking { ProgressView("Checking Coding Plan…") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var miniMaxLinker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter the Subscription Key from Billing → Token Plan. When Reset uses it only with MiniMax’s quota endpoint and stores it in this device’s Keychain.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            SecureField("MiniMax Token Plan key", text: $miniMaxAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .padding(14)
                .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 14))

            Button {
                completionTask = Task {
                    if await store.addMiniMaxAccount(apiKey: miniMaxAPIKey, replacing: relinkingAccount) { dismiss() }
                }
            } label: {
                Label("Connect MiniMax Token Plan", systemImage: "key.fill")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.large)
            .disabled(miniMaxAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isLinking)
            if store.isLinking { ProgressView("Checking Token Plan…") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var syntheticLinker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter a Synthetic API key. When Reset reads only the rolling five-hour and weekly quota endpoint.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            providerSecretField("Synthetic API key", text: $syntheticAPIKey)
            Button {
                completionTask = Task {
                    if await store.addSyntheticAccount(
                        apiKey: syntheticAPIKey,
                        replacing: relinkingAccount
                    ) { dismiss() }
                }
            } label: {
                Label("Connect Synthetic", systemImage: "key.fill")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.large)
            .disabled(syntheticAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || store.isLinking)
            if store.isLinking { ProgressView("Checking Synthetic quota…") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ollamaCloudLinker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ollama API keys do not expose Cloud quota. Paste the Cookie request header from ollama.com/settings; it stays in this device’s Keychain and cannot be enabled for server monitoring.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            providerSecretField("Cookie request header", text: $ollamaCookie)
            Button {
                completionTask = Task {
                    if await store.addOllamaCloudAccount(
                        cookie: ollamaCookie,
                        replacing: relinkingAccount
                    ) { dismiss() }
                }
            } label: {
                Label("Connect Ollama Cloud", systemImage: "lock.fill")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.large)
            .disabled(ollamaCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || store.isLinking)
            if store.isLinking { ProgressView("Checking Ollama Cloud quota…") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var warpLinker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter the API key generated by Warp. When Reset reads only Warp’s request-credit limit and refresh time.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            providerSecretField("Warp API key", text: $warpAPIKey)
            Button {
                completionTask = Task {
                    if await store.addWarpAccount(apiKey: warpAPIKey, replacing: relinkingAccount) {
                        dismiss()
                    }
                }
            } label: {
                Label("Connect Warp", systemImage: "key.fill")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.large)
            .disabled(warpAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || store.isLinking)
            if store.isLinking { ProgressView("Checking Warp credits…") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var antigravityLinker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Experimental: enter the installed-app OAuth configuration used by your Antigravity setup, then sign in with Google. It is stored in Keychain with your tokens and is never included in When Reset’s source or sent to its Worker.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("OAuth client ID", text: $antigravityClientID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .padding(14)
                .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 14))
            SecureField("OAuth client secret", text: $antigravityClientSecret)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .padding(14)
                .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 14))
            Text("Quotas come from an internal Code Assist API that may change. When Reset never sends prompts or model requests.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                store.beginAntigravityLink(
                    clientID: antigravityClientID,
                    clientSecret: antigravityClientSecret
                )
                if let url = store.antigravityLink?.authorizationURL { openURL(url) }
            } label: {
                Label("Continue with Google", systemImage: "arrow.right")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.large)
            .disabled(antigravityClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || antigravityClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || store.isLinking)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compatibleAPILinker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect an HTTPS endpoint that returns reset windows as JSON, including Sub2API’s GET /v1/usage shape. The URL and bearer key stay on-device to prevent a self-hosted Worker from requesting arbitrary hosts.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Provider name", text: $compatibleName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .padding(14)
                .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 14))
            TextField("https://example.com/v1/usage", text: $compatibleEndpoint)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.system(.body, design: .monospaced))
                .padding(14)
                .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 14))
            providerSecretField("Bearer API key", text: $compatibleAPIKey)
            Button {
                completionTask = Task {
                    if await store.addCompatibleAPIAccount(
                        endpoint: compatibleEndpoint,
                        apiKey: compatibleAPIKey,
                        name: compatibleName,
                        replacing: relinkingAccount
                    ) { dismiss() }
                }
            } label: {
                Label("Connect compatible API", systemImage: "network")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.large)
            .disabled(compatibleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || compatibleEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || compatibleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || store.isLinking)
            if store.isLinking { ProgressView("Checking compatible quota…") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var openAIAPILinker: some View {
        apiBillingLinker(
            providerName: "OpenAI API",
            keyTitle: "OpenAI Admin API key",
            key: $openAIAPIKey,
            budget: $openAIMonthlyBudget,
            help: "OpenAI’s organization Cost API requires an Admin API key. A standard project key cannot read billing data. Add an optional monthly budget to show remaining balance; without one, When Reset shows month-to-date spend.",
            progress: "Checking OpenAI API spend…"
        ) {
            await store.addOpenAIAPIAccount(
                apiKey: openAIAPIKey,
                monthlyBudget: parsedBudget(openAIMonthlyBudget),
                replacing: relinkingAccount
            )
        }
    }

    private var anthropicAPILinker: some View {
        apiBillingLinker(
            providerName: "Anthropic API",
            keyTitle: "Anthropic Admin API key",
            key: $anthropicAPIKey,
            budget: $anthropicMonthlyBudget,
            help: "Anthropic’s Usage and Cost API requires an organization Admin API key, not a standard Claude API key. Add an optional monthly budget to show remaining balance; without one, When Reset shows month-to-date spend.",
            progress: "Checking Anthropic API spend…"
        ) {
            await store.addAnthropicAPIAccount(
                apiKey: anthropicAPIKey,
                monthlyBudget: parsedBudget(anthropicMonthlyBudget),
                replacing: relinkingAccount
            )
        }
    }

    private func apiBillingLinker(
        providerName: String,
        keyTitle: String,
        key: Binding<String>,
        budget: Binding<String>,
        help: String,
        progress: String,
        connect: @escaping () async -> Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(help)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            providerSecretField(keyTitle, text: key)
            TextField("Monthly budget in USD (optional)", text: budget)
                .keyboardType(.decimalPad)
                .font(.system(.body, design: .monospaced))
                .padding(14)
                .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 14))
            Text("The key is stored in iCloud Keychain. Server monitoring uploads it only to a self-hosted Worker after you separately confirm that account setting.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                completionTask = Task {
                    if await connect() { dismiss() }
                }
            } label: {
                Label("Connect \(providerName)", systemImage: "dollarsign.gauge.chart.lefthalf.righthalf")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.large)
            .disabled(key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || !isValidOptionalBudget(budget.wrappedValue)
                      || store.isLinking)
            if store.isLinking { ProgressView(progress) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var newAPILinker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect a New API or One API-compatible service using its OpenAI-style billing endpoints. When Reset reads the API key’s total allowance, usage, remaining balance, and expiry. Custom endpoints stay on-device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Provider name", text: $newAPIName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .padding(14)
                .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 14))
            TextField("https://api.example.com", text: $newAPIBaseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.system(.body, design: .monospaced))
                .padding(14)
                .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 14))
            providerSecretField("API key", text: $newAPIKey)
            Button {
                completionTask = Task {
                    if await store.addNewAPIAccount(
                        baseURL: newAPIBaseURL,
                        apiKey: newAPIKey,
                        name: newAPIName,
                        replacing: relinkingAccount
                    ) { dismiss() }
                }
            } label: {
                Label("Connect API balance", systemImage: "creditcard.fill")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.large)
            .disabled(newAPIName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || newAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || newAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || store.isLinking)
            if store.isLinking { ProgressView("Checking API balance…") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mainstreamAPILinker(_ provider: ProviderID) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mainstreamAPIHelp(provider))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            providerSecretField("\(provider.displayName) API key", text: $mainstreamAPIKey)
            if provider == .fireworksAI {
                TextField("Fireworks account ID (optional)", text: $fireworksAccountID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .padding(14)
                    .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 14))
                Text("Leave the account ID empty when the API key can access exactly one account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(relinkingAccount?.isRemoteOnly == true
                 ? "The key is sent directly to your authenticated Worker to replace its encrypted copy. It is not stored on this device or returned by the Worker."
                 : "The key is stored in iCloud Keychain. Server monitoring uploads it only after you separately confirm that account setting.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                completionTask = Task {
                    let success = await addMainstreamAPIAccount(provider)
                    if success { dismiss() }
                }
            } label: {
                Label("Connect \(provider.displayName)", systemImage: provider.systemImageName)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.large)
            .disabled(mainstreamAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || store.isLinking)
            if store.isLinking { ProgressView("Checking \(provider.displayName)…") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mainstreamAPIHelp(_ provider: ProviderID) -> String {
        switch provider {
        case .openRouter:
            "When Reset reads this API key’s enforced spending limit, remaining amount, reset cadence, and expiry from OpenRouter."
        case .fireworksAI:
            "When Reset reads the account’s monthly API spending limit and usage from Fireworks AI."
        case .deepSeek:
            "When Reset reads the available DeepSeek API wallet balance. This is prepaid credit, not a resettable quota."
        case .poe:
            "When Reset reads the available Poe API point balance. Poe does not report a reset time for these points."
        default:
            ""
        }
    }

    private func addMainstreamAPIAccount(_ provider: ProviderID) async -> Bool {
        switch provider {
        case .openRouter:
            await store.addOpenRouterAccount(apiKey: mainstreamAPIKey,
                                             replacing: relinkingAccount)
        case .fireworksAI:
            await store.addFireworksAIAccount(
                apiKey: mainstreamAPIKey,
                accountID: fireworksAccountID,
                replacing: relinkingAccount
            )
        case .deepSeek:
            await store.addDeepSeekAccount(apiKey: mainstreamAPIKey,
                                           replacing: relinkingAccount)
        case .poe:
            await store.addPoeAccount(apiKey: mainstreamAPIKey,
                                      replacing: relinkingAccount)
        default:
            false
        }
    }

    private func parsedBudget(_ value: String) -> Double? {
        Double(value.replacingOccurrences(of: ",", with: "."))
    }

    private func isValidOptionalBudget(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard let amount = parsedBudget(trimmed) else { return false }
        return amount.isFinite && amount > 0
    }

    private func providerSecretField(_ title: String, text: Binding<String>) -> some View {
        SecureField(title, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(.body, design: .monospaced))
            .padding(14)
            .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private func claudeCodeView(_ link: ClaudeOAuthLink) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Finish Claude sign-in")
                    .font(.title2.bold())
                Text("After approving access in Safari, copy the authorization code from Claude and paste it here.")
                    .foregroundStyle(.secondary)
                TextField("Authorization code", text: $claudeCode, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2...5)
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
                Button {
                    completionTask = Task {
                        if await store.completeClaudeLink(code: claudeCode, replacing: relinkingAccount) { dismiss() }
                    }
                } label: {
                    Label("Finish linking", systemImage: "checkmark.circle.fill")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .controlSize(.large)
                .disabled(claudeCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isLinking)
                Button { openURL(link.authorizationURL) } label: {
                    Label("Open Claude again", systemImage: "safari")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .controlSize(.large)
                Text("The code may include a #state suffix. Paste the complete value so When Reset can verify the sign-in attempt.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func antigravityCodeView(_ link: AntigravityOAuthLink) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Finish Antigravity sign-in")
                    .font(.title2.bold())
                Text("Google redirects to a desktop localhost address, which will not load on iPhone. Copy the complete URL from Safari’s address bar and paste it here.")
                    .foregroundStyle(.secondary)
                TextField("http://localhost:51121/oauth-callback?code=…", text: $antigravityCallback,
                          axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(3...7)
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
                Button {
                    completionTask = Task {
                        if await store.completeAntigravityLink(
                            callback: antigravityCallback,
                            replacing: relinkingAccount
                        ) { dismiss() }
                    }
                } label: {
                    Label("Finish linking", systemImage: "checkmark.circle.fill")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .controlSize(.large)
                .disabled(antigravityCallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || store.isLinking)
                Button { openURL(link.authorizationURL) } label: {
                    Label("Open Google again", systemImage: "safari")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .controlSize(.large)
                Text("When Reset verifies the OAuth state before exchanging the code. This integration never sends prompts or model requests.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func linkView(_ link: DeviceLinkPresentation) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                ProviderIcon(providerID: link.providerID)
                    .frame(width: 64, height: 64)
                Text("Enter this code")
                    .font(.title2.bold())
                Text(link.userCode)
                    .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                    .textSelection(.enabled)
                    .padding(.vertical, 8)
                Button { UIPasteboard.general.string = link.userCode } label: {
                    Label("Copy code", systemImage: "doc.on.doc")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .controlSize(.large)
                Button { openURL(link.verificationURL) } label: {
                    Label("Open \(link.providerID.displayName) linking", systemImage: "safari")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .controlSize(.large)
                if store.isLinking {
                    ProgressView("Waiting for \(link.providerID.displayName)…")
                } else {
                    Label("Authorization check paused", systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                }
                Text("The code expires \(link.expiresAt, style: .relative).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    openURL(link.verificationURL)
                } label: {
                    Label("Open authorization page again", systemImage: "safari")
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                HStack {
                    Button("Check now") {
                        resumeDeviceLink(link.providerID)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Start over") {
                        startDeviceLink(link.providerID)
                    }
                    .buttonStyle(.bordered)
                }
                Text("If you already approved access and this view is still waiting, choose Check now. Start over creates a new one-time code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)
            .padding(.horizontal, 20)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func workerRelinkStatusView(_ account: MonitoredAccount) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                ProviderIcon(providerID: account.providerID)
                    .frame(width: 64, height: 64)
                if store.accountLinkProgress.isVerifyingWorker {
                    ProgressView()
                        .controlSize(.large)
                    Text("Updating Worker sign-in…")
                        .font(.title2.bold())
                    Text("Provider authorization succeeded. When Reset is securely replacing the Worker credential and checking that quota refresh is active.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("Worker sign-in update failed")
                        .font(.title2.bold())
                    Text(store.refreshFailures[account.id]?.message
                         ?? "The provider accepted the sign-in, but the Worker could not confirm the replacement credential.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if store.accountLinkProgress.canRetryWithoutAuthorization {
                        Button("Retry Worker update") {
                            retryWorkerReplacement(for: account)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Sign in again") {
                        startDeviceLink(account.providerID)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 48)
            .padding(.horizontal, 24)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func cancel() {
        completionTask?.cancel()
        store.cancelLink()
        dismiss()
    }

    private func startDeviceLink(_ provider: ProviderID) {
        let previousTask = completionTask
        completionTask = Task {
            previousTask?.cancel()
            await previousTask?.value
            guard !Task.isCancelled else { return }
            store.cancelLink()
            await store.beginDeviceLink(for: provider, replacing: relinkingAccount)
            guard !Task.isCancelled,
                  let link = store.deviceLink,
                  link.providerID == provider else { return }
            openURL(link.verificationURL)
            if await store.completeDeviceLink(replacing: relinkingAccount) {
                dismissAfterSuccess()
            }
        }
    }

    private func resumeDeviceLink(_ provider: ProviderID) {
        guard store.deviceLink?.providerID == provider else {
            startDeviceLink(provider)
            return
        }
        let previousTask = completionTask
        completionTask = Task {
            previousTask?.cancel()
            await previousTask?.value
            guard !Task.isCancelled,
                  store.deviceLink?.providerID == provider else { return }
            if await store.completeDeviceLink(replacing: relinkingAccount) {
                dismissAfterSuccess()
            }
        }
    }

    private func retryWorkerReplacement(for account: MonitoredAccount) {
        let previousTask = completionTask
        completionTask = Task {
            previousTask?.cancel()
            await previousTask?.value
            guard !Task.isCancelled else { return }
            if await store.retryWorkerCredentialReplacement(for: account.id) {
                dismissAfterSuccess()
            }
        }
    }

    @MainActor
    private func dismissAfterSuccess() {
        guard !didRequestDismiss else { return }
        didRequestDismiss = true
        dismiss()
    }
}

private struct ProviderCard: View {
    let provider: ProviderID
    let selected: Bool

    var body: some View {
        HStack(spacing: 14) {
            ProviderIcon(providerID: provider)
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.displayName).font(.headline).foregroundStyle(.primary)
                Text(provider.accountDescription)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "chevron.right")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 78)
        .contentShape(.rect)
    }
}
#endif
