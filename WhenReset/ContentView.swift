#if os(iOS)
import SwiftUI

struct ContentView: View {
    private enum Tab: Hashable { case usage, settings }

    @Environment(\.scenePhase) private var scenePhase
    @State private var updates = UpdateCheckController()
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
        .environment(updates)
        .environment(ForecastSettingsStore.shared)
        .environment(CodexResetStore.shared)
        .onAppear {
            #if DEBUG
            if ScreenshotLaunch.isActive,
               ["settings", "settingsRoot", "forecasts", "about", "notifications",
                "tokenActivity", "tokenActivityWeekly", "tokenActivityCumulative",
                "tokenActivityEmpty", "tokenActivityExpanded"]
                .contains(ScreenshotLaunch.screen) {
                selectedTab = .settings
            }
            #endif
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if let banner = updates.banner, updates.preferences.remindWhenAvailable {
                UpdateAvailableBanner(
                    message: UpdateCopy.available(version: banner.version, build: banner.build),
                    openTitle: openTitle(for: banner),
                    onOpen: {
                        if let url = banner.openURL { updates.open(url) }
                    },
                    onDismiss: { updates.dismissBanner() }
                )
            }
        }
        .task { await updates.prepare() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await updates.softCheckIfNeeded() }
        }
    }

    private func stageWorkerLink(_ draft: WorkerLinkDraft) {
        selectedTab = .settings
        pendingWorkerLink = draft
    }

    private func openTitle(for banner: UpdateBanner) -> LocalizedStringKey? {
        guard banner.openURL != nil else { return nil }
        switch updates.channel {
        case .appStore: return "Open App Store"
        case .testFlight: return "Open TestFlight"
        case .development: return nil
        }
    }
}

private struct UpdateAvailableBanner: View {
    var message: String
    var openTitle: LocalizedStringKey?
    var onOpen: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if let openTitle {
                    Button(openTitle, action: onOpen)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Button("Not now", action: onDismiss)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .accessibilityIdentifier("update-available-banner")
    }
}

private struct UsageTabView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.interfaceStyle) private var interfaceStyle
    @State private var showingAddAccount = false
    @State private var relinkingAccount: MonitoredAccount?
    @State private var accountPendingRemoval: MonitoredAccount?
    @State private var settingsAccount: MonitoredAccount?

    var body: some View {
        NavigationStack {
            Group {
                if store.accounts.isEmpty { emptyState }
                else { accountList }
            }
            .navigationTitle(store.accounts.isEmpty ? "Blinky" : "Usage")
            .onAppear {
                #if DEBUG
                if ScreenshotLaunch.isActive {
                    if ScreenshotLaunch.screen == "reorder" { editingAccountOrder = true }
                    if ScreenshotLaunch.screen == "addAccount" || ScreenshotLaunch.screen == "deviceCode" {
                        showingAddAccount = true
                    }
                }
                #endif
            }
            .navigationBarTitleDisplayMode(store.accounts.isEmpty ? .inline : .large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.accounts.isEmpty {
                        Button { Task { await store.refreshAll() } } label: {
                            if store.isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                        }.disabled(store.isRefreshing)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !store.accounts.isEmpty {
                        Menu {
                            Picker("Sort accounts", selection: Binding(
                                get: { store.usageListSort },
                                set: { store.setUsageListSort($0) }
                            )) {
                                ForEach(UsageListSort.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        .accessibilityIdentifier("usage-sort")
                        .accessibilityLabel("Sort accounts")
                        if store.usageListSort == .custom {
                            Button(editingAccountOrder ? "Done" : "Edit") {
                                editingAccountOrder.toggle()
                            }
                        }
                        Button("Add", systemImage: "plus") { showingAddAccount = true }
                    }
                }
            }
            .onChange(of: store.usageListSort) { _, sort in
                if sort != .custom { editingAccountOrder = false }
            }
            .refreshable { await store.refreshAll() }
            .blinkyNavigationGlass(interfaceStyle)
            .navigationDestination(item: $settingsAccount) { account in
                AccountSettingsView(account: account)
            }
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
        .blinkyScreenBackdrop(interfaceStyle)
    }

    private var emptyState: some View {
        FirstRunExperienceView(
            connectAccount: { showingAddAccount = true }
        )
    }

    @State private var editingAccountOrder = false

    private var accountList: some View {
        List {
            ForEach(store.displayedAccounts) { account in
                let snapshot = store.snapshots[account.id]
                let failure = store.refreshFailures[account.id]
                Section {
                    if editingAccountOrder {
                        AccountReorderRow(account: account)
                            .modifier(UsageAccountChrome(style: interfaceStyle))
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ProviderSectionHeader(
                                account: account,
                                plan: snapshot?.plan ?? account.plan,
                                failure: failure,
                                openSettings: { settingsAccount = account }
                            )
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
                        }
                        .modifier(UsageAccountChrome(style: interfaceStyle))
                    }
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { accountPendingRemoval = account }
                }
                .modifier(AccountDragModifier(
                    enabled: store.usageListSort == .custom && !editingAccountOrder,
                    accountID: account.id,
                    moveBefore: { dragged in
                        store.moveAccount(dragged, before: account.id)
                    }
                ))
            }
            .onMove { offsets, destination in
                guard store.usageListSort == .custom else { return }
                store.moveAccounts(from: offsets, to: destination)
            }
        }
        .accessibilityIdentifier("usage-style-\(interfaceStyle.rawValue)")
        .modifier(UsageListSurface(style: interfaceStyle))
        .environment(\.editMode, .constant(editingAccountOrder ? .active : .inactive))
    }
}

private struct FirstRunExperienceView: View {
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

                    Text("See usage across your coding plans.")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .tracking(-0.7)
                    Text("Each provider's remaining allowance, with the next reset as a detail.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: connectAccount) {
                    Label("Connect an account", systemImage: "person.crop.circle.badge.plus")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 15))
                .controlSize(.large)
                .accessibilityIdentifier("connect-account-button")

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

private struct AccountDragModifier: ViewModifier {
    var enabled: Bool
    var accountID: UUID
    var moveBefore: (UUID) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrag { NSItemProvider(object: accountID.uuidString as NSString) }
                .onDrop(of: [.text], isTargeted: nil) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                        guard let raw = value as? String, let dragged = UUID(uuidString: raw) else { return }
                        Task { @MainActor in
                            moveBefore(dragged)
                        }
                    }
                    return true
                }
        } else {
            content
        }
    }
}

private struct AccountReorderRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.quotaPercentBasis) private var percentBasis
    let account: MonitoredAccount

    var body: some View {
        let snapshot = store.snapshots[account.id]?.filtered(using: store.settings(for: account))
        let headline = snapshot?.headlineWindow(pinnedMetricID: nil)
        HStack(spacing: 10) {
            ProviderIcon(providerID: account.providerID, symbolName: account.customSymbolName)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.resolvedDisplayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(account.providerSectionTitle(plan: snapshot?.plan ?? account.plan))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let headline {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(percentBasis.labeled(remainingPercent: headline.remainingPercent))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if headline.showsCountdown {
                        Text(CountdownDisplay.compactString(until: headline.resetsAt))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ProviderSectionHeader: View {
    let account: MonitoredAccount
    let plan: String?
    let failure: AccountRefreshFailure?
    var openSettings: () -> Void
    @Environment(\.interfaceStyle) private var interfaceStyle

    var body: some View {
        HStack(spacing: interfaceStyle == .screenTime ? 6 : 7) {
            ProviderIcon(providerID: account.providerID, symbolName: account.customSymbolName)
                .frame(width: iconSide, height: iconSide)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.resolvedDisplayName)
                    .font(nameFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(account.providerSectionTitle(plan: plan))
                    .font(interfaceStyle == .screenTime ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let failure {
                Image(systemName: failure.systemImageName)
                    .foregroundStyle(.red)
                    .accessibilityLabel(failure.title)
            }
            Spacer(minLength: 10)
            Button(action: openSettings) {
                settingsGear
            }
            .buttonStyle(.plain)
        }
        .textCase(nil)
    }

    /// Screen Time uses a smaller header so the rounded percent stays the figure.
    /// Classic and Liquid Glass keep the account name as the card title.
    private var nameFont: Font {
        interfaceStyle == .screenTime ? .subheadline.weight(.semibold) : .headline
    }

    private var iconSide: CGFloat {
        interfaceStyle == .screenTime ? 22 : 28
    }

    private var settingsGear: some View {
        Image(systemName: "gearshape.fill")
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .accessibilityLabel("\(account.providerDisplayName) account settings")
    }
}

private struct AccountFailureView: View {
    let account: MonitoredAccount
    let failure: AccountRefreshFailure
    let cachedAt: Date?
    let retry: () -> Void
    let relink: () -> Void
    let remove: () -> Void

    private var isExpiredWorkerSession: Bool {
        failure == AccountRefreshFailure(
            workerSessionStatus: .expired,
            checkedAt: failure.failedAt
        )
    }

    private var isWorkerSessionCheckFailure: Bool {
        failure == AccountRefreshFailure(
            workerSessionStatus: .error,
            checkedAt: failure.failedAt
        )
    }

    private var title: String {
        if isExpiredWorkerSession { return "Worker sign-in expired" }
        if isWorkerSessionCheckFailure { return "Worker session check failed" }
        return failure.title
    }

    private var message: String {
        if isExpiredWorkerSession {
            return "Cloud quota refresh has stopped for this account. Reconnect the provider sign-in to resume Worker updates."
        }
        return failure.message
    }

    private var tint: Color {
        failure.requiresRelink ? .red : .orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: failure.systemImageName)
                .font(.headline)
                .foregroundStyle(tint)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if isExpiredWorkerSession {
                Text("Worker reported this \(failure.failedAt, style: .relative).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let cachedAt {
                Text("Showing the latest saved usage from \(cachedAt, style: .relative).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if isExpiredWorkerSession {
                    Button(
                        "Reconnect now",
                        systemImage: "arrow.triangle.2.circlepath",
                        action: relink
                    )
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .accessibilityHint("Opens the sign-in flow to resume Worker quota refresh")
                } else if failure.requiresRelink,
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
        .padding(12)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(tint.opacity(0.24), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

struct UsageCard: View {
    let snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if snapshot.usageWindows.isEmpty, let balance = snapshot.apiBalance {
                APIBalanceRow(balance: balance)
            } else if snapshot.usageWindows.isEmpty {
                Label("No resettable limits reported", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(snapshot.usageWindows.enumerated()), id: \.offset) { _, window in
                    LimitRow(window: window)
                }
            }
            UsageFooter(snapshot: snapshot)
        }
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
                UsageMeter(remainingFraction: fraction)
            }

            HStack(spacing: 8) {
                if balance.kind != .wallet {
                    Text("Spent \(Self.formattedValue(balance.spent, balance: balance))")
                }
                if let limit = balance.limit, !balance.isUnlimited, balance.kind != .wallet {
                    Spacer()
                    Text("Budget \(Self.formattedValue(limit, balance: balance))")
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
        return Self.formattedValue(balance.remaining ?? balance.spent, balance: balance)
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

    static func formattedValue(_ amount: Double, balance: APIBalance) -> String {
        if let unit = balance.unitLabel {
            return "\(amount.formatted(.number.grouping(.automatic).precision(.fractionLength(0)))) \(unit)"
        }
        return formatted(amount, currencyCode: balance.currencyCode)
    }
}

struct LimitRow: View {
    let window: UsageWindow
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.interfaceStyle) private var interfaceStyle
    @Environment(\.quotaPercentBasis) private var percentBasis

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(window.displayTitle)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(percentBasis.labeled(remainingPercent: window.remainingPercent))
                        .font(percentFont)
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
                if window.showsCountdown {
                    Text(QuotaResetClock.subline(until: window.resetsAt, from: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                UsageMeter(
                    remainingFraction: window.remainingPercent / 100,
                    prominent: interfaceStyle == .screenTime
                )
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Screen Time's percent is a larger rounded figure. Classic stays a subheadline.
    private var percentFont: Font {
        switch interfaceStyle {
        case .screenTime:
            .system(.title3, design: .rounded).weight(.semibold)
        case .classic, .liquidGlass:
            .subheadline.weight(.semibold)
        }
    }

    private var tint: Color {
        UsageMeterTint.color(remainingFraction: window.remainingPercent / 100, colorScheme: colorScheme)
    }
}
#endif
