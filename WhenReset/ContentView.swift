import SwiftUI

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
                Text("This deletes its saved credentials, cached usage, and monitor settings from this device.")
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
            ProviderIcon(providerID: account.providerID)
                .frame(width: 18, height: 18)
            Text(account.providerID.sectionTitle(plan: plan))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            if let failure {
                Image(systemName: failure.systemImageName)
                    .foregroundStyle(.red)
                    .accessibilityLabel(failure.title)
            }
            Spacer(minLength: 10)
            Text(account.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
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

struct AccountSettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let account: MonitoredAccount
    @State private var settings = AccountMonitorSettings()
    @State private var showingRelink = false
    @State private var confirmingRemoval = false

    var body: some View {
        Form {
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
                if account.providerID.supportsBankedResets {
                    Toggle("Banked resets", isOn: $settings.showBankedResets)
                }
                if let snapshot = store.snapshots[account.id] {
                    ForEach(snapshot.usageWindows, id: \.metricID) { window in
                        Toggle(window.displayTitle, isOn: metricBinding(window))
                    }
                }
            } header: {
                Text("Displayed limits")
            } footer: {
                Text("These choices apply to this account card and widgets.")
            }
            Section {
                if account.providerID.supportsBankedResets {
                    Toggle("Banked reset expiries", isOn: $settings.showBankedResetsInLiveActivity)
                }
                if let snapshot = store.snapshots[account.id] {
                    ForEach(snapshot.usageWindows, id: \.metricID) { window in
                        Toggle(window.displayTitle, isOn: liveActivityMetricBinding(window))
                    }
                }
            } header: {
                Text("Live Activity content")
            } footer: {
                Text("Selected limits from this account are candidates for the single global Live Activity.")
            }
            Section("Account") {
                if !account.isDemo {
                    Button("Sign in again", systemImage: "arrow.triangle.2.circlepath") {
                        showingRelink = true
                    }
                }
                Button(account.isDemo ? "Remove demo" : "Remove account", systemImage: "trash", role: .destructive) {
                    confirmingRemoval = true
                }
            }
        }
        .navigationTitle(account.providerID.displayName)
        .onAppear { settings = store.settings(for: account) }
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
                 : "This deletes its saved credentials, cached usage, and monitor settings from this device.")
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
            else { settings.hiddenLiveActivityMetricIDs.insert(window.metricID) }
        }
    }
}

struct GlobalLiveActivitySettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var settings = GlobalLiveActivitySettings()

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    Button(store.hasLiveActivity ? "Stop Global Live Activity" : "Start Global Live Activity",
                           systemImage: store.hasLiveActivity ? "stop.circle" : "bolt.circle") {
                        Task { await store.toggleLiveActivity() }
                    }
                }
                Section("Automatic start") {
                    Picker("Start", selection: $settings.mode) {
                        ForEach(LiveActivityMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if settings.mode == .nearReset {
                        Picker("When reset is within", selection: $settings.nearResetMinutes) {
                            Text("30 minutes").tag(30); Text("1 hour").tag(60); Text("2 hours").tag(120)
                            Text("4 hours").tag(240); Text("8 hours").tag(480)
                        }
                    }
                }
                Section {
                    Text("One Live Activity summarizes the most constrained enabled limit across every account. Use each account header’s cog on the Usage tab to choose its content.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Live Activity")
            .onAppear { settings = store.liveActivitySettings }
            .onChange(of: settings) { _, newValue in store.setLiveActivitySettings(newValue) }
        }
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
