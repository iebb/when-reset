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

    fileprivate static func reloadWidgets() {
        #if canImport(WidgetKit)
        Task { @MainActor in
            WidgetCenter.shared.reloadAllTimelines()
        }
        #endif
    }
}

/// How a remaining-allowance meter is drawn. Segmented is the default.
enum UsageBarStyle: String, CaseIterable, Identifiable, Sendable {
    case segmented
    case continuous

    var id: String { rawValue }

    static let `default` = UsageBarStyle.segmented
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
    func blinkyUsageChrome(colorScheme: ColorScheme? = AppAppearance.current.colorScheme) -> some View {
        environment(\.locale, AppLanguage.current.locale)
            .environment(\.usageBarStyle, UsageBarStyle.current)
            .preferredColorScheme(colorScheme)
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

    nonisolated static let continuousHeight: CGFloat = 6
    nonisolated static let segmentedHeight: CGFloat = 12
    nonisolated static let tickWidth: CGFloat = 2.5
    nonisolated static let tickGap: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(fraction, 0), 1)
            switch style {
            case .continuous:
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    Capsule().fill(accent).frame(width: max(0, proxy.size.width * clamped))
                }
            case .segmented:
                let ticks = Self.ticks(width: proxy.size.width, fraction: clamped, scale: scale)
                HStack(spacing: Self.tickGap * scale) {
                    ForEach(0..<ticks.count, id: \.self) { index in
                        Capsule()
                            .fill(index < ticks.lit ? accent : track)
                            .frame(width: Self.tickWidth * scale)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
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
    @Environment(\.usageBarStyle) private var style
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        UsageBar(
            fraction: remainingFraction,
            accent: UsageMeterTint.color(remainingFraction: remainingFraction, colorScheme: colorScheme),
            track: Color.primary.opacity(0.16),
            style: style
        )
        .frame(maxWidth: .infinity)
        .frame(height: style.barHeight)
    }
}
