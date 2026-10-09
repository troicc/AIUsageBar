import Foundation

/// Interface language. `system` follows the user's macOS language order.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// Shown in the language picker in each language's own name.
    var pickerTitle: String {
        switch self {
        case .system: return L("Follow System")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}

/// In-code string tables. The English text is the key, so English output is
/// unchanged and a missing translation falls back to English. Tables live in
/// `L10n+*.swift`, one per UI area, and are merged here.
enum L10n {
    static let languageDefaultsKey = "appLanguage"

    static var language: AppLanguage {
        get {
            UserDefaults.standard.string(forKey: languageDefaultsKey)
                .flatMap(AppLanguage.init(rawValue:)) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: languageDefaultsKey)
            cachedUsesChinese = nil
        }
    }

    private static var cachedUsesChinese: Bool?

    /// Whether strings resolve to Simplified Chinese right now.
    static var usesChinese: Bool {
        if let cached = cachedUsesChinese { return cached }
        let resolved: Bool
        switch language {
        case .english: resolved = false
        case .simplifiedChinese: resolved = true
        case .system:
            // Only the app follows the system language. Command-line
            // regression tests compile these sources too and must keep
            // producing the English strings they assert on.
            let isAppBundle = Bundle.main.bundleURL.pathExtension == "app"
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            resolved = isAppBundle && preferred.hasPrefix("zh")
        }
        cachedUsesChinese = resolved
        return resolved
    }

    static let simplifiedChinese: [String: String] = {
        var table: [String: String] = [:]
        for part in [L10nTable.menu, L10nTable.settings, L10nTable.dashboard, L10nTable.data, L10nTable.design] {
            table.merge(part) { first, _ in first }
        }
        return table
    }()

    static func translate(_ english: String) -> String {
        guard usesChinese else { return english }
        return simplifiedChinese[english] ?? english
    }
}

/// Namespace for the per-area translation tables.
enum L10nTable {}

/// Localizes a user-visible string. Pass the exact English text.
func L(_ english: String) -> String {
    L10n.translate(english)
}

/// Localizes a format string (`%@`, `%d`, `%.0f`…) and fills it in. The
/// translated format must use the same placeholders in the same order.
func L(_ englishFormat: String, _ arguments: CVarArg...) -> String {
    String(format: L10n.translate(englishFormat), arguments: arguments)
}
