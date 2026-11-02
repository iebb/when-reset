import Foundation

enum UsageNotificationCopy {
    static func format(_ key: String.LocalizationValue, _ args: CVarArg...) -> String {
        String(format: String.localized(key), locale: AppLanguage.current.locale, arguments: args)
    }
}
