import Foundation

/// The quota trend's facts, worked out once per history instead of on every
/// frame: they must match what the readings give directly, and the cache must
/// rebuild whenever the history, window, style or time moves on.
@main
struct QuotaTrendFactsRegression {
    static func main() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let hours = 10 * 24
        // A reading every 10 minutes: 5-hour windows back to back, two weekly windows.
        var fiveHour: [ClaudeQuotaSample] = []
        var weekly: [ClaudeQuotaSample] = []
        for step in 0..<(hours * 6) {
            let time = start.addingTimeInterval(Double(step) * 600)
            let elapsed = time.timeIntervalSince(start)
            let window = floor(elapsed / 18_000)
            let inWindow = elapsed - window * 18_000
            fiveHour.append(ClaudeQuotaSample(timestamp: time, usedPercent: min(100, inWindow / 18_000 * 120),
                                              resetsAt: start.addingTimeInterval((window + 1) * 18_000)))
            let week = floor(elapsed / (7 * 86_400))
            let inWeek = elapsed - week * 7 * 86_400
            weekly.append(ClaudeQuotaSample(timestamp: time, usedPercent: min(100, inWeek / 3600 * 0.6),
                                            resetsAt: start.addingTimeInterval((week + 1) * 7 * 86_400)))
        }
        let history = [ClaudeQuotaSeries(id: "five-hour", title: "5 hours", samples: fiveHour),
                       ClaudeQuotaSeries(id: "weekly", title: "Weekly", samples: weekly)]
        let now = start.addingTimeInterval(Double(hours) * 3600 - 300)

        // Weekly, insights: the current weekly window, the pace the trend used to work out itself.
        let week = QuotaTrendFacts(history: history, selected: "weekly", insights: true, subscriptionDate: nil, now: now)
        let weeklyCycles = history[1].cycles()
        precondition(week.isWeekly && week.laneCycles == weeklyCycles && week.weeklyCycles == weeklyCycles
                     && week.fiveHourCycles == history[0].cycles(), "cycles of each lane")
        precondition(week.currentRange == weeklyCycles.last!.interval, "insights weekly view spans the current week")
        precondition(week.pace == ClaudeQuotaInsights.weeklyPace(history: history, now: now), "weekly pace")
        precondition(week.quiet == (week.pace?.quietRuns(now: now) ?? []), "quiet stretches")
        precondition(week.maxPan == week.currentRange.start.timeIntervalSince(start), "scrolls back to the first reading")
        precondition(week.drawnLane == history[1].thinned(bucket: week.currentRange.duration / 400) && week.drawnCompanion == nil,
                     "the drawn lane is thinned once for the whole history")
        let back = week.range(pan: 86_400)
        precondition(back.duration == week.currentRange.duration && back.end == week.currentRange.end.addingTimeInterval(-86_400))

        // 5 hours, insights: the day runs on to the window's reset; the allowance comes from the quota size.
        let day = QuotaTrendFacts(history: history, selected: "five-hour", insights: true, subscriptionDate: nil, now: now)
        let windowEnd = history[0].cycles().last!.interval.end
        precondition(day.currentRange.end == min(windowEnd, now.addingTimeInterval(5 * 3600)) && day.currentRange.duration == 86_400)
        precondition(day.pace == history[0].pace(now: now, lookback: 3600), "5-hour pace")
        precondition(day.windowsPerWeek == ClaudeQuotaInsights.scaleTrend(fiveHour: history[0], weekly: history[1]).current
                     && day.allowance == nil)
        precondition(day.weeklyUsed == history[1].pace(now: now, lookback: 86_400)?.usedPercent)
        precondition(day.drawnCompanion == history[1].thinned(bucket: 86_400 / 400), "weekly line under the 5-hour one")

        // Classic: the 5-hour day ends now; the weekly view spans the subscription month.
        let classicDay = QuotaTrendFacts(history: history, selected: "five-hour", insights: false, subscriptionDate: nil, now: now)
        precondition(classicDay.currentRange.end == now && classicDay.pace == nil && classicDay.windowsPerWeek == nil)
        let estimate = ClaudeQuotaSeries.fiveHourWindowsPerWeek(fiveHour: history[0], weekly: history[1], now: now)
        precondition(classicDay.allowance?.perWeek == estimate?.perWeek && classicDay.allowance?.remaining == estimate?.remaining)
        let renews = now.addingTimeInterval(12 * 86_400)
        let month = QuotaTrendFacts(history: history, selected: "weekly", insights: false, subscriptionDate: renews, now: now)
        precondition(month.currentRange == ClaudeQuotaSeries.billingCycle(now: now, anchor: renews), "billing cycle")
        let unknown = QuotaTrendFacts(history: history, selected: "missing", insights: true, subscriptionDate: nil, now: now)
        precondition(unknown.lane?.id == "five-hour", "an unknown window falls back to the first lane")
        print("PASS | Quota trend facts: ranges, cycles, pace, allowance and thinning match the readings")

        // The cache hands back the same facts until something they depend on changes.
        let cache = QuotaTrendCache()
        let key = QuotaTrendCache.Key(history: history, selected: "weekly", insights: true, subscriptionDate: nil)
        let built = cache.facts(for: key, now: now)
        precondition(cache.facts(for: key, now: now.addingTimeInterval(10)).now == built.now, "kept between frames")
        precondition(cache.facts(for: key, now: now.addingTimeInterval(45)).now == now.addingTimeInterval(45),
                     "rebuilt once time moves on")
        let other = QuotaTrendCache.Key(history: history, selected: "five-hour", insights: true, subscriptionDate: nil)
        precondition(cache.facts(for: other, now: now.addingTimeInterval(45)).lane?.id == "five-hour", "rebuilt for another window")
        let classic = QuotaTrendCache.Key(history: history, selected: "five-hour", insights: false, subscriptionDate: nil)
        precondition(cache.facts(for: classic, now: now.addingTimeInterval(45)).pace == nil, "rebuilt for another style")
        var newer = history
        let next = ClaudeQuotaSample(timestamp: now.addingTimeInterval(60), usedPercent: 99, resetsAt: windowEnd)
        newer[0] = ClaudeQuotaSeries(id: "five-hour", title: "5 hours", samples: fiveHour + [next])
        let refreshed = cache.facts(for: QuotaTrendCache.Key(history: newer, selected: "five-hour", insights: false,
                                                             subscriptionDate: nil),
                                    now: now.addingTimeInterval(50))
        precondition(refreshed.lane?.samples.last == next, "rebuilt when a refresh adds a reading")
        print("PASS | Quota trend cache: reused between frames, rebuilt on new readings, window, style or time")
    }
}
