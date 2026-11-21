import Foundation

/// How much each account has been used lately. The busiest account goes first
/// in the menu and is the one the merged menu-bar icon shows, so a quota that
/// is nearly spent but no longer used does not take the top spot.
///
/// The score adds up the quota points consumed (5-hour window where there is
/// one), each weighted by its age: a point counts half after `halfLife` and
/// not at all after `horizon`.
enum ProviderActivity {
    static let halfLife: TimeInterval = 6 * 3600
    static let horizon: TimeInterval = 7 * 86_400

    typealias Step = (timestamp: Date, points: Double)

    static func score(_ steps: [Step], now: Date) -> Double {
        steps.reduce(0) { total, step in
            let age = now.timeIntervalSince(step.timestamp)
            guard age >= 0, age <= horizon, step.points.isFinite, step.points > 0 else { return total }
            return total + step.points * pow(0.5, age / halfLife)
        }
    }

    /// The series a quota group is scored on: its 5-hour window, or its only window.
    static func activitySeries(_ series: [ClaudeQuotaSeries]) -> ClaudeQuotaSeries? {
        series.first { $0.id == "five-hour" } ?? series.first
    }

    static func score(_ series: ClaudeQuotaSeries, now: Date) -> Double {
        // Only the readings inside the horizon: the history is kept indefinitely.
        let start = now.addingTimeInterval(-horizon)
        return score(series.within(DateInterval(start: start, end: max(start, now))).consumptionSteps(since: start), now: now)
    }

    /// Each Antigravity pool's score, by pool ID.
    static func poolScores(_ pools: [QuotaTrendPool], now: Date) -> [String: Double] {
        var scores: [String: Double] = [:]
        for pool in pools {
            guard let series = activitySeries(pool.series) else { continue }
            scores[pool.id] = score(series, now: now)
        }
        return scores
    }

    /// The pool used most lately, when any was used at all.
    static func busiestPool(_ scores: [String: Double], order: [String]) -> String? {
        var best: (id: String, score: Double)?
        for id in order {
            guard let value = scores[id], value > minimumScore else { continue }
            if best.map({ value > $0.score }) ?? true { best = (id, value) }
        }
        return best?.id
    }

    /// The score from the account's own quota history: Claude's 5-hour
    /// window, or every Antigravity pool. Nil without one.
    static func historyScore(snapshot: ProviderSnapshot, dashboard: ProviderDashboard, now: Date) -> Double? {
        if snapshot.provider == "antigravity", !dashboard.quotaTrendPools.isEmpty {
            return poolScores(dashboard.quotaTrendPools, now: now).values.reduce(0, +)
        }
        if snapshot.provider == "claude", let series = activitySeries(dashboard.claudeQuotaHistory) {
            return score(series, now: now)
        }
        return nil
    }

    /// Antigravity, once its pools' history is attached: the pool used most
    /// lately represents the account, and its windows go first in the quota list.
    static func preferBusiestPool(snapshot: inout ProviderSnapshot, dashboard: inout ProviderDashboard, now: Date) {
        guard snapshot.provider == "antigravity" else { return }
        let scores = poolScores(dashboard.quotaTrendPools, now: now)
        snapshot.preferredQuotaPoolID = busiestPool(scores, order: dashboard.quotaTrendPools.map(\.id))
        applyPreferredPool(snapshot.antigravityHeadline?.poolID, to: &dashboard)
    }

    static func applyPreferredPool(_ poolID: String?, to dashboard: inout ProviderDashboard) {
        guard let poolID = poolID else { return }
        func pool(of lane: DashboardQuotaLane) -> String? {
            guard lane.id.hasPrefix("scoped-") else { return nil }
            return AntigravityQuotaNaming.pool(id: String(lane.id.dropFirst("scoped-".count)), title: lane.title)?.id
        }
        let preferred = dashboard.quotas.filter { pool(of: $0) == poolID }
        guard !preferred.isEmpty else { return }
        dashboard.quotas = preferred + dashboard.quotas.filter { pool(of: $0) != poolID }
    }

    /// Scores at or below this are no use at all.
    static let minimumScore = 0.001

    /// Accounts used lately first, busiest first; then the rest with the
    /// tightest quota first; then in the given order.
    static func ranked(_ snapshots: [ProviderSnapshot], scores: [String: Double]) -> [ProviderSnapshot] {
        snapshots.enumerated().sorted { left, right in
            let leftScore = scores[left.element.id] ?? 0, rightScore = scores[right.element.id] ?? 0
            let leftActive = leftScore > minimumScore, rightActive = rightScore > minimumScore
            if leftActive != rightActive { return leftActive }
            if leftActive, leftScore != rightScore { return leftScore > rightScore }
            switch (left.element.headlineUsedPercent, right.element.headlineUsedPercent) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left.offset < right.offset
            }
        }.map(\.element)
    }
}

/// Recent consumption for accounts without a quota history of their own:
/// rises in the headline quota (above its high-water mark, so small downward
/// corrections are not counted twice) and, for prepaid accounts, balance
/// decreases as a share of the balance. Kept for `ProviderActivity.horizon`
/// in `provider-activity-v1.json`.
final class ProviderActivityStore {
    private struct Step: Codable, Hashable {
        let timestamp: Date
        let points: Double
    }

    private struct Account: Codable {
        var usedPercent: Double?
        var highWater: Double?
        var resetsAt: Date?
        var balance: Double?
        var steps: [Step] = []
    }

    private let fileURL: URL
    private var accounts: [String: Account] = [:]
    private var canSave = true

    init(storageDirectory: URL? = nil) {
        let root = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIUsageBar", isDirectory: true)
        fileURL = root.appendingPathComponent("provider-activity-v1.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                accounts = try decoder.decode([String: Account].self, from: Data(contentsOf: fileURL))
            } catch {
                // Never replace a file that could not be read.
                canSave = false
            }
        }
    }

    /// Records the snapshot's current reading and returns the account's recent rises.
    func record(snapshot: ProviderSnapshot, now: Date = Date()) -> [ProviderActivity.Step] {
        let key = StableIdentifier.hash(snapshot.id)
        var account = accounts[key] ?? Account()
        let before = account.steps.count
        var changed = accounts[key] == nil

        if snapshot.error == nil {
            if let window = snapshot.headlineQuotaWindow, let used = window.usedPercent,
               used.isFinite, (0...100).contains(used) {
                let rise = Self.rise(account: account, used: used, resetsAt: window.resetsAt)
                if rise.points > 0.01 { account.steps.append(Step(timestamp: now, points: rise.points)) }
                account.highWater = rise.highWater
                if account.usedPercent != used || account.resetsAt != window.resetsAt { changed = true }
                account.usedPercent = used
                account.resetsAt = window.resetsAt
            } else if let observation = ProviderFinanceObservationExtractor.observation(
                provider: snapshot.provider, rawJSON: snapshot.rawJSON), observation.total.isFinite {
                if let previous = account.balance, previous > 0, observation.total < previous {
                    account.steps.append(Step(timestamp: now, points: (previous - observation.total) / previous * 100))
                }
                if account.balance != observation.total { changed = true }
                account.balance = observation.total
            }
        }

        let cutoff = now.addingTimeInterval(-ProviderActivity.horizon)
        let kept = account.steps.filter { $0.timestamp >= cutoff && $0.timestamp <= now }
        if kept.count != account.steps.count || account.steps.count != before { changed = true }
        account.steps = kept
        accounts[key] = account
        if changed { save() }
        return account.steps.map { ($0.timestamp, $0.points) }
    }

    /// Points consumed since the last reading. A window that started over
    /// (its reset time moved on and usage fell below the high-water mark)
    /// counts from zero; within a window only rises above the mark count.
    private static func rise(account: Account, used: Double, resetsAt: Date?) -> (points: Double, highWater: Double) {
        guard let highWater = account.highWater else { return (0, used) }
        let movedOn = !ClaudeQuotaSeries.sameWindow(account.resetsAt, resetsAt)
        if (movedOn && used < highWater) || highWater - used >= ClaudeQuotaSeries.earlyResetDrop {
            return (used, used)
        }
        return (max(0, used - highWater), max(highWater, used))
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
        } catch {
            NSLog("Provider activity could not be saved: %@", error.localizedDescription)
        }
    }
}
