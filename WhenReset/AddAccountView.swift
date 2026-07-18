import SwiftUI

struct AddAccountView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let relinkingAccount: MonitoredAccount?
    @State private var completionTask: Task<Void, Never>?
    @State private var selectedProvider: ProviderID?
    @State private var claudeCode = ""
    @State private var zaiAPIKey = ""
    @State private var miniMaxAPIKey = ""
    @State private var isAddingDemo = false

    init(relinkingAccount: MonitoredAccount? = nil) {
        self.relinkingAccount = relinkingAccount
        _selectedProvider = State(initialValue: relinkingAccount?.providerID)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let link = store.deviceLink {
                    linkView(link)
                } else if let claudeLink = store.claudeLink {
                    claudeCodeView(claudeLink)
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
            }
            .alert("Couldn’t link account", isPresented: .init(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(store.errorMessage ?? "Unknown error") }
        }
    }

    private var providerView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(relinkingAccount == nil ? "See every reset at a glance" : "Reconnect \(relinkingAccount?.providerID.displayName ?? "account")")
                        .font(.title2.bold())
                    Text(relinkingAccount == nil
                         ? "Connect a provider, or explore the complete experience without signing in."
                         : "Sign in again to resume updates. Your saved usage and monitor settings stay in place until reconnection succeeds.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                if store.accounts.isEmpty, relinkingAccount == nil {
                    demoCard
                }

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
            .padding(.horizontal, 18)
            .padding(.vertical, 22)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var availableProviders: [ProviderID] {
        relinkingAccount.map { [$0.providerID] } ?? ProviderID.allCases
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
                    Text("Preview the experience")
                        .font(.headline)
                    Text("Randomized ChatGPT limits, banked resets, widgets, and Live Activity.")
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
                    Text(isAddingDemo ? "Preparing demo…" : "Try it out with our demo")
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
        case .chatGPT, .kimi, .githubCopilot:
            deviceLinker(provider)
        case .claude:
            claudeLinker
        case .zai:
            zaiLinker
        case .miniMax:
            miniMaxLinker
        }
    }

    private func deviceLinker(_ provider: ProviderID) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(deviceLinkDescription(provider))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                completionTask = Task {
                    await store.beginDeviceLink(for: provider)
                    if let link = store.deviceLink {
                        openURL(link.verificationURL)
                        if await store.completeDeviceLink(replacing: relinkingAccount) { dismiss() }
                    }
                }
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
        case .kimi:
            "Uses Kimi Code’s device authorization flow. This integration relies on Kimi’s public first-party client and is experimental."
        case .githubCopilot:
            "Uses GitHub device authorization. Exact Copilot quotas come from an undocumented endpoint and may change."
        case .claude, .zai, .miniMax:
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
                ProgressView("Waiting for \(link.providerID.displayName)…")
                Text("The code expires \(link.expiresAt, style: .relative).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)
            .padding(.horizontal, 20)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func cancel() {
        completionTask?.cancel()
        store.cancelLink()
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
