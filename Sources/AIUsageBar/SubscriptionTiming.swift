import Foundation

struct SubscriptionTiming: Hashable {
    enum Kind: String, CaseIterable {
        case expires, renews
        var title: String { self == .expires ? L("Subscription expires") : L("Subscription renews") }
    }

    let date: Date
    let kind: Kind
    let isManual: Bool
    /// Derived from when the subscription started, not reported as a renewal date.
    var isEstimated = false
    /// A manual date that passed while the plan stayed active, moved on by whole months.
    var rolledForward = false

    static func preferenceKey(for snapshot: ProviderSnapshot) -> String {
        // Claude CLI metadata may identify an account without changing its history ID.
        let identity = snapshot.id + "::" + (snapshot.accountDisplayName?.lowercased() ?? "")
        return "subscriptionDate.\(snapshot.provider).\(StableIdentifier.hash(identity))"
    }

    /// Dates the provider reports come first, then the one entered for this
    /// account, then a monthly renewal estimated from when the subscription
    /// started. While the plan is still `active`, a manual date that has
    /// passed moves to the same day of the next month, since the plan renewed.
    static func resolve(expires: Date?, renews: Date?, manual: String, started: Date? = nil,
                        active: Bool = false, now: Date = Date(), calendar: Calendar = .current) -> Self? {
        if let date = expires { return Self(date: date, kind: .expires, isManual: false) }
        if let date = renews { return Self(date: date, kind: .renews, isManual: false) }
        let parts = manual.split(separator: "|", omittingEmptySubsequences: false)
        if parts.count == 2, let kind = Kind(rawValue: String(parts[0])),
           let date = dayFormatter.date(from: String(parts[1])),
           dayFormatter.string(from: date) == parts[1]
        {
            guard active else { return Self(date: date, kind: kind, isManual: true) }
            let next = nextMonthly(from: date, onOrAfter: calendar.startOfDay(for: now), calendar: calendar)
            return Self(date: next, kind: kind, isManual: true, rolledForward: next != date)
        }
        guard let started = started, started <= now else { return nil }
        let next = nextMonthly(from: started, onOrAfter: now.addingTimeInterval(1), calendar: calendar)
        return Self(date: next, kind: .renews, isManual: false, isEstimated: true)
    }

    /// The first of `anchor`, one month later, two months later, … that is on
    /// or after `limit`. Counted from the anchor, so the 31st stays the 31st
    /// (or the month's last day) instead of drifting.
    static func nextMonthly(from anchor: Date, onOrAfter limit: Date, calendar: Calendar = .current) -> Date {
        guard anchor < limit else { return anchor }
        let months = calendar.dateComponents([.month], from: anchor, to: limit).month ?? 0
        for offset in max(0, months)...(max(0, months) + 2) {
            if let date = calendar.date(byAdding: .month, value: offset, to: anchor), date >= limit { return date }
        }
        return anchor
    }

    static func encode(date: Date, kind: Kind) -> String {
        kind.rawValue + "|" + dayFormatter.string(from: date)
    }

    private static var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    var dateText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = isManual ? .none : .short
        return formatter.string(from: date)
    }

    func status(now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                          to: calendar.startOfDay(for: date)).day ?? 0
        if days < 0 || (!isManual && date <= now) {
            return kind == .expires ? L("Expiry date passed") : L("Renewal date passed")
        }
        return days == 0 ? L("Today") : days == 1 ? L("1 day left") : L("%d days left", days)
    }
}
