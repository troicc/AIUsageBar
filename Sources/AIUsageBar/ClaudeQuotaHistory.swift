import Foundation

struct ClaudeQuotaSample: Codable, Hashable, Identifiable {
    let timestamp: Date
    let usedPercent: Double
    let resetsAt: Date?
    var id: Date { timestamp }
}

/// Where a rise in the shared quota most likely came from.
enum ClaudeQuotaSource: String, Hashable {
    /// Claude Code on this Mac was active during the rise.
    case claudeCode
    /// No local Claude Code activity: web, desktop or another machine.
    case otherDevices
}

struct ClaudeQuotaSeries: Hashable, Identifiable {
    let id: String
    let title: String
    let samples: [ClaudeQuotaSample]
    /// Source of each rising segment, keyed by the timestamp of the sample
    /// that ends it. Empty until `attributed(activeMinutes:)` runs.
    var sources: [Date: ClaudeQuotaSource] = [:]
    /// Percentage points of this window consumed in the series, by source.
    var claudeCodePoints: Double = 0
    var otherDevicePoints: Double = 0

    var attributedPoints: Double { claudeCodePoints + otherDevicePoints }

    var windowDuration: TimeInterval? {
        switch id {
        case "five-hour": return 5 * 3600
        case "weekly": return 7 * 86_400
        default: return nil
        }
    }

    /// When the window of the sample at `index` began: its reset time minus the
    /// window length, kept between the previous sample and this one. Falls back
    /// to the sample's own timestamp when the start cannot be derived.
    func windowStart(at index: Int) -> Date {
        let sample = samples[index]
        guard let resetsAt = sample.resetsAt, let duration = windowDuration else { return sample.timestamp }
        let start = resetsAt.addingTimeInterval(-duration)
        let earliest = index > 0 ? samples[index - 1].timestamp : .distantPast
        return min(max(start, earliest), sample.timestamp)
    }

    /// Splits quota consumption between local Claude Code and everything
    /// else, for rises after `since` (the span the activity log covers). A rise counts as Claude Code when Claude Code logged any usage
    /// between the two samples (with `slack` before the first, since the
    /// server reports usage with a short delay); otherwise it came from web,
    /// desktop or another device. Overlapping use is credited to Claude
    /// Code, so the other-device share is a lower bound.
    func attributed(activeMinutes: Set<Int>, since: Date = .distantPast, slack: TimeInterval = 180) -> ClaudeQuotaSeries {
        var result = self
        result.sources = [:]
        result.claudeCodePoints = 0
        result.otherDevicePoints = 0
        guard samples.count > 1 else { return result }
        for index in 1..<samples.count {
            let previous = samples[index - 1]
            let next = samples[index]
            let delta = next.usedPercent - previous.usedPercent
            guard previous.timestamp >= since, Self.connects(previous, next), delta > 0.05 else { continue }
            let first = Int(previous.timestamp.addingTimeInterval(-slack).timeIntervalSince1970 / 60)
            let last = Int(next.timestamp.timeIntervalSince1970 / 60)
            let local = first <= last && (first...last).contains { activeMinutes.contains($0) }
            result.sources[next.timestamp] = local ? .claudeCode : .otherDevices
            if local { result.claudeCodePoints += delta } else { result.otherDevicePoints += delta }
        }
        return result
    }

    /// Longest interval between two readings that still counts as observed.
    static let observedGap: TimeInterval = 3600

    /// Do not draw consumption through resets, corrections or an unobserved interval.
    static func connects(_ previous: ClaudeQuotaSample, _ next: ClaudeQuotaSample) -> Bool {
        next.timestamp > previous.timestamp &&
            next.timestamp.timeIntervalSince(previous.timestamp) <= observedGap &&
            sameWindow(previous.resetsAt, next.resetsAt) &&
            !(previous.resetsAt.map { $0 <= next.timestamp } ?? false) &&
            next.usedPercent >= previous.usedPercent
    }

    /// How the line passes between the readings at `index - 1` and `index`
    /// when they belong to different windows: it holds the old reading until
    /// `end` (the old window's reset), drops to zero, stays there until `start`
    /// (the new window's start) and rises from zero to the new reading. A new
    /// window always starts from zero, so it is never joined to the old one.
    /// Both times stay between the two readings; nil within one window.
    func reset(before index: Int) -> (end: Date, start: Date)? {
        guard index > 0, index < samples.count else { return nil }
        let previous = samples[index - 1], next = samples[index]
        guard next.timestamp > previous.timestamp else { return nil }
        if Self.restartedEarly(previous, next) { return (previous.timestamp, previous.timestamp) }
        guard !Self.sameWindow(previous.resetsAt, next.resetsAt) else { return nil }
        let start = windowStart(at: index)
        // A reading taken just after its own reset time still reports the old window.
        let end = min(max(previous.resetsAt ?? start, previous.timestamp), next.timestamp)
        return (end, max(start, end))
    }

    /// A drop at least this large within one window is a reset, not a correction.
    static let earlyResetDrop: Double = 25

    /// A window that started over before its reset time, keeping that time:
    /// a reset card, or a reset granted by Anthropic.
    static func restartedEarly(_ previous: ClaudeQuotaSample, _ next: ClaudeQuotaSample) -> Bool {
        sameWindow(previous.resetsAt, next.resetsAt) && previous.usedPercent - next.usedPercent >= earlyResetDrop
    }

    /// Whether a window ended between the readings at `index - 1` and `index`.
    /// An idle account reports no window, so starting one after that is not a reset.
    func hasReset(before index: Int) -> Bool {
        index > 0 && index < samples.count && samples[index - 1].resetsAt != nil && reset(before: index) != nil
    }

    /// Readings inside `range`, plus the nearest one on each side so the line
    /// runs on to the edges of a scrolled view.
    func within(_ range: DateInterval) -> ClaudeQuotaSeries {
        // Samples are sorted; binary search keeps scrolling through long histories cheap.
        func firstIndex(after date: Date, inclusive: Bool) -> Int {
            var low = 0, high = samples.count
            while low < high {
                let mid = (low + high) / 2
                let time = samples[mid].timestamp
                if inclusive ? time < date : time <= date { low = mid + 1 } else { high = mid }
            }
            return low
        }
        let lower = max(0, firstIndex(after: range.start, inclusive: true) - 1)
        let upper = min(samples.count, firstIndex(after: range.end, inclusive: false) + 1)
        return ClaudeQuotaSeries(id: id, title: title, samples: lower < upper ? Array(samples[lower..<upper]) : [],
                                 sources: sources, claudeCodePoints: claudeCodePoints, otherDevicePoints: otherDevicePoints)
    }

    /// Gaps longer than this are drawn as unrecorded: an hour over a day, about
    /// 15 hours over a month, so only real breaks stand out at either scale.
    static func longGap(over range: DateInterval) -> TimeInterval {
        max(observedGap, range.duration / 48)
    }

    /// Stretches with a reading at least every `maxGap`. A lone reading is a zero-length span.
    func recordedSpans(maxGap: TimeInterval) -> [DateInterval] {
        var spans: [DateInterval] = []
        for sample in samples {
            if let last = spans.last, sample.timestamp.timeIntervalSince(last.end) <= maxGap {
                spans[spans.count - 1] = DateInterval(start: last.start, end: sample.timestamp)
            } else {
                spans.append(DateInterval(start: sample.timestamp, duration: 0))
            }
        }
        return spans
    }

    /// At most one reading per `bucket` seconds, for drawing a long range.
    /// Readings on either side of a reset, correction or gap are always kept,
    /// as is the latest one, so the shape and the breaks stay exact.
    func thinned(bucket: TimeInterval) -> ClaudeQuotaSeries {
        guard bucket > 0, samples.count > 2 else { return self }
        var kept: [ClaudeQuotaSample] = []
        for (index, sample) in samples.enumerated() {
            let isEdge = index == 0 || index == samples.count - 1 ||
                !Self.connects(samples[index - 1], sample) || !Self.connects(sample, samples[index + 1])
            if isEdge || kept.last.map({ sample.timestamp.timeIntervalSince($0.timestamp) >= bucket }) ?? true {
                kept.append(sample)
            }
        }
        return ClaudeQuotaSeries(id: id, title: title, samples: kept, sources: sources,
                                 claudeCodePoints: claudeCodePoints, otherDevicePoints: otherDevicePoints)
    }

    /// The subscription month that contains `now`, given any renewal or
    /// expiry date (rolled by whole months). Without one, the last 30 days.
    static func billingCycle(now: Date, anchor: Date?, calendar: Calendar = .current) -> DateInterval {
        guard var end = anchor else { return DateInterval(start: now.addingTimeInterval(-30 * 86_400), end: now) }
        for _ in 0..<600 where end <= now {
            guard let next = calendar.date(byAdding: .month, value: 1, to: end) else { break }
            end = next
        }
        for _ in 0..<600 {
            guard let previous = calendar.date(byAdding: .month, value: -1, to: end), previous > now else { break }
            end = previous
        }
        let start = calendar.date(byAdding: .month, value: -1, to: end) ?? end.addingTimeInterval(-30 * 86_400)
        guard end > now, start <= now else { return DateInterval(start: now.addingTimeInterval(-30 * 86_400), end: now) }
        return DateInterval(start: start, end: end)
    }

    /// Percentage points consumed between readings inside `range`: rises
    /// within a window, plus each new window's reading counted from zero.
    func consumedPoints(in range: DateInterval) -> Double {
        guard samples.count > 1 else { return 0 }
        var total = 0.0
        for index in 1..<samples.count where samples[index - 1].timestamp >= range.start
            && samples[index].timestamp <= range.end
        {
            total += consumed(before: index)
        }
        return total
    }

    /// Points consumed between the readings at `index - 1` and `index`.
    func consumed(before index: Int) -> Double {
        let previous = samples[index - 1], next = samples[index]
        return reset(before: index) != nil ? next.usedPercent : max(0, next.usedPercent - previous.usedPercent)
    }

    /// Each rise, timed at the reading that ends it, from `start` on.
    func consumptionSteps(since start: Date = .distantPast) -> [(timestamp: Date, points: Double)] {
        guard samples.count > 1 else { return [] }
        return (1..<samples.count).compactMap { index in
            guard samples[index - 1].timestamp >= start else { return nil }
            let points = consumed(before: index)
            return points > 0 ? (samples[index].timestamp, points) : nil
        }
    }

    /// One window of this series, from its start to its reset, with the
    /// stretches it was used up and how much was used at the last reading.
    /// A window that started over early ends there, and the next one begins.
    struct Cycle: Hashable {
        let interval: DateInterval
        let exhausted: [DateInterval]
        let usedPercent: Double
        var peakPercent: Double = 0

        /// Shares more than an instant with `range`; touching its edge is not enough.
        func overlaps(_ range: DateInterval) -> Bool {
            min(interval.end, range.end) > max(interval.start, range.start)
        }
    }

    /// The windows with a known reset time, oldest first.
    func cycles() -> [Cycle] {
        guard let duration = windowDuration else { return [] }
        var result: [Cycle] = []
        var group: [ClaudeQuotaSample] = []
        // When the current group began by starting over early.
        var restartedAt: Date?
        func flush(endingEarlyAt early: Date?) {
            guard let resetsAt = group.last?.resetsAt, let last = group.last else { return }
            let start = max(resetsAt.addingTimeInterval(-duration), restartedAt ?? .distantPast)
            let end = max(start, early ?? resetsAt)
            // From the first reading at 100% to the next one below it, or the window's end.
            var exhausted: [DateInterval] = []
            var since: Date?
            for sample in group {
                if sample.usedPercent >= 100 {
                    if since == nil { since = sample.timestamp }
                } else if let first = since {
                    exhausted.append(DateInterval(start: first, end: max(first, sample.timestamp)))
                    since = nil
                }
            }
            if let first = since { exhausted.append(DateInterval(start: first, end: max(first, end))) }
            result.append(Cycle(interval: DateInterval(start: start, end: end), exhausted: exhausted,
                                usedPercent: last.usedPercent,
                                peakPercent: group.map(\.usedPercent).max() ?? last.usedPercent))
        }
        for sample in samples where sample.resetsAt != nil {
            if let last = group.last {
                if !Self.sameWindow(last.resetsAt, sample.resetsAt) {
                    flush(endingEarlyAt: nil)
                    group = []
                    restartedAt = nil
                } else if Self.restartedEarly(last, sample) {
                    flush(endingEarlyAt: last.timestamp)
                    group = []
                    restartedAt = last.timestamp
                }
            }
            group.append(sample)
        }
        flush(endingEarlyAt: nil)
        return result
    }

    /// How many full five-hour windows one weekly window holds, from the most
    /// recent weekly window with at least `minimumWeekly` points used, and how
    /// many are left in the current one. Both lanes are read at the same
    /// times, so their consumption over a window compares directly.
    static func fiveHourWindowsPerWeek(fiveHour: ClaudeQuotaSeries, weekly: ClaudeQuotaSeries,
                                       now: Date = Date(), minimumWeekly: Double = 20)
        -> (perWeek: Double, remaining: Double, fromCurrent: Bool)?
    {
        let cycles = weekly.cycles()
        guard let current = cycles.last, let latest = weekly.samples.last else { return nil }
        for cycle in cycles.reversed() {
            let span = DateInterval(start: cycle.interval.start, end: min(cycle.interval.end, now))
            let weeklyPoints = weekly.consumedPoints(in: span)
            let fiveHourPoints = fiveHour.consumedPoints(in: span)
            guard weeklyPoints >= minimumWeekly, fiveHourPoints > 0 else { continue }
            let perWeek = fiveHourPoints / weeklyPoints
            // A window whose reset has passed with no newer reading is spent anew.
            let used = current.interval.end > now ? latest.usedPercent : 0
            return (perWeek, max(0, 100 - used) / 100 * perWeek, cycle == current)
        }
        return nil
    }

    /// The server reports a window's reset time with a few seconds of drift
    /// between requests; a real new window moves it by hours.
    static func sameWindow(_ left: Date?, _ right: Date?) -> Bool {
        switch (left, right) {
        case (nil, nil): return true
        case let (l?, r?): return abs(l.timeIntervalSince(r)) <= 300
        default: return false
        }
    }
}

extension ProviderSnapshot {
    var claudeSharedQuotaWindows: [(id: String, title: String, window: RateWindow)] {
        guard provider == "claude", source?.lowercased().contains("admin") != true else { return [] }
        let windows = [usage?.primary, usage?.secondary, usage?.tertiary].compactMap { $0 }
        var result: [(id: String, title: String, window: RateWindow)] = []
        for (id, title, minutes, fallback) in [
            ("five-hour", L("5 hours"), 300.0, usage?.primary),
            ("weekly", L("Weekly"), 10080.0, usage?.secondary),
        ] {
            let window = windows.first { $0.windowMinutes == minutes }
                ?? (fallback?.windowMinutes == nil ? fallback : nil)
            if let window = window, let percent = window.usedPercent, percent.isFinite, (0...100).contains(percent) {
                result.append((id, title, window))
            }
        }
        return result
    }

    // New quota history can use the CLI display identity without migrating token/cost ledgers.
    var claudeQuotaAccountKey: String? {
        let email = [usage?.identity?.accountEmail, usage?.accountEmail, account, cliAccountStatus?.email]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .first { !$0.isEmpty }
        guard provider == "claude", let email = email else { return nil }
        let org = (usage?.identity?.accountOrganization ?? usage?.accountOrganization ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return StableIdentifier.hash("claude::\(email)::\(org)")
    }
}

/// Account quota percentages stay separate from token and estimated-cost history.
/// History is kept indefinitely: about 15 KB a day on disk.
final class ClaudeQuotaHistoryStore {
    private let fileURL: URL
    private var accounts: [String: [String: [ClaudeQuotaSample]]] = [:]
    private var canSave = true
    private(set) var persistenceError: String?

    init(storageDirectory: URL? = nil) {
        let root = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIUsageBar", isDirectory: true)
        fileURL = root.appendingPathComponent("claude-quota-history-v1.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                accounts = try decoder.decode([String: [String: [ClaudeQuotaSample]]].self, from: Data(contentsOf: fileURL))
            } catch {
                canSave = false
                persistenceError = L("Quota history could not be read; the original file is preserved.")
            }
        }
    }

    func record(snapshot: ProviderSnapshot, now: Date = Date()) -> [ClaudeQuotaSeries] {
        guard let key = snapshot.claudeQuotaAccountKey else { return [] }
        // Only upstream measurement times can create samples. Enrichment, currency changes,
        // errors and repeated cached responses must never fabricate fresh observations.
        if snapshot.error == nil, let reportedTime = snapshot.usage?.updatedAt,
           reportedTime <= now {
            // ISO-8601 persistence uses seconds; keep in-memory identity at the same precision.
            let measured = Date(timeIntervalSince1970: floor(reportedTime.timeIntervalSince1970))
            var changed = false
            for lane in snapshot.claudeSharedQuotaWindows {
                var samples = accounts[key]?[lane.id] ?? []
                guard samples.last.map({ measured > $0.timestamp }) ?? true else { continue }
                samples.append(ClaudeQuotaSample(timestamp: measured, usedPercent: lane.window.usedPercent!,
                    resetsAt: lane.window.resetsAt.map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970)) }))
                accounts[key, default: [:]][lane.id] = samples
                changed = true
            }
            if changed {
                for account in Array(accounts.keys) {
                    var lanes = accounts[account] ?? [:]
                    for (lane, samples) in lanes {
                        lanes[lane] = samples.filter {
                            $0.timestamp <= now && $0.usedPercent.isFinite && (0...100).contains($0.usedPercent)
                        }.sorted { $0.timestamp < $1.timestamp }
                    }
                    accounts[account] = lanes.values.allSatisfy({ $0.isEmpty }) ? nil : lanes
                }
                save()
            }
        }
        // The whole history; the view shows a range of it and can be scrolled back.
        return [("five-hour", L("5 hours")), ("weekly", L("Weekly"))].compactMap { id, title in
            let samples = (accounts[key]?[id] ?? []).filter {
                $0.timestamp <= now && $0.usedPercent.isFinite && (0...100).contains($0.usedPercent)
            }.sorted { $0.timestamp < $1.timestamp }
            return samples.isEmpty ? nil : ClaudeQuotaSeries(id: id, title: title, samples: samples)
        }
    }

    private func save() {
        guard canSave else { return }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(accounts).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            persistenceError = nil
        } catch {
            persistenceError = L("Quota history could not be saved. Current quotas are still available.")
        }
    }
}
