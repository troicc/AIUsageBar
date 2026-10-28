import Foundation

/// One reading of the included (cloud) credit balance.
struct ClaudeCreditSample: Codable, Hashable {
    let timestamp: Date
    let limitDollars: Double
    let remainingDollars: Double
    let expiresAt: Date?

    var usedDollars: Double { max(0, limitDollars - remainingDollars) }

    /// The same grant: a renewed or new grant changes the limit or expiry.
    func sameGrant(_ other: ClaudeCreditSample) -> Bool {
        guard abs(limitDollars - other.limitDollars) < 0.005 else { return false }
        switch (expiresAt, other.expiresAt) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince(b)) <= 300
        default: return false
        }
    }
}

/// The included credit is spent by cloud sessions, which leave no local
/// Claude Code logs. Its spending is the drop in balance between readings,
/// counted at the reading that saw it.
struct ClaudeCreditHistory: Hashable {
    struct Spend: Hashable {
        var dollars: Double = 0
        /// Part of `dollars` already used when the balance was first read;
        /// it is counted at that first reading.
        var untrackedDollars: Double = 0
    }

    let samples: [ClaudeCreditSample]

    func spent(since start: Date) -> Spend {
        var spend = Spend()
        for (index, sample) in samples.enumerated() where sample.timestamp >= start {
            if index == 0 {
                spend.dollars += sample.usedDollars
                spend.untrackedDollars += sample.usedDollars
            } else {
                let previous = samples[index - 1]
                // A new grant starts from what it had used by its first reading.
                spend.dollars += sample.sameGrant(previous)
                    ? max(0, sample.usedDollars - previous.usedDollars) : sample.usedDollars
            }
        }
        return spend
    }
}

/// Included-credit readings per Claude account, kept indefinitely. A reading
/// is stored only when the balance or the grant changes.
final class ClaudeCreditHistoryStore {
    private let fileURL: URL
    private var accounts: [String: [ClaudeCreditSample]] = [:]
    private var canSave = true

    init(storageDirectory: URL? = nil) {
        let root = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIUsageBar", isDirectory: true)
        fileURL = root.appendingPathComponent("claude-cloud-credit-v1.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                accounts = try decoder.decode([String: [ClaudeCreditSample]].self, from: Data(contentsOf: fileURL))
            } catch {
                canSave = false
            }
        }
    }

    @discardableResult
    func record(_ credit: ClaudeIncludedCredit?, account: String, now: Date = Date()) -> ClaudeCreditHistory? {
        if let credit = credit, credit.limitDollars.isFinite, credit.remainingDollars.isFinite {
            let sample = ClaudeCreditSample(
                timestamp: Date(timeIntervalSince1970: floor(now.timeIntervalSince1970)),
                limitDollars: credit.limitDollars, remainingDollars: credit.remainingDollars,
                expiresAt: credit.expiresAt.map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970)) })
            var samples = accounts[account] ?? []
            let unchanged = samples.last.map {
                $0.sameGrant(sample) && abs($0.remainingDollars - sample.remainingDollars) < 0.005
            } ?? false
            if !unchanged, samples.last.map({ sample.timestamp > $0.timestamp }) ?? true {
                samples.append(sample)
                accounts[account] = samples
                save()
            }
        }
        return history(account: account)
    }

    func history(account: String) -> ClaudeCreditHistory? {
        guard let samples = accounts[account], !samples.isEmpty else { return nil }
        return ClaudeCreditHistory(samples: samples)
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
            NSLog("Cloud credit history could not be saved: %@", error.localizedDescription)
        }
    }
}
