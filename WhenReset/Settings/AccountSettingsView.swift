#if os(iOS)
import Charts
import SwiftUI
import UIKit

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
    @State private var confirmingWorkerCredentialAuthority = false
    @State private var isUploadingLocalHistory = false
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
                    if failure == AccountRefreshFailure(
                        workerSessionStatus: .expired,
                        checkedAt: failure.failedAt
                    ) {
                        Label("Worker sign-in expired", systemImage: failure.systemImageName)
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text("Cloud quota refresh has stopped for this account. Reconnect the provider sign-in to resume Worker updates.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Worker reported this \(failure.failedAt, style: .relative).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Reconnect now", systemImage: "arrow.triangle.2.circlepath") {
                            showingRelink = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .accessibilityHint("Opens the sign-in flow to resume Worker quota refresh")
                    } else {
                        let isWorkerSessionCheckFailure = failure == AccountRefreshFailure(
                            workerSessionStatus: .error,
                            checkedAt: failure.failedAt
                        )
                        Label(
                            isWorkerSessionCheckFailure
                                ? "Worker session check failed"
                                : failure.title,
                            systemImage: failure.systemImageName
                        )
                            .foregroundStyle(failure.requiresRelink ? .red : .orange)
                        Text(failure.message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
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
                        title: balance.kind == .wallet
                            ? balance.title
                            : (balance.isUnlimited || balance.remaining != nil
                               ? "API balance" : "API spend this month"),
                        value: balance.isUnlimited
                            ? "Unlimited"
                            : APIBalanceRow.formattedValue(balance.remaining ?? balance.spent,
                                                           balance: balance)
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
                Section {
                    Toggle("Notify About Detected Resets", isOn: $settings.notifyAboutResets)
                    Toggle("Notify at Scheduled Reset Time",
                           isOn: $settings.notifyAtScheduledReset)
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Detected quota resets and new banked resets use this switch. Unexpected or early resets, and alerts at the scheduled time, also need the matching switch in Settings → Notifications.")
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
                        if store.isServerMonitoringEnabled(for: currentAccount) {
                            Button {
                                uploadLocalHistory()
                            } label: {
                                if isUploadingLocalHistory {
                                    Label("Uploading Local History…", systemImage: "icloud.and.arrow.up")
                                } else {
                                    Label("Upload Local History", systemImage: "icloud.and.arrow.up")
                                }
                            }
                            .disabled(isUploadingLocalHistory)
                            if currentAccount.usesWorkerAsCredentialAuthority {
                                Label("Worker is the credential authority",
                                      systemImage: "checkmark.icloud.fill")
                                    .foregroundStyle(.secondary)
                            } else if store.hasLocalCredentials(for: currentAccount) {
                                Button("Remove Synced Credentials", systemImage: "key.slash") {
                                    confirmingWorkerCredentialAuthority = true
                                }
                            }
                        }
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
                        Text("Enabling this uploads credentials and local history. You can then remove the synchronized Keychain copy and keep the Worker authoritative.")
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
        .blinkySettingsCanvas()
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
        .onChange(of: settings) { _, newValue in
            guard store.settings(for: account) != newValue else { return }
            store.setSettings(newValue, for: account)
        }
        .onChange(of: store.monitorSettings[account.id] ?? AccountMonitorSettings()) { _, newValue in
            if settings != newValue { settings = newValue }
        }
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
            "Keep credentials only on \(pushServerHost)?",
            isPresented: $confirmingWorkerCredentialAuthority,
            titleVisibility: .visible
        ) {
            Button("Remove Synced Credentials", role: .destructive) {
                store.setWorkerAsCredentialAuthority(true, for: currentAccount)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the provider credential from iCloud Keychain on synced devices. The encrypted Worker copy remains authoritative. Signing in again replaces the Worker copy and is removed from Keychain after the verified upload.")
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
        case .zai, .zhipu, .miniMax, .synthetic, .warp, .openRouter, .fireworksAI,
             .deepSeek, .poe:
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

    private func uploadLocalHistory() {
        guard !isUploadingLocalHistory else { return }
        isUploadingLocalHistory = true
        Task {
            _ = await store.uploadLocalHistoryToWorker(for: currentAccount)
            isUploadingLocalHistory = false
        }
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
#endif
