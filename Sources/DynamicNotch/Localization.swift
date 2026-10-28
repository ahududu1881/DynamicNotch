import Foundation

enum Localization {
    /// Language code chosen in Settings ("en" / "tr"); nil follows the system language.
    nonisolated(unsafe) static var override: String?
}

extension AppLanguage {
    /// nil = follow the system.
    var code: String? { self == .system ? nil : rawValue }
}

/// Tiny Turkish/English switch; the UI only has a handful of strings. English is the fallback for every other language.
func L(_ tr: String, _ en: String) -> String {
    let code = Localization.override ?? Locale.preferredLanguages.first ?? "en"
    return code.hasPrefix("tr") ? tr : en
}
