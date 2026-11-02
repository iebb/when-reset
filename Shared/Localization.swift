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

enum UsageText {
    static func remainingPercent(_ value: Double) -> String {
        let percent = Int(value.rounded())
        return String(format: String.localized("%lld%% left"), locale: AppLanguage.current.locale, percent)
    }

    static func soonestBadge() -> String {
        String.localized("Soonest")
    }
}
