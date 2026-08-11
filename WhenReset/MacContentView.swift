#if os(macOS)
import AppKit
import SwiftUI

struct MacContentView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: UUID?
    @State private var showingAddAccount = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Accounts") {
                    ForEach(store.accounts) { account in
                        HStack(spacing: 10) {
                            ProviderIcon(providerID: account.providerID,
                                         symbolName: account.customSymbolName)
                                .frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.resolvedDisplayName).lineLimit(1)
                                Text(account.providerDisplayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .tag(account.id)
                    }
                }
            }
            .navigationTitle("When Reset")
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        showingAddAccount = true
                    } label: {
                        Label("Add account", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    SettingsLink {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                }
                .padding(12)
                .background(.bar)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            if let account = selectedAccount {
                MacAccountDetailView(account: account)
                    .id(account.id)
            } else {
                MacEmptyStateView(showingAddAccount: $showingAddAccount)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showingAddAccount) {
            MacAddAccountView()
                .environment(store)
        }
        .alert("When Reset", isPresented: errorIsPresented) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "Something went wrong.")
        }
        .onAppear { repairSelection() }
        .onChange(of: store.accounts.map(\.id)) { _, _ in repairSelection() }
    }

    private var selectedAccount: MonitoredAccount? {
        guard let selection else { return nil }
        return store.accounts.first { $0.id == selection }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }

    private func repairSelection() {
        if selection.flatMap({ id in store.accounts.first { $0.id == id } }) == nil {
            selection = store.accounts.first?.id
        }
    }
}

private struct MacEmptyStateView: View {
    @Environment(AppStore.self) private var store
    @Binding var showingAddAccount: Bool
    @State private var isAddingDemo = false

    var body: some View {
        ContentUnavailableView {
            Label("Know when your limit resets", systemImage: "clock.arrow.circlepath")
        } description: {
            Text("Connect an account to see quota, reset, and balance information on your Mac, desktop widgets, and menu bar.")
        } actions: {
            HStack {
                Button("Add account") { showingAddAccount = true }
                    .buttonStyle(.borderedProminent)
                Button("Try demo") {
                    isAddingDemo = true
                    Task {
                        _ = await store.addDemoAccount()
                        isAddingDemo = false
                    }
                }
                .disabled(isAddingDemo)
            }
        }
    }
}

private struct MacAccountDetailView: View {
    @Environment(AppStore.self) private var store
    let account: MonitoredAccount
    @State private var showingRelink = false
    @State private var showingRemovalConfirmation = false

    private var currentAccount: MonitoredAccount {
        store.accounts.first { $0.id == account.id } ?? account
    }

    private var snapshot: UsageSnapshot? { store.snapshots[account.id] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                accountHeader

                if let failure = store.refreshFailures[account.id] {
                    Label(failure.message, systemImage: failure.systemImageName)
                        .foregroundStyle(failure.requiresRelink ? .red : .orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.08), in: .rect(cornerRadius: 12))
                }

                if let snapshot {
                    usageSection(snapshot)
                } else {
                    ContentUnavailableView(
                        "No usage yet",
                        systemImage: "arrow.clockwise.circle",
                        description: Text("Refresh this account to load its latest limits.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                }

                accountPreferences
                accountActions
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(currentAccount.resolvedDisplayName)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { _ = await store.refresh(currentAccount) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing || currentAccount.isDemo)
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .sheet(isPresented: $showingRelink) {
            MacAddAccountView(relinkingAccount: currentAccount)
                .environment(store)
        }
        .confirmationDialog(
            "Remove \(currentAccount.resolvedDisplayName)?",
            isPresented: $showingRemovalConfirmation
        ) {
            Button("Remove account", role: .destructive) { store.remove(currentAccount) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved credentials, settings, and local history for this account will be removed from this Mac.")
        }
    }

    private var accountHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            ProviderIcon(providerID: currentAccount.providerID,
                         symbolName: currentAccount.customSymbolName)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(currentAccount.resolvedDisplayName)
                    .font(.largeTitle.bold())
                Text(currentAccount.providerSectionTitle(plan: currentAccount.plan))
                    .foregroundStyle(.secondary)
                if let fetchedAt = snapshot?.fetchedAt {
                    Text("Updated \(fetchedAt, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func usageSection(_ snapshot: UsageSnapshot) -> some View {
        let visibleWindows = snapshot.usageWindows.filter { store.settings(for: currentAccount).shows($0) }
        if visibleWindows.isEmpty && snapshot.availableResetCount == 0 {
            ContentUnavailableView(
                "No resettable limits reported",
                systemImage: "checkmark.circle",
                description: Text("The provider did not return an active reset window.")
            )
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                ForEach(visibleWindows, id: \.metricID) { window in
                    MacUsageWindowCard(window: window)
                }
                if store.settings(for: currentAccount).showBankedResets,
                   snapshot.availableResetCount > 0 {
                    MacBankedResetCard(snapshot: snapshot)
                }
            }
        }
    }

    private var accountPreferences: some View {
        GroupBox("Account preferences") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Notify about detected resets", isOn: accountSetting(\.notifyAboutResets))
                Toggle("Notify at scheduled reset time", isOn: accountSetting(\.notifyAtScheduledReset))
                if currentAccount.providerID.supportsBankedResets {
                    Toggle("Show banked resets", isOn: accountSetting(\.showBankedResets))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private var accountActions: some View {
        HStack {
            if !currentAccount.isDemo && !currentAccount.isRemoteOnly {
                Button("Reconnect account") { showingRelink = true }
            }
            Spacer()
            Button("Remove account", role: .destructive) {
                showingRemovalConfirmation = true
            }
        }
    }

    private func accountSetting(_ keyPath: WritableKeyPath<AccountMonitorSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.settings(for: currentAccount)[keyPath: keyPath] },
            set: { value in
                var settings = store.settings(for: currentAccount)
                settings[keyPath: keyPath] = value
                store.setSettings(settings, for: currentAccount)
            }
        )
    }
}

private struct MacUsageWindowCard: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(window.displayTitle).font(.headline)
                Spacer()
                Text("\(Int(window.remainingPercent.rounded()))% left")
                    .font(.headline.monospacedDigit())
            }
            ProgressView(value: window.remainingPercent, total: 100)
                .tint(window.remainingPercent <= 10 ? .red : .blue)
            HStack {
                Text("Resets")
                    .foregroundStyle(.secondary)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(CountdownDisplay.usageString(until: window.resetsAt, from: context.date))
                        .monospacedDigit()
                }
            }
            .font(.caption)
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 14))
    }
}

private struct MacBankedResetCard: View {
    let snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Banked resets").font(.headline)
                Spacer()
                Text("\(snapshot.availableResetCount)")
                    .font(.headline.monospacedDigit())
            }
            if let expiry = snapshot.nextBankedResetExpiry() {
                HStack {
                    Text("Next expiry").foregroundStyle(.secondary)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(CountdownDisplay.usageString(until: expiry, from: context.date))
                            .monospacedDigit()
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.teal.opacity(0.10), in: .rect(cornerRadius: 14))
    }
}

struct MacMenuBarView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    private var targets: [MacStatusTarget] {
        MacStatusTarget.targets(accounts: store.accounts, snapshots: store.snapshots,
                                settings: store.monitorSettings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("When Reset", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.small) }
                Button {
                    Task { _ = await store.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(store.isRefreshing)
                .help("Refresh all accounts")
            }
            .padding(14)

            Divider()

            if targets.isEmpty {
                ContentUnavailableView(
                    "No upcoming resets",
                    systemImage: "clock.badge.checkmark",
                    description: Text("Open When Reset to add or refresh an account.")
                )
                .frame(height: 190)
            } else {
                VStack(spacing: 0) {
                    ForEach(targets.prefix(5)) { target in
                        MacMenuStatusRow(target: target)
                        if target.id != targets.prefix(5).last?.id { Divider().padding(.leading, 48) }
                    }
                }
            }

            Divider()
            HStack {
                Button("Open When Reset") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
            .padding(14)
        }
        .frame(width: 360)
    }
}

private struct MacMenuStatusRow: View {
    let target: MacStatusTarget

    var body: some View {
        HStack(spacing: 10) {
            ProviderIcon(providerID: target.providerID, symbolName: target.symbolName)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.accountName).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(target.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let value = target.valueLabel {
                    Text(value).font(.caption.bold().monospacedDigit())
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(CountdownDisplay.compactString(until: target.date, from: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct MacStatusTarget: Identifiable {
    let id: String
    let accountName: String
    let providerID: ProviderID
    let symbolName: String?
    let title: String
    let valueLabel: String?
    let date: Date

    static func targets(accounts: [MonitoredAccount], snapshots: [UUID: UsageSnapshot],
                        settings: [UUID: AccountMonitorSettings], now: Date = .now) -> [Self] {
        accounts.flatMap { account -> [Self] in
            guard let snapshot = snapshots[account.id] else { return [] }
            let accountSettings = settings[account.id] ?? .init()
            var result = snapshot.usageWindows
                .filter { $0.resetsAt > now && accountSettings.shows($0) }
                .map { window in
                    Self(
                        id: "\(account.id.uuidString):\(window.metricID)",
                        accountName: account.resolvedDisplayName,
                        providerID: account.providerID,
                        symbolName: account.customSymbolName,
                        title: window.displayTitle,
                        valueLabel: "\(Int(window.remainingPercent.rounded()))% left",
                        date: window.resetsAt
                    )
                }
            if accountSettings.showBankedResets,
               let expiry = snapshot.nextBankedResetExpiry(after: now) {
                result.append(Self(
                    id: "\(account.id.uuidString):banked-resets",
                    accountName: account.resolvedDisplayName,
                    providerID: account.providerID,
                    symbolName: account.customSymbolName,
                    title: "Banked resets",
                    valueLabel: "\(snapshot.availableResetCount) available",
                    date: expiry
                ))
            }
            return result
        }
        .sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.accountName.localizedCaseInsensitiveCompare($1.accountName) == .orderedAscending
        }
    }
}

struct MacSettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form {
            Section("Refresh") {
                Picker("While When Reset is running", selection: refreshInterval) {
                    ForEach(RefreshInterval.inAppOptions, id: \.self) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
            }

            Section("Notifications") {
                Toggle("Unexpected or early resets", isOn: notificationSetting(\.notifyAboutUnexpectedResets))
                Toggle("Scheduled reset times", isOn: notificationSetting(\.notifyAtScheduledReset))
            }

            Section("Live Activity on Mac") {
                Label {
                    Text("Apple displays an active When Reset Live Activity from your paired iPhone or iPad in the Mac menu bar. The native Mac menu-bar item above remains available even when no paired-device Live Activity is running.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "iphone.and.arrow.forward.inward")
                }
            }

            Section("About") {
                LabeledContent("Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                }
                Link("Source code", destination: URL(string: "https://github.com/iebb/when-reset")!)
                Link("Report an issue", destination: URL(string: "https://github.com/iebb/when-reset/issues")!)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var refreshInterval: Binding<RefreshInterval> {
        Binding(
            get: { store.refreshSettings.inAppInterval },
            set: { value in
                var settings = store.refreshSettings
                settings.inAppInterval = value
                store.setRefreshSettings(settings)
            }
        )
    }

    private func notificationSetting(
        _ keyPath: WritableKeyPath<GlobalNotificationSettings, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { store.notificationSettings[keyPath: keyPath] },
            set: { value in
                var settings = store.notificationSettings
                settings[keyPath: keyPath] = value
                store.setNotificationSettings(settings)
            }
        )
    }
}

private struct MacAddAccountView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let relinkingAccount: MonitoredAccount?

    @State private var selectedProvider: ProviderID?
    @State private var secret = ""
    @State private var endpoint = ""
    @State private var providerName = ""
    @State private var callback = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var completionTask: Task<Void, Never>?

    init(relinkingAccount: MonitoredAccount? = nil) {
        self.relinkingAccount = relinkingAccount
        _selectedProvider = State(initialValue: relinkingAccount?.providerID)
    }

    private var providers: [ProviderID] {
        ProviderAvailability.providerChoices(locale: locale,
                                             relinkingProvider: relinkingAccount?.providerID)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let selectedProvider {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            providerHeader(selectedProvider)
                            providerLinker(selectedProvider)
                        }
                        .padding(24)
                        .frame(maxWidth: 620, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    List(providers, id: \.rawValue) { provider in
                        Button {
                            selectedProvider = provider
                        } label: {
                            HStack(spacing: 12) {
                                ProviderIcon(providerID: provider).frame(width: 34, height: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(provider.displayName).font(.headline)
                                    Text(provider.accountDescription)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 5)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(relinkingAccount == nil ? "Add account" : "Reconnect account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if selectedProvider != nil && relinkingAccount == nil {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            cancelLink()
                            selectedProvider = nil
                        } label: {
                            Label("Providers", systemImage: "chevron.left")
                        }
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 620)
        .onDisappear { completionTask?.cancel(); store.cancelLink() }
    }

    private func providerHeader(_ provider: ProviderID) -> some View {
        HStack(spacing: 14) {
            ProviderIcon(providerID: provider).frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.displayName).font(.title2.bold())
                Text(provider.accountDescription).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func providerLinker(_ provider: ProviderID) -> some View {
        switch provider.rawValue {
        case "chatgpt", "grok", "kimi", "github_copilot":
            deviceLinker(provider)
        case "claude":
            claudeLinker
        case "antigravity":
            antigravityLinker
        case "compatible_api":
            compatibleLinker
        case "zai", "minimax", "synthetic", "ollama_cloud", "warp":
            apiKeyLinker(provider)
        default:
            ContentUnavailableView(
                "Connect on iPhone or iPad",
                systemImage: "iphone",
                description: Text("This provider can be viewed and refreshed on Mac after its account is synchronized through iCloud Keychain.")
            )
            .frame(maxWidth: .infinity, minHeight: 280)
        }
    }

    private func deviceLinker(_ provider: ProviderID) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("When Reset uses the provider’s device authorization page. Credentials are stored in your Keychain.")
                .foregroundStyle(.secondary)
            if let link = store.deviceLink, link.providerID == provider {
                GroupBox("Authorization code") {
                    HStack {
                        Text(link.userCode)
                            .font(.title.monospaced().bold())
                            .textSelection(.enabled)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link.userCode, forType: .string)
                        }
                    }
                    .padding(.top, 4)
                }
                ProgressView("Waiting for authorization…")
            } else {
                Button("Continue in browser") {
                    completionTask = Task {
                        await store.beginDeviceLink(for: provider, replacing: relinkingAccount)
                        guard let link = store.deviceLink, link.providerID == provider else { return }
                        NSWorkspace.shared.open(link.verificationURL)
                        if await store.completeDeviceLink(replacing: relinkingAccount) { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isLinking)
            }
        }
    }

    private var claudeLinker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to Claude, then paste the authorization code shown after approval.")
                .foregroundStyle(.secondary)
            if let link = store.claudeLink {
                Button("Open Claude authorization") { NSWorkspace.shared.open(link.authorizationURL) }
                TextField("Authorization code", text: $callback)
                    .textFieldStyle(.roundedBorder)
                Button("Complete connection") {
                    completionTask = Task {
                        if await store.completeClaudeLink(code: callback,
                                                          replacing: relinkingAccount) { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(callback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || store.isLinking)
            } else {
                Button("Start Claude sign-in") {
                    store.beginClaudeLink()
                    if let link = store.claudeLink { NSWorkspace.shared.open(link.authorizationURL) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var antigravityLinker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Use your Google OAuth desktop client. The client secret and resulting tokens remain in Keychain on this device.")
                .foregroundStyle(.secondary)
            if let link = store.antigravityLink {
                Button("Open Google authorization") { NSWorkspace.shared.open(link.authorizationURL) }
                TextField("Callback URL or authorization code", text: $callback)
                    .textFieldStyle(.roundedBorder)
                Button("Complete connection") {
                    completionTask = Task {
                        if await store.completeAntigravityLink(callback: callback,
                                                               replacing: relinkingAccount) { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(callback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || store.isLinking)
            } else {
                TextField("OAuth client ID", text: $clientID).textFieldStyle(.roundedBorder)
                SecureField("OAuth client secret", text: $clientSecret).textFieldStyle(.roundedBorder)
                Button("Start Google sign-in") {
                    store.beginAntigravityLink(clientID: clientID, clientSecret: clientSecret)
                    if let link = store.antigravityLink { NSWorkspace.shared.open(link.authorizationURL) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || clientSecret.isEmpty || store.isLinking)
            }
        }
    }

    private var compatibleLinker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect an OpenAI-compatible quota endpoint. The endpoint and key remain on this Mac.")
                .foregroundStyle(.secondary)
            TextField("Provider name", text: $providerName).textFieldStyle(.roundedBorder)
            TextField("HTTPS endpoint", text: $endpoint).textFieldStyle(.roundedBorder)
            SecureField("API key", text: $secret).textFieldStyle(.roundedBorder)
            Button("Connect endpoint") {
                completionTask = Task {
                    if await store.addCompatibleAPIAccount(endpoint: endpoint, apiKey: secret,
                                                           name: providerName,
                                                           replacing: relinkingAccount) { dismiss() }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || secret.isEmpty || store.isLinking)
        }
    }

    private func apiKeyLinker(_ provider: ProviderID) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(provider.rawValue == "ollama_cloud"
                 ? "Paste the Ollama Cloud browser session cookie. It remains in Keychain on this Mac."
                 : "Paste the provider API key. It is stored in Keychain and is never shown again.")
                .foregroundStyle(.secondary)
            SecureField(provider.rawValue == "ollama_cloud" ? "Session cookie" : "API key", text: $secret)
                .textFieldStyle(.roundedBorder)
            Button("Connect \(provider.displayName)") {
                completionTask = Task {
                    let success: Bool
                    switch provider.rawValue {
                    case "zai": success = await store.addZAIAccount(apiKey: secret,
                                                                     replacing: relinkingAccount)
                    case "minimax": success = await store.addMiniMaxAccount(apiKey: secret,
                                                                             replacing: relinkingAccount)
                    case "synthetic": success = await store.addSyntheticAccount(apiKey: secret,
                                                                                  replacing: relinkingAccount)
                    case "ollama_cloud": success = await store.addOllamaCloudAccount(cookie: secret,
                                                                                      replacing: relinkingAccount)
                    case "warp": success = await store.addWarpAccount(apiKey: secret,
                                                                       replacing: relinkingAccount)
                    default: success = false
                    }
                    if success { dismiss() }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(secret.isEmpty || store.isLinking)
            if store.isLinking { ProgressView("Checking account…") }
        }
    }

    private func cancelLink() {
        completionTask?.cancel()
        completionTask = nil
        store.cancelLink()
    }
}
#endif
