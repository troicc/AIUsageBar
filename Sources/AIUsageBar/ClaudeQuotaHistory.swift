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

    /// When the window of `previous` ended between the two readings, if known.
    static func reset(between previous: ClaudeQuotaSample, _ next: ClaudeQuotaSample) -> Date? {
        guard let resetsAt = previous.resetsAt, !sameWindow(resetsAt, next.resetsAt),
              resetsAt > previous.timestamp, resetsAt <= next.timestamp.addingTimeInterval(300) else { return nil }
        return min(resetsAt, next.timestamp)
    }

    /// Readings inside `range`.
    func within(_ range: DateInterval) -> ClaudeQuotaSeries {
        ClaudeQuotaSeries(id: id, title: title,
                          samples: samples.filter { $0.timestamp >= range.start && $0.timestamp <= range.end },
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
final class ClaudeQuotaHistoryStore {
    /// Long enough to hold a full subscription month.
    static let retention: TimeInterval = 35 * 86_400
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
        let cutoff = now.addingTimeInterval(-Self.retention)
        // Only upstream measurement times can create samples. Enrichment, currency changes,
        // errors and repeated cached responses must never fabricate fresh observations.
        if snapshot.error == nil, let reportedTime = snapshot.usage?.updatedAt,
           reportedTime <= now, reportedTime >= cutoff {
            // ISO-8601 persistence uses seconds; keep in-memory identity at the same precision.
            let measured = Date(timeIntervalSince1970: floor(reportedTime.timeIntervalSince1970))
            var changed = false
            for lane in snapshot.claudeSharedQuotaWindows {
                var samples = accounts[key]?[lane.id] ?? []
                guard samples.last.map({ measured > $0.timestamp }) ?? true else { continue }
                samples.append(ClaudeQuotaSample(timestamp: measured, usedPercent: lane.window.usedPercent!,
                    resetsAt: lane.window.resetsAt.map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970)) }))
                accounts[key, default: [:]][lane.id] = Array(samples.suffix(10000))
                changed = true
            }
            if changed {
                for account in Array(accounts.keys) {
                    var lanes = accounts[account] ?? [:]
                    for (lane, samples) in lanes {
                        lanes[lane] = samples.filter {
                            $0.timestamp >= cutoff && $0.timestamp <= now && $0.usedPercent.isFinite && (0...100).contains($0.usedPercent)
                        }.sorted { $0.timestamp < $1.timestamp }
                    }
                    accounts[account] = lanes.values.allSatisfy({ $0.isEmpty }) ? nil : lanes
                }
                save()
            }
        }
        // The weekly trend spans a whole subscription month; the view picks the cycle.
        return [("five-hour", L("5 hours"), 86_400.0), ("weekly", L("Weekly"), Self.retention)].compactMap { id, title, span in
            let displayCutoff = now.addingTimeInterval(-span)
            let samples = (accounts[key]?[id] ?? []).filter {
                $0.timestamp >= displayCutoff && $0.timestamp <= now && $0.usedPercent.isFinite && (0...100).contains($0.usedPercent)
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
