import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// How a continuous meter is drawn for one interface style.
///
/// Classic stays a thin pill. Screen Time uses a short-cornered block, the
/// way Screen Time draws a category bar. Liquid Glass stays a pill, with a
/// stronger track so it reads on a blurred surface.
struct UsageMeterMetrics: Equatable, Sendable {
    var height: CGFloat
    var cap: UsageMeterCap
    var trackOpacity: Double
}

enum UsageMeterCap: Equatable, Sendable {
    case round
    case square
}

enum InterfaceMetrics {
    /// Space between account cards. One value for every interface style.
    static let cardSpacing: CGFloat = 14
}

extension InterfaceStyle {
    func continuousMeter(prominent: Bool) -> UsageMeterMetrics {
        switch self {
        case .classic:
            return UsageMeterMetrics(height: 6, cap: .round, trackOpacity: 0.14)
        case .screenTime:
            // A short-cornered block, tall enough that it does not read as a pill.
            // Cards pass `prominent`; widgets stay a step shorter.
            return UsageMeterMetrics(height: prominent ? 14 : 10, cap: .square, trackOpacity: 0.16)
        case .liquidGlass:
            return UsageMeterMetrics(height: prominent ? 8 : 6, cap: .round, trackOpacity: 0.28)
        }
    }
}

enum InterfacePalette {
    static func screenTimeCanvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.07, green: 0.08, blue: 0.11)
            : Color(red: 0.88, green: 0.91, blue: 0.96)
    }

    /// Opaque page fill. `UIColor.systemBackground` has no macOS name.
    static var pageBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

/// Screen Time page fill, including the area behind the large title.
private struct ScreenTimePageFill: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        InterfacePalette.screenTimeCanvas(colorScheme)
            .ignoresSafeArea()
    }
}

/// Saturated field behind Liquid Glass, so the blur has something to blur.
struct InterfaceGlassBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        LinearGradient(
            colors: dark
                ? [
                    Color(red: 0.05, green: 0.08, blue: 0.22),
                    Color(red: 0.20, green: 0.06, blue: 0.24),
                    Color(red: 0.03, green: 0.16, blue: 0.18),
                ]
                : [
                    Color(red: 0.42, green: 0.68, blue: 0.98),
                    Color(red: 0.74, green: 0.50, blue: 0.96),
                    Color(red: 0.32, green: 0.84, blue: 0.80),
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

/// Widget and Live Activity fill. Follows the same three surfaces as the app.
struct InterfaceWidgetBackground: View {
    @Environment(\.interfaceStyle) private var interfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch interfaceStyle {
        case .classic:
            InterfacePalette.pageBackground
        case .screenTime:
            InterfacePalette.screenTimeCanvas(colorScheme)
        case .liquidGlass:
            ZStack {
                InterfaceGlassBackdrop()
                Rectangle().fill(.ultraThinMaterial)
            }
        }
    }
}

struct UsageListSurface: ViewModifier {
    var style: InterfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        // `insetGrouped` is iOS-only. The Mac widget compiles this file and
        // does not draw the usage list.
        #if os(iOS)
        switch style {
        case .classic:
            content
                .listStyle(.insetGrouped)
                .blinkyCardSpacing()
                .blinkyBottomScrollMargin()
        case .screenTime:
            content
                .listStyle(.insetGrouped)
                .blinkyCardSpacing()
                .blinkyBottomScrollMargin()
                .scrollContentBackground(.hidden)
                .background(InterfacePalette.screenTimeCanvas(colorScheme).ignoresSafeArea())
        case .liquidGlass:
            // Plain list: an inset-grouped section is its own card, and a
            // glass plate inside it reads as a card inside a card.
            content
                .listStyle(.plain)
                .listSectionSeparator(.hidden)
                .blinkyPlainListHeaders()
                .blinkyCardSpacing()
                .blinkyBottomScrollMargin()
                .scrollContentBackground(.hidden)
                .background(InterfaceGlassBackdrop())
        }
        #else
        content
        #endif
    }
}

struct UsageAccountChrome: ViewModifier {
    var style: InterfaceStyle

    func body(content: Content) -> some View {
        switch style {
        case .classic:
            content
        case .screenTime:
            content
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(InterfacePalette.pageBackground)
        case .liquidGlass:
            content
                .blinkyGlassPlate()
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        }
    }
}

private struct BlinkyNavigationChrome: ViewModifier {
    var style: InterfaceStyle

    func body(content: Content) -> some View {
        switch style {
        case .classic:
            content
        case .screenTime, .liquidGlass:
            content.blinkyClearNavigationBar()
        }
    }
}

private struct SettingsCanvasModifier: ViewModifier {
    @Environment(\.interfaceStyle) private var style

    func body(content: Content) -> some View {
        switch style {
        case .classic:
            content.blinkyBottomScrollMargin()
        case .screenTime:
            content
                .scrollContentBackground(.hidden)
                .background(ScreenTimePageFill())
                .blinkyClearNavigationBar()
                .blinkyBottomScrollMargin()
        case .liquidGlass:
            content
                .scrollContentBackground(.hidden)
                .background(InterfaceGlassBackdrop())
                .blinkyClearNavigationBar()
                .blinkyBottomScrollMargin()
        }
    }
}

private struct SettingsSectionModifier: ViewModifier {
    @Environment(\.interfaceStyle) private var style

    func body(content: Content) -> some View {
        switch style {
        case .classic:
            content
        case .screenTime:
            content.listRowBackground(InterfacePalette.pageBackground)
        case .liquidGlass:
            content.listRowBackground(GlassSectionFill())
        }
    }
}

private struct GlassSectionFill: View {
    var body: some View {
        Rectangle().fill(.ultraThinMaterial)
    }
}

extension View {
    /// Plain lists keep a header slot even when the section has no header.
    @ViewBuilder
    func blinkyPlainListHeaders() -> some View {
        #if os(iOS)
        self.environment(\.defaultMinListHeaderHeight, 0)
        #else
        self
        #endif
    }

    /// The same gap between account cards in every style. iOS-only API.
    @ViewBuilder
    func blinkyCardSpacing() -> some View {
        #if os(iOS)
        self.listSectionSpacing(InterfaceMetrics.cardSpacing)
        #else
        self
        #endif
    }

    /// Extra scroll room so the last card can move clear of the tab bar.
    @ViewBuilder
    func blinkyBottomScrollMargin() -> some View {
        #if os(iOS)
        self.contentMargins(.bottom, 28, for: .scrollContent)
        #else
        self
        #endif
    }

    /// Keep the large title on the same surface as the page.
    ///
    /// A visible toolbar background paints its own band over the large title
    /// and ends in a hard edge. Hiding it lets the page color run behind
    /// "Usage" and "Settings" the way the system list does.
    @ViewBuilder
    func blinkyClearNavigationBar() -> some View {
        #if os(iOS)
        self.toolbarBackground(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    /// Page color behind the navigation bar as well as the list.
    @ViewBuilder
    func blinkyScreenBackdrop(_ style: InterfaceStyle) -> some View {
        switch style {
        case .classic:
            self
        case .screenTime:
            self.background {
                ScreenTimePageFill()
            }
        case .liquidGlass:
            self.background {
                InterfaceGlassBackdrop()
            }
        }
    }

    func blinkyNavigationGlass(_ style: InterfaceStyle) -> some View {
        modifier(BlinkyNavigationChrome(style: style))
    }

    func blinkySettingsCanvas() -> some View {
        modifier(SettingsCanvasModifier())
    }

    func blinkySettingsSection() -> some View {
        modifier(SettingsSectionModifier())
    }

    /// One glass surface: fill, a single hairline, and a soft shadow.
    /// No second stroke and no padding outside the shape, so the list does
    /// not draw another plate around it.
    @ViewBuilder
    func blinkyGlassPlate() -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        #if os(iOS)
        if #available(iOS 26, *) {
            self
                .padding(16)
                .glassEffect(.regular, in: shape)
                .overlay { shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5) }
                .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)
        } else {
            blinkyMaterialPlate(shape)
        }
        #else
        blinkyMaterialPlate(shape)
        #endif
    }

    func blinkyMaterialPlate(_ shape: RoundedRectangle) -> some View {
        padding(16)
            .background(.ultraThinMaterial, in: shape)
            .overlay { shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5) }
            .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)
    }

    /// Frosted inset for secondary card details.
    @ViewBuilder
    func blinkyInsetGlass() -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        #if os(iOS)
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
        #endif
    }
}

/// Home Screen multi-account list. The three styles stay readable at widget size:
/// Classic is a plain stack, Screen Time adds a category rail and a block bar,
/// Liquid Glass puts each account on its own chip.
struct StyledMultiAccountList: View {
    var snapshots: [UsageSnapshot]
    var showsSecondLimit: Bool
    /// Frozen clock for screenshots. Nil follows the widget timeline.
    var now: Date? = nil

    private var clock: Date { now ?? .now }

    /// Medium is short. A reset-card line replaces the "Usage" title so the
    /// last account in the stored order still fits. Large keeps the title.
    private var tight: Bool {
        !ResetCardSurface.showsUsageTitle(
            showsSecondLimit: showsSecondLimit,
            snapshots: snapshots,
            now: clock
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: tight ? 3 : 5) {
            if !tight {
                Text("Usage")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(snapshots, id: \.accountID) { snapshot in
                StyledMultiAccountRow(
                    snapshot: snapshot,
                    showsSecondLimit: showsSecondLimit,
                    now: now,
                    tight: tight
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct StyledMultiAccountRow: View {
    var snapshot: UsageSnapshot
    var showsSecondLimit: Bool
    var now: Date? = nil
    var tight = false
    @Environment(\.interfaceStyle) private var interfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    private var resetFact: ResetCardSurface.Fact? {
        ResetCardSurface.fact(snapshot: snapshot, now: now ?? .now)
    }

    var body: some View {
        switch interfaceStyle {
        case .classic, .screenTime:
            row.padding(.vertical, tight ? 0 : 1)
        case .liquidGlass:
            row
                .padding(.horizontal, 6)
                .padding(.vertical, tight ? 2 : 4)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var row: some View {
        let headline = snapshot.headlineWindow(pinnedMetricID: nil)
        let secondary = headline.flatMap { snapshot.secondaryLimit(after: $0) }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                ProviderIcon(providerID: snapshot.accountProviderID ?? .chatGPT, symbolName: snapshot.accountSymbolName)
                    .frame(width: 16, height: 16)
                Text(snapshot.resolvedAccountName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let headline {
                    if headline.showsCountdown {
                        Text(CountdownDisplay.compactString(until: headline.resetsAt))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(UsageText.widgetFigure(headline.remainingPercent))
                        .font(.caption.weight(interfaceStyle == .screenTime ? .bold : .regular).monospacedDigit())
                        .foregroundStyle(interfaceStyle == .screenTime ? AnyShapeStyle(tint) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                }
            }
            if let headline {
                UsageMeter(remainingFraction: headline.remainingPercent / 100)
                if showsSecondLimit, let secondary {
                    HStack {
                        Text(secondary.displayTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(UsageText.widgetFigure(secondary.remainingPercent))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            if let resetFact {
                ResetCardAccountRow(count: resetFact.count, expiresAt: resetFact.expiresAt, now: now)
            }
        }
    }

    private var tint: Color {
        let remaining = (snapshot.headlineWindow(pinnedMetricID: nil)?.remainingPercent ?? 100) / 100
        return UsageMeterTint.color(remainingFraction: remaining, colorScheme: colorScheme)
    }
}

#if os(iOS)
struct StyledLiveAccountList: View {
    var rows: [UsageActivityAccountRow]
    var onDarkSurface = false
    /// Lower than `LiveActivityAccounts.maximum` only for an accessibility size.
    var limit = LiveActivityAccounts.maximum
    /// One or two accounts keep the roomy row. The lock screen switches at three;
    /// the expanded island switches at two so the region stays short.
    var denseFrom = 3
    var now: Date? = nil
    @Environment(\.interfaceStyle) private var interfaceStyle

    private var visible: [UsageActivityAccountRow] {
        Array(LiveActivityAccounts.visible(rows).prefix(max(0, limit)))
    }

    private var dense: Bool { visible.count >= denseFrom }

    var body: some View {
        VStack(alignment: .leading, spacing: dense ? 3 : (interfaceStyle == .screenTime ? 8 : 6)) {
            if dense, let summary = ResetCardSurface.aggregate(
                visible.map { ($0.resetCardCount, $0.resetCardExpiresAt) }
            ) {
                ResetCardAccountRow(
                    count: summary.count,
                    expiresAt: summary.expiresAt,
                    now: now,
                    onDarkSurface: onDarkSurface
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(visible) { account in
                StyledLiveAccountRow(
                    account: account,
                    onDarkSurface: onDarkSurface,
                    now: now,
                    dense: dense
                )
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct StyledLiveAccountRow: View {
    var account: UsageActivityAccountRow
    var onDarkSurface = false
    var now: Date? = nil
    var dense = false
    @Environment(\.interfaceStyle) private var interfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if dense {
            denseStack
        } else {
            switch interfaceStyle {
            case .classic, .screenTime:
                roomyStack
            case .liquidGlass:
                if onDarkSurface {
                    roomyStack
                } else {
                    roomyStack
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.45), lineWidth: 0.5)
                        }
                }
            }
        }
    }

    /// One text line and a 3pt bar. The card count is a badge, not a second
    /// line, so four or five accounts cannot collapse onto each other.
    private var denseStack: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .center, spacing: 4) {
                ProviderIcon(providerID: account.providerID, symbolName: account.symbolName)
                    .frame(width: 12, height: 12)
                Text(account.accountName)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if account.isSoonestReset {
                    Text(UsageText.soonestBadge())
                        .font(.system(size: 9, weight: .bold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(onDarkSurface ? 0.35 : 0.85), in: .capsule)
                        .layoutPriority(1)
                }
                Spacer(minLength: 4)
                if let reset = account.headlineResetsAt {
                    LiveAccountCountdown(expiry: reset, now: now)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(onDarkSurface ? Color.white.opacity(0.72) : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .layoutPriority(1)
                }
                Text(UsageText.widgetFigure(account.headlineRemainingPercent))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(2)
                if account.resetCardCount > 0 {
                    ResetCardCountBadge(count: account.resetCardCount)
                        .layoutPriority(2)
                }
            }
            LiveCompactMeter(remainingFraction: account.headlineRemainingPercent / 100, onDarkSurface: onDarkSurface)
        }
        .foregroundStyle(onDarkSurface ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    }

    private var roomyStack: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ProviderIcon(providerID: account.providerID, symbolName: account.symbolName)
                    .frame(width: 14, height: 14)
                Text(account.accountName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if account.isSoonestReset {
                    Text(UsageText.soonestBadge())
                        .font(.caption2.weight(.bold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 4)
                        .background(.orange.opacity(onDarkSurface ? 0.35 : 0.85), in: .capsule)
                        .layoutPriority(1)
                }
                Spacer(minLength: 4)
                if let reset = account.headlineResetsAt {
                    LiveAccountCountdown(expiry: reset, now: now)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(onDarkSurface ? Color.white.opacity(0.72) : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .layoutPriority(1)
                }
                Text(UsageText.widgetFigure(account.headlineRemainingPercent))
                    .font((interfaceStyle == .screenTime ? Font.subheadline.weight(.bold) : Font.caption).monospacedDigit())
                    .foregroundStyle(interfaceStyle == .screenTime ? AnyShapeStyle(tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(2)
            }
            UsageMeter(
                remainingFraction: account.headlineRemainingPercent / 100,
                prominent: interfaceStyle == .screenTime
            )
            if let secondary = account.secondaryTitle, let percent = account.secondaryRemainingPercent {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(secondary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(UsageText.widgetFigure(percent))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(1)
                }
            }
            if account.resetCardCount > 0 {
                ResetCardAccountRow(
                    count: account.resetCardCount,
                    expiresAt: account.resetCardExpiresAt,
                    now: now,
                    onDarkSurface: onDarkSurface
                )
            }
        }
        .foregroundStyle(onDarkSurface ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    }

    private var tint: Color {
        UsageMeterTint.color(
            remainingFraction: account.headlineRemainingPercent / 100,
            colorScheme: onDarkSurface ? .dark : colorScheme
        )
    }
}

/// Equal-width percent chips for the compact island.
///
/// The chip is only as wide as the percent, so the account nearest the camera
/// sits against the cutout instead of behind a pad of empty black.
struct LiveCompactCluster: View {
    var accounts: [UsageActivityAccountRow]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(accounts) { account in
                VStack(spacing: 0) {
                    ProviderIcon(providerID: account.providerID, symbolName: account.symbolName)
                        .frame(width: 13, height: 13)
                    Text(UsageText.widgetFigure(account.headlineRemainingPercent))
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .frame(width: 24)
                .accessibilityElement(children: .combine)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
    }
}

private struct LiveAccountCountdown: View {
    var expiry: Date
    var now: Date?

    var body: some View {
        if let now {
            Text(CountdownDisplay.compactString(until: expiry, from: now))
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(CountdownDisplay.compactString(until: expiry, from: context.date))
            }
        }
    }
}

private struct LiveCompactMeter: View {
    var remainingFraction: Double
    var onDarkSurface: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.quotaPercentBasis) private var basis

    var body: some View {
        let remaining = min(1, max(0, remainingFraction))
        let fill = basis.fillFraction(remainingFraction: remaining)
        let tint = UsageMeterTint.color(
            remainingFraction: remaining,
            colorScheme: onDarkSurface ? .dark : colorScheme
        )
        Capsule()
            .fill(Color.primary.opacity(0.16))
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(tint)
                    .scaleEffect(x: max(fill, fill > 0 ? 0.02 : 0), y: 1, anchor: .leading)
            }
            .frame(height: 3)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}
#endif
