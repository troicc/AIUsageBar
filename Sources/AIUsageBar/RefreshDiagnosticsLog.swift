import Foundation

/// A small local log of why provider data could not be shown, so a gap in the
/// menu (for example Claude's CLI usage probe failing for hours) can be traced
/// afterwards. It records every failed refresh and provider error, a single
/// line when a provider recovers, and a single line when a Claude result
/// arrives without the account identity that quota history needs.
///
/// Lines never contain account names or emails: accounts appear as a short
/// hash, and email addresses inside error messages are masked. The file lives
/// next to the other local stores (0600) and is trimmed to `maxBytes`.
final class RefreshDiagnosticsLog {
    let fileURL: URL
    private let maxBytes: Int
    private let lock = NSLock()
    /// Consecutive failed refreshes per snapshot ID.
    private var failures: [String: Int] = [:]
    private var refreshFailures = 0
    private var claudeIdentityMissing = false
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }()

    init(directory: URL? = nil, maxBytes: Int = 256 * 1024) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIUsageBar", isDirectory: true)
        fileURL = root.appendingPathComponent("refresh-diagnostics.log")
        self.maxBytes = max(4 * 1024, maxBytes)
    }

    /// Records the outcome of a refresh whose engine call itself succeeded.
    func record(snapshots: [ProviderSnapshot], now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var lines: [String] = []
        if refreshFailures > 0 {
            lines.append("refresh recovered after \(refreshFailures) failed refresh(es)")
            refreshFailures = 0
        }
        for snapshot in snapshots {
            let label = Self.label(for: snapshot)
            if let error = snapshot.error {
                let count = (failures[snapshot.id] ?? 0) + 1
                failures[snapshot.id] = count
                let code = error.code.map { "[\($0)] " } ?? ""
                let message = Self.sanitized(error.message ?? "no message")
                lines.append("\(label) ERROR #\(count) \(code)\(message)")
            } else if snapshot.usage == nil {
                let count = (failures[snapshot.id] ?? 0) + 1
                failures[snapshot.id] = count
                lines.append("\(label) ERROR #\(count) no usage data in the engine result")
            } else if let count = failures.removeValue(forKey: snapshot.id)
                // A failed result usually carries no account, so its ID is
                // the provider's account-less "<provider>::default".
                ?? failures.removeValue(forKey: Self.accountlessID(snapshot.provider))
            {
                lines.append("\(label) recovered after \(count) failed refresh(es)")
            }

            guard snapshot.provider == "claude", snapshot.error == nil, snapshot.usage != nil else { continue }
            let missing = snapshot.claudeQuotaAccountKey == nil
            if missing != claudeIdentityMissing {
                claudeIdentityMissing = missing
                lines.append(missing
                    ? "\(label) WARN no account identity (claude auth status unavailable); quota history is not recorded"
                    : "\(label) account identity available again; quota history recording resumed")
            }
        }
        append(lines, now: now)
    }

    /// Records a refresh where the engine call failed as a whole.
    func recordRefreshFailure(_ message: String, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        refreshFailures += 1
        append(["refresh FAILED #\(refreshFailures) \(Self.sanitized(message))"], now: now)
    }

    private static func accountlessID(_ provider: String) -> String {
        "\(provider.lowercased())::default"
    }

    private static func label(for snapshot: ProviderSnapshot) -> String {
        "\(snapshot.provider) source=\(snapshot.source ?? "unknown") account=\(StableIdentifier.hash(snapshot.id))"
    }

    static func sanitized(_ message: String, limit: Int = 600) -> String {
        var text = message.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        text = text.replacingOccurrences(
            of: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",
            with: "<email>",
            options: .regularExpression)
        if text.count > limit { text = String(text.prefix(limit)) + "…" }
        return text
    }

    private func append(_ lines: [String], now: Date) {
        guard !lines.isEmpty else { return }
        let stamp = timestampFormatter.string(from: now)
        let text = lines.map { "\(stamp) \($0)\n" }.joined()
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        do {
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(
                    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try trimIfNeeded()
        } catch {
            NSLog("Refresh diagnostics log unavailable: %@", error.localizedDescription)
        }
    }

    /// Keeps the newest half once the file outgrows `maxBytes`.
    private func trimIfNeeded() throws {
        let data = try Data(contentsOf: fileURL)
        guard data.count > maxBytes else { return }
        var tail = data.suffix(maxBytes / 2)
        if let newline = tail.firstIndex(of: 0x0A) {
            tail = tail[tail.index(after: newline)...]
        }
        try Data(tail).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
