import Foundation

/// Shared helpers for tolerant provider JSON. Payloads mix snake_case,
/// camelCase and spaced keys, so lookups compare normalized keys.
enum JSONKeys {
    static func normalize(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Normalizes every key. Keys that collide after normalization (for
    /// example `input_tokens` and `inputTokens`) keep the value of the
    /// lexicographically first original key, so the result is deterministic
    /// and a collision can never trap.
    static func normalizedDictionary(_ dictionary: [String: Any]) -> [String: Any] {
        var output: [String: Any] = [:]
        for key in dictionary.keys.sorted() {
            let normalized = normalize(key)
            if output[normalized] == nil { output[normalized] = dictionary[key] }
        }
        return output
    }
}

/// Cached date formatters. Creating formatters is expensive and these run for
/// every history row of every refresh. Date formatters are thread-safe for
/// parsing and formatting on macOS 10.9 and later.
enum FlexibleDate {
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()

    private static let localFormatters: [DateFormatter] = [
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
    ].map(posixFormatter)

    /// `yyyy-MM-dd` in the user's current time zone.
    static let dayKey = posixFormatter("yyyy-MM-dd")

    static func posixFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = format
        return formatter
    }

    static func iso8601(_ text: String) -> Date? {
        isoFractional.date(from: text) ?? isoPlain.date(from: text)
    }

    static func iso8601String(_ date: Date) -> String {
        isoPlain.string(from: date)
    }

    /// Patterns for short chart and axis labels in each interface language.
    enum LabelStyle {
        case day, dayTime, monthYear

        fileprivate var englishPattern: String {
            switch self {
            case .day: return "MMM d"
            case .dayTime: return "MMM d HH:mm"
            case .monthYear: return "MMM yy"
            }
        }

        fileprivate var chinesePattern: String {
            switch self {
            case .day: return "M月d日"
            case .dayTime: return "M月d日 HH:mm"
            case .monthYear: return "yy年M月"
            }
        }
    }

    private static let englishLabelFormatters: [LabelStyle: DateFormatter] = [
        .day: posixFormatter(LabelStyle.day.englishPattern),
        .dayTime: posixFormatter(LabelStyle.dayTime.englishPattern),
        .monthYear: posixFormatter(LabelStyle.monthYear.englishPattern),
    ]
    private static let chineseLabelFormatters: [LabelStyle: DateFormatter] = [
        .day: posixFormatter(LabelStyle.day.chinesePattern),
        .dayTime: posixFormatter(LabelStyle.dayTime.chinesePattern),
        .monthYear: posixFormatter(LabelStyle.monthYear.chinesePattern),
    ]

    /// "Sep 8" in English, "9月8日" in Chinese. Pass `calendar` when the
    /// caller works in a specific calendar/time zone (reports, tests).
    static func label(_ date: Date, style: LabelStyle, calendar: Calendar? = nil) -> String {
        if let calendar = calendar {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = L10n.usesChinese ? style.chinesePattern : style.englishPattern
            return formatter.string(from: date)
        }
        let table = L10n.usesChinese ? chineseLabelFormatters : englishLabelFormatters
        return table[style]!.string(from: date)
    }

    /// Accepts epoch seconds or milliseconds, ISO 8601, and local
    /// `yyyy-MM-dd[ HH:mm[:ss]]` strings.
    static func parse(_ value: Any) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        let text = String(describing: value)
        if let date = iso8601(text) { return date }
        for formatter in localFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
