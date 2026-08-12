#if os(macOS)
import AppKit
import Charts
import SwiftUI

struct MacContentView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: UUID?
    @State private var showingAddAccount = false
    @State private var showingRemoteWorkerAccounts = false
    @State private var pendingWorkerLink: WorkerLinkDraft?
    @State private var workerLinkError: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Accounts") {
                    ForEach(store.accounts) { account in
                        HStack(spacing: 10) {
                            ProviderIcon(providerID: account.providerID,
                                         symbolName: account.customSymbolName)
                                .frame(width: 26, height: 26)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.resolvedDisplayName).lineLimit(1)
                                Text(account.providerDisplayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "\(account.resolvedDisplayName), \(account.providerDisplayName)"
                        )
                        .tag(account.id)
                    }
                }
            }
            .navigationTitle("When Reset")
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 18) {
                    Button {
                        showingAddAccount = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityLabel("Add account")
                    .help("Add account")
                    if store.pushServerStatus == .registered {
                        Button {
                            showingRemoteWorkerAccounts = true
                        } label: {
                            Label("Worker", systemImage: "icloud.and.arrow.down")
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .accessibilityLabel("Add accounts from Cloudflare Worker")
                        .help("Add accounts from Cloudflare Worker")
                    }
                    Spacer()
                    SettingsLink {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                    .help("Settings")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
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
        .sheet(isPresented: $showingRemoteWorkerAccounts) {
            MacRemoteWorkerAccountsView()
                .environment(store)
        }
        .sheet(item: $pendingWorkerLink) { draft in
            MacWorkerLinkReviewView(draft: draft)
                .environment(store)
        }
        .alert("When Reset", isPresented: errorIsPresented) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "Something went wrong.")
        }
        .alert("Couldn’t read Worker link", isPresented: Binding(
            get: { workerLinkError != nil },
            set: { if !$0 { workerLinkError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workerLinkError ?? "The Worker link is invalid.")
        }
        .onOpenURL(perform: stageWorkerLink)
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

    private func stageWorkerLink(_ url: URL) {
        do {
            pendingWorkerLink = .pairing(try WorkerLinkPayload.parse(url))
        } catch {
            workerLinkError = error.localizedDescription
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
                Button {
                    isAddingDemo = true
                    Task {
                        defer { isAddingDemo = false }
                        _ = await store.addDemoAccount()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isAddingDemo { ProgressView().controlSize(.small) }
                        Text(isAddingDemo ? "Adding demo…" : "Try demo")
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
    @State private var isRefreshingAccount = false

    private var currentAccount: MonitoredAccount {
        store.accounts.first { $0.id == account.id } ?? account
    }

    private var snapshot: UsageSnapshot? { store.snapshots[account.id] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                accountHeader

                if let failure = store.refreshFailures[account.id] {
                    HStack(spacing: 12) {
                        Label(failure.message, systemImage: failure.systemImageName)
                            .foregroundStyle(failure.requiresRelink ? .red : .orange)
                        Spacer()
                        if failure.requiresRelink,
                           !currentAccount.isDemo,
                           !currentAccount.isRemoteOnly || currentAccount.providerID == .chatGPT {
                            Button(
                                currentAccount.isRemoteOnly
                                    ? "Update Worker sign-in" : "Reconnect"
                            ) { showingRelink = true }
                        }
                    }
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

                MacUsageHistorySection(account: currentAccount)
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
                    refreshAccount()
                } label: {
                    if isRefreshingAccount {
                        Label("Refreshing", systemImage: "arrow.clockwise")
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.isRefreshing || isRefreshingAccount || currentAccount.isDemo)
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
            Text(removalMessage)
        }
    }

    private var accountHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            ProviderIcon(providerID: currentAccount.providerID,
                         symbolName: currentAccount.customSymbolName)
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
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
            if store.isRefreshing || isRefreshingAccount {
                ProgressView("Refreshing")
                    .controlSize(.small)
                    .labelStyle(.iconOnly)
            }
        }
    }

    @ViewBuilder
    private func usageSection(_ snapshot: UsageSnapshot) -> some View {
        let settings = store.settings(for: currentAccount)
        let visibleWindows = MacUsagePresentation.visibleWindows(in: snapshot, settings: settings)
        let availableResetCount = MacUsagePresentation.availableResetCount(in: snapshot)
        let showsBankedResets = settings.showBankedResets && availableResetCount > 0
        if visibleWindows.isEmpty && !showsBankedResets {
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
                if showsBankedResets {
                    MacBankedResetCard(snapshot: snapshot, count: availableResetCount)
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
            if !currentAccount.isDemo
                && (!currentAccount.isRemoteOnly || currentAccount.providerID == .chatGPT) {
                Button(
                    currentAccount.isRemoteOnly
                        ? "Update Worker sign-in" : "Reconnect account"
                ) { showingRelink = true }
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

    private var removalMessage: String {
        if currentAccount.isDemo {
            return "Demo settings and local history will be removed from this Mac."
        }
        var message = "The account and credentials will be deleted from iCloud Keychain, which can remove them from synced Apple devices. Settings and history stored on this Mac will also be deleted."
        if store.isServerMonitoringEnabled(for: currentAccount) {
            message += " Its copy on your linked self-hosted Worker will also be removed."
        }
        return message
    }

    private func refreshAccount() {
        guard !store.isRefreshing, !isRefreshingAccount, !currentAccount.isDemo else { return }
        let account = currentAccount
        isRefreshingAccount = true
        Task {
            defer { isRefreshingAccount = false }
            _ = await store.refresh(account)
        }
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
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(CountdownDisplay.compactString(until: window.resetsAt, from: context.date))
                        .monospacedDigit()
                }
            }
            .font(.caption)
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.displayTitle)
        .accessibilityValue(
            "\(Int(window.remainingPercent.rounded())) percent remaining. Resets \(window.resetsAt.formatted(date: .abbreviated, time: .shortened))."
        )
    }
}

private struct MacBankedResetCard: View {
    let snapshot: UsageSnapshot
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Banked resets").font(.headline)
                Spacer()
                Text("\(count)")
                    .font(.headline.monospacedDigit())
            }
            if let expiry = snapshot.nextBankedResetExpiry() {
                HStack {
                    Text("Next expiry").foregroundStyle(.secondary)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(CountdownDisplay.compactString(until: expiry, from: context.date))
                            .monospacedDigit()
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.teal.opacity(0.10), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Banked resets")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        guard let expiry = snapshot.nextBankedResetExpiry() else {
            return "\(count) available"
        }
        return "\(count) available. Next expiry \(expiry.formatted(date: .abbreviated, time: .shortened))."
    }
}

private enum MacHistoryPreset: String, CaseIterable, Identifiable {
    case day = "24h"
    case week = "7d"
    case month = "30d"
    case all = "All"

    var id: Self { self }

    var duration: TimeInterval? {
        switch self {
        case .day: 24 * 60 * 60
        case .week: 7 * 24 * 60 * 60
        case .month: 30 * 24 * 60 * 60
        case .all: nil
        }
    }
}

private struct MacUsageHistorySection: View {
    @Environment(AppStore.self) private var store
    let account: MonitoredAccount
    @State private var selectedRange: ClosedRange<Date>?
    @State private var isFetchingWorkerHistory = false

    private var accountPoints: [UsageHistoryPoint] {
        store.usageHistory
            .filter { $0.accountID == account.id }
            .sorted { $0.recordedAt < $1.recordedAt }
    }

    private var availableRange: ClosedRange<Date>? {
        MacUsageHistoryPresentation.availableRange(
            points: accountPoints,
            accountID: account.id
        )
    }

    var body: some View {
        GroupBox {
            if let availableRange {
                let range = effectiveRange(within: availableRange)
                let series = MacUsageHistoryPresentation.series(
                    points: store.usageHistory,
                    accountID: account.id,
                    in: range
                )
                VStack(alignment: .leading, spacing: 10) {
                    MacHistoryRangeControls(
                        selection: rangeBinding(within: availableRange),
                        availableRange: availableRange,
                        points: accountPoints,
                        isFetchingRemoteHistory: isWorkerHistoryFetchInProgress,
                        fetchRemoteHistory: workerHistoryFetchAction
                    )

                    if let error = store.historyStorageError {
                        Label(error, systemImage: "externaldrive.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if series.isEmpty {
                        ContentUnavailableView(
                            "No samples in this range",
                            systemImage: "calendar.badge.exclamationmark",
                            description: Text("Slide either range endpoint or choose a preset to include recorded samples.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 170)
                    } else {
                        ForEach(series) { item in
                            MacUsageHistorySeriesCard(series: item, range: range)
                        }
                    }
                }
                .padding(.top, 2)
            } else {
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        "No usage history yet",
                        systemImage: "chart.xyaxis.line",
                        description: Text("A local or Worker sample will appear after the next successful refresh.")
                    )
                    if canFetchWorkerHistory {
                        MacWorkerHistoryFetchButton(
                            isFetching: isWorkerHistoryFetchInProgress,
                            action: fetchWorkerHistory
                        )
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: 210)
            }
        } label: {
            Label("Usage history", systemImage: "chart.xyaxis.line")
        }
        .onAppear { reconcileSelection(oldRange: nil, newRange: availableRange) }
        .onChange(of: availableRange) { oldRange, newRange in
            reconcileSelection(oldRange: oldRange, newRange: newRange)
        }
    }

    private func effectiveRange(within availableRange: ClosedRange<Date>) -> ClosedRange<Date> {
        guard let selectedRange else {
            return MacUsageHistoryPresentation.defaultRange(within: availableRange)
        }
        return MacUsageHistoryPresentation.normalizedRange(
            start: selectedRange.lowerBound,
            end: selectedRange.upperBound,
            within: availableRange
        )
    }

    private var canFetchWorkerHistory: Bool {
        store.pushServerSettings.mode != .disabled
            && store.isServerMonitoringEnabled(for: account)
    }

    private var workerHistoryFetchAction: (() -> Void)? {
        guard canFetchWorkerHistory else { return nil }
        return { fetchWorkerHistory() }
    }

    private var isWorkerHistoryFetchInProgress: Bool {
        isFetchingWorkerHistory || store.isRefreshing
    }

    private func fetchWorkerHistory() {
        guard !isFetchingWorkerHistory, !store.isRefreshing else { return }
        isFetchingWorkerHistory = true
        Task {
            _ = await store.fetchRetainedWorkerHistory(for: account)
            isFetchingWorkerHistory = false
        }
    }

    private func rangeBinding(within availableRange: ClosedRange<Date>)
        -> Binding<ClosedRange<Date>> {
        Binding(
            get: { effectiveRange(within: availableRange) },
            set: { newValue in
                selectedRange = MacUsageHistoryPresentation.normalizedRange(
                    start: newValue.lowerBound,
                    end: newValue.upperBound,
                    within: availableRange
                )
            }
        )
    }

    private func reconcileSelection(
        oldRange: ClosedRange<Date>?,
        newRange: ClosedRange<Date>?
    ) {
        guard let newRange else {
            selectedRange = nil
            return
        }
        guard let selectedRange else {
            self.selectedRange = MacUsageHistoryPresentation.defaultRange(within: newRange)
            return
        }

        if let oldRange,
           abs(selectedRange.upperBound.timeIntervalSince(oldRange.upperBound)) < 1 {
            let duration = selectedRange.upperBound.timeIntervalSince(selectedRange.lowerBound)
            self.selectedRange = MacUsageHistoryPresentation.normalizedRange(
                start: newRange.upperBound.addingTimeInterval(-duration),
                end: newRange.upperBound,
                within: newRange
            )
        } else {
            self.selectedRange = MacUsageHistoryPresentation.normalizedRange(
                start: selectedRange.lowerBound,
                end: selectedRange.upperBound,
                within: newRange
            )
        }
    }
}

private struct MacHistoryRangeControls: View {
    @Binding var selection: ClosedRange<Date>
    let availableRange: ClosedRange<Date>
    let points: [UsageHistoryPoint]
    let isFetchingRemoteHistory: Bool
    let fetchRemoteHistory: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(MacHistoryPreset.allCases) { preset in
                        Button {
                            apply(preset)
                        } label: {
                            if matches(preset) {
                                Label(preset.rawValue.uppercased(), systemImage: "checkmark")
                            } else {
                                Text(preset.rawValue.uppercased())
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(activePresetLabel)
                            .font(.caption.weight(.semibold).monospacedDigit())
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: .rect(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("History range preset")
                .accessibilityValue(activePresetLabel)

                Text(rangeSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 8)

                if let fetchRemoteHistory {
                    MacWorkerHistoryFetchButton(
                        isFetching: isFetchingRemoteHistory,
                        action: fetchRemoteHistory
                    )
                }

                HStack(spacing: 4) {
                    Button { slide(by: -1) } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 20, height: 20)
                            .background(.quaternary, in: .rect(cornerRadius: 6))
                    }
                    .disabled(!canSlideBackward)
                    .accessibilityLabel("Earlier history")

                    Button { slide(by: 1) } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: 20, height: 20)
                            .background(.quaternary, in: .rect(cornerRadius: 6))
                    }
                    .disabled(!canSlideForward)
                    .accessibilityLabel("Later history")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .padding(.horizontal, 2)

            MacHistoryNavigator(
                selection: $selection,
                availableRange: availableRange,
                points: points
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.background.opacity(0.42), in: .rect(cornerRadius: 8))
        }
        .padding(10)
        .background(.quaternary.opacity(0.24), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.secondary.opacity(0.14), lineWidth: 1)
        }
    }

    private var rangeSummary: String {
        let duration = selection.upperBound.timeIntervalSince(selection.lowerBound)
        if duration <= 2 * 24 * 60 * 60 {
            let style = Date.FormatStyle.dateTime
                .month(.abbreviated).day().hour().minute()
            return "\(selection.lowerBound.formatted(style))  →  \(selection.upperBound.formatted(style))"
        }
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        return "\(selection.lowerBound.formatted(style))  →  \(selection.upperBound.formatted(style))"
    }

    private var activePresetLabel: String {
        MacHistoryPreset.allCases.first(where: matches)?.rawValue.uppercased() ?? "CUSTOM"
    }

    private var canSlideBackward: Bool {
        selection.lowerBound.timeIntervalSince(availableRange.lowerBound) > 1
    }

    private var canSlideForward: Bool {
        availableRange.upperBound.timeIntervalSince(selection.upperBound) > 1
    }

    private func apply(_ preset: MacHistoryPreset) {
        guard let duration = preset.duration else {
            selection = availableRange
            return
        }
        selection = MacUsageHistoryPresentation.normalizedRange(
            start: availableRange.upperBound.addingTimeInterval(-duration),
            end: availableRange.upperBound,
            within: availableRange
        )
    }

    private func matches(_ preset: MacHistoryPreset) -> Bool {
        let tolerance: TimeInterval = 61
        if preset == .all {
            return abs(selection.lowerBound.timeIntervalSince(availableRange.lowerBound)) < tolerance
                && abs(selection.upperBound.timeIntervalSince(availableRange.upperBound)) < tolerance
        }
        guard let duration = preset.duration else { return false }
        let selectedDuration = selection.upperBound.timeIntervalSince(selection.lowerBound)
        let expectedDuration = min(
            duration,
            availableRange.upperBound.timeIntervalSince(availableRange.lowerBound)
        )
        return abs(selectedDuration - expectedDuration) < tolerance
    }

    private func slide(by direction: Double) {
        let duration = selection.upperBound.timeIntervalSince(selection.lowerBound)
        let offset = duration * 0.8 * direction
        var start = selection.lowerBound.addingTimeInterval(offset)
        start = min(
            max(start, availableRange.lowerBound),
            availableRange.upperBound.addingTimeInterval(-duration)
        )
        selection = start...start.addingTimeInterval(duration)
    }
}

private struct MacWorkerHistoryFetchButton: View {
    let isFetching: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isFetching {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "icloud.and.arrow.down")
                }
                Text(isFetching ? "Fetching" : "Fetch")
            }
            .frame(minWidth: 62)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isFetching)
        .help("Fetch the full retained history from the linked Worker")
        .accessibilityLabel(
            isFetching ? "Fetching history from Worker" : "Fetch history from Worker"
        )
    }
}

private struct MacHistoryNavigator: View {
    @Binding var selection: ClosedRange<Date>
    let availableRange: ClosedRange<Date>
    let points: [UsageHistoryPoint]

    private var chartPoints: [MacHistoryChartPoint] {
        Dictionary(grouping: points, by: \.metricID).flatMap { metricID, values in
            MacUsageHistorySeries(
                metricID: metricID,
                title: values.last?.metricTitle ?? "Usage limit",
                points: values.sorted { $0.recordedAt < $1.recordedAt }
            ).chartPoints
        }
    }

    var body: some View {
        Chart {
            ForEach(chartPoints) { chartPoint in
                let point = chartPoint.point
                LineMark(
                    x: .value("Recorded", point.recordedAt),
                    y: .value("Percent remaining", point.remainingPercent),
                    series: .value("Metric segment", chartPoint.segmentID)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(by: .value("Metric", point.metricTitle))
                .lineStyle(StrokeStyle(
                    lineWidth: 1.25,
                    dash: chartPoint.isGapConnector ? [6, 4] : []
                ))
                .opacity(0.8)
            }
        }
        .chartXScale(domain: availableRange)
        .chartYScale(domain: 0...100)
        .chartLegend(.hidden)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .chartPlotStyle { plot in
            plot.background(.background.opacity(0.45), in: .rect(cornerRadius: 6))
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let frame = geometry[plotFrame]
                    MacHistoryNavigatorOverlay(
                        selection: $selection,
                        availableRange: availableRange,
                        size: frame.size
                    )
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .frame(height: 64)
        .accessibilityLabel("History navigator")
        .accessibilityValue(
            "Showing \(selection.lowerBound.formatted(date: .abbreviated, time: .shortened)) through \(selection.upperBound.formatted(date: .abbreviated, time: .shortened))"
        )
    }
}

private struct MacHistoryNavigatorOverlay: View {
    private enum DragTarget {
        case lowerHandle
        case selection
        case upperHandle
    }

    @Binding var selection: ClosedRange<Date>
    let availableRange: ClosedRange<Date>
    let size: CGSize
    @State private var lowerDragOrigin: ClosedRange<Date>?
    @State private var selectionDragOrigin: ClosedRange<Date>?
    @State private var upperDragOrigin: ClosedRange<Date>?

    private let handleWidth: CGFloat = 12
    private let handleHitWidth: CGFloat = 24

    var body: some View {
        let startX = xPosition(for: selection.lowerBound)
        let endX = xPosition(for: selection.upperBound)
        let selectionWidth = max(1, endX - startX)
        let lowerHandleCenterX = handleCenterPosition(for: startX)
        let upperHandleCenterX = handleCenterPosition(for: endX)

        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(.rect)

            Rectangle()
                .fill(.black.opacity(0.32))
                .frame(width: max(0, startX), height: size.height)

            Rectangle()
                .fill(.black.opacity(0.32))
                .frame(width: max(0, size.width - endX), height: size.height)
                .offset(x: endX)

            Rectangle()
                .fill(Color.accentColor.opacity(0.08))
                .overlay {
                    Rectangle()
                        .stroke(Color.accentColor.opacity(0.9), lineWidth: 1)
                }
                .frame(width: selectionWidth, height: size.height)
                .offset(x: startX)
                .contentShape(.rect)
                .gesture(dragGesture(for: .selection))

            MacHistoryNavigatorHandle()
                .frame(width: handleWidth, height: size.height)
                .contentShape(.rect)
                .frame(width: handleHitWidth, height: size.height)
                .offset(x: lowerHandleCenterX - handleHitWidth / 2)
                .gesture(dragGesture(for: .lowerHandle))
                .accessibilityLabel("Range start")
                .accessibilityValue(selection.lowerBound.formatted(date: .abbreviated, time: .shortened))
                .accessibilityAdjustableAction { direction in
                    adjustHandle(.lowerHandle, direction: direction)
                }

            MacHistoryNavigatorHandle()
                .frame(width: handleWidth, height: size.height)
                .contentShape(.rect)
                .frame(width: handleHitWidth, height: size.height)
                .offset(x: upperHandleCenterX - handleHitWidth / 2)
                .gesture(dragGesture(for: .upperHandle))
                .accessibilityLabel("Range end")
                .accessibilityValue(selection.upperBound.formatted(date: .abbreviated, time: .shortened))
                .accessibilityAdjustableAction { direction in
                    adjustHandle(.upperHandle, direction: direction)
                }
        }
        .clipped()
        .contentShape(.rect)
        .gesture(
            SpatialTapGesture()
                .onEnded { value in
                    recenter(at: value.location.x)
                },
            including: .gesture
        )
    }

    private var availableDuration: TimeInterval {
        max(0, availableRange.upperBound.timeIntervalSince(availableRange.lowerBound))
    }

    private var minimumDuration: TimeInterval {
        min(MacUsageHistoryPresentation.minimumSelectionDuration, availableDuration)
    }

    private func xPosition(for date: Date) -> CGFloat {
        guard availableDuration > 0, size.width > 0 else { return 0 }
        let elapsed = date.timeIntervalSince(availableRange.lowerBound)
        return min(max(CGFloat(elapsed / availableDuration) * size.width, 0), size.width)
    }

    private func handleCenterPosition(for boundaryX: CGFloat) -> CGFloat {
        let inset = min(handleWidth / 2, size.width / 2)
        return min(max(boundaryX, inset), max(inset, size.width - inset))
    }

    private func dragGesture(for target: DragTarget) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                updateDrag(target, translation: value.translation.width)
            }
            .onEnded { _ in
                setDragOrigin(nil, for: target)
            }
    }

    private func updateDrag(_ target: DragTarget, translation: CGFloat) {
        guard size.width > 0, availableDuration > 0 else { return }
        let origin = dragOrigin(for: target) ?? selection
        if dragOrigin(for: target) == nil {
            setDragOrigin(selection, for: target)
        }
        let offset = TimeInterval(translation / size.width) * availableDuration

        switch target {
        case .lowerHandle:
            let latestStart = origin.upperBound.addingTimeInterval(-minimumDuration)
            let start = min(
                max(origin.lowerBound.addingTimeInterval(offset), availableRange.lowerBound),
                latestStart
            )
            selection = start...origin.upperBound
        case .upperHandle:
            let earliestEnd = origin.lowerBound.addingTimeInterval(minimumDuration)
            let end = max(
                min(origin.upperBound.addingTimeInterval(offset), availableRange.upperBound),
                earliestEnd
            )
            selection = origin.lowerBound...end
        case .selection:
            let duration = origin.upperBound.timeIntervalSince(origin.lowerBound)
            let latestStart = availableRange.upperBound.addingTimeInterval(-duration)
            let start = min(
                max(origin.lowerBound.addingTimeInterval(offset), availableRange.lowerBound),
                latestStart
            )
            selection = start...start.addingTimeInterval(duration)
        }
    }

    private func recenter(at x: CGFloat) {
        guard size.width > 0, availableDuration > 0 else { return }
        let startX = xPosition(for: selection.lowerBound)
        let endX = xPosition(for: selection.upperBound)
        guard x < startX || x > endX else { return }

        let fraction = min(max(x / size.width, 0), 1)
        let center = availableRange.lowerBound.addingTimeInterval(
            TimeInterval(fraction) * availableDuration
        )
        let duration = selection.upperBound.timeIntervalSince(selection.lowerBound)
        let latestStart = availableRange.upperBound.addingTimeInterval(-duration)
        let start = min(
            max(center.addingTimeInterval(-duration / 2), availableRange.lowerBound),
            latestStart
        )
        selection = start...start.addingTimeInterval(duration)
    }

    private func adjustHandle(_ target: DragTarget, direction: AccessibilityAdjustmentDirection) {
        let step = max(minimumDuration, availableDuration / 100)
        let offset: TimeInterval
        switch direction {
        case .increment: offset = step
        case .decrement: offset = -step
        @unknown default: return
        }
        let points = CGFloat(offset / availableDuration) * size.width
        setDragOrigin(selection, for: target)
        updateDrag(target, translation: points)
        setDragOrigin(nil, for: target)
    }

    private func dragOrigin(for target: DragTarget) -> ClosedRange<Date>? {
        switch target {
        case .lowerHandle: lowerDragOrigin
        case .selection: selectionDragOrigin
        case .upperHandle: upperDragOrigin
        }
    }

    private func setDragOrigin(_ origin: ClosedRange<Date>?, for target: DragTarget) {
        switch target {
        case .lowerHandle: lowerDragOrigin = origin
        case .selection: selectionDragOrigin = origin
        case .upperHandle: upperDragOrigin = origin
        }
    }
}

private struct MacHistoryNavigatorHandle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.regularMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(.secondary.opacity(0.9), lineWidth: 1)
            }
            .overlay {
                HStack(spacing: 2) {
                    Capsule().fill(.secondary).frame(width: 1, height: 13)
                    Capsule().fill(.secondary).frame(width: 1, height: 13)
                }
            }
            .padding(.vertical, 2)
            .shadow(color: .black.opacity(0.22), radius: 1, y: 1)
    }
}

private struct MacUsageHistorySeriesCard: View {
    let series: MacUsageHistorySeries
    let range: ClosedRange<Date>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(series.title)
                    .font(.headline)
                Spacer()
                Text("\(Int(series.latest.remainingPercent.rounded()))% left")
                    .font(.headline.monospacedDigit())
            }

            Text(series.planSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)

            MacUsageHistoryChart(series: series, range: range)

            HStack {
                Text("Last recorded")
                Spacer()
                Text(series.latest.recordedAt,
                     format: .dateTime.month(.abbreviated).day().hour().minute())
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 14))
    }
}

private struct MacUsageHistoryChart: View {
    let series: MacUsageHistorySeries
    let range: ClosedRange<Date>

    private var color: Color {
        switch series.latest.windowMinutes {
        case 300: .blue
        case 10_080: .purple
        default: .indigo
        }
    }

    private var duration: TimeInterval {
        range.upperBound.timeIntervalSince(range.lowerBound)
    }

    var body: some View {
        Chart {
            ForEach(series.chartPoints) { chartPoint in
                let point = chartPoint.point
                LineMark(
                    x: .value("Refresh", point.recordedAt),
                    y: .value("Percent remaining", point.remainingPercent),
                    series: .value("Source and plan", chartPoint.segmentID)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(
                    lineWidth: 2,
                    dash: chartPoint.isGapConnector ? [6, 4] : []
                ))
            }

            ForEach(series.planChangePoints) { point in
                RuleMark(x: .value("Plan changed", point.recordedAt))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: range)
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
            if duration <= 2 * 24 * 60 * 60 {
                AxisMarks(values: .stride(by: .hour, count: duration <= 12 * 60 * 60 ? 2 : 6)) {
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.hour())
                }
            } else if duration <= 14 * 24 * 60 * 60 {
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
        .chartPlotStyle { plot in
            plot.background(.background.opacity(0.35), in: .rect(cornerRadius: 8))
        }
        .frame(height: 210)
        .accessibilityLabel("\(series.title) usage history")
        .accessibilityValue(
            "\(series.points.count) samples. Latest value \(Int(series.latest.remainingPercent.rounded())) percent remaining."
        )
    }
}

struct MacMenuBarView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            menuContent(
                targets: MacStatusTarget.targets(
                    accounts: store.accounts,
                    snapshots: store.snapshots,
                    settings: store.monitorSettings,
                    now: context.date
                ),
                now: context.date
            )
        }
        .frame(width: 370)
    }

    private func menuContent(targets: [MacStatusTarget], now: Date) -> some View {
        let displayedTargets = Array(targets.prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("When Reset", systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                    if let latestUpdate {
                        Text("Updated \(latestUpdate, format: .relative(presentation: .named))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if store.isRefreshing {
                    ProgressView("Refreshing")
                        .controlSize(.small)
                        .labelStyle(.iconOnly)
                }
                Button {
                    Task { _ = await store.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(store.isRefreshing || store.accounts.isEmpty)
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityLabel("Refresh all accounts")
                .help("Refresh all accounts")
            }
            .padding(14)

            Divider()

            if !store.refreshFailures.isEmpty {
                Button(action: openMainWindow) {
                    Label(attentionLabel, systemImage: "exclamationmark.triangle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()
            }

            if displayedTargets.isEmpty {
                ContentUnavailableView(
                    "No upcoming resets",
                    systemImage: "clock.badge.checkmark",
                    description: Text("Open When Reset to add or refresh an account.")
                )
                .frame(height: 190)
            } else {
                VStack(spacing: 0) {
                    ForEach(displayedTargets) { target in
                        MacMenuStatusRow(target: target, now: now)
                        if target.id != displayedTargets.last?.id {
                            Divider().padding(.leading, 48)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button("Open When Reset", action: openMainWindow)
                    .keyboardShortcut("o", modifiers: .command)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .buttonStyle(.plain)
            .padding(14)
        }
    }

    private var latestUpdate: Date? {
        store.snapshots.values.map(\.fetchedAt).max()
    }

    private var attentionLabel: String {
        let count = store.refreshFailures.count
        return count == 1 ? "1 account needs attention" : "\(count) accounts need attention"
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MacMenuStatusRow: View {
    let target: MacStatusTarget
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            ProviderIcon(providerID: target.providerID, symbolName: target.symbolName)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.accountName).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(target.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let value = target.valueLabel {
                    Text(value).font(.caption.bold().monospacedDigit())
                }
                Text(CountdownDisplay.compactString(until: target.date, from: now))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(target.accountName), \(target.title)")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let value = target.valueLabel.map { "\($0). " } ?? ""
        return "\(value)Resets \(target.date.formatted(date: .abbreviated, time: .shortened))."
    }
}

struct MacSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var workerLinkText = ""
    @State private var pendingWorkerLink: WorkerLinkDraft?
    @State private var showingRemoteWorkerAccounts = false
    @State private var showingDisconnectConfirmation = false
    @State private var workerLinkError: String?

    private static let cloudWorkerURL = URL(
        string: "https://when-reset-push.ieb.workers.dev"
    )!

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

            Section("Cloudflare Worker") {
                LabeledContent("Service") {
                    Text(Self.cloudWorkerURL.host ?? Self.cloudWorkerURL.absoluteString)
                        .textSelection(.enabled)
                }

                if store.pushServerSettings.mode == .disabled {
                    Link("Create a one-use pairing link", destination: Self.cloudWorkerURL)
                    TextField("Paste whenreset:// link", text: $workerLinkText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                    Button("Review & Link") { stageWorkerLink(workerLinkText) }
                        .buttonStyle(.borderedProminent)
                        .disabled(workerLinkText.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty)
                    Text("Pairing registers this Mac directly with the same Worker. The one-use link expires after five minutes; long-lived device credentials stay in this Mac’s Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Status", value: store.pushServerStatus.title)
                    if case .failed = store.pushServerStatus {
                        Button("Retry registration") { store.retryPushRegistration() }
                    }
                    if store.pushServerStatus == .registered {
                        Button("Add accounts from Worker", systemImage: "icloud.and.arrow.down") {
                            showingRemoteWorkerAccounts = true
                        }
                        Button("Send test refresh") {
                            Task { await store.requestTestPushRefresh() }
                        }
                    }
                    Link("Open Worker", destination: Self.cloudWorkerURL)
                    Button("Disconnect this Mac", role: .destructive) {
                        showingDisconnectConfirmation = true
                    }
                }
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
        .sheet(item: $pendingWorkerLink) { draft in
            MacWorkerLinkReviewView(draft: draft)
                .environment(store)
        }
        .sheet(isPresented: $showingRemoteWorkerAccounts) {
            MacRemoteWorkerAccountsView()
                .environment(store)
        }
        .alert("Couldn’t read Worker link", isPresented: Binding(
            get: { workerLinkError != nil },
            set: { if !$0 { workerLinkError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workerLinkError ?? "The Worker link is invalid.")
        }
        .confirmationDialog(
            "Disconnect this Mac from the Worker?",
            isPresented: $showingDisconnectConfirmation
        ) {
            Button("Disconnect", role: .destructive) { store.disablePushServer() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remote-only accounts will remain visible but cannot refresh until this Mac is linked again.")
        }
        .onOpenURL { stageWorkerLink($0.absoluteString) }
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

    private func stageWorkerLink(_ value: String) {
        do {
            let payload = try WorkerLinkPayload.parse(value)
            workerLinkText = ""
            pendingWorkerLink = .pairing(payload)
        } catch {
            workerLinkError = error.localizedDescription
        }
    }
}

private struct MacWorkerLinkReviewView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let draft: WorkerLinkDraft

    @State private var metadata: WorkerLinkMetadata?
    @State private var interval = RefreshInterval.tenMinutes
    @State private var trustsWorker = false
    @State private var isValidating = true
    @State private var isCommitting = false
    @State private var validationError: String?
    @State private var confirmingLink = false

    private var host: String {
        metadata?.serverURL.host ?? draft.serverURL.host ?? draft.serverURL.absoluteString
    }

    var body: some View {
        NavigationStack {
            Form {
                if isValidating {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Verifying Cloudflare Worker…")
                        }
                    }
                } else if let validationError {
                    Section {
                        Label(validationError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Button("Try again") { Task { await validateWorker() } }
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
                        Picker("Refresh monitoring", selection: $interval) {
                            ForEach(RefreshInterval.serverMonitoringOptions, id: \.self) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    }

                    Section("What this Mac sends") {
                        Label("A device identifier and APNs token for silent refresh hints",
                              systemImage: "bell.badge")
                        Label("No provider credentials are uploaded while linking",
                              systemImage: "lock.shield.fill")
                        Label("Imported accounts read sanitized usage and history from the Worker",
                              systemImage: "icloud.and.arrow.down")
                    }

                    Section("Trust") {
                        Text("The linked Worker can return account usage stored for your existing devices. Continue only if you control \(host).")
                            .foregroundStyle(.orange)
                        Toggle("I trust this Cloudflare Worker", isOn: $trustsWorker)
                        Button("Link this Mac") { confirmingLink = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(!trustsWorker || isCommitting)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Review Worker Link")
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
                "Link this Mac to \(host)?",
                isPresented: $confirmingLink,
                titleVisibility: .visible
            ) {
                Button("Link Mac") { commitLink() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("When Reset will create device-local registration credentials and send this Mac’s APNs token. Provider credentials remain on the Worker.")
            }
        }
        .frame(minWidth: 620, minHeight: 520)
    }

    @MainActor
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
                monitoringAccountIDs: [],
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

private struct MacRemoteWorkerAccountsView: View {
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
                Section("Remote-only accounts") {
                    workerInfoRow(
                        "Provider credentials stay encrypted on the Cloudflare Worker.",
                        systemImage: "lock.shield.fill"
                    )
                    workerInfoRow(
                        "Usage, reset windows, and retained history sync from the Worker.",
                        systemImage: "cloud.fill"
                    )
                }

                Section("Available accounts") {
                    if isLoading {
                        HStack {
                            ProgressView()
                            Text("Loading Worker accounts…")
                        }
                    } else if accounts.isEmpty {
                        ContentUnavailableView(
                            "No accounts available",
                            systemImage: "icloud.slash",
                            description: Text("All available Worker accounts are already on this Mac.")
                        )
                        .frame(minHeight: 180)
                    } else {
                        ForEach(accounts) { account in
                            Toggle(isOn: selectionBinding(account.id)) {
                                HStack(spacing: 12) {
                                    ProviderIcon(providerID: account.providerID)
                                        .frame(width: 28, height: 28)
                                        .accessibilityHidden(true)
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
            .formStyle(.grouped)
            .navigationTitle("Add from Worker")
            .toolbar {
                ToolbarItem {
                    Button("Check sessions", systemImage: "arrow.clockwise") {
                        Task { await loadAccounts() }
                    }
                    .disabled(isLoading || isImporting)
                    .help("Check account sessions on the Worker")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { importSelection() }
                        .disabled(selectedIDs.isEmpty || isImporting)
                }
            }
            .task { await loadAccounts() }
            .alert("Couldn’t add accounts", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "The Worker accounts could not be imported.")
            }
        }
        .frame(minWidth: 620, minHeight: 520)
    }

    private func workerInfoRow(_ text: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 24, alignment: .center)
                .foregroundStyle(.secondary)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
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
                                ProviderIcon(providerID: provider)
                                    .frame(width: 34, height: 34)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(provider.displayName).font(.headline)
                                    Text(provider.accountDescription)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
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
                    Button("Cancel") {
                        cancelLink()
                        dismiss()
                    }
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
            ProviderIcon(providerID: provider)
                .frame(width: 46, height: 46)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.displayName).font(.title2.bold())
                Text(provider.accountDescription).foregroundStyle(.secondary)
                if relinkingAccount?.isRemoteOnly == true {
                    Text("The fresh credential is sent directly to the Worker, is not stored on this Mac, and can never be downloaded from the Worker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
            Text(relinkingAccount?.isRemoteOnly == true
                 ? "When Reset uses the provider’s device authorization page. The replacement credential is sent directly to your Worker and is not stored on this Mac."
                 : "When Reset uses the provider’s device authorization page. Credentials are stored securely in iCloud Keychain.")
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
                if store.isLinking {
                    ProgressView("Waiting for authorization…")
                } else {
                    Label("Authorization check paused", systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                }
                Text("This code expires \(link.expiresAt, style: .relative).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open authorization page again") {
                        NSWorkspace.shared.open(link.verificationURL)
                    }
                    Button("Check now") {
                        resumeDeviceLink(provider)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Start over") {
                        startDeviceLink(provider)
                    }
                }
                Text("If you already approved access and this view is still waiting, choose Check now. Start over creates a new one-time code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Continue in browser") {
                    startDeviceLink(provider)
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
                if store.isLinking { ProgressView("Completing connection…") }
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
            Text("Use your Google OAuth desktop client. The client secret and resulting tokens are stored securely in iCloud Keychain.")
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
                if store.isLinking { ProgressView("Completing connection…") }
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
            Text("Connect an OpenAI-compatible quota endpoint. The endpoint and key are stored securely in iCloud Keychain.")
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
            if store.isLinking { ProgressView("Checking endpoint…") }
        }
    }

    private func apiKeyLinker(_ provider: ProviderID) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(provider.rawValue == "ollama_cloud"
                 ? "Paste the Ollama Cloud browser session cookie. It is stored securely in iCloud Keychain."
                 : "Paste the provider API key. It is stored securely in iCloud Keychain and is never shown again.")
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
            NSWorkspace.shared.open(link.verificationURL)
            if await store.completeDeviceLink(replacing: relinkingAccount) { dismiss() }
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
            if await store.completeDeviceLink(replacing: relinkingAccount) { dismiss() }
        }
    }
}
#endif
