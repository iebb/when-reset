import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Light, dark, or whatever the system is using.
enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    static let storageKey = "settings.appearance"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var title: String {
        switch self {
        case .system: String.localized("System")
        case .light: String.localized("Light")
        case .dark: String.localized("Dark")
        }
    }

    static var current: AppAppearance {
        let raw = UserDefaults(suiteName: AppIdentity.appGroupIdentifier)?.string(forKey: storageKey)
            ?? UserDefaults.standard.string(forKey: storageKey)
        return AppAppearance(rawValue: raw ?? "") ?? .system
    }

    static func choose(_ appearance: AppAppearance) {
        let defaults = UserDefaults.standard
        let shared = UserDefaults(suiteName: AppIdentity.appGroupIdentifier)
        if appearance == .system {
            defaults.removeObject(forKey: storageKey)
            shared?.removeObject(forKey: storageKey)
        } else {
            defaults.set(appearance.rawValue, forKey: storageKey)
            shared?.set(appearance.rawValue, forKey: storageKey)
        }
        reloadWidgets()
        NotificationCenter.default.post(name: .blinkyAppearanceChanged, object: appearance)
    }

    static func reloadWidgets() {
        #if canImport(WidgetKit)
        Task { @MainActor in
            WidgetCenter.shared.reloadAllTimelines()
        }
        #endif
    }
}

/// How the usage cards are drawn. Independent of light, dark, or system theme.
enum InterfaceStyle: String, CaseIterable, Identifiable, Sendable {
    case classic
    case screenTime
    case liquidGlass

    var id: String { rawValue }

    static let `default` = InterfaceStyle.liquidGlass
    static let storageKey = "settings.interfaceStyle"

    var title: String {
        switch self {
        case .classic: String.localized("Classic")
        case .screenTime: String.localized("Screen Time")
        case .liquidGlass: String.localized("Liquid Glass")
        }
    }

    static var current: InterfaceStyle {
        let raw = UserDefaults(suiteName: AppIdentity.appGroupIdentifier)?.string(forKey: storageKey)
            ?? UserDefaults.standard.string(forKey: storageKey)
        return InterfaceStyle(rawValue: raw ?? "") ?? .default
    }

    static func choose(_ style: InterfaceStyle) {
        UserDefaults.standard.set(style.rawValue, forKey: storageKey)
        UserDefaults(suiteName: AppIdentity.appGroupIdentifier)?.set(style.rawValue, forKey: storageKey)
        AppAppearance.reloadWidgets()
        NotificationCenter.default.post(name: .blinkyInterfaceStyleChanged, object: style)
    }
}

private struct InterfaceStyleKey: EnvironmentKey {
    static let defaultValue = InterfaceStyle.default
}

extension EnvironmentValues {
    var interfaceStyle: InterfaceStyle {
        get { self[InterfaceStyleKey.self] }
        set { self[InterfaceStyleKey.self] = newValue }
    }
}

/// What a quota percentage and its bar represent.
///
/// Remaining is the default: 75% and a bar filled to 75% means three quarters
/// are left. Used inverts both the number and the fill. The color stays tied
/// to how much is left, so a full used bar is still the warning color.
enum QuotaPercentBasis: String, CaseIterable, Identifiable, Sendable {
    case remaining
    case used

    var id: String { rawValue }

    static let storageKey = "settings.quotaPercentBasis"
    static let `default` = QuotaPercentBasis.remaining

    var title: String {
        switch self {
        case .remaining: String.localized("Remaining")
        case .used: String.localized("Used")
        }
    }

    static var current: QuotaPercentBasis {
        let raw = UserDefaults(suiteName: AppIdentity.appGroupIdentifier)?.string(forKey: storageKey)
            ?? UserDefaults.standard.string(forKey: storageKey)
        return QuotaPercentBasis(rawValue: raw ?? "") ?? .default
    }

    static func choose(_ basis: QuotaPercentBasis) {
        UserDefaults.standard.set(basis.rawValue, forKey: storageKey)
        UserDefaults(suiteName: AppIdentity.appGroupIdentifier)?.set(basis.rawValue, forKey: storageKey)
        AppAppearance.reloadWidgets()
        NotificationCenter.default.post(name: .blinkyQuotaPercentBasisChanged, object: basis)
    }

    func displayed(remainingPercent: Double) -> Int {
        let remaining = min(100, max(0, remainingPercent))
        switch self {
        case .remaining:
            return Int(remaining.rounded())
        case .used:
            return Int((100 - remaining).rounded())
        }
    }

    /// Bare number for widgets and Live Activity. No "剩余" or "已用".
    func figure(remainingPercent: Double) -> String {
        "\(displayed(remainingPercent: remainingPercent))%"
    }

    /// In-app label. Widgets do not use this.
    func labeled(remainingPercent: Double) -> String {
        let percent = Int64(displayed(remainingPercent: remainingPercent))
        let key = self == .remaining ? "%lld%% left" : "%lld%% used"
        return String(
            format: String.localized(String.LocalizationValue(stringLiteral: key)),
            locale: AppLanguage.current.locale,
            percent
        )
    }

    func fillFraction(remainingFraction: Double) -> Double {
        let remaining = min(1, max(0, remainingFraction))
        return self == .used ? 1 - remaining : remaining
    }
}

private struct QuotaPercentBasisKey: EnvironmentKey {
    static let defaultValue = QuotaPercentBasis.default
}

extension EnvironmentValues {
    var quotaPercentBasis: QuotaPercentBasis {
        get { self[QuotaPercentBasisKey.self] }
        set { self[QuotaPercentBasisKey.self] = newValue }
    }
}

extension Notification.Name {
    static let blinkyQuotaPercentBasisChanged = Notification.Name("blinky.quotaPercentBasis.changed")
}

/// How a remaining-allowance meter is drawn. Continuous is the default.
enum UsageBarStyle: String, CaseIterable, Identifiable, Sendable {
    case continuous
    case segmented

    var id: String { rawValue }

    static let `default` = UsageBarStyle.continuous
    static let storageKey = "settings.usageBarStyle"

    var title: String {
        switch self {
        case .segmented: String.localized("Segmented")
        case .continuous: String.localized("Continuous")
        }
    }

    var barHeight: CGFloat {
        self == .segmented ? UsageBar.segmentedHeight : UsageBar.continuousHeight
    }

    static var current: UsageBarStyle {
        let raw = UserDefaults(suiteName: AppIdentity.appGroupIdentifier)?.string(forKey: storageKey)
            ?? UserDefaults.standard.string(forKey: storageKey)
        return UsageBarStyle(rawValue: raw ?? "") ?? .default
    }

    static func choose(_ style: UsageBarStyle) {
        let defaults = UserDefaults.standard
        let shared = UserDefaults(suiteName: AppIdentity.appGroupIdentifier)
        defaults.set(style.rawValue, forKey: storageKey)
        shared?.set(style.rawValue, forKey: storageKey)
        AppAppearance.reloadWidgets()
        NotificationCenter.default.post(name: .blinkyUsageBarStyleChanged, object: style)
    }
}

extension Notification.Name {
    static let blinkyAppearanceChanged = Notification.Name("blinky.appearance.changed")
    static let blinkyUsageBarStyleChanged = Notification.Name("blinky.usageBarStyle.changed")
    static let blinkyInterfaceStyleChanged = Notification.Name("blinky.interfaceStyle.changed")
}

private struct UsageBarStyleKey: EnvironmentKey {
    static let defaultValue = UsageBarStyle.default
}

extension EnvironmentValues {
    var usageBarStyle: UsageBarStyle {
        get { self[UsageBarStyleKey.self] }
        set { self[UsageBarStyleKey.self] = newValue }
    }
}

extension View {
    /// Locale, bar style, and color scheme as stored in settings.
    /// Widget and Live Activity roots use this because they are not inside the app scene.
    /// Pass `.dark` for surfaces that stay on a black background, such as the Dynamic Island.
    ///
    /// A stored light or dark choice is applied as the `colorScheme` environment,
    /// not `preferredColorScheme`: WidgetKit ignores `preferredColorScheme`, so
    /// widgets and Live Activities kept following the system theme. Nil leaves
    /// the system appearance alone.
    func blinkyUsageChrome(colorScheme: ColorScheme? = AppAppearance.current.colorScheme) -> some View {
        modifier(StoredColorSchemeOverride(scheme: colorScheme))
            .environment(\.locale, AppLanguage.current.locale)
            .environment(\.usageBarStyle, UsageBarStyle.current)
            .environment(\.interfaceStyle, InterfaceStyle.current)
            .environment(\.quotaPercentBasis, QuotaPercentBasis.current)
    }
}

private struct StoredColorSchemeOverride: ViewModifier {
    var scheme: ColorScheme?

    func body(content: Content) -> some View {
        if let scheme {
            content.environment(\.colorScheme, scheme)
        } else {
            content
        }
    }
}

/// Remaining-allowance color. Green while comfortable, warning red at or below
/// 25% left, and a deeper red when nothing is left. Matches Mac's Red alert
/// thresholds (warn at 75% used).
enum UsageMeterTint {
    static func color(remainingFraction: Double, colorScheme: ColorScheme) -> Color {
        let remaining = min(max(remainingFraction, 0), 1)
        let dark = colorScheme == .dark
        if remaining <= 0 {
            return dark
                ? Color(red: 0.85, green: 0.09, blue: 0.13)
                : Color(red: 0.68, green: 0.06, blue: 0.10)
        }
        if remaining <= 0.25 {
            return dark
                ? Color(red: 1.00, green: 0.31, blue: 0.26)
                : Color(red: 0.87, green: 0.22, blue: 0.17)
        }
        return dark
            ? Color(red: 0.00, green: 0.90, blue: 0.55)
            : Color(red: 0.00, green: 0.58, blue: 0.35)
    }
}

/// A limit's bar, continuous or segmented.
///
/// Segmented is a row of thin ticks across the same width, lit up to the
/// fraction: every tick the same, the gaps the same, as many as fit. A
/// fraction above zero always lights at least one, so a limit just touched
/// does not read as untouched; a fraction short of whole never lights the
/// last, so a limit nearly spent does not read as spent.
struct UsageBar: View {
    let fraction: Double
    let accent: Color
    let track: Color
    let style: UsageBarStyle
    var scale: CGFloat = 1
    var cap: UsageMeterCap = .round

    nonisolated static let continuousHeight: CGFloat = 6
    nonisolated static let segmentedHeight: CGFloat = 12
    nonisolated static let tickWidth: CGFloat = 2.5
    nonisolated static let tickGap: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(fraction, 0), 1)
            switch style {
            case .continuous:
                let width = max(0, proxy.size.width * clamped)
                switch cap {
                case .round:
                    ZStack(alignment: .leading) {
                        Capsule().fill(track)
                        Capsule().fill(accent).frame(width: width)
                    }
                case .square:
                    let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
                    ZStack(alignment: .leading) {
                        shape.fill(track)
                        shape.fill(accent).frame(width: width)
                    }
                }
            case .segmented:
                let ticks = Self.ticks(width: proxy.size.width, fraction: clamped, scale: scale)
                HStack(spacing: Self.tickGap * scale) {
                    ForEach(0..<ticks.count, id: \.self) { index in
                        tick(index < ticks.lit ? accent : track, width: Self.tickWidth * scale)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func tick(_ color: Color, width: CGFloat) -> some View {
        switch cap {
        case .round:
            Capsule().fill(color).frame(width: width)
        case .square:
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(color)
                .frame(width: width)
        }
    }

    nonisolated static func ticks(width: CGFloat, fraction: Double, scale: CGFloat = 1) -> (count: Int, lit: Int) {
        let step = (tickWidth + tickGap) * scale
        let count = max(Int(((width + tickGap * scale) / step).rounded(.down)), 1)
        let clamped = min(max(fraction, 0), 1)
        var lit = Int((clamped * Double(count)).rounded())
        if clamped > 0 { lit = max(lit, 1) }
        if clamped < 1 { lit = min(lit, count - 1) }
        return (count, clamped >= 1 ? count : lit)
    }
}

/// Remaining-fraction meter used on cards, widgets, and Live Activity.
struct UsageMeter: View {
    var remainingFraction: Double
    /// Usage cards draw a thicker continuous bar. Widgets stay compact.
    var prominent: Bool = false
    @Environment(\.usageBarStyle) private var style
    @Environment(\.interfaceStyle) private var interfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    @Environment(\.quotaPercentBasis) private var percentBasis

    var body: some View {
        let metrics = interfaceStyle.continuousMeter(prominent: prominent)
        let continuous = style == .continuous
        let remaining = min(1, max(0, remainingFraction))
        UsageBar(
            fraction: percentBasis.fillFraction(remainingFraction: remaining),
            accent: UsageMeterTint.color(remainingFraction: remaining, colorScheme: colorScheme),
            track: Color.primary.opacity(continuous ? metrics.trackOpacity : 0.16),
            style: style,
            cap: metrics.cap
        )
        .frame(maxWidth: .infinity)
        .frame(height: continuous ? metrics.height : style.barHeight)
    }
}
