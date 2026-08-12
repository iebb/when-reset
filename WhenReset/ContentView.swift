#if os(iOS)
import Charts
import SwiftUI
import UIKit

enum AppLinks {
    static let sourceCode = URL(string: "https://github.com/iebb/when-reset")!
    static let issues = URL(string: "https://github.com/iebb/when-reset/issues")!
}

struct ContentView: View {
    private enum Tab: Hashable { case usage, settings }

    @State private var selectedTab = Tab.usage
    @State private var pendingWorkerLink: WorkerLinkDraft?
    @State private var workerLinkError: String?

    var body: some View {
        TabView(selection: $selectedTab) {
            UsageTabView()
                .tabItem { Label("Usage", systemImage: "chart.bar.fill") }
                .tag(Tab.usage)
            SettingsView(onStageWorkerLink: stageWorkerLink)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .onOpenURL { url in
            do {
                let payload = try WorkerLinkPayload.parse(url)
                selectedTab = .settings
                pendingWorkerLink = .pairing(payload)
            } catch {
                workerLinkError = error.localizedDescription
            }
        }
        .sheet(item: $pendingWorkerLink) { draft in
            WorkerLinkReviewView(draft: draft)
        }
        .alert("Couldn’t read Worker link", isPresented: Binding(
            get: { workerLinkError != nil },
            set: { if !$0 { workerLinkError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workerLinkError ?? "The Worker link is invalid.")
        }
    }

    private func stageWorkerLink(_ draft: WorkerLinkDraft) {
        selectedTab = .settings
        pendingWorkerLink = draft
    }
}

private struct UsageTabView: View {
    @Environment(AppStore.self) private var store
    @State private var showingAddAccount = false
    @State private var relinkingAccount: MonitoredAccount?
    @State private var accountPendingRemoval: MonitoredAccount?
    @State private var isPreparingDemo = false

    var body: some View {
        NavigationStack {
            Group {
                if store.accounts.isEmpty { emptyState }
                else { accountList }
            }
            .navigationTitle(store.accounts.isEmpty ? "When Reset" : "Usage")
            .navigationBarTitleDisplayMode(store.accounts.isEmpty ? .inline : .automatic)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.accounts.isEmpty {
                        Button { Task { await store.refreshAll() } } label: {
                            if store.isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                        }.disabled(store.isRefreshing)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !store.accounts.isEmpty {
                        Button("Add", systemImage: "plus") { showingAddAccount = true }
                    }
                }
            }
            .refreshable { await store.refreshAll() }
            .sheet(isPresented: $showingAddAccount) { AddAccountView() }
            .sheet(item: $relinkingAccount) { account in
                AddAccountView(relinkingAccount: account)
            }
            .confirmationDialog(
                "Remove account?",
                isPresented: Binding(
                    get: { accountPendingRemoval != nil },
                    set: { if !$0 { accountPendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let account = accountPendingRemoval {
                    Button("Remove \(account.providerDisplayName) account", role: .destructive) {
                        store.remove(account)
                        accountPendingRemoval = nil
                    }
                }
                Button("Cancel", role: .cancel) { accountPendingRemoval = nil }
            } message: {
                if accountPendingRemoval?.isRemoteOnly == true {
                    Text("This removes the Worker subscription and this device’s cached usage, recorded history, and monitor settings. Provider credentials remain on the Worker.")
                } else {
                    Text("This deletes the account and credentials from devices using your iCloud Keychain, plus this device’s cached usage, recorded history, and monitor settings.")
                }
            }
            .alert("Couldn’t update", isPresented: .init(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(store.errorMessage ?? "Unknown error") }
        }
    }

    private var emptyState: some View {
        FirstRunExperienceView(
            isPreparingDemo: isPreparingDemo,
            openDemo: {
                guard !isPreparingDemo else { return }
                isPreparingDemo = true
                Task {
                    await store.addDemoAccount()
                    isPreparingDemo = false
                }
            },
            connectAccount: { showingAddAccount = true }
        )
    }

    private var accountList: some View {
        List {
            ForEach(store.accounts) { account in
                let snapshot = store.snapshots[account.id]
                let failure = store.refreshFailures[account.id]
                Section {
                    if let failure {
                        AccountFailureView(
                            account: account,
                            failure: failure,
                            cachedAt: snapshot?.fetchedAt,
                            retry: { Task { await store.refresh(account) } },
                            relink: { relinkingAccount = account },
                            remove: { accountPendingRemoval = account }
                        )
                    }
                    if let snapshot {
                        UsageCard(snapshot: snapshot.filtered(using: store.settings(for: account)))
                    } else if failure == nil {
                        HStack { ProgressView(); Text("Loading usage…").foregroundStyle(.secondary) }
                    } else {
                        Label("No cached usage is available", systemImage: "tray")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    ProviderSectionHeader(
                        account: account,
                        plan: snapshot?.plan ?? account.plan,
                        failure: failure
                    )
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { accountPendingRemoval = account }
                }
            }
        }.listStyle(.insetGrouped)
    }
}

private struct FirstRunExperienceView: View {
    let isPreparingDemo: Bool
    let openDemo: () -> Void
    let connectAccount: () -> Void

    private let features = [
        FirstRunFeature(icon: "waveform.path.ecg.rectangle.fill", title: "Live countdowns",
                        detail: "Lock Screen and Dynamic Island"),
        FirstRunFeature(icon: "square.grid.2x2.fill", title: "Home Screen widgets",
                        detail: "Choose an account and quota"),
        FirstRunFeature(icon: "bell.badge.fill", title: "Reset alerts",
                        detail: "Scheduled and detected resets"),
        FirstRunFeature(icon: "chart.xyaxis.line", title: "Usage history",
                        detail: "24 hours, 7 days, and 30 days")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Coding-plan companion", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(Color.accentColor.opacity(0.11), in: .capsule)

                    Text("Know what resets next.")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .tracking(-0.7)
                    Text("See every quota, countdown, and trend in one calm, native dashboard.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                FirstRunDashboardPreview()

                VStack(spacing: 10) {
                    Button(action: connectAccount) {
                        Label("Connect an account", systemImage: "person.crop.circle.badge.plus")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 15))
                    .controlSize(.large)
                    .disabled(isPreparingDemo)
                    .accessibilityIdentifier("connect-account-button")

                    Button(action: openDemo) {
                        HStack {
                            if isPreparingDemo { ProgressView() }
                            Text(isPreparingDemo ? "Preparing demo…" : "Try the demo")
                                .fontWeight(.semibold)
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 15))
                    .controlSize(.large)
                    .disabled(isPreparingDemo)
                    .accessibilityIdentifier("open-demo-button")

                    Label("No sign-in or credentials needed for the demo", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Made for the moments between resets")
                        .font(.headline)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        ForEach(features) { feature in
                            FirstRunFeatureCard(feature: feature)
                        }
                    }
                }
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("first-run-screen")
    }
}

private struct FirstRunFeature: Identifiable {
    var id: String { title }
    let icon: String
    let title: String
    let detail: String
}

private struct FirstRunFeatureCard: View {
    let feature: FirstRunFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: feature.icon)
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.11), in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(feature.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color(.separator).opacity(0.22), lineWidth: 1)
        }
    }
}

private struct FirstRunDashboardPreview: View {
    @State private var nextReset = Date.now.addingTimeInterval(5_430)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "timer")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.gradient, in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Your AI Provider")
                        .font(.headline)
                    Text("Credential-free demo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Next reset")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(timerInterval: Date.now...nextReset, countsDown: true, showsHours: true)
                        .font(.headline)
                        .monospacedDigit()
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .lastTextBaseline, spacing: 5) {
                    Text("42%")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("remaining")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: 42, total: 100)
                    .tint(Color.accentColor)
                    .scaleEffect(x: 1, y: 1.35)
            }

            HStack(spacing: 0) {
                FirstRunMiniMetric(title: "5-hour limit", value: "42%", tint: .blue)
                Divider()
                    .frame(height: 34)
                    .padding(.horizontal, 16)
                FirstRunMiniMetric(title: "Weekly limit", value: "71%", tint: .purple)
            }
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color(.separator).opacity(0.28), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
        .accessibilityIdentifier("first-run-preview")
    }
}

private struct FirstRunMiniMetric: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                Text(title)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProviderSectionHeader: View {
    let account: MonitoredAccount
    let plan: String?
    let failure: AccountRefreshFailure?

    var body: some View {
        HStack(spacing: 7) {
            ProviderIcon(providerID: account.providerID, symbolName: account.customSymbolName)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.resolvedDisplayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(account.providerSectionTitle(plan: plan))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let failure {
                Image(systemName: failure.systemImageName)
                    .foregroundStyle(.red)
                    .accessibilityLabel(failure.title)
            }
            Spacer(minLength: 10)
            NavigationLink {
                AccountSettingsView(account: account)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.body)
                    .accessibilityLabel("\(account.providerDisplayName) account settings")
            }
            .buttonStyle(.plain)
        }
        .textCase(nil)
    }
}

private struct AccountFailureView: View {
    let account: MonitoredAccount
    let failure: AccountRefreshFailure
    let cachedAt: Date?
    let retry: () -> Void
    let relink: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(failure.title, systemImage: failure.systemImageName)
                .font(.headline)
                .foregroundStyle(.red)
            Text(failure.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let cachedAt {
                Text("Showing the latest saved usage from \(cachedAt, style: .relative).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if failure.requiresRelink,
                   !account.isRemoteOnly || account.providerID == .chatGPT {
                    Button(
                        account.isRemoteOnly ? "Update Worker sign-in" : "Sign in again",
                        systemImage: "arrow.triangle.2.circlepath",
                        action: relink
                    )
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Try again", systemImage: "arrow.clockwise", action: retry)
                        .buttonStyle(.borderedProminent)
                }
                Button("Remove", systemImage: "trash", role: .destructive, action: remove)
                    .buttonStyle(.bordered)
            }
            .controlSize(.regular)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

private enum AccountSettingsPage: String, CaseIterable {
    case account = "Account"
    case usage = "Usage"
}

private struct MissingQuotaHistoryOption: Identifiable {
    var id: String { metricID }
    var metricID: String
    var title: String
    var windowMinutes: Int?
}

struct AccountSettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let account: MonitoredAccount
    @State private var settings = AccountMonitorSettings()
    @State private var draftDisplayName = ""
    @State private var draftSymbolName: String?
    @State private var savedDisplayName = ""
    @State private var savedSymbolName: String?
    @State private var showingRelink = false
    @State private var confirmingRemoval = false
    @State private var confirmingServerMonitoring = false
    @State private var selectedPage = AccountSettingsPage.account
    @State private var historyRange = UsageHistoryRange.day

    private var currentAccount: MonitoredAccount {
        store.accounts.first(where: { $0.id == account.id }) ?? account
    }

    private var currentPlan: String? {
        let value = store.snapshots[account.id]?.plan ?? currentAccount.plan
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private var missingQuotaHistoryOptions: [MissingQuotaHistoryOption] {
        var options: [String: MissingQuotaHistoryOption] = [:]
        if let snapshot = store.snapshots[account.id] {
            for window in snapshot.usageWindows {
                options[window.metricID] = MissingQuotaHistoryOption(
                    metricID: window.metricID,
                    title: window.displayTitle,
                    windowMinutes: window.windowMinutes
                )
            }
        }
        for point in store.usageHistory where point.accountID == account.id {
            if options[point.metricID] == nil {
                options[point.metricID] = MissingQuotaHistoryOption(
                    metricID: point.metricID,
                    title: point.metricTitle,
                    windowMinutes: point.windowMinutes
                )
            }
        }
        return options.values.sorted {
            if ($0.windowMinutes ?? .max) != ($1.windowMinutes ?? .max) {
                return ($0.windowMinutes ?? .max) < ($1.windowMinutes ?? .max)
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Account page", selection: $selectedPage) {
                    ForEach(AccountSettingsPage.allCases, id: \.self) { page in
                        Text(page.rawValue).tag(page)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .listRowBackground(Color.clear)

            if selectedPage == .account {
            if let failure = store.refreshFailures[account.id] {
                Section {
                    Label(failure.title, systemImage: failure.systemImageName)
                        .foregroundStyle(.red)
                    Text(failure.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                AccountInformationRow(
                    title: "Name",
                    value: currentAccount.profileName ?? "Not provided",
                    isSensitive: currentAccount.profileName != nil
                )
                AccountInformationRow(title: "Email", value: currentAccount.email ?? "Not provided",
                                      isSensitive: currentAccount.email != nil)
                AccountInformationRow(
                    title: "Plan",
                    value: currentAccount.providerID.planDisplayName(currentPlan) ?? "Not provided"
                )
                AccountInformationRow(
                    title: "Plan expiry",
                    value: currentAccount.planExpiresAt?.formatted(date: .abbreviated, time: .shortened)
                        ?? "Not provided"
                )
                if let balance = store.snapshots[account.id]?.apiBalance {
                    AccountInformationRow(
                        title: balance.isUnlimited || balance.remaining != nil
                            ? "API balance" : "API spend this month",
                        value: balance.isUnlimited
                            ? "Unlimited"
                            : APIBalanceRow.formatted(
                                balance.remaining ?? balance.spent,
                                currencyCode: balance.currencyCode
                            )
                    )
                    if let accessExpiresAt = balance.accessExpiresAt {
                        AccountInformationRow(
                            title: "API key expiry",
                            value: accessExpiresAt.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                }
                if currentAccount.providerID == .claude, let trialExpiresAt = currentAccount.trialExpiresAt {
                    AccountInformationRow(
                        title: "Trial expiry",
                        value: trialExpiresAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }
            } header: {
                HStack(spacing: 7) {
                    ProviderIcon(providerID: currentAccount.providerID,
                                 symbolName: currentAccount.customSymbolName)
                        .frame(width: 15, height: 15)
                    Text(currentAccount.providerDisplayName)
                }
            } footer: {
                if currentAccount.isRemoteOnly {
                    Text("Account details and usage are downloaded from the Worker. Provider credentials never leave the Worker.")
                } else {
                    Text("Provider-reported details update during refresh. The account and its credentials sync through iCloud Keychain.")
                }
            }
            if !account.isDemo {
                if !(store.snapshots[account.id]?.usageWindows.isEmpty ?? false) {
                    Section {
                        Toggle("Notify About Detected Resets", isOn: $settings.notifyAboutResets)
                        Toggle("Notify at Scheduled Reset Time",
                               isOn: $settings.notifyAtScheduledReset)
                    } header: {
                        Text("Notifications")
                    } footer: {
                        Text("Scheduled-time and unexpected reset alerts also require their global settings.")
                    }
                }
                Section {
                    if currentAccount.isRemoteOnly {
                        Label("Remote Worker only", systemImage: "lock.icloud.fill")
                    } else {
                        Toggle("Monitor on Self-hosted Server",
                               isOn: serverMonitoringBinding)
                            .disabled(!currentAccount.providerID.supportsOffDeviceMonitoring
                                      || (!store.isServerMonitoringEnabled(for: currentAccount)
                                          && store.pushServerStatus != .registered))
                    }
                } header: {
                    Text("Self-hosted monitoring")
                } footer: {
                    if currentAccount.isRemoteOnly {
                        Text("Server-side refreshes and silent pushes are the only update source. Local provider refresh and sign-in are unavailable.")
                    } else if !currentAccount.providerID.supportsOffDeviceMonitoring {
                        Text("This provider’s credentials stay on this device and cannot be uploaded for off-device monitoring.")
                    } else if store.pushServerSettings.mode == .disabled {
                        Text("Configure a self-hosted server in Settings first.")
                    } else {
                        Text("Enabling this uploads the account credentials to your Worker after you confirm.")
                    }
                }
            }
            if !missingQuotaHistoryOptions.isEmpty {
                Section {
                    ForEach(missingQuotaHistoryOptions) { option in
                        Picker(option.title,
                               selection: missingQuotaHistoryBinding(option.metricID)) {
                            ForEach(MissingQuotaHistoryBehavior.allCases, id: \.self) { behavior in
                                Text(behavior.title).tag(behavior)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                } header: {
                    Text("When quota is missing")
                }
            }
            Section("Appearance") {
                TextField("Display name", text: $draftDisplayName)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit(saveAppearance)
                NavigationLink {
                    AccountIconPicker(selection: $draftSymbolName, providerID: account.providerID)
                } label: {
                    LabeledContent("Icon") {
                        ProviderIcon(providerID: account.providerID, symbolName: draftSymbolName)
                            .frame(width: 30, height: 30)
                    }
                }
                Button("Save appearance", systemImage: "checkmark") { saveAppearance() }
                    .disabled(!appearanceHasChanges)
                if draftDisplayName != currentAccount.displayName || draftSymbolName != nil {
                    Button("Use provider defaults", systemImage: "arrow.uturn.backward") {
                        draftDisplayName = currentAccount.displayName
                        draftSymbolName = nil
                        saveAppearance()
                    }
                }
            }
            if let snapshot = store.snapshots[account.id], !snapshot.usageWindows.isEmpty {
                ForEach(snapshot.usageWindows, id: \.metricID) { window in
                    Section {
                        Toggle("Show in Usage and widgets", isOn: metricBinding(window))
                        Toggle("Include in Live Activity", isOn: liveActivityMetricBinding(window))
                        if settings.showsInLiveActivity(window) {
                            LiveActivityRuleRows(rule: quotaRuleBinding(window), allowsPercentage: true)
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Text(window.displayTitle)
                            Spacer(minLength: 8)
                            LiveActivityPinButton(
                                title: window.displayTitle,
                                isPinned: settings.isPinnedInLiveActivity(window),
                                isEnabled: isMetricPinEligible(window)
                            ) {
                                toggleMetricPin(window)
                            }
                        }
                    } footer: {
                        metricLiveActivityFooter(window)
                    }
                }
            } else if store.snapshots[account.id]?.apiBalance == nil {
                Section("Quotas") {
                    Label("Refresh this account to configure its quotas", systemImage: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                }
            }
            if account.providerID.supportsBankedResets {
                Section {
                    Toggle("Show in Usage and widgets", isOn: $settings.showBankedResets)
                    Toggle("Include in Live Activity", isOn: bankedLiveActivityBinding)
                    if settings.showBankedResetsInLiveActivity {
                        LiveActivityRuleRows(rule: bankedLiveActivityRuleBinding,
                                             allowsPercentage: false)
                    }
                } header: {
                    HStack(spacing: 8) {
                        Text("Banked resets")
                        Spacer(minLength: 8)
                        LiveActivityPinButton(
                            title: "Banked resets",
                            isPinned: settings.isBankedResetPinnedInLiveActivity,
                            isEnabled: isBankedResetPinEligible
                        ) {
                            toggleBankedResetPin()
                        }
                    }
                } footer: {
                    bankedLiveActivityFooter
                }
            }
            Section("Connection") {
                AccountInformationRow(
                    title: "Added",
                    value: currentAccount.addedAt.formatted(date: .abbreviated, time: .shortened)
                )
                if !account.isDemo,
                   !currentAccount.isRemoteOnly || currentAccount.providerID == .chatGPT {
                    Button(
                        currentAccount.isRemoteOnly ? "Update Worker sign-in" : "Sign in again",
                        systemImage: "arrow.triangle.2.circlepath"
                    ) {
                        showingRelink = true
                    }
                }
                if currentAccount.isRemoteOnly {
                    AccountInformationRow(title: "Refresh source", value: "Self-hosted Worker")
                }
                Button(account.isDemo ? "Remove demo" : "Remove account", systemImage: "trash", role: .destructive) {
                    confirmingRemoval = true
                }
            }
            } else {
                AccountUsageHistorySections(account: currentAccount, range: $historyRange)
            }
        }
        .navigationTitle(currentAccount.resolvedDisplayName)
        .onAppear {
            settings = store.settings(for: account)
            draftDisplayName = currentAccount.resolvedDisplayName
            draftSymbolName = currentAccount.customSymbolName
            savedDisplayName = draftDisplayName
            savedSymbolName = draftSymbolName
        }
        .onDisappear(perform: saveAppearance)
        .onChange(of: selectedPage) { oldValue, _ in
            if oldValue == .account { saveAppearance() }
        }
        .onChange(of: settings) { _, newValue in store.setSettings(newValue, for: account) }
        .sheet(isPresented: $showingRelink) {
            AddAccountView(relinkingAccount: account)
        }
        .confirmationDialog(
            "Upload credentials to \(pushServerHost)?",
            isPresented: $confirmingServerMonitoring,
            titleVisibility: .visible
        ) {
            Button("Upload Credentials") { confirmServerMonitoring() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This sends \(credentialDisclosure) to \(pushServerHost). The Worker encrypts stored credentials, but whoever controls it can use them. Continue only if you control this Worker.")
        }
        .confirmationDialog(
            account.isDemo ? "Remove demo?" : "Remove account?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button(account.isDemo ? "Remove Demo" : "Remove Account", role: .destructive) {
                store.remove(account)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if account.isDemo {
                Text("This deletes the demo and its generated usage from this device.")
            } else if currentAccount.isRemoteOnly {
                Text("This removes the Worker subscription and this device’s cached usage, recorded history, and monitor settings. Provider credentials remain on the Worker.")
            } else {
                Text("This deletes the account and credentials from devices using your iCloud Keychain, plus this device’s cached usage, recorded history, and monitor settings.")
            }
        }
    }

    private var serverMonitoringBinding: Binding<Bool> {
        Binding {
            guard let serverURL = try? store.pushServerSettings.resolvedServerURL() else {
                return false
            }
            return settings.monitorOnSelfHostedServer
                && settings.selfHostedServerConsentURL == serverURL.absoluteString
        } set: { isEnabled in
            if isEnabled {
                confirmingServerMonitoring = true
            } else {
                settings.monitorOnSelfHostedServer = false
                settings.selfHostedServerConsentURL = nil
            }
        }
    }

    private var pushServerHost: String {
        (try? store.pushServerSettings.resolvedServerURL())?.host ?? "this Worker"
    }

    private var credentialDisclosure: String {
        switch currentAccount.providerID {
        case .chatGPT, .claude, .grok, .kimi:
            "this account’s access token, refresh token, and ID token when available"
        case .zai, .miniMax, .synthetic, .warp:
            "this account’s API key"
        case .openAIAPI, .anthropicAPI:
            "this account’s organization Admin API key and optional monthly budget"
        case .githubCopilot:
            "this account’s credentials"
        case .ollamaCloud:
            "this account’s browser session cookie"
        case .antigravity:
            "this account’s Google OAuth tokens"
        case .compatibleAPI:
            "this account’s endpoint URL and API key"
        case .newAPI:
            "this account’s endpoint URL and API key"
        }
    }

    private func confirmServerMonitoring() {
        guard currentAccount.providerID.supportsOffDeviceMonitoring,
              let serverURL = try? store.pushServerSettings.resolvedServerURL() else { return }
        settings.monitorOnSelfHostedServer = true
        settings.selfHostedServerConsentURL = serverURL.absoluteString
    }

    private func metricBinding(_ window: UsageWindow) -> Binding<Bool> {
        Binding {
            settings.shows(window)
        } set: { isShown in
            if isShown { settings.hiddenMetricIDs.remove(window.metricID) }
            else { settings.hiddenMetricIDs.insert(window.metricID) }
        }
    }

    private func liveActivityMetricBinding(_ window: UsageWindow) -> Binding<Bool> {
        Binding {
            settings.showsInLiveActivity(window)
        } set: { isShown in
            if isShown { settings.hiddenLiveActivityMetricIDs.remove(window.metricID) }
            else {
                settings.hiddenLiveActivityMetricIDs.insert(window.metricID)
                settings.pinnedLiveActivityMetricIDs.remove(window.metricID)
            }
        }
    }

    private func quotaRuleBinding(_ window: UsageWindow) -> Binding<LiveActivityQuotaRule> {
        Binding {
            settings.liveActivityRule(for: window)
        } set: { rule in
            settings.liveActivityQuotaRules[window.metricID] = rule
            if rule.trigger == .never {
                settings.pinnedLiveActivityMetricIDs.remove(window.metricID)
            }
        }
    }

    private var bankedLiveActivityBinding: Binding<Bool> {
        Binding {
            settings.showBankedResetsInLiveActivity
        } set: { isShown in
            settings.showBankedResetsInLiveActivity = isShown
            if !isShown {
                settings.pinnedLiveActivityMetricIDs.remove(AccountMonitorSettings.bankedResetMetricID)
            }
        }
    }

    private var bankedLiveActivityRuleBinding: Binding<LiveActivityQuotaRule> {
        Binding {
            settings.bankedResetLiveActivityRule
        } set: { rule in
            settings.bankedResetLiveActivityRule = rule
            if rule.trigger == .never {
                settings.pinnedLiveActivityMetricIDs.remove(AccountMonitorSettings.bankedResetMetricID)
            }
        }
    }

    private func isMetricPinEligible(_ window: UsageWindow) -> Bool {
        settings.showsInLiveActivity(window)
            && settings.liveActivityRule(for: window).trigger != .never
    }

    private var isBankedResetPinEligible: Bool {
        settings.showBankedResetsInLiveActivity
            && settings.bankedResetLiveActivityRule.trigger != .never
    }

    private func toggleMetricPin(_ window: UsageWindow) {
        guard isMetricPinEligible(window) else { return }
        if settings.pinnedLiveActivityMetricIDs.contains(window.metricID) {
            settings.pinnedLiveActivityMetricIDs.remove(window.metricID)
        } else {
            settings.pinnedLiveActivityMetricIDs.insert(window.metricID)
        }
    }

    private func toggleBankedResetPin() {
        guard isBankedResetPinEligible else { return }
        let metricID = AccountMonitorSettings.bankedResetMetricID
        if settings.pinnedLiveActivityMetricIDs.contains(metricID) {
            settings.pinnedLiveActivityMetricIDs.remove(metricID)
        } else {
            settings.pinnedLiveActivityMetricIDs.insert(metricID)
        }
    }

    @ViewBuilder
    private func metricLiveActivityFooter(_ window: UsageWindow) -> some View {
        if !settings.showsInLiveActivity(window) {
            Text("Include this quota in the Live Activity to make it eligible for starring.")
        } else if settings.liveActivityRule(for: window).trigger == .never {
            Text("Choose a trigger other than Never to make this quota eligible for starring.")
        }
    }

    @ViewBuilder
    private var bankedLiveActivityFooter: some View {
        if !settings.showBankedResetsInLiveActivity {
            Text("Uses the earliest future reset for this account. Include it in the Live Activity to make it eligible for starring.")
        } else if settings.bankedResetLiveActivityRule.trigger == .never {
            Text("Uses the earliest future reset for this account. Choose a trigger other than Never to make it eligible for starring.")
        }
    }

    private var appearanceHasChanges: Bool {
        draftDisplayName != savedDisplayName || draftSymbolName != savedSymbolName
    }

    private func missingQuotaHistoryBinding(_ metricID: String) -> Binding<MissingQuotaHistoryBehavior> {
        Binding {
            settings.missingQuotaHistoryBehavior(for: metricID)
        } set: { behavior in
            if behavior == .omit {
                settings.missingQuotaHistoryBehaviors.removeValue(forKey: metricID)
            } else {
                settings.missingQuotaHistoryBehaviors[metricID] = behavior
            }
        }
    }

    private func saveAppearance() {
        guard appearanceHasChanges else { return }
        store.setAppearance(displayName: draftDisplayName, symbolName: draftSymbolName, for: account)
        let normalized = draftDisplayName
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        draftDisplayName = normalized.isEmpty ? currentAccount.displayName : String(normalized.prefix(64))
        savedDisplayName = draftDisplayName
        savedSymbolName = draftSymbolName
    }
}

private enum UsageHistoryRange: String, CaseIterable, Identifiable {
    case day = "24 Hours"
    case week = "7 Days"
    case month = "30 Days"

    var id: Self { self }
    var duration: TimeInterval {
        switch self {
        case .day: 24 * 60 * 60
        case .week: 7 * 24 * 60 * 60
        case .month: 30 * 24 * 60 * 60
        }
    }
}

private struct UsageHistorySeries: Identifiable {
    var id: String { metricID }
    var metricID: String
    var title: String
    var points: [UsageHistoryPoint]

    var latest: UsageHistoryPoint { points[points.count - 1] }

    var includesServerSamples: Bool { points.contains { $0.source == .server } }

    var sourceSummary: String {
        let includesDeviceSamples = points.contains { $0.source != .server }
        return includesDeviceSamples ? "Device + self-hosted Worker" : "Self-hosted Worker"
    }

    var planSummary: String {
        var plans: [String] = []
        var previousKey: String?
        var hasPrevious = false
        for point in points {
            let key = canonicalPlan(point.plan)
            let display = point.providerID.planDisplayName(point.plan) ?? "Not recorded"
            if !hasPrevious || key != previousKey {
                plans.append(display)
            } else {
                plans[plans.count - 1] = display
            }
            previousKey = key
            hasPrevious = true
        }
        return plans.joined(separator: " → ")
    }

    var planChangePoints: [UsageHistoryPoint] {
        guard points.count > 1 else { return [] }
        var result: [UsageHistoryPoint] = []
        var previousPlan = canonicalPlan(points[0].plan)
        for point in points.dropFirst() {
            let plan = canonicalPlan(point.plan)
            if plan != previousPlan { result.append(point) }
            previousPlan = plan
        }
        return result
    }

    var chartPoints: [UsageHistoryLineChartPoint] {
        UsageHistoryLineSegmentation.chartPoints(from: points, seriesID: metricID)
    }

    private func canonicalPlan(_ plan: String?) -> String? {
        guard let normalized = plan?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else { return nil }
        return normalized.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

private struct AccountUsageHistorySections: View {
    @Environment(AppStore.self) private var store
    let account: MonitoredAccount
    @Binding var range: UsageHistoryRange

    var body: some View {
        let end = Date.now
        let start = end.addingTimeInterval(-range.duration)
        let allAccountPoints = store.usageHistory.filter { $0.accountID == account.id }
        let visiblePoints = allAccountPoints.filter { $0.recordedAt >= start && $0.recordedAt <= end }
        let series = makeSeries(from: visiblePoints)

        Section("History range") {
            Picker("History range", selection: $range) {
                ForEach(UsageHistoryRange.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        if let error = store.historyStorageError {
            Section {
                Label("History couldn’t be saved", systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.red)
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        if series.isEmpty {
            Section {
                ContentUnavailableView {
                    Label(emptyTitle(hasAnyHistory: !allAccountPoints.isEmpty),
                          systemImage: "chart.xyaxis.line")
                } description: {
                    Text(emptyMessage(hasAnyHistory: !allAccountPoints.isEmpty))
                }
            }
        } else {
            ForEach(series) { item in
                Section {
                    LabeledContent("Plan") {
                        Text(item.planSummary)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.caption)
                    if item.includesServerSamples {
                        LabeledContent("Source", value: item.sourceSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    UsageHistoryChart(series: item, range: range, start: start, end: end)
                    HStack(alignment: .firstTextBaseline) {
                        Text("Last recorded")
                        Spacer(minLength: 12)
                        Text(item.latest.recordedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                } header: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.title)
                        Spacer(minLength: 8)
                        Text("\(Int(item.latest.remainingPercent.rounded()))% left")
                            .monospacedDigit()
                    }
                } footer: {
                    if item.latest.kind == .weekly || item.latest.windowMinutes == 10_080 {
                        Text("At that refresh, \(CountdownDisplay.string(until: item.latest.resetsAt, from: item.latest.recordedAt)) remained in the weekly period.")
                    }
                }
            }
        }

    }

    private func makeSeries(from points: [UsageHistoryPoint]) -> [UsageHistorySeries] {
        Dictionary(grouping: points, by: \.metricID).map { metricID, values in
            let sorted = values.sorted { $0.recordedAt < $1.recordedAt }
            return UsageHistorySeries(
                metricID: metricID,
                title: sorted.last?.metricTitle ?? "Usage limit",
                points: sorted
            )
        }.sorted { lhs, rhs in
            let left = lhs.latest
            let right = rhs.latest
            if displayOrder(left) != displayOrder(right) {
                return displayOrder(left) < displayOrder(right)
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func displayOrder(_ point: UsageHistoryPoint) -> Int {
        if point.kind == .additional { return 2 }
        return switch point.windowMinutes {
        case 300: 0
        case 10_080: 1
        default: 2
        }
    }

    private func emptyTitle(hasAnyHistory: Bool) -> String {
        hasAnyHistory ? "No samples in the last \(range.rawValue.lowercased())" : "No usage history yet"
    }

    private func emptyMessage(hasAnyHistory: Bool) -> String {
        if hasAnyHistory, range != .month {
            return "Choose a longer range to see older samples, or refresh this account to record a new one."
        }
        return "A point is added after the next successful account refresh."
    }

}

private struct UsageHistoryChart: View {
    let series: UsageHistorySeries
    let range: UsageHistoryRange
    let start: Date
    let end: Date

    private var color: Color {
        switch series.latest.windowMinutes {
        case 300: .blue
        case 10_080: .purple
        default: .indigo
        }
    }

    var body: some View {
        Chart {
            ForEach(series.chartPoints) { chartPoint in
                let point = chartPoint.point
                LineMark(
                    x: .value("Refresh", point.recordedAt),
                    y: .value("Percent remaining", point.remainingPercent),
                    series: .value("Plan period", chartPoint.segmentID)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(
                    lineWidth: 2,
                    dash: chartPoint.isGapConnector ? [6, 4] : []
                ))
                .accessibilityLabel(point.recordedAt.formatted(date: .abbreviated, time: .shortened))
                .accessibilityValue("\(Int(point.remainingPercent.rounded())) percent remaining")
            }
            ForEach(series.planChangePoints) { point in
                RuleMark(x: .value("Plan changed", point.recordedAt))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let percentage = value.as(Int.self) { Text("\(percentage)%") }
                }
            }
        }
        .chartXAxis {
            if range == .day {
                AxisMarks(values: .stride(by: .hour, count: 6)) {
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.hour())
                }
            } else if range == .week {
                AxisMarks(values: .stride(by: .day, count: 1)) {
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated).day())
                }
            } else {
                AxisMarks(values: .stride(by: .day, count: 5)) {
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 190)
        .accessibilityLabel("\(series.title) remaining percentage history")
        .accessibilityValue("\(series.points.count) samples. Latest value \(Int(series.latest.remainingPercent.rounded())) percent remaining. Plan \(series.latest.providerID.planDisplayName(series.latest.plan) ?? "not recorded"). \(series.planChangePoints.count) plan changes.")
    }
}

private struct LiveActivityPinButton: View {
    let title: String
    let isPinned: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPinned ? "star.fill" : "star")
                .font(.body.weight(.semibold))
                .foregroundStyle(isEnabled ? Color.yellow : Color.secondary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(isPinned
                            ? "Unpin \(title) from Live Activity"
                            : "Pin \(title) in Live Activity")
        .accessibilityValue(isPinned ? "Pinned" : "Not pinned")
        .accessibilityHint(isEnabled
                           ? "Pinned metrics appear first when eligible. Multiple pinned metrics are ordered by nearest reset."
                           : "Include this metric and choose a trigger other than Never to enable pinning.")
    }
}

private struct AccountInformationRow: View {
    let title: String
    let value: String
    var isSensitive = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                Spacer(minLength: 12)
                valueText
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                valueText
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var valueText: some View {
        Text(value)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
            .privacySensitive(isSensitive)
    }
}

private struct LiveActivityRuleRows: View {
    @Binding var rule: LiveActivityQuotaRule
    let allowsPercentage: Bool

    private var triggers: [LiveActivityTrigger] {
        allowsPercentage ? LiveActivityTrigger.allCases : [.remainingHours, .never]
    }

    var body: some View {
        Picker("Include in Live Activity when", selection: $rule.trigger) {
            ForEach(triggers, id: \.self) { trigger in
                Text(trigger.title).tag(trigger)
            }
        }
        switch rule.trigger {
        case .remainingPercent:
            Stepper("At \(rule.remainingPercent)% remaining", value: $rule.remainingPercent,
                    in: 0...100, step: 5)
        case .remainingHours:
            Picker("Reset is within", selection: $rule.remainingHours) {
                Text("30 minutes").tag(0.5)
                Text("1 hour").tag(1.0)
                Text("2 hours").tag(2.0)
                Text("4 hours").tag(4.0)
                Text("8 hours").tag(8.0)
                Text("12 hours").tag(12.0)
                Text("24 hours").tag(24.0)
                Text("2 days").tag(48.0)
                Text("1 week").tag(168.0)
            }
        case .exhausted, .never:
            EmptyView()
        }
    }
}

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    let onStageWorkerLink: (WorkerLinkDraft) -> Void
    @State private var settings = GlobalLiveActivitySettings()
    @State private var notificationSettings = GlobalNotificationSettings()
    @State private var refreshSettings = GlobalRefreshSettings()
    @State private var pushServerSettings = PushServerSettings()
    @State private var pushServerAccessKey = ""
    @State private var showingWorkerLinkEntry = false
    @State private var showingRemoteWorkerAccounts = false
    @State private var stagedLinkFromEntry: WorkerLinkDraft?
    @State private var pushServerActionError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Notifications") {
                    Toggle("Notify About Unexpected Resets",
                           isOn: $notificationSettings.notifyAboutUnexpectedResets)
                    Toggle("Notify at Scheduled Reset Time",
                           isOn: $notificationSettings.notifyAtScheduledReset)
                }
                Section("Refresh") {
                    Picker("In app", selection: $refreshSettings.inAppInterval) {
                        ForEach(RefreshInterval.inAppOptions, id: \.self) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                    Picker("Background & Live Activity",
                           selection: $refreshSettings.backgroundInterval) {
                        ForEach(RefreshInterval.backgroundOptions, id: \.self) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                }
                Section("Self-hosted Worker") {
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
                    }
                    Button(pushServerActionTitle, action: applyPushServerAction)
                    .disabled(!canApplyPushServerSettings)

                    if pushServerSettings.mode != .disabled
                        || store.pushServerSettings.mode != .disabled
                        || store.pushServerStatus != .disabled {
                        LabeledContent("Status", value: store.pushServerStatus.title)
                        if case .failed = store.pushServerStatus {
                            Button("Retry") { store.retryPushRegistration() }
                        }
                        if store.pushServerStatus == .registered {
                            Button("Add Accounts from Worker",
                                   systemImage: "icloud.and.arrow.down") {
                                showingRemoteWorkerAccounts = true
                            }
                            Button("Send Test Refresh") {
                                Task { await store.requestTestPushRefresh() }
                            }
                        }
                    }
                }
                Section {
                    Picker("Behavior", selection: $settings.mode) {
                        ForEach(LiveActivityMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Show Live Activity")
                } footer: {
                    Text(modeExplanation)
                }
                Section("Content") {
                    Toggle("Show percentage remaining", isOn: $settings.showRemainingPercentage)
                    Toggle("Show banked resets", isOn: $settings.showBankedResets)
                }
                Section("GitHub") {
                    Link(destination: AppLinks.sourceCode) {
                        Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: AppLinks.issues) {
                        Label("Report an Issue", systemImage: "exclamationmark.bubble")
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                settings = store.liveActivitySettings
                notificationSettings = store.notificationSettings
                refreshSettings = store.refreshSettings
                pushServerSettings = store.pushServerSettings
            }
            .onChange(of: store.pushServerSettings) { _, newValue in
                pushServerSettings = newValue
            }
            .onChange(of: settings) { _, newValue in store.setLiveActivitySettings(newValue) }
            .onChange(of: notificationSettings) { _, newValue in
                store.setNotificationSettings(newValue)
            }
            .onChange(of: refreshSettings) { _, newValue in
                store.setRefreshSettings(newValue)
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
                Text(pushServerActionError ?? "The Worker settings could not be updated.")
            }
        }
    }

    private var modeExplanation: String {
        switch settings.mode {
        case .automatic:
            "Starts after a refresh finds that any included quota matches its account rule."
        case .always:
            "Shows whenever at least one included quota or banked reset is available."
        case .disabled:
            "Ends the current Live Activity and prevents When Reset from starting another one."
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
        }
        return enteredKey.count >= 32
    }

    private var pushServerActionTitle: String {
        if pushServerSettings.mode == .disabled { return "Turn Off" }
        let enteredKey = pushServerAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let proposedURL = try? PushServerConfiguration.normalizedServerOrigin(
            pushServerSettings.customServerURL
        )
        let currentURL = try? store.pushServerSettings.resolvedServerURL()
        return proposedURL == currentURL && enteredKey.isEmpty ? "Apply Interval" : "Review & Link"
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
                store.updatePushServerMonitoringInterval(
                    pushServerSettings.serverMonitoringInterval
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

private struct WorkerLinkEntryView: View {
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

private struct WorkerLinkReviewView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let draft: WorkerLinkDraft
    @State private var metadata: WorkerLinkMetadata?
    @State private var validationError: String?
    @State private var selectedAccountIDs: Set<UUID> = []
    @State private var interval = RefreshInterval.fiveMinutes
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
                    }

                    Section("Data sent after confirmation") {
                        Label("This device’s APNs token for silent refresh hints",
                              systemImage: "bell.badge")
                        Label("Provider and workspace identifiers, plan, and quota descriptors for selected accounts",
                              systemImage: "list.bullet.rectangle")
                        Label("Selected quota history is retained by the Worker for 35 days",
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
            return "When Reset will send this device’s APNs token to \(host). No provider credentials will be uploaded."
        }
        return "When Reset will send this device’s APNs token and the selected access tokens, refresh tokens, ID tokens, or API keys to \(host)."
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
        case .zai, .miniMax, .synthetic, .warp:
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
    @State private var accounts: [RemoteWorkerAccountCandidate] = []
    @State private var selectedIDs: Set<String> = []
    @State private var isLoading = true
    @State private var isImporting = false
    @State private var errorMessage: String?

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
            .navigationTitle("Add from Worker")
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
            .alert("Couldn’t Add Accounts", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "The Worker accounts could not be imported.")
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
        errorMessage = nil
        do {
            accounts = try await store.availableRemoteWorkerAccounts()
            selectedIDs.formIntersection(accounts.map(\.id))
        } catch {
            accounts = []
            errorMessage = error.localizedDescription
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
                errorMessage = error.localizedDescription
                isImporting = false
                await loadAccounts()
            }
        }
    }
}

private struct AccountIconPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String?
    let providerID: ProviderID
    @State private var searchText = ""
    @State private var symbols: [SFSymbolCatalog.Symbol] = []

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 12)]

    private var filteredSymbols: [SFSymbolCatalog.Symbol] {
        let query = searchText
            .replacingOccurrences(of: ".", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return symbols }
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        return symbols.filter { symbol in
            let searchable = symbol.name.replacingOccurrences(of: ".", with: " ").lowercased()
            return terms.allSatisfy { searchable.contains($0) }
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                Button {
                    selection = nil
                    dismiss()
                } label: {
                    VStack(spacing: 7) {
                        ProviderIcon(providerID: providerID)
                            .frame(width: 30, height: 30)
                        Text("Provider default")
                            .font(.caption2)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 70)
                    .padding(6)
                    .background(selection == nil ? Color.accentColor.opacity(0.16) : .clear,
                                in: .rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                ForEach(filteredSymbols) { symbol in
                    SymbolPickerTile(name: symbol.name, selected: selection == symbol.name) {
                        selection = symbol.name
                        dismiss()
                    }
                }
            }
            .padding()
        }
        .overlay {
            if symbols.isEmpty { ProgressView("Loading symbols…") }
        }
        .navigationTitle("Account icon")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search all symbols")
        .task { symbols = SFSymbolCatalog.load() }
    }
}

private struct SymbolPickerTile: View {
    let name: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let available = UIImage(systemName: name) != nil
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: available ? name : "questionmark.square.dashed")
                    .font(.title2)
                    .frame(height: 30)
                Text(name.replacingOccurrences(of: ".", with: " "))
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 70)
            .padding(6)
            .background(selected ? Color.accentColor.opacity(0.16) : .clear,
                        in: .rect(cornerRadius: 12))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityLabel(name.replacingOccurrences(of: ".", with: " "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private enum SFSymbolCatalog {
    struct Catalog: Decodable {
        let symbols: [Symbol]
    }

    struct Symbol: Decodable, Identifiable {
        let name: String
        let year: Int
        var id: String { name }
    }

    static func load() -> [Symbol] {
        guard let data = NSDataAsset(name: "SFSymbolNames")?.data,
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            return []
        }
        let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let maximumYear = switch osMajor {
        case 26...: 2025
        case 18...: 2024
        default: 2023
        }
        return catalog.symbols.filter { $0.year <= maximumYear }
    }
}

struct UsageCard: View {
    let snapshot: UsageSnapshot

    var body: some View {
        VStack(spacing: 16) {
            if let balance = snapshot.apiBalance {
                APIBalanceRow(balance: balance)
            }
            if snapshot.availableResetCount > 0 || !snapshot.availableResetCredits.isEmpty {
                BankedResetBar(snapshot: snapshot)
            }
            if snapshot.usageWindows.isEmpty, snapshot.apiBalance == nil {
                Label("No resettable limits reported", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(snapshot.usageWindows.enumerated()), id: \.offset) { _, window in
                    LimitRow(window: window)
                }
            }
            HStack { Text("Updated"); Spacer(); Text(snapshot.fetchedAt, style: .relative) }.font(.caption2).foregroundStyle(.tertiary)
        }.padding(.vertical, 6)
    }
}

struct APIBalanceRow: View {
    let balance: APIBalance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(balance.title)
                    .font(.headline)
                Spacer(minLength: 8)
                if let periodEnd = balance.periodEnd {
                    Text("through \(periodEnd, format: .dateTime.month(.abbreviated).day())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(primaryValue)
                    .font(.title2.bold().monospacedDigit())
                Text(primaryLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if let fraction = balance.fractionRemaining {
                ProgressView(value: fraction, total: 1)
                    .tint(fraction <= 0.1 ? .red : .green)
            }

            HStack(spacing: 8) {
                Text("Spent \(Self.formatted(balance.spent, currencyCode: balance.currencyCode))")
                if let limit = balance.limit, !balance.isUnlimited {
                    Spacer()
                    Text("Budget \(Self.formatted(limit, currencyCode: balance.currencyCode))")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            if let accessExpiresAt = balance.accessExpiresAt {
                HStack {
                    Text("Key expires")
                    Spacer()
                    Text(accessExpiresAt, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var primaryValue: String {
        if balance.isUnlimited { return "Unlimited" }
        return Self.formatted(balance.remaining ?? balance.spent, currencyCode: balance.currencyCode)
    }

    private var primaryLabel: String {
        if balance.isUnlimited { return "allowance" }
        return balance.remaining == nil ? "spent" : "left"
    }

    static func formatted(_ amount: Double, currencyCode: String) -> String {
        amount.formatted(
            .currency(code: currencyCode.uppercased())
                .precision(.fractionLength(2))
        )
    }
}

private struct BankedResetBar: View {
    let snapshot: UsageSnapshot

    private var credits: [ResetCredit] { snapshot.availableResetCredits }
    private var count: Int { max(snapshot.availableResetCount, credits.count) }

    @ViewBuilder
    var body: some View {
        if let nearest = snapshot.nextBankedResetCredit(), let expiry = nearest.expiresAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(at: context.date, nearest: nearest, expiry: expiry)
            }
        } else {
            content(at: .now, nearest: nil, expiry: nil)
        }
    }

    private func content(at date: Date, nearest: ResetCredit?, expiry: Date?) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("\(count) banked reset\(count == 1 ? "" : "s")")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                if let expiry {
                    Text(CountdownDisplay.string(until: expiry, from: date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let nearest, let remaining = nearest.remainingLifetimeFraction(at: date) {
                ProgressView(value: remaining, total: 1).tint(.teal)
            }
            ForEach(Array(credits.enumerated()), id: \.element.id) { index, credit in
                HStack {
                    Text("Reset #\(index + 1)")
                    Spacer()
                    if let expiry = credit.expiresAt {
                        Text(expiry, format: .dateTime.year().month(.abbreviated).day().hour().minute().second())
                            .multilineTextAlignment(.trailing)
                    } else {
                        Text("Expiry unavailable")
                    }
                }
                .foregroundStyle(.secondary)
            }
            if count > credits.count {
                ForEach(credits.count..<count, id: \.self) { index in
                    HStack { Text("Reset #\(index + 1)"); Spacer(); Text("Expiry unavailable") }
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
    }
}

struct LimitRow: View {
    let window: UsageWindow

    private var color: Color {
        switch window.windowMinutes {
        case 300: .blue
        case 10_080: .purple
        default: .indigo
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(window.displayTitle).font(.headline).lineLimit(1)
                    Spacer()
                    Text(CountdownDisplay.usageString(until: window.resetsAt, from: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(1)
                }
                HStack(spacing: 10) {
                    ProgressView(value: window.remainingPercent, total: 100).tint(color)
                    Text("\(Int(window.remainingPercent.rounded()))% left")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
#endif
