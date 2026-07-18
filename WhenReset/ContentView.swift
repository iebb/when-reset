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
                AccountInformationRow(title: "Provider", value: currentAccount.providerID.displayName)
                AccountInformationRow(title: "Name", value: currentAccount.displayName)
                AccountInformationRow(title: "Email", value: currentAccount.email ?? "Not provided",
                                      isSensitive: currentAccount.email != nil)
                AccountInformationRow(
                    title: "Plan",
                    value: currentPlan?.replacingOccurrences(of: "_", with: " ") ?? "Not provided"
                )
                AccountInformationRow(
                    title: "Plan expiry",
                    value: currentAccount.planExpiresAt?.formatted(date: .abbreviated, time: .shortened)
                        ?? "Not provided"
                )
                AccountInformationRow(
                    title: "Connected",
                    value: currentAccount.addedAt.formatted(date: .abbreviated, time: .shortened)
                )
            } header: {
                Text("Account information")
            } footer: {
                Text("These details are reported by the provider. Sign in again to refresh them; the display name below remains your own customization.")
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
                        Text(window.displayTitle)
                    } footer: {
                        if settings.liveActivityRule(for: window).trigger == .never,
                           settings.showsInLiveActivity(window) {
                            Text("This quota is excluded from the Live Activity until you choose another rule.")
                        }
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
                    Toggle("Include in Live Activity", isOn: $settings.showBankedResetsInLiveActivity)
                    if settings.showBankedResetsInLiveActivity {
                        LiveActivityRuleRows(rule: $settings.bankedResetLiveActivityRule,
                                             allowsPercentage: false)
                    }
                } header: {
                    Text("Banked resets")
                } footer: {
                    Text("Uses the earliest future reset expiry for this account.")
                }
            }
            Section("Connection") {
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
        .navigationTitle(currentAccount.resolvedDisplayName)
        .onAppear {
            settings = store.settings(for: account)
            draftDisplayName = currentAccount.resolvedDisplayName
            draftSymbolName = currentAccount.customSymbolName
            savedDisplayName = draftDisplayName
            savedSymbolName = draftSymbolName
        }
        .onDisappear(perform: saveAppearance)
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

    private func quotaRuleBinding(_ window: UsageWindow) -> Binding<LiveActivityQuotaRule> {
        Binding {
            settings.liveActivityRule(for: window)
        } set: { rule in
            settings.liveActivityQuotaRules[window.metricID] = rule
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
        Picker("Show when", selection: $rule.trigger) {
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

    var body: some View {
        NavigationStack {
            Form {
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
                if settings.mode == .automatic {
                    Section {
                        Text("Each included quota appears only after its own percentage, time, or exhaustion rule matches.")
                    } header: {
                        Text("Automatic rules")
                    }
                }
                Section {
                    Text("The Live Activity orders matching resets from nearest to farthest, with the nearest target in the large panel and up to three more below. Open an account’s settings from Usage to configure each quota.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Live Activity")
            .onAppear { settings = store.liveActivitySettings }
            .onChange(of: settings) { _, newValue in store.setLiveActivitySettings(newValue) }
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
