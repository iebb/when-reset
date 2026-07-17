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
            .alert("Couldn’t update", isPresented: .init(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(store.errorMessage ?? "Unknown error") }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Monitor your limits", systemImage: "gauge.with.dots.needle.33percent")
        } description: {
            Text("Link a ChatGPT account to see usage windows, countdowns, and banked resets.")
        } actions: {
            Button("Link account") { showingAddAccount = true }.buttonStyle(.borderedProminent)
        }
    }

    private var accountList: some View {
        List {
            ForEach(store.accounts) { account in
                Section {
                    if let snapshot = store.snapshots[account.id] {
                        UsageCard(snapshot: snapshot.filtered(using: store.settings(for: account)))
                    } else {
                        HStack { ProgressView(); Text("Loading usage…").foregroundStyle(.secondary) }
                    }
                } header: {
                    ProviderSectionHeader(account: account)
                }
                .swipeActions { Button("Remove", role: .destructive) { store.remove(account) } }
            }
        }.listStyle(.insetGrouped)
    }
}

private struct ProviderSectionHeader: View {
    let account: MonitoredAccount

    var body: some View {
        HStack(spacing: 7) {
            Image(account.providerID == .chatGPT ? "ChatGPTLogo" : "ClaudeLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
            Text(account.providerID.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
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

struct AccountSettingsView: View {
    @Environment(AppStore.self) private var store
    let account: MonitoredAccount
    @State private var settings = AccountMonitorSettings()

    var body: some View {
        Form {
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
        }
        .navigationTitle(account.providerID.displayName)
        .onAppear { settings = store.settings(for: account) }
        .onChange(of: settings) { _, newValue in store.setSettings(newValue, for: account) }
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
            ForEach(Array(snapshot.usageWindows.enumerated()), id: \.offset) { _, window in
                LimitRow(window: window)
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
