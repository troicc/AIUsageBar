import Foundation

/// Everything the trend shows that stays the same while it is scrolled or
/// hovered: the lanes and their windows, the pace and its forecast, and the
/// current range. Working these out reads the whole history, so they are
/// built once per history, window and style (see `QuotaTrendCache`), and a
/// frame of a drag only cuts the visible stretch out of them.
struct QuotaTrendFacts {
    let now: Date
    let lane: ClaudeQuotaSeries?
    let weeklyLane: ClaudeQuotaSeries?
    let fiveHourLane: ClaudeQuotaSeries?
    /// The shown lane, and the weekly one drawn under the 5-hour line, thinned
    /// for drawing once for the whole history, so the curve keeps its shape while scrolled.
    let drawnLane: ClaudeQuotaSeries?
    let drawnCompanion: ClaudeQuotaSeries?
    let laneCycles: [ClaudeQuotaSeries.Cycle]
    let weeklyCycles: [ClaudeQuotaSeries.Cycle]
    let fiveHourCycles: [ClaudeQuotaSeries.Cycle]
    let pace: QuotaPace?
    /// The usually quiet stretches ahead that the forecast stays flat across.
    let quiet: [DateInterval]
    let subscriptionDate: Date?
    let currentRange: DateInterval
    /// Far enough back for the oldest reading to reach the left edge.
    let maxPan: TimeInterval
    /// Full 5-hour windows a week holds, for the classic 5-hour view.
    let allowance: (perWeek: Double, remaining: Double, fromCurrent: Bool)?
    /// The same from the quota-size level, and the weekly share used, for the insights 5-hour view.
    let windowsPerWeek: Double?
    let weeklyUsed: Double

    var isWeekly: Bool { lane?.id == "weekly" }

    init(history: [ClaudeQuotaSeries], selected: String, insights: Bool, subscriptionDate: Date?, now: Date) {
        self.now = now
        self.subscriptionDate = subscriptionDate
        let lane = history.first { $0.id == selected } ?? history.first
        let weeklyLane = history.first { $0.id == "weekly" }
        let fiveHourLane = history.first { $0.id == "five-hour" }
        self.lane = lane
        self.weeklyLane = weeklyLane
        self.fiveHourLane = fiveHourLane
        let isWeekly = lane?.id == "weekly"
        let laneCycles = lane?.cycles() ?? []
        let weeklyCycles = isWeekly ? laneCycles : weeklyLane?.cycles() ?? []
        let fiveHourCycles = lane?.id == "five-hour" ? laneCycles : fiveHourLane?.cycles() ?? []
        self.laneCycles = laneCycles
        self.weeklyCycles = weeklyCycles
        self.fiveHourCycles = fiveHourCycles

        let pace: QuotaPace?
        if !insights {
            pace = nil
        } else if isWeekly {
            pace = ClaudeQuotaInsights.weeklyPace(history: history, now: now)
        } else {
            pace = lane?.pace(now: now, lookback: 3600)
        }
        self.pace = pace
        quiet = pace?.quietRuns(now: now) ?? []

        // The weekly lane spans the current subscription month (the current
        // weekly window with insights); the 5-hour lane the last day.
        let currentRange: DateInterval
        if !isWeekly {
            // With insights the day runs on to the current window's reset, leaving room for the forecast.
            let windowEnd = insights ? laneCycles.last.flatMap { $0.interval.end > now ? $0.interval.end : nil } : nil
            let end = min(windowEnd ?? now, now.addingTimeInterval(5 * 3600))
            currentRange = DateInterval(start: end.addingTimeInterval(-86_400), end: end)
        } else if insights {
            if let cycle = weeklyCycles.last?.interval, cycle.start <= now, cycle.end > now {
                currentRange = cycle
            } else {
                currentRange = DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now)
            }
        } else {
            currentRange = ClaudeQuotaSeries.billingCycle(now: now, anchor: subscriptionDate)
        }
        self.currentRange = currentRange
        maxPan = lane?.samples.first.map { max(0, currentRange.start.timeIntervalSince($0.timestamp)) } ?? 0

        let bucket = currentRange.duration / 400
        drawnLane = lane?.thinned(bucket: bucket)
        drawnCompanion = isWeekly ? nil : weeklyLane?.thinned(bucket: bucket)

        if !isWeekly, let weekly = weeklyLane, let fiveHour = fiveHourLane {
            allowance = insights ? nil : ClaudeQuotaSeries.fiveHourWindowsPerWeek(fiveHour: fiveHour, weekly: weekly, now: now)
            windowsPerWeek = insights ? ClaudeQuotaInsights.scaleTrend(fiveHour: fiveHour, weekly: weekly).current : nil
            weeklyUsed = insights
                ? weekly.pace(now: now, lookback: 86_400)?.usedPercent ?? weekly.samples.last?.usedPercent ?? 0 : 0
        } else {
            allowance = nil
            windowsPerWeek = nil
            weeklyUsed = 0
        }
    }

    /// The current range, scrolled back by `pan`.
    func range(pan: TimeInterval) -> DateInterval {
        DateInterval(start: currentRange.start.addingTimeInterval(-pan), duration: currentRange.duration)
    }
}

/// Holds the trend's facts between frames. It lives in `@State` but is not
/// observed, so filling it never redraws anything by itself.
final class QuotaTrendCache {
    struct Key: Equatable {
        let history: [ClaudeQuotaSeries]
        let selected: String
        let insights: Bool
        let subscriptionDate: Date?
    }

    private var key: Key?
    private var facts: QuotaTrendFacts?

    /// The facts for `key`, rebuilt when it changes or `now` moves on by more than `tolerance`.
    func facts(for key: Key, now: Date, tolerance: TimeInterval = 30) -> QuotaTrendFacts {
        if let facts = facts, key == self.key, abs(now.timeIntervalSince(facts.now)) < tolerance { return facts }
        let built = QuotaTrendFacts(history: key.history, selected: key.selected, insights: key.insights,
                                    subscriptionDate: key.subscriptionDate, now: now)
        self.key = key
        facts = built
        return built
    }
}
