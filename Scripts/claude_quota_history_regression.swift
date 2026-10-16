import Foundation

@main
struct ClaudeQuotaHistoryRegression {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let store = ClaudeQuotaHistoryStore(storageDirectory: directory)
        func snapshot(_ percent: Double, time: Date?, account: String? = "a@example.com", reset: Date? = nil,
                      source: String = "oauth", error: Bool = false, minutes: Double? = 300) -> ProviderSnapshot {
            ProviderSnapshot(provider: "claude", version: nil, source: source, status: nil,
                usage: UsageSnapshot(primary: RateWindow(usedPercent: percent, windowMinutes: minutes, resetsAt: reset),
                    secondary: RateWindow(usedPercent: 50, windowMinutes: 10080, resetsAt: nil), tertiary: nil,
                    updatedAt: time, identity: nil, accountEmail: account, accountOrganization: nil, loginMethod: nil),
                credits: nil, account: nil, plan: nil, error: error ? ProviderError(message: "offline") : nil, rawJSON: nil)
        }
        let end = start.addingTimeInterval(7200)
        let first = snapshot(20, time: start, reset: end)
        precondition(store.record(snapshot: first, now: start).count == 2)
        let secondTime = start.addingTimeInterval(600)
        let second = snapshot(30, time: secondTime, reset: end)
        let secondSeries = store.record(snapshot: second, now: secondTime)
        precondition(secondSeries[0].samples.count == 2)
        precondition(ClaudeQuotaSeries.connects(secondSeries[0].samples[0], secondSeries[0].samples[1]))
        precondition(store.record(snapshot: second, now: secondTime)[0].samples.count == 2, "repeat/enrichment must not sample twice")
        precondition(store.record(snapshot: first, now: secondTime)[0].samples.count == 2, "old response ignored")
        precondition(store.record(snapshot: snapshot(80, time: secondTime.addingTimeInterval(60), error: true), now: secondTime.addingTimeInterval(60))[0].samples.count == 2)
        precondition(store.record(snapshot: snapshot(80, time: nil), now: secondTime)[0].samples.count == 2)
        precondition(store.record(snapshot: snapshot(80, time: end), now: secondTime)[0].samples.count == 2, "future measurement ignored")
        precondition(store.record(snapshot: snapshot(80, time: secondTime, account: nil), now: secondTime).isEmpty)
        precondition(store.record(snapshot: snapshot(80, time: secondTime, account: "b@example.com"), now: secondTime)[0].samples.count == 1)
        precondition(store.record(snapshot: snapshot(80, time: secondTime, source: "web"), now: secondTime)[0].samples.count == 2, "same account across sources shares quota history")
        let reloaded = ClaudeQuotaHistoryStore(storageDirectory: directory)
        precondition(reloaded.record(snapshot: second, now: secondTime)[0].samples == secondSeries[0].samples)
        let fractionalTime = secondTime.addingTimeInterval(300.125)
        let fractional = snapshot(40, time: fractionalTime, reset: end.addingTimeInterval(0.125))
        let saved = reloaded.record(snapshot: fractional, now: fractionalTime)
        let again = ClaudeQuotaHistoryStore(storageDirectory: directory).record(snapshot: fractional, now: fractionalTime)
        precondition(saved == again && again[0].samples.count == 3, "fractional measurement deduplicates after reload")
        let file = directory.appendingPathComponent("claude-quota-history-v1.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        precondition((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let data = try Data(contentsOf: file)
        let text = String(decoding: data, as: UTF8.self)
        precondition(!text.contains("example.com") && !text.contains("tokens") && !text.contains("cost"))
        precondition(snapshot(20, time: start, source: "admin-api").claudeSharedQuotaWindows.isEmpty)
        precondition(snapshot(20, time: start, minutes: 10080).claudeSharedQuotaWindows.count == 1, "weekly primary is never labeled 5 hours")
        precondition(snapshot(.infinity, time: start).claudeSharedQuotaWindows.count == 1)
        let before = secondSeries[0].samples.last!
        for after in [
            ClaudeQuotaSample(timestamp: secondTime.addingTimeInterval(60), usedPercent: 1, resetsAt: end),
            ClaudeQuotaSample(timestamp: secondTime.addingTimeInterval(60), usedPercent: 40, resetsAt: end.addingTimeInterval(3600)),
            ClaudeQuotaSample(timestamp: secondTime.addingTimeInterval(4000), usedPercent: 40, resetsAt: end),
            ClaudeQuotaSample(timestamp: end, usedPercent: 40, resetsAt: end),
        ] { precondition(!ClaudeQuotaSeries.connects(before, after), "reset/decrease/missing interval must break chart") }
        // Across a reset the chart drops at the old window's reset time and
        // rises from zero once the new window starts.
        func pair(_ next: ClaudeQuotaSample, after first: ClaudeQuotaSample = before) -> ClaudeQuotaSeries {
            ClaudeQuotaSeries(id: "five-hour", title: "5 hours", samples: [first, next])
        }
        let crossed = pair(ClaudeQuotaSample(timestamp: end.addingTimeInterval(4000), usedPercent: 5,
                                             resetsAt: end.addingTimeInterval(18400)))
        precondition(crossed.reset(before: 1)?.end == end && crossed.reset(before: 1)?.start == end.addingTimeInterval(400)
                     && crossed.hasReset(before: 1), "drop at the old reset, rise from the new window's start")
        precondition(pair(ClaudeQuotaSample(timestamp: secondTime.addingTimeInterval(4000), usedPercent: 40, resetsAt: end))
            .reset(before: 1) == nil, "same window has no reset")
        // A reading taken seconds after its own reset still shows the old
        // window; the next window must still start from zero, not join it.
        let stale = ClaudeQuotaSample(timestamp: end.addingTimeInterval(25), usedPercent: 67, resetsAt: end)
        let afterStale = pair(ClaudeQuotaSample(timestamp: end.addingTimeInterval(2800), usedPercent: 10,
                                                resetsAt: end.addingTimeInterval(18000)), after: stale)
        precondition(afterStale.reset(before: 1)?.end == stale.timestamp && afterStale.reset(before: 1)?.start == stale.timestamp
                     && afterStale.hasReset(before: 1), "a stale reading is followed by a drop to zero")
        // An idle account reports no window; a window starting after that
        // stays at zero until it starts, and is not marked as a reset.
        let idle = ClaudeQuotaSample(timestamp: end, usedPercent: 0, resetsAt: nil)
        let woke = pair(ClaudeQuotaSample(timestamp: end.addingTimeInterval(7200), usedPercent: 4,
                                          resetsAt: end.addingTimeInterval(7200 + 16200)), after: idle)
        precondition(woke.reset(before: 1)?.start == end.addingTimeInterval(5400) && !woke.hasReset(before: 1),
                     "a window after idle rises from its own start without a reset marker")
        let gapSeries = ClaudeQuotaSeries(id: "weekly", title: "Weekly", samples: [
            ClaudeQuotaSample(timestamp: secondTime, usedPercent: 50, resetsAt: end),
            ClaudeQuotaSample(timestamp: secondTime.addingTimeInterval(1800), usedPercent: 51, resetsAt: end),
            ClaudeQuotaSample(timestamp: secondTime.addingTimeInterval(20000), usedPercent: 55, resetsAt: end),
        ])
        precondition(gapSeries.recordedSpans(maxGap: 3600) == [
            DateInterval(start: secondTime, end: secondTime.addingTimeInterval(1800)),
            DateInterval(start: secondTime.addingTimeInterval(20000), duration: 0),
        ], "recorded stretches split at gaps over an hour")
        precondition(gapSeries.recordedSpans(maxGap: 86400).count == 1, "a month view only splits at long gaps")
        precondition(gapSeries.within(DateInterval(start: secondTime.addingTimeInterval(1000), duration: 1000)).samples == gapSeries.samples,
                     "a scrolled range keeps the nearest reading on each side")
        precondition(gapSeries.within(DateInterval(start: secondTime.addingTimeInterval(1800), duration: 60)).samples
                     == Array(gapSeries.samples[0...2]) &&
                     gapSeries.within(DateInterval(start: secondTime.addingTimeInterval(30000), duration: 60)).samples
                     == [gapSeries.samples[2]], "range edges are inclusive; past the end keeps the last reading")
        precondition(ClaudeQuotaSeries.longGap(over: DateInterval(start: secondTime, duration: 86400)) == 3600 &&
                     ClaudeQuotaSeries.longGap(over: DateInterval(start: secondTime, duration: 30 * 86400)) == 15 * 3600)
        let dense = ClaudeQuotaSeries(id: "weekly", title: "Weekly", samples: (0..<100).map {
            ClaudeQuotaSample(timestamp: secondTime.addingTimeInterval(Double($0) * 60), usedPercent: Double($0) / 4, resetsAt: end)
        })
        let thin = dense.thinned(bucket: 600)
        precondition(thin.samples.count == 11 && thin.samples.last == dense.samples.last, "thinning keeps one per bucket and the latest")
        // Billing cycle: the subscription month containing now, rolled from any anchor.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func day(_ text: String) -> Date { ISO8601DateFormatter().date(from: text + "T00:00:00Z")! }
        let today = day("2026-10-12").addingTimeInterval(3600)
        for anchor in ["2026-10-14", "2026-08-14", "2027-01-14"] {
            precondition(ClaudeQuotaSeries.billingCycle(now: today, anchor: day(anchor), calendar: utc)
                == DateInterval(start: day("2026-09-14"), end: day("2026-10-14")), "cycle from \(anchor)")
        }
        precondition(ClaudeQuotaSeries.billingCycle(now: today, anchor: nil, calendar: utc)
            == DateInterval(start: today.addingTimeInterval(-30 * 86400), end: today), "no subscription date: last 30 days")
        let yearLater = reloaded.record(snapshot: second, now: start.addingTimeInterval(400 * 86400))
        precondition(yearLater.map(\.id) == ["five-hour", "weekly"] && yearLater[0].samples == saved[0].samples,
                     "history is kept indefinitely; the view picks the range")
        // Corrupt storage must remain recoverable, not overwritten by new observations.
        try Data("broken".utf8).write(to: file)
        let broken = ClaudeQuotaHistoryStore(storageDirectory: directory)
        _ = broken.record(snapshot: first, now: start)
        precondition(broken.persistenceError != nil && (try! Data(contentsOf: file)) == Data("broken".utf8))
        // Attribution: rises during local Claude Code activity count as
        // Claude Code; rises with no local activity count as other devices.
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = t0.addingTimeInterval(4 * 3600)
        let attributionSeries = ClaudeQuotaSeries(id: "five-hour", title: "5 hours", samples: [
            ClaudeQuotaSample(timestamp: t0, usedPercent: 10, resetsAt: reset),
            ClaudeQuotaSample(timestamp: t0.addingTimeInterval(600), usedPercent: 25, resetsAt: reset),
            ClaudeQuotaSample(timestamp: t0.addingTimeInterval(1200), usedPercent: 31, resetsAt: reset),
            ClaudeQuotaSample(timestamp: t0.addingTimeInterval(1800), usedPercent: 31, resetsAt: reset),
            ClaudeQuotaSample(timestamp: t0.addingTimeInterval(9000), usedPercent: 50, resetsAt: reset),
        ])
        let activeMinute = Int(t0.addingTimeInterval(300).timeIntervalSince1970 / 60)
        let attributed = attributionSeries.attributed(activeMinutes: [activeMinute])
        precondition(abs(attributed.claudeCodePoints - 15) < 0.001, "rise with local activity is Claude Code")
        precondition(abs(attributed.otherDevicePoints - 6) < 0.001, "rise without local activity is other devices")
        precondition(attributed.sources[t0.addingTimeInterval(600)] == .claudeCode)
        precondition(attributed.sources[t0.addingTimeInterval(1200)] == .otherDevices)
        precondition(attributed.sources[t0.addingTimeInterval(9000)] == nil, "gaps over an hour are not attributed")
        let slackMinute = Int(t0.addingTimeInterval(1200 - 120).timeIntervalSince1970 / 60)
        precondition(attributionSeries.attributed(activeMinutes: [slackMinute])
            .sources[t0.addingTimeInterval(1800)] == nil, "flat intervals are not attributed")
        print("PASS | Claude shared quota: identity/source isolation, timestamps, resets, gaps, persistence and token separation")
        let drifted = ClaudeQuotaSample(timestamp: t0.addingTimeInterval(600), usedPercent: 12, resetsAt: reset.addingTimeInterval(37))
        precondition(ClaudeQuotaSeries.connects(attributionSeries.samples[0], drifted), "seconds of reset drift stay one window")
        // Reset markers sit at the new window's start (reset time minus the
        // window length), not at the first sample observed after the reset.
        let newReset = t0.addingTimeInterval(12 * 3600)
        let resetSeries = ClaudeQuotaSeries(id: "five-hour", title: "5 hours", samples: [
            ClaudeQuotaSample(timestamp: t0, usedPercent: 40, resetsAt: reset),
            ClaudeQuotaSample(timestamp: t0.addingTimeInterval(8 * 3600), usedPercent: 3, resetsAt: newReset),
        ])
        precondition(resetSeries.windowStart(at: 1) == t0.addingTimeInterval(7 * 3600), "window start is reset minus 5 h")
        let earlySample = ClaudeQuotaSeries(id: "five-hour", title: "5 hours", samples: [
            ClaudeQuotaSample(timestamp: t0, usedPercent: 40, resetsAt: reset),
            ClaudeQuotaSample(timestamp: t0.addingTimeInterval(600), usedPercent: 3, resetsAt: newReset),
        ])
        precondition(earlySample.windowStart(at: 1) == t0.addingTimeInterval(600), "window start never follows its sample")
        let lateReset = ClaudeQuotaSeries(id: "five-hour", title: "5 hours", samples: [
            ClaudeQuotaSample(timestamp: t0, usedPercent: 40, resetsAt: reset),
            ClaudeQuotaSample(timestamp: t0.addingTimeInterval(3600), usedPercent: 3, resetsAt: t0.addingTimeInterval(2 * 3600)),
        ])
        precondition(lateReset.windowStart(at: 1) == t0, "window start never precedes the previous sample")
        precondition(ClaudeQuotaSeries(id: "other", title: "Other", samples: resetSeries.samples)
            .windowStart(at: 1) == resetSeries.samples[1].timestamp, "unknown window falls back to the sample")
        // Weekly windows and how many full 5-hour windows one holds. Both
        // lanes are read at the same times.
        let weekEnd = t0.addingTimeInterval(7 * 86400)
        var fiveHourSamples: [ClaudeQuotaSample] = [], weeklySamples: [ClaudeQuotaSample] = []
        for hour in 0..<20 {
            // Each 5-hour window is used up (0 → 100) and adds 25 weekly points.
            let time = t0.addingTimeInterval(Double(hour) * 3600)
            let window = Double(hour / 5), step = Double(hour % 5)
            fiveHourSamples.append(ClaudeQuotaSample(timestamp: time, usedPercent: step * 25,
                                                     resetsAt: t0.addingTimeInterval((window + 1) * 5 * 3600)))
            weeklySamples.append(ClaudeQuotaSample(timestamp: time, usedPercent: min(100, window * 25 + step * 6.25),
                                                   resetsAt: weekEnd))
        }
        let fiveHourLane = ClaudeQuotaSeries(id: "five-hour", title: "5 hours", samples: fiveHourSamples)
        let weeklyLane = ClaudeQuotaSeries(id: "weekly", title: "Weekly", samples: weeklySamples)
        let weekCycles = weeklyLane.cycles()
        precondition(weekCycles.count == 1 && weekCycles[0].interval == DateInterval(start: t0, end: weekEnd)
                     && weekCycles[0].exhausted == [DateInterval(start: t0.addingTimeInterval(19 * 3600), end: weekEnd)],
                     "one weekly window, used up from its 20th hour to its reset")
        let lowered = ClaudeQuotaSeries(id: "weekly", title: "Weekly", samples: [
            ClaudeQuotaSample(timestamp: t0, usedPercent: 100, resetsAt: weekEnd),
            ClaudeQuotaSample(timestamp: t0.addingTimeInterval(3600), usedPercent: 60, resetsAt: weekEnd),
        ]).cycles()
        precondition(lowered[0].exhausted == [DateInterval(start: t0, end: t0.addingTimeInterval(3600))],
                     "a used-up week the server lowers again ends its stretch")
        let allowance = ClaudeQuotaSeries.fiveHourWindowsPerWeek(fiveHour: fiveHourLane, weekly: weeklyLane,
                                                                 now: t0.addingTimeInterval(20 * 3600))!
        let lastWeekly = weeklySamples.last!.usedPercent
        precondition(abs(allowance.perWeek - (fiveHourLane.consumedPoints(in: weekCycles[0].interval) / lastWeekly)) < 0.001
                     && allowance.fromCurrent, "per week compares the two lanes' consumption")
        precondition(abs(allowance.remaining - (100 - lastWeekly) / 100 * allowance.perWeek) < 0.001)
        precondition(ClaudeQuotaSeries.fiveHourWindowsPerWeek(fiveHour: fiveHourLane, weekly: ClaudeQuotaSeries(
            id: "weekly", title: "Weekly", samples: Array(weeklySamples.prefix(3))), now: t0.addingTimeInterval(3 * 3600)) == nil,
                     "too little weekly use gives no estimate")
        // Official account usage: per-product weekly breakdown and the
        // included credit (the window that carries dollar amounts).
        let accountJSON = Data("""
        {"five_hour":{"utilization":91.0,"limit_dollars":null,"resets_at":"2026-10-09T13:20:00Z"},
         "iguana_necktie":{"limit_dollars":250,"remaining_dollars":250.0,"used_dollars":0.0,"resets_at":"2026-11-05T07:59:00+00:00"},
         "seven_day_breakdown":{"as_of":"2026-10-09T12:49:13.754853+00:00","window_started_at":"2026-10-08T23:00:00+00:00",
           "rows":[{"display_name":"Claude Code","key":"claude_code","percent":24},{"display_name":"Chats","key":"chat","percent":2},
                   {"display_name":"Cowork","key":"cowork","percent":74},{"display_name":"Other","key":"other","percent":0}]}}
        """.utf8)
        let account = ClaudeAccountUsage.parse(accountJSON)
        precondition(account?.breakdown?.rows.map(\.key) == ["claude_code", "chat", "cowork", "other"])
        precondition(account?.breakdown?.rows.first { $0.key == "cowork" }?.percent == 74)
        precondition(account?.breakdown?.windowStartedAt != nil && account?.breakdown?.asOf != nil)
        let profile = Data(#"{"organization":{"billing_type":"stripe_subscription","subscription_created_at":"2026-01-05T08:15:30.250000Z"}}"#.utf8)
        let profileStart = ClaudeAccountUsage.subscriptionStart(fromProfile: profile)
        precondition(profileStart.map { abs($0.timeIntervalSince(ISO8601DateFormatter().date(from: "2026-01-05T08:15:30Z")!)) < 1 } == true,
                     "profile subscription start")
        precondition(ClaudeAccountUsage.subscriptionStart(fromProfile: Data(#"{"organization":{"subscription_created_at":null}}"#.utf8)) == nil)
        precondition(account?.includedCredit == ClaudeIncludedCredit(limitDollars: 250, remainingDollars: 250,
            expiresAt: FlexibleDate.iso8601("2026-11-05T07:59:00+00:00")))
        precondition(ClaudeAccountUsage.parse(Data("{\"five_hour\":{\"utilization\":1}}".utf8)) == nil)
        precondition(ClaudeAccountUsage.parse(Data("not json".utf8)) == nil)
        print("PASS | Claude quota attribution: local Claude Code vs other devices, gaps and flat intervals")
        print("PASS | Claude account usage: official product breakdown and included credit")
    }
}
