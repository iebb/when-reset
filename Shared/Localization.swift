import Foundation
import SwiftUI

/// Interface language. Matches Blinky Mac's override, limited to the languages this app ships.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case chineseSimplified

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .english: Locale(identifier: "en")
        case .chineseSimplified: Locale(identifier: "zh-Hans")
        }
    }

    var title: String {
        switch self {
        case .system: String.localized("System")
        case .english: "English"
        case .chineseSimplified: "简体中文"
        }
    }

    static let storageKey = "settings.language"

    static var current: AppLanguage {
        let raw = UserDefaults(suiteName: AppIdentity.appGroupIdentifier)?.string(forKey: storageKey)
            ?? UserDefaults.standard.string(forKey: storageKey)
        return AppLanguage(rawValue: raw ?? "") ?? .system
    }

    static func choose(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        let shared = UserDefaults(suiteName: AppIdentity.appGroupIdentifier)
        if language == .system {
            defaults.removeObject(forKey: storageKey)
            shared?.removeObject(forKey: storageKey)
        } else {
            defaults.set(language.rawValue, forKey: storageKey)
            shared?.set(language.rawValue, forKey: storageKey)
        }
        NotificationCenter.default.post(name: .blinkyLanguageChanged, object: language)
    }
}

extension Notification.Name {
    static let blinkyLanguageChanged = Notification.Name("blinky.language.changed")
}

extension String {
    static func localized(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: bundle(for: AppLanguage.current))
    }

    private static func bundle(for language: AppLanguage) -> Bundle {
        let name: String?
        switch language {
        case .system: name = nil
        case .english: name = "en"
        case .chineseSimplified: name = "zh-Hans"
        }
        guard let name,
              let path = Bundle.main.path(forResource: name, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }
}

extension Text {
    init(localized key: String.LocalizationValue) {
        self.init(String.localized(key))
    }
}

enum UpdatedCaption {
    /// One caption: "Updated 12s ago" / "12 秒前更新".
    static func phrase(since date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date).rounded(.down)))
        let locale = AppLanguage.current.locale
        let body: String
        if seconds < 60 {
            body = String(format: String.localized("%llds ago"), locale: locale, Int64(seconds))
        } else if seconds < 3_600 {
            body = String(format: String.localized("%lldm ago"), locale: locale, Int64(seconds / 60))
        } else if seconds < 86_400 {
            body = String(format: String.localized("%lldh ago"), locale: locale, Int64(seconds / 3_600))
        } else {
            body = String(format: String.localized("%lldd ago"), locale: locale, Int64(seconds / 86_400))
        }
        return String(format: String.localized("Updated %@"), locale: locale, body)
    }
}

enum BankedResetCopy {
    /// One collapsed line. The credit is already usable; `expiresAt` is when
    /// that credit can no longer be spent, not when it becomes available.
    static func collapsedLine(count: Int, expiresAt: Date?, now: Date) -> String {
        let locale = AppLanguage.current.locale
        let name = count == 1
            ? String.localized("1 banked reset")
            : String(format: String.localized("%lld banked resets"), locale: locale, Int64(max(count, 0)))
        guard let expiresAt, expiresAt > now else { return name }
        let when = expiresPhrase(until: expiresAt, from: now, soonestOfMany: count > 1)
        return "\(name) · \(when)"
    }

    static func expiresPhrase(until expiry: Date, from now: Date, soonestOfMany: Bool) -> String {
        let remaining = max(0, Int(expiry.timeIntervalSince(now).rounded(.down)))
        let locale = AppLanguage.current.locale
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60
        let body: String
        if days > 0 {
            body = hours > 0
                ? String(format: String.localized("%lldd %lldh"), locale: locale, Int64(days), Int64(hours))
                : String(format: String.localized("%lldd"), locale: locale, Int64(days))
        } else if hours > 0 {
            body = minutes > 0
                ? String(format: String.localized("%lldh %02lldm"), locale: locale, Int64(hours), Int64(minutes))
                : String(format: String.localized("%lldh"), locale: locale, Int64(hours))
        } else {
            body = String(format: String.localized("%lldm"), locale: locale, Int64(max(minutes, remaining == 0 ? 0 : 1)))
        }
        let key = soonestOfMany ? "next expires in %@" : "expires in %@"
        return String(
            format: String.localized(String.LocalizationValue(stringLiteral: key)),
            locale: locale,
            body
        )
    }
}

enum UsageText {
    /// In-app wording. Follows the remaining/used setting and keeps the word.
    static func remainingPercent(_ value: Double) -> String {
        QuotaPercentBasis.current.labeled(remainingPercent: value)
    }

    /// Widgets, the lock screen, and the Dynamic Island. The number only.
    static func widgetFigure(_ remainingPercent: Double) -> String {
        QuotaPercentBasis.current.figure(remainingPercent: remainingPercent)
    }

    static func soonestBadge() -> String {
        String.localized("Soonest")
    }
}
