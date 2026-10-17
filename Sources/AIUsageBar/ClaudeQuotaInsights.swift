import Foundation

/// How the quota trend is drawn: with pace, projections and usage insights,
/// or the earlier classic charts.
enum QuotaChartMode: String, CaseIterable, Identifiable {
    case insights
    case classic

    static let preferenceKey = "quotaChartMode"

    var id: String { rawValue }
    var title: String { L(self == .insights ? "Insights" : "Classic") }
}

/// How fast the current window is being used, against an even pace through it.
struct QuotaPace: Hashable {
    let cycle: DateInterval
    let usedPercent: Double
    /// Where an even pace through the window would be now.
    let evenPercent: Double
    /// Percentage points per hour over the recent look-back.
    let ratePerHour: Double
    /// When the window runs out at that rate, if before it resets; when it
    /// ran out, if it already has.
    var runsOutAt: Date?
    let isExhausted: Bool
    /// False while the window is too young for its rate to mean much.
    var isMeasured = true
    /// The projected used share hour by hour from now, shaped by the usual
    /// rhythm of the week; empty when the forecast is a straight line.
    var forecast: [Point] = []
    /// The rhythm the forecast follows, and the factor that matches it to the recent rate.
    var rhythm: QuotaUsageRhythm?
    var rhythmScale: Double = 0

    struct Point: Hashable {
        let date: Date
        let percent: Double
    }

    /// Whether the forecast leaves out the hours usually spent asleep or away.
    var followsRhythm: Bool { !forecast.isEmpty }

    /// Points ahead of (positive) or behind an even pace.
    var ahead: Double { usedPercent - evenPercent }

    /// Used share expected at the reset at the current rate, capped at 100.
    func projectedAtReset(now: Date) -> Double {
        if let last = forecast.last { return min(100, last.percent) }
        return min(100, usedPercent + ratePerHour * max(0, cycle.end.timeIntervalSince(now)) / 3600)
    }

    /// The used share the forecast expects at `date` (kept between now and
    /// the reset), capped at 100.
    func projectedPercent(at date: Date, now: Date) -> Double {
        let date = min(max(date, now), cycle.end)
        guard followsRhythm else { return min(100, usedPercent + ratePerHour * date.timeIntervalSince(now) / 3600) }
        var previous = Point(date: now, percent: usedPercent)
        for point in forecast {
            if date <= point.date {
                let span = point.date.timeIntervalSince(previous.date)
                let fraction = span > 0 ? date.timeIntervalSince(previous.date) / span : 1
                return previous.percent + (point.percent - previous.percent) * fraction
            }
            previous = point
        }
        return min(100, previous.percent)
    }
}

/// How use is usually spread over the week, from the history: average
/// points an hour by weekday and hour. A forecast that follows it adds
/// nothing over the hours usually spent asleep or away.
struct QuotaUsageRhythm: Hashable {
    /// Points per hour, by weekday (0 is Monday) and hour.
    let grid: [[Double]]
    let calendar: Calendar

    /// An hour under this share of the average one counts as quiet.
    static let quietShare = 0.15

    var averageRate: Double { grid.joined().reduce(0, +) / 168 }

    func rate(at date: Date) -> Double {
        let slot = Self.slot(date, calendar: calendar)
        return grid[slot.weekday][slot.hour]
    }

    func isQuiet(at date: Date) -> Bool { rate(at: date) < averageRate * Self.quietShare }

    /// Points expected over `interval` at the usual rate of each hour.
    func points(in interval: DateInterval) -> Double {
        Self.hours(in: interval, calendar: calendar).reduce(0) { $0 + rate(at: $1.start) * $1.duration / 3600 }
    }

    static func slot(_ date: Date, calendar: Calendar) -> (weekday: Int, hour: Int) {
        let components = calendar.dateComponents([.weekday, .hour], from: date)
        return (((components.weekday ?? 2) + 5) % 7, components.hour ?? 0)
    }

    /// `interval` cut at each hour boundary.
    static func hours(in interval: DateInterval, calendar: Calendar) -> [DateInterval] {
        var pieces: [DateInterval] = []
        var start = interval.start
        while start < interval.end {
            let end = min(interval.end, calendar.dateInterval(of: .hour, for: start)?.end ?? interval.end)
            guard end > start else { break }
            pieces.append(DateInterval(start: start, end: end))
            start = end
        }
        return pieces
    }

    /// The rhythm of the last `days`, once at least three days are recorded.
    /// Each rise is spread over the time between its two readings. A weekday's
    /// hour seen at least twice blends its own average with that hour's
    /// average over all days; otherwise the all-days average stands alone.
    static func make(from series: ClaudeQuotaSeries, now: Date, days: Double = 28,
                     calendar: Calendar = .current) -> QuotaUsageRhythm?
    {
        let since = now.addingTimeInterval(-days * 86_400)
        let recent = series.within(DateInterval(start: since, end: now))
        let samples = recent.samples
        guard let first = samples.first(where: { $0.timestamp >= since }),
              now.timeIntervalSince(first.timestamp) >= 3 * 86_400 else { return nil }
        var points = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        var seen = points
        for index in 1..<samples.count where samples[index - 1].timestamp >= since && samples[index].timestamp <= now {
            let amount = recent.consumed(before: index)
            guard amount > 0 else { continue }
            let end = samples[index].timestamp
            let span = DateInterval(start: min(end, recent.reset(before: index)?.start ?? samples[index - 1].timestamp), end: end)
            guard span.duration >= 1 else {
                let slot = Self.slot(end, calendar: calendar)
                points[slot.weekday][slot.hour] += amount
                continue
            }
            for piece in hours(in: span, calendar: calendar) {
                let slot = Self.slot(piece.start, calendar: calendar)
                points[slot.weekday][slot.hour] += amount * piece.duration / span.duration
            }
        }
        for piece in hours(in: DateInterval(start: first.timestamp, end: now), calendar: calendar) {
            let slot = Self.slot(piece.start, calendar: calendar)
            seen[slot.weekday][slot.hour] += piece.duration / 3600
        }
        guard points.joined().reduce(0, +) > 0 else { return nil }
        let hourly: [Double] = (0..<24).map { (hour: Int) -> Double in
            let total: Double = points.reduce(0.0) { $0 + $1[hour] }
            let hours: Double = seen.reduce(0.0) { $0 + $1[hour] }
            return hours > 0 ? total / hours : 0
        }
        let grid: [[Double]] = (0..<7).map { (weekday: Int) -> [Double] in
            (0..<24).map { (hour: Int) -> Double in
                let hours = seen[weekday][hour]
                return hours >= 2 ? (hourly[hour] + points[weekday][hour] / hours) / 2 : hourly[hour]
            }
        }
        return QuotaUsageRhythm(grid: grid, calendar: calendar)
    }
}

/// How many full five-hour windows a weekly window holds, day by day, and
/// where that changed: the visible trace of a change in the official limits.
struct QuotaScaleTrend: Hashable {
    struct Point: Hashable {
        let day: Date
        let windowsPerWeek: Double
    }

    struct Shift: Hashable {
        let day: Date
        let before: Double
        let after: Double
        var change: Double { after / before - 1 }
    }

    let points: [Point]
    /// Typical value now: the level since the latest change, or over the latest days.
    let current: Double?
    let shift: Shift?
}

/// When and how the 5-hour windows get used.
struct QuotaHabits: Hashable {
    /// Points of 5-hour quota used, per week, by weekday (0 is Monday) and hour.
    let grid: [[Double]]
    /// The two busiest hours of the day, busiest first.
    let peakHours: [Int]
    /// The longest stretch of hours with almost no use: its first hour and length.
    let quietStart: Int?
    let quietLength: Int
    /// Median time from a window's start until it was used up.
    let drainTime: TimeInterval?
    let windowsUsed: Int
    let windowsUsedUp: Int
}

struct ClaudeQuotaInsights: Hashable {
    let weeklyPace: QuotaPace?
    let fiveHourPace: QuotaPace?
    let scale: QuotaScaleTrend
    let habits: QuotaHabits
    /// This weekly window's speed against the previous one, as a ratio minus one.
    let paceChange: Double?

    /// Habits cover the last four weeks; the five-hour drain the last two.
    static func make(history: [ClaudeQuotaSeries], now: Date = Date(),
                     calendar: Calendar = .current) -> ClaudeQuotaInsights?
    {
        guard let fiveHour = history.first(where: { $0.id == "five-hour" }) else { return nil }
        let weekly = history.first { $0.id == "weekly" }
        return ClaudeQuotaInsights(
            weeklyPace: weeklyPace(history: history, now: now, calendar: calendar),
            fiveHourPace: fiveHour.pace(now: now, lookback: 3600),
            scale: weekly.map { scaleTrend(fiveHour: fiveHour, weekly: $0, calendar: calendar) }
                ?? QuotaScaleTrend(points: [], current: nil, shift: nil),
            habits: habits(fiveHour: fiveHour, now: now, calendar: calendar),
            paceChange: weekly.flatMap { paceChange(weekly: $0, now: now) })
    }

    /// The weekly window's pace, its forecast following the usual rhythm of
    /// the week (from the finer 5-hour readings when there are any).
    static func weeklyPace(history: [ClaudeQuotaSeries], now: Date = Date(),
                           calendar: Calendar = .current) -> QuotaPace?
    {
        guard let weekly = history.first(where: { $0.id == "weekly" }) else { return nil }
        let source = history.first { $0.id == "five-hour" } ?? weekly
        return weekly.pace(now: now, lookback: 86_400,
                           rhythm: QuotaUsageRhythm.make(from: source, now: now, calendar: calendar))
    }

    // MARK: Scale

    /// Readings carry whole percentages, so days with little weekly use are too noisy.
    static let minimumDailyWeeklyPoints: Double = 5

    static func scaleTrend(fiveHour: ClaudeQuotaSeries, weekly: ClaudeQuotaSeries,
                           calendar: Calendar = .current) -> QuotaScaleTrend
    {
        func daily(_ series: ClaudeQuotaSeries) -> [Date: Double] {
            var result: [Date: Double] = [:]
            for step in series.consumptionSteps() {
                result[calendar.startOfDay(for: step.timestamp), default: 0] += step.points
            }
            return result
        }
        let fiveHourDays = daily(fiveHour), weeklyDays = daily(weekly)
        let points = weeklyDays.keys.sorted().compactMap { day -> QuotaScaleTrend.Point? in
            guard let weeklyPoints = weeklyDays[day], weeklyPoints >= minimumDailyWeeklyPoints,
                  let fiveHourPoints = fiveHourDays[day], fiveHourPoints > 0 else { return nil }
            return QuotaScaleTrend.Point(day: day, windowsPerWeek: fiveHourPoints / weeklyPoints)
        }
        let values = points.map(\.windowsPerWeek)
        let change = shift(in: points)
        let current = change?.after ?? (values.isEmpty ? nil : median(Array(values.suffix(7))))
        return QuotaScaleTrend(points: points, current: current, shift: change)
    }

    /// The single split that best separates earlier from later days (the
    /// least spread around each side's median, on a log scale), when the
    /// typical value moved by at least `threshold` and each side has `minimumDays`.
    static func shift(in points: [QuotaScaleTrend.Point], minimumDays: Int = 3,
                      threshold: Double = 0.3) -> QuotaScaleTrend.Shift?
    {
        guard points.count >= minimumDays * 2 else { return nil }
        let logs = points.map { log(max(0.01, $0.windowsPerWeek)) }
        func spread(_ values: ArraySlice<Double>) -> Double {
            let middle = median(Array(values))
            return values.reduce(0) { $0 + abs($1 - middle) }
        }
        var best: (index: Int, cost: Double)?
        for index in minimumDays...(logs.count - minimumDays) {
            let cost = spread(logs[..<index]) + spread(logs[index...])
            if cost < (best?.cost ?? .infinity) - 1e-9 { best = (index, cost) }
        }
        guard let split = best?.index else { return nil }
        let values = points.map(\.windowsPerWeek)
        let before = median(Array(values[..<split])), after = median(Array(values[split...]))
        guard before > 0, abs(after / before - 1) >= threshold else { return nil }
        return QuotaScaleTrend.Shift(day: points[split].day, before: before, after: after)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    // MARK: Habits

    static func habits(fiveHour: ClaudeQuotaSeries, now: Date, calendar: Calendar = .current) -> QuotaHabits {
        let since = now.addingTimeInterval(-28 * 86_400)
        let steps = fiveHour.consumptionSteps(since: since)
        let first = steps.first?.timestamp ?? now
        let weeks = max(1, now.timeIntervalSince(max(since, first)) / (7 * 86_400))
        var grid = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        for step in steps {
            let weekday = (calendar.component(.weekday, from: step.timestamp) + 5) % 7
            grid[weekday][calendar.component(.hour, from: step.timestamp)] += step.points / weeks
        }
        let hourly: [Double] = (0..<24).map { (hour: Int) -> Double in grid.reduce(0.0) { $0 + $1[hour] } }
        let total: Double = hourly.reduce(0, +)
        // Busiest hours on a three-hour window, at least four hours apart.
        let smoothed: [Double] = (0..<24).map { (hour: Int) -> Double in
            let before: Double = hourly[(hour + 23) % 24], after: Double = hourly[(hour + 1) % 24]
            return before + hourly[hour] + after
        }
        var peaks: [Int] = []
        for hour in (0..<24).sorted(by: { smoothed[$0] > smoothed[$1] }) where total > 0 {
            if peaks.allSatisfy({ min(abs($0 - hour), 24 - abs($0 - hour)) >= 4 }) { peaks.append(hour) }
            if peaks.count == 2 { break }
        }
        // Quiet: hours under 2% of the day's use, the longest run (wrapping midnight).
        var quiet: (start: Int, length: Int)?
        if total > 0 {
            let still = hourly.map { $0 < total * 0.02 }
            for start in 0..<24 where still[start] && !still[(start + 23) % 24] {
                var length = 0
                while length < 24, still[(start + length) % 24] { length += 1 }
                if length > (quiet?.length ?? 2) { quiet = (start, length) }
            }
        }
        let recent = fiveHour.cycles().filter {
            $0.interval.end > now.addingTimeInterval(-14 * 86_400) && $0.interval.start <= now && $0.peakPercent > 0
        }
        let drains = recent.compactMap { cycle in
            cycle.exhausted.first.map { $0.start.timeIntervalSince(cycle.interval.start) }
        }.filter { $0 > 0 }
        return QuotaHabits(grid: grid, peakHours: peaks, quietStart: quiet?.start, quietLength: quiet?.length ?? 0,
                           drainTime: drains.isEmpty ? nil : median(drains),
                           windowsUsed: recent.count, windowsUsedUp: recent.filter { !$0.exhausted.isEmpty }.count)
    }

    // MARK: Pace change

    /// Points per hour in this weekly window so far, against the previous
    /// window up to when it was used up (or its end).
    static func paceChange(weekly: ClaudeQuotaSeries, now: Date) -> Double? {
        let cycles = weekly.cycles()
        guard cycles.count >= 2, let current = cycles.last, current.interval.end > now else { return nil }
        let previous = cycles[cycles.count - 2]
        let currentSpan = DateInterval(start: current.interval.start, end: now)
        let previousEnd = previous.exhausted.first?.start ?? previous.interval.end
        let previousSpan = DateInterval(start: previous.interval.start, end: max(previous.interval.start, previousEnd))
        guard currentSpan.duration >= 12 * 3600, previousSpan.duration >= 12 * 3600 else { return nil }
        let currentRate = weekly.consumedPoints(in: currentSpan) / currentSpan.duration
        let previousRate = weekly.consumedPoints(in: previousSpan) / previousSpan.duration
        guard previousRate > 0, currentRate > 0 else { return nil }
        return currentRate / previousRate - 1
    }
}

extension ClaudeQuotaSeries {
    /// Pace of the window that contains `now`, from its readings over the last
    /// `lookback`; the rate needs at least a quarter of that to project from.
    /// With a `rhythm`, the forecast spreads that rate over the coming hours
    /// as usual use does, flat through the quiet ones.
    func pace(now: Date, lookback: TimeInterval, rhythm: QuotaUsageRhythm? = nil) -> QuotaPace? {
        guard let cycle = cycles().last, cycle.interval.start <= now, cycle.interval.end > now,
              let latest = samples.last, latest.resetsAt != nil else { return nil }
        let interval = cycle.interval
        let even = min(100, max(0, now.timeIntervalSince(interval.start) / max(1, interval.duration) * 100))
        let span = DateInterval(start: max(interval.start, now.addingTimeInterval(-lookback)), end: now)
        let measured = span.duration >= lookback / 4
        let rate = measured ? consumedPoints(in: span) / span.duration * 3600 : 0
        let used = latest.usedPercent
        var runsOut: Date?
        if used >= 100 {
            runsOut = cycle.exhausted.last?.start
        } else if measured, rate > 0.01 {
            let date = now.addingTimeInterval((100 - used) / rate * 3600)
            if date < interval.end { runsOut = date }
        }
        var result = QuotaPace(cycle: interval, usedPercent: used, evenPercent: even, ratePerHour: rate,
                               runsOutAt: runsOut, isExhausted: used >= 100, isMeasured: measured || used >= 100)
        // The rhythm sets the shape; the recent rate sets the level. It needs the
        // look-back to cover a fair share of usual use to scale from.
        if let rhythm = rhythm, measured, used < 100, rate > 0.01 {
            let expected = rhythm.points(in: span)
            if expected > 0, expected >= rhythm.averageRate * span.duration / 3600 * 0.3 {
                let factor = consumedPoints(in: span) / expected
                var level = used
                var points: [QuotaPace.Point] = []
                runsOut = nil
                for piece in QuotaUsageRhythm.hours(in: DateInterval(start: now, end: interval.end), calendar: rhythm.calendar) {
                    let added = factor * rhythm.rate(at: piece.start) * piece.duration / 3600
                    if level + added >= 100 {
                        let date = piece.start.addingTimeInterval((100 - level) / added * piece.duration)
                        points.append(QuotaPace.Point(date: date, percent: 100))
                        runsOut = date
                        break
                    }
                    level += added
                    points.append(QuotaPace.Point(date: piece.end, percent: level))
                }
                result.runsOutAt = runsOut
                result.forecast = points
                result.rhythm = rhythm
                result.rhythmScale = factor
            }
        }
        return result
    }
}
