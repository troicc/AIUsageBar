import Foundation

/// Minute-level activity of Claude Code on this Mac, read incrementally from
/// its session logs (`~/.claude/projects/**/*.jsonl`). Used only to tell
/// whether a rise in the shared Claude quota coincided with local Claude
/// Code work; web and desktop chats leave no local trace.
actor ClaudeCodeActivityLog {
    private let roots: [URL]
    private let window: TimeInterval
    /// Bytes already consumed per file, so each refresh reads only new lines.
    private var offsets: [String: UInt64] = [:]
    /// Tokens per epoch minute (seconds / 60).
    private var minutes: [Int: Double] = [:]
    /// Large files first seen mid-life are read from this many trailing bytes.
    private let initialTailBytes: UInt64 = 16 * 1024 * 1024
    private let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let isoPlain = ISO8601DateFormatter()

    init(
        roots: [URL]? = nil,
        window: TimeInterval = 26 * 3600,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        if let roots = roots {
            self.roots = roots
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            var candidates = [
                home.appendingPathComponent(".claude/projects", isDirectory: true),
                home.appendingPathComponent(".config/claude/projects", isDirectory: true),
            ]
            if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
                candidates.insert(URL(fileURLWithPath: custom).appendingPathComponent("projects", isDirectory: true), at: 0)
            }
            self.roots = candidates
        }
        self.window = window
    }

    /// Epoch minutes with local Claude Code token usage inside the window.
    func activeMinutes(now: Date = Date()) -> Set<Int> {
        scan(now: now)
        return Set(minutes.filter { $0.value > 0 }.keys)
    }

    private func scan(now: Date) {
        let cutoff = now.addingTimeInterval(-window)
        let fileManager = FileManager.default
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let modified = values.contentModificationDate, modified >= cutoff,
                      let size = values.fileSize.map(UInt64.init)
                else { continue }
                read(url, size: size, cutoff: cutoff)
            }
        }
        let oldest = Int(cutoff.timeIntervalSince1970 / 60)
        minutes = minutes.filter { $0.key >= oldest }
    }

    private func read(_ url: URL, size: UInt64, cutoff: Date) {
        let key = url.path
        var start = offsets[key] ?? (size > initialTailBytes ? size - initialTailBytes : 0)
        if start > size { start = 0 } // truncated or replaced
        guard size > start, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: start)
            guard let data = try handle.readToEnd(), !data.isEmpty else { return }
            // Consume complete lines only; a line still being written is
            // picked up on the next scan.
            guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
            let complete = data[data.startIndex...lastNewline]
            var lineStart = complete.startIndex
            // A tail read may start mid-line; skip to the first full line.
            if offsets[key] == nil, start > 0, let first = complete.firstIndex(of: 0x0A) {
                lineStart = complete.index(after: first)
            }
            for index in complete.indices[lineStart...] where complete[index] == 0x0A {
                consume(complete[lineStart..<index], cutoff: cutoff)
                lineStart = complete.index(after: index)
            }
            offsets[key] = start + UInt64(complete.count)
        } catch {
            return
        }
    }

    private func consume(_ line: Data, cutoff: Date) {
        // Cheap prefilter before JSON parsing: only assistant turns with usage.
        guard line.count > 40,
              line.range(of: Data("\"usage\"".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let stamp = object["timestamp"] as? String,
              let date = isoFractional.date(from: stamp) ?? isoPlain.date(from: stamp),
              date >= cutoff,
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return }
        let tokens = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
            .compactMap { (usage[$0] as? NSNumber)?.doubleValue }
            .reduce(0, +)
        guard tokens > 0 else { return }
        minutes[Int(date.timeIntervalSince1970 / 60), default: 0] += tokens
    }
}
