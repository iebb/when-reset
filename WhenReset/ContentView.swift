import Charts
import SwiftUI
import UIKit

struct ContentView: View {
    var body: some View {
        TabView {
            UsageTabView()
                .tabItem { Label("Usage", systemImage: "chart.bar.fill") }
            GlobalLiveActivitySettingsView()
                .tabItem { Label("Activity", systemImage: "livephoto") }
        }
    }
}

private struct UsageTabView: View {
    @Environment(AppStore.self) private var store
    @State private var showingAddAccount = false
    @State private var relinkingAccount: MonitoredAccount?
    @State private var accountPendingRemoval: MonitoredAccount?

    var body: some View {
        NavigationStack {
            Group {
                if store.accounts.isEmpty { emptyState }
                else { accountList }
            }
            .navigationTitle("Usage")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.accounts.isEmpty {
                        Button { Task { await store.refreshAll() } } label: {
                            if store.isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                        }.disabled(store.isRefreshing)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Add", systemImage: "plus") { showingAddAccount = true } }
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
                    Button("Remove \(account.providerID.displayName) account", role: .destructive) {
                        store.remove(account)
                        accountPendingRemoval = nil
                    }
                }
                Button("Cancel", role: .cancel) { accountPendingRemoval = nil }
            } message: {
                Text("This deletes its saved credentials, cached usage, recorded history, and monitor settings from this device.")
            }
            .alert("Couldn’t update", isPresented: .init(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(store.errorMessage ?? "Unknown error") }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Monitor your limits", systemImage: "gauge.with.dots.needle.33percent")
        } description: {
            Text("Link a provider account to see usage windows and reset countdowns.")
        } actions: {
            Button {
                showingAddAccount = true
            } label: {
                Text("Link account")
                    .font(.headline)
                    .frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
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
                Text(account.providerID.sectionTitle(plan: plan))
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
                    .accessibilityLabel("\(account.providerID.displayName) account settings")
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
                if failure.requiresRelink {
                    Button("Sign in again", systemImage: "arrow.triangle.2.circlepath", action: relink)
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
                if currentAccount.providerID == .claude, let trialExpiresAt = currentAccount.trialExpiresAt {
                    AccountInformationRow(
                        title: "Trial expiry",
                        value: trialExpiresAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }
            } header: {
                HStack(spacing: 7) {
                    ProviderIcon(providerID: currentAccount.providerID)
                        .frame(width: 15, height: 15)
                    Text(currentAccount.providerID.displayName)
                }
            } footer: {
                Text("Provider-reported account details, updated during account refresh when available.")
            }
            if !account.isDemo {
                Section {
                    Toggle("Notify Me About Resets", isOn: $settings.notifyAboutResets)
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Unexpected reset alerts also require the global notification setting.")
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
            if let snapshot = store.snapshots[account.id] {
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
            } else {
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
                if !account.isDemo {
                    Button("Sign in again", systemImage: "arrow.triangle.2.circlepath") {
                        showingRelink = true
                    }
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
            Text(account.isDemo
                 ? "This deletes the demo and its generated usage from this device."
                 : "This deletes its saved credentials, cached usage, recorded history, and monitor settings from this device.")
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

    var id: Self { self }
    var duration: TimeInterval {
        switch self {
        case .day: 24 * 60 * 60
        case .week: 7 * 24 * 60 * 60
        }
    }
}

private struct UsageHistorySeries: Identifiable {
    var id: String { metricID }
    var metricID: String
    var title: String
    var points: [UsageHistoryPoint]

    var latest: UsageHistoryPoint { points[points.count - 1] }

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

    var chartPoints: [UsageHistoryChartPoint] {
        var segment = 0
        var previousPlan: String?
        return points.enumerated().map { index, point in
            let plan = canonicalPlan(point.plan)
            if index > 0, plan != previousPlan { segment += 1 }
            previousPlan = plan
            return UsageHistoryChartPoint(point: point, segmentID: "\(metricID):\(segment)")
        }
    }

    var singletonChartPoints: [UsageHistoryChartPoint] {
        Dictionary(grouping: chartPoints, by: \.segmentID).values.compactMap { segment in
            segment.count == 1 ? segment[0] : nil
        }
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

private struct UsageHistoryChartPoint: Identifiable {
    var id: String { point.id }
    var point: UsageHistoryPoint
    var segmentID: String
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
        if hasAnyHistory, range == .day {
            return "Choose 7 Days to see older samples, or refresh this account to record a new one."
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
                .interpolationMethod(.stepEnd)
                .foregroundStyle(color)
                .accessibilityLabel(point.recordedAt.formatted(date: .abbreviated, time: .shortened))
                .accessibilityValue("\(Int(point.remainingPercent.rounded())) percent remaining")
            }
            ForEach(series.singletonChartPoints) { chartPoint in
                let point = chartPoint.point
                PointMark(
                    x: .value("Refresh", point.recordedAt),
                    y: .value("Percent remaining", point.remainingPercent)
                )
                .foregroundStyle(color)
                .symbolSize(70)
            }
            ForEach(series.planChangePoints) { point in
                RuleMark(x: .value("Plan changed", point.recordedAt))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
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
            } else {
                AxisMarks(values: .stride(by: .day, count: 1)) {
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated).day())
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

struct GlobalLiveActivitySettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var settings = GlobalLiveActivitySettings()
    @State private var notificationSettings = GlobalNotificationSettings()

    var body: some View {
        NavigationStack {
            Form {
                Section("Notifications") {
                    Toggle("Notify About Unexpected Resets",
                           isOn: $notificationSettings.notifyAboutUnexpectedResets)
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
            }
            .navigationTitle("Live Activity")
            .onAppear {
                settings = store.liveActivitySettings
                notificationSettings = store.notificationSettings
            }
            .onChange(of: settings) { _, newValue in store.setLiveActivitySettings(newValue) }
            .onChange(of: notificationSettings) { _, newValue in
                store.setNotificationSettings(newValue)
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
            if snapshot.availableResetCount > 0 || !snapshot.availableResetCredits.isEmpty {
                BankedResetBar(snapshot: snapshot)
            }
            if snapshot.usageWindows.isEmpty {
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
