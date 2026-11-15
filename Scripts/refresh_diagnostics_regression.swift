import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("Refresh diagnostics regression failed: \(message)\n").utf8))
    exit(1)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
}

private func claude(error: String? = nil, email: String? = "someone@example.com") -> ProviderSnapshot {
    let usage = error == nil
        ? UsageSnapshot(
            primary: nil, secondary: nil, tertiary: nil, updatedAt: Date(),
            identity: nil, accountEmail: email, accountOrganization: nil, loginMethod: nil)
        : nil
    return ProviderSnapshot(
        provider: "claude", version: nil, source: "claude", status: nil, usage: usage, credits: nil,
        account: nil, plan: nil, error: error.map { ProviderError(message: $0) }, rawJSON: nil)
}

private func lines(_ log: RefreshDiagnosticsLog) -> [String] {
    guard let text = try? String(contentsOf: log.fileURL, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init)
}

let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("refresh-diagnostics-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: directory) }

// Healthy refreshes write nothing.
let diagnostics = RefreshDiagnosticsLog(directory: directory)
diagnostics.record(snapshots: [claude()])
require(lines(diagnostics).isEmpty, "a healthy refresh must not write")

// Every failure is recorded, with emails masked and newlines collapsed.
diagnostics.record(snapshots: [claude(error: "Claude CLI timed out\nfor someone@example.com")])
diagnostics.record(snapshots: [claude(error: "Claude CLI timed out")])
var current = lines(diagnostics)
require(current.count == 2, "each failed refresh is one line, got \(current)")
require(current[0].contains("claude source=claude"), "line names provider and source")
require(current[0].contains("ERROR #1 Claude CLI timed out for <email>"), "message is sanitized: \(current[0])")
require(current[1].contains("ERROR #2"), "consecutive failures are counted")
require(!current.joined().contains("example.com"), "no email may reach the log")

// Recovery is logged once; later healthy refreshes stay silent.
diagnostics.record(snapshots: [claude()])
diagnostics.record(snapshots: [claude()])
current = lines(diagnostics)
require(current.count == 3 && current[2].contains("recovered after 2 failed refresh(es)"), "recovery line: \(current)")

// Missing account identity is logged when it starts and when it ends.
diagnostics.record(snapshots: [claude(email: nil)])
diagnostics.record(snapshots: [claude(email: nil)])
diagnostics.record(snapshots: [claude()])
current = lines(diagnostics)
require(current.count == 5, "identity changes are logged once each: \(current)")
require(current[3].contains("WARN no account identity"), "identity warning")
require(current[4].contains("identity available again"), "identity restored")

// Whole-refresh failures and their recovery.
diagnostics.recordRefreshFailure("Timed out after 120 seconds")
diagnostics.record(snapshots: [claude()])
current = lines(diagnostics)
require(current[5].contains("refresh FAILED #1 Timed out after 120 seconds"), "refresh failure")
require(current[6].contains("refresh recovered after 1 failed refresh(es)"), "refresh recovery")

// The file is private and trimmed to its size limit, keeping whole lines.
let permissions = (try? FileManager.default.attributesOfItem(atPath: diagnostics.fileURL.path)[.posixPermissions]) as? NSNumber
require(permissions?.intValue == 0o600, "log must be 0600")
let small = RefreshDiagnosticsLog(directory: directory.appendingPathComponent("small"), maxBytes: 4 * 1024)
for index in 0..<200 { small.recordRefreshFailure("failure \(index)") }
let data = (try? Data(contentsOf: small.fileURL)) ?? Data()
require(data.count <= 4 * 1024, "log is trimmed, size \(data.count)")
let trimmed = lines(small)
require(trimmed.last?.hasSuffix("failure 199") == true, "newest line kept")
require(trimmed.allSatisfy { $0.contains("refresh FAILED #") }, "trim keeps whole lines")

print("Refresh diagnostics regression passed")
