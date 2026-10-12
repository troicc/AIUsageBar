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
        // Across a reset the chart drops at the old window's reset time.
        precondition(ClaudeQuotaSeries.reset(between: before, ClaudeQuotaSample(
            timestamp: end.addingTimeInterval(4000), usedPercent: 5, resetsAt: end.addingTimeInterval(7200))) == end)
        precondition(ClaudeQuotaSeries.reset(between: before, ClaudeQuotaSample(
            timestamp: secondTime.addingTimeInterval(4000), usedPercent: 40, resetsAt: end)) == nil, "same window has no reset")
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
        precondition(reloaded.record(snapshot: second, now: start.addingTimeInterval(90000)).map(\.id) == ["weekly"],
                     "5-hour lane shows a day; the weekly lane keeps the billing month")
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
        precondition(account?.includedCredit == ClaudeIncludedCredit(limitDollars: 250, remainingDollars: 250,
            expiresAt: FlexibleDate.iso8601("2026-11-05T07:59:00+00:00")))
        precondition(ClaudeAccountUsage.parse(Data("{\"five_hour\":{\"utilization\":1}}".utf8)) == nil)
        precondition(ClaudeAccountUsage.parse(Data("not json".utf8)) == nil)
        print("PASS | Claude quota attribution: local Claude Code vs other devices, gaps and flat intervals")
        print("PASS | Claude account usage: official product breakdown and included credit")
    }
}
