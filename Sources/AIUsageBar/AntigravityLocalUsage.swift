import Foundation
import SQLite3

/// Reads machine-local Antigravity conversation history (`~/.gemini/antigravity-cli/conversations/*.db`,
/// `~/.gemini/antigravity/*.db`, `~/.gemini/antigravity/conversations/*.db`, with a tokscale JSONL cache
/// fallback when no SQLite files exist) in read-only mode, without touching conversation text or spawning `agy`.
enum AntigravityLocalUsage {
    enum Coverage: Equatable {
        case complete
        case partial
        case unavailable
    }

    enum ScanFailure: Error {
        case exhausted
        case schemaExhausted
        case invalid
    }

    struct Context {
        let home: URL
        let additionalProfileHomes: [String]
        let environment: [String: String]

        init(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            additionalProfileHomes: [String] = [],
            homeOverride: URL? = nil
        ) {
            self.environment = environment
            self.additionalProfileHomes = additionalProfileHomes
            if let homeOverride = homeOverride {
                self.home = homeOverride
            } else if let rawHome = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !rawHome.isEmpty
            {
                self.home = URL(fileURLWithPath: rawHome, isDirectory: true)
            } else {
                self.home = FileManager.default.homeDirectoryForCurrentUser
            }
        }

        var databaseRoots: [URL] {
            Self.geminiHomeDirectories(
                home: self.home,
                environment: self.environment,
                additionalProfileHomes: self.additionalProfileHomes
            ).flatMap { geminiHome in
                ["antigravity-cli/conversations", "antigravity", "antigravity/conversations"].map {
                    geminiHome.appendingPathComponent($0, isDirectory: true)
                }
            }
        }

        var cacheRoot: URL {
            let tokscaleDir: URL
            if let override = self.environment["TOKSCALE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !override.isEmpty
            {
                tokscaleDir = URL(fileURLWithPath: override, isDirectory: true)
            } else {
                tokscaleDir = self.home.appendingPathComponent(".config/tokscale", isDirectory: true)
            }
            return tokscaleDir.appendingPathComponent("antigravity-cache/sessions", isDirectory: true)
        }

        static func geminiHomeDirectories(
            home: URL,
            environment: [String: String],
            additionalProfileHomes: [String]
        ) -> [URL] {
            let primary: URL
            if let override = environment["GEMINI_CLI_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !override.isEmpty
            {
                primary = URL(fileURLWithPath: override, isDirectory: true)
            } else {
                primary = home.appendingPathComponent(".gemini", isDirectory: true)
            }
            guard !additionalProfileHomes.isEmpty else { return [primary] }
            let additional = additionalProfileHomes.compactMap { raw -> URL? in
                let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty, !path.contains("\0") else { return nil }
                if path == "~" { return home }
                if path.hasPrefix("~/") {
                    return home.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
                }
                guard path.hasPrefix("/") else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            var seen = Set<String>()
            return ([primary] + additional).filter {
                seen.insert($0.standardizedFileURL.resolvingSymlinksInPath().path).inserted
            }
        }
    }

    struct Limits {
        var databases = 500
        var directoryEntries = 10_000
        var rowsPerDatabase = 10_000
        var rows = 100_000
        var blobBytes = 16 * 1024 * 1024
        var databaseBytes = 64 * 1024 * 1024
        var bytes = 512 * 1024 * 1024
        var schemaEntries = 128
        var schemaColumns = 64
        var schemaBytes = 64 * 1024
        var duration: TimeInterval = 30
    }

    struct Statistics {
        var directoryEntries = 0
        var files = 0
        var rows = 0
        var attemptedBytes = 0
        var materializedPayloadBytes = 0
        var schemaEntries = 0
        var schemaColumns = 0
        var schemaBytes = 0
        var sqliteHandlesOpened = 0
        var sqliteHandlesClosed = 0
        var immutableFallbacks = 0
        var foreignDatabases = 0
    }

    struct ScanResult {
        let payload: CostHistoryPayload?
        let coverage: Coverage
        let statistics: Statistics
        let evidenceIsContradicted: Bool
        let evidenceIsUnstable: Bool
    }

    final class Budget {
        let limits: Limits
        let cancellation: () throws -> Void
        let clock: () -> TimeInterval
        let started: TimeInterval
        var statistics = Statistics()
        private(set) var databaseSchemaBytes = 0

        init(
            limits: Limits,
            clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            cancellation: @escaping () throws -> Void = {}
        ) {
            self.limits = limits
            self.clock = clock
            self.started = clock()
            self.cancellation = cancellation
        }

        func check() throws {
            try self.cancellation()
            guard self.clock() - self.started < self.limits.duration else { throw ScanFailure.exhausted }
        }

        func chargeBytes(_ count: Int) throws {
            try self.check()
            let (attempted, overflow) = self.statistics.attemptedBytes.addingReportingOverflow(count)
            self.statistics.attemptedBytes = overflow ? Int.max : attempted
            guard !overflow, attempted <= self.limits.bytes else { throw ScanFailure.exhausted }
        }

        func chargeRow() throws {
            try self.check()
            self.statistics.rows += 1
            guard self.statistics.rows <= self.limits.rows else { throw ScanFailure.exhausted }
        }

        func beginDatabase() {
            self.databaseSchemaBytes = 0
        }

        func chargeSchemaBytes(_ count: Int) throws {
            try self.check()
            let (total, totalOverflow) = self.statistics.schemaBytes.addingReportingOverflow(count)
            self.statistics.schemaBytes = totalOverflow ? Int.max : total
            let (attempted, overflow) = self.databaseSchemaBytes.addingReportingOverflow(count)
            self.databaseSchemaBytes = overflow ? Int.max : attempted
            guard !overflow, attempted <= self.limits.schemaBytes else { throw ScanFailure.schemaExhausted }
        }
    }

    struct Event: Equatable {
        let session: String
        let row: Int64
        let turn: AntigravityProtoReader.ParsedTurn
        let cacheWrite: Int
        let input: Int
        let outputWithReasoning: Int
        let total: Int

        init?(session: String, row: Int64, turn: AntigravityProtoReader.ParsedTurn, cacheWrite: Int) {
            guard let usage = turn.usage,
                  turn.timestampMs != nil,
                  let combinedOutput = Self.checkedSum([usage.output, usage.reasoning]),
                  let total = Self.checkedSum([usage.newInput, combinedOutput, usage.cacheRead, cacheWrite])
            else { return nil }
            self.session = session
            self.row = row
            self.turn = turn
            self.cacheWrite = cacheWrite
            self.input = usage.newInput
            self.outputWithReasoning = combinedOutput
            self.total = total
        }

        static func checkedSum(_ values: [Int]) -> Int? {
            var sum = 0
            for value in values {
                guard value >= 0 else { return nil }
                let (next, overflow) = sum.addingReportingOverflow(value)
                if overflow { return nil }
                sum = next
            }
            return sum
        }
    }

    struct SourceResult {
        var events: [Event] = []
        var isComplete = true
        var containsHistorySource = false
        var evidenceIsUnstable = false
    }

    private struct Discovery {
        var paths: [URL] = []
        var isComplete = true
    }

    private struct RowIdentity: Hashable {
        let session: String
        let row: Int64
    }

    private struct ResponseIdentity: Hashable {
        let session: String
        let response: String
    }

    private struct LabelIdentity: Hashable {
        let session: String
        let label: String
    }

    private struct ModelAccumulator {
        var tokens = 0
        var costUSD: Double? = 0
        var hasUnpriced = false

        mutating func add(tokens delta: Int, cost: Double?) -> Bool {
            let (next, overflow) = self.tokens.addingReportingOverflow(delta)
            guard !overflow else { return false }
            self.tokens = next
            if let cost = cost {
                if !self.hasUnpriced {
                    self.costUSD = (self.costUSD ?? 0) + cost
                }
            } else {
                self.hasUnpriced = true
                self.costUSD = nil
            }
            return true
        }
    }

    private struct DayAccumulator {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheCreation = 0
        var total = 0
        var models: [String: ModelAccumulator] = [:]
        var hasUnpriced = false
        var knownCostSum = 0.0
        var hasAnyCost = false

        mutating func add(
            model: String,
            input: Int,
            output: Int,
            cacheRead: Int,
            cacheCreation: Int,
            total: Int,
            cost: Double?,
            unattributedZero: Bool
        ) -> Bool {
            let (nextIn, o1) = self.input.addingReportingOverflow(input)
            let (nextOut, o2) = self.output.addingReportingOverflow(output)
            let (nextRead, o3) = self.cacheRead.addingReportingOverflow(cacheRead)
            let (nextCreate, o4) = self.cacheCreation.addingReportingOverflow(cacheCreation)
            let (nextTotal, o5) = self.total.addingReportingOverflow(total)
            guard !o1, !o2, !o3, !o4, !o5 else { return false }

            if !unattributedZero {
                var modelAcc = self.models[model] ?? ModelAccumulator()
                guard modelAcc.add(tokens: total, cost: cost) else { return false }
                self.models[model] = modelAcc
            }
            self.input = nextIn
            self.output = nextOut
            self.cacheRead = nextRead
            self.cacheCreation = nextCreate
            self.total = nextTotal
            if let cost = cost {
                self.knownCostSum += cost
                self.hasAnyCost = true
            } else {
                self.hasUnpriced = true
            }
            return true
        }

        func makeDay(date: String) -> CostHistoryDay {
            let sortedNames = self.models.keys.sorted()
            let breakdowns: [CostModelBreakdown]? = sortedNames.isEmpty ? nil : sortedNames.map { name in
                let acc = self.models[name]!
                return CostModelBreakdown(
                    modelName: name,
                    cost: acc.hasUnpriced ? nil : acc.costUSD,
                    totalTokens: Double(acc.tokens))
            }
            let resolvedDayCost: Double?
            if self.hasUnpriced {
                resolvedDayCost = nil
            } else if self.hasAnyCost {
                resolvedDayCost = self.knownCostSum
            } else {
                resolvedDayCost = nil
            }
            return CostHistoryDay(
                date: date,
                inputTokens: Double(self.input),
                outputTokens: Double(self.output),
                cacheReadTokens: Double(self.cacheRead),
                cacheCreationTokens: Double(self.cacheCreation),
                totalTokens: Double(self.total),
                totalCost: resolvedDayCost,
                modelsUsed: sortedNames.isEmpty ? nil : sortedNames,
                modelBreakdowns: breakdowns)
        }
    }

    // MARK: - Public Entry Points

    static func supplementJSON(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        additionalProfileHomes: [String] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        let context = Context(environment: environment, additionalProfileHomes: additionalProfileHomes)
        let result = self.scan(context: context, now: now, calendar: calendar)
        guard let payload = result.payload else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func scan(
        context: Context,
        now: Date = Date(),
        calendar: Calendar = .current,
        limits: Limits = Limits(),
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        checkCancellation: @escaping () throws -> Void = {}
    ) -> ScanResult {
        let budget = Budget(limits: limits, clock: clock, cancellation: checkCancellation)
        do {
            let databases = try self.discover(roots: context.databaseRoots, suffix: "db", budget: budget)
            if !databases.paths.isEmpty || !databases.isComplete {
                let source = try self.readDatabases(databases.paths, budget: budget)
                return try self.aggregate(
                    source,
                    discoveryComplete: databases.isComplete,
                    now: now,
                    calendar: calendar,
                    budget: budget)
            }
            let cache = try self.discover(roots: [context.cacheRoot], suffix: "jsonl", budget: budget)
            guard !cache.paths.isEmpty || !cache.isComplete else {
                return ScanResult(
                    payload: nil,
                    coverage: .unavailable,
                    statistics: budget.statistics,
                    evidenceIsContradicted: false,
                    evidenceIsUnstable: false)
            }
            let source = try self.readJSONL(cache.paths, budget: budget)
            return try self.aggregate(
                source,
                discoveryComplete: cache.isComplete,
                now: now,
                calendar: calendar,
                budget: budget)
        } catch ScanFailure.exhausted, ScanFailure.schemaExhausted {
            return ScanResult(
                payload: nil,
                coverage: .partial,
                statistics: budget.statistics,
                evidenceIsContradicted: false,
                evidenceIsUnstable: false)
        } catch {
            return ScanResult(
                payload: nil,
                coverage: .unavailable,
                statistics: budget.statistics,
                evidenceIsContradicted: false,
                evidenceIsUnstable: false)
        }
    }

    // MARK: - Aggregation

    private static func aggregate(
        _ source: SourceResult,
        discoveryComplete: Bool,
        now: Date,
        calendar: Calendar,
        budget: Budget
    ) throws -> ScanResult {
        var isComplete = discoveryComplete
            && source.isComplete
            && budget.statistics.sqliteHandlesOpened == budget.statistics.sqliteHandlesClosed
        var contradicted = false

        if isComplete, !source.containsHistorySource {
            return ScanResult(
                payload: nil,
                coverage: .unavailable,
                statistics: budget.statistics,
                evidenceIsContradicted: false,
                evidenceIsUnstable: source.evidenceIsUnstable)
        }

        var models: [LabelIdentity: String] = [:]
        var conflicts = Set<LabelIdentity>()
        for event in source.events {
            try budget.check()
            if let label = event.turn.label, let model = event.turn.model {
                let key = LabelIdentity(session: event.session, label: label)
                if let prior = models[key], prior != model {
                    conflicts.insert(key)
                } else {
                    models[key] = model
                }
            }
        }

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"

        var rows: [RowIdentity: Event] = [:]
        var responses: [ResponseIdentity: Event] = [:]
        var byDay: [String: DayAccumulator] = [:]

        for event in source.events {
            try budget.check()
            guard let usage = event.turn.usage, let timestampMs = event.turn.timestampMs else {
                isComplete = false
                continue
            }
            let rowKey = RowIdentity(session: event.session, row: event.row)
            if let prior = rows[rowKey] {
                if prior != event {
                    isComplete = false
                    contradicted = true
                }
                continue
            }
            let responseKey = usage.responseID.map { ResponseIdentity(session: event.session, response: $0) }
            if let responseKey = responseKey, let prior = responses[responseKey] {
                if prior.turn != event.turn || prior.cacheWrite != event.cacheWrite {
                    isComplete = false
                    contradicted = true
                } else {
                    rows[rowKey] = event
                }
                continue
            }

            let labelKey = event.turn.label.map { LabelIdentity(session: event.session, label: $0) }
            let inherited = labelKey.flatMap { conflicts.contains($0) ? nil : models[$0] }
            let rawModel = (event.turn.model ?? inherited ?? "unknown").trimmingCharacters(in: .whitespacesAndNewlines)
            let model = rawModel.isEmpty ? "unknown" : rawModel
            let date = Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)
            let dayKey = dayFormatter.string(from: date)
            let unattributedZero = event.total == 0 && model == "unknown"
            let cost: Double? = unattributedZero ? 0 : AntigravityBuiltInPricing.costUSD(
                model: model,
                date: date,
                inputTokens: event.input,
                cacheReadTokens: usage.cacheRead,
                cacheWriteTokens: event.cacheWrite,
                outputTokens: event.outputWithReasoning)

            var dayAcc = byDay[dayKey] ?? DayAccumulator()
            guard dayAcc.add(
                model: model,
                input: event.input,
                output: event.outputWithReasoning,
                cacheRead: usage.cacheRead,
                cacheCreation: event.cacheWrite,
                total: event.total,
                cost: cost,
                unattributedZero: unattributedZero)
            else {
                isComplete = false
                continue
            }
            byDay[dayKey] = dayAcc
            rows[rowKey] = event
            if let responseKey = responseKey {
                responses[responseKey] = event
            }
        }

        let coverage: Coverage = isComplete ? .complete : .partial
        let daily = byDay.keys.sorted().map { byDay[$0]!.makeDay(date: $0) }

        // Publish either complete history (including complete empty DBs) or valid partial rows
        // when neither contradicted nor unstable.
        guard coverage == .complete || (!daily.isEmpty && !contradicted && !source.evidenceIsUnstable) else {
            return ScanResult(
                payload: nil,
                coverage: coverage,
                statistics: budget.statistics,
                evidenceIsContradicted: contradicted,
                evidenceIsUnstable: source.evidenceIsUnstable)
        }
        guard !contradicted, !source.evidenceIsUnstable else {
            return ScanResult(
                payload: nil,
                coverage: coverage,
                statistics: budget.statistics,
                evidenceIsContradicted: contradicted,
                evidenceIsUnstable: source.evidenceIsUnstable)
        }

        let todayKey = dayFormatter.string(from: now)
        let cutoffDate = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? .distantPast
        let cutoffKey = dayFormatter.string(from: cutoffDate)
        let recentDays = daily.filter { $0.date >= cutoffKey && $0.date <= todayKey }
        let todayRow = daily.first(where: { $0.date == todayKey })

        let sessionTokens: Double? = todayRow?.totalTokens ?? (coverage == .complete ? 0 : nil)
        let sessionCostUSD: Double? = todayRow != nil ? todayRow?.resolvedCost : (coverage == .complete && daily.isEmpty ? 0 : nil)
        let last30Tokens = recentDays.reduce(0.0) { $0 + ($1.totalTokens ?? 0) }
        let last30Cost: Double?
        if recentDays.isEmpty {
            last30Cost = coverage == .complete && daily.isEmpty ? 0 : nil
        } else {
            last30Cost = CostHistoryPayload.completeSum(recentDays.map(\.resolvedCost))
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        let payload = CostHistoryPayload(
            provider: "antigravity",
            source: "local",
            updatedAt: iso.string(from: now),
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCostUSD,
            last30DaysTokens: recentDays.isEmpty && coverage != .complete ? nil : last30Tokens,
            last30DaysCostUSD: last30Cost,
            daily: daily,
            totals: daily.isEmpty ? nil : CostHistoryTotals(
                inputTokens: daily.reduce(0.0) { $0 + ($1.inputTokens ?? 0) },
                outputTokens: daily.reduce(0.0) { $0 + ($1.outputTokens ?? 0) },
                cacheReadTokens: daily.reduce(0.0) { $0 + ($1.cacheReadTokens ?? 0) },
                cacheCreationTokens: daily.reduce(0.0) { $0 + ($1.cacheCreationTokens ?? 0) },
                totalTokens: daily.reduce(0.0) { $0 + ($1.totalTokens ?? 0) },
                totalCost: CostHistoryPayload.completeSum(daily.map(\.resolvedCost))),
            scanIsPartial: coverage == .partial ? true : nil)

        return ScanResult(
            payload: payload,
            coverage: coverage,
            statistics: budget.statistics,
            evidenceIsContradicted: false,
            evidenceIsUnstable: false)
    }

    // MARK: - Discovery

    private static func discover(roots: [URL], suffix: String, budget: Budget) throws -> Discovery {
        var result = Discovery()
        for root in roots {
            try budget.check()
            do {
                let values = try root.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else {
                    result.isComplete = false
                    continue
                }
            } catch {
                if (error as NSError).code == NSFileReadNoSuchFileError { continue }
                result.isComplete = false
                continue
            }
            var enumerationFailed = false
            guard let enumerator = FileManager.default.enumerator(
                at: root.resolvingSymlinksInPath(),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                })
            else {
                result.isComplete = false
                continue
            }
            while true {
                try budget.check()
                guard let url = enumerator.nextObject() as? URL else { break }
                budget.statistics.directoryEntries += 1
                guard budget.statistics.directoryEntries <= budget.limits.directoryEntries else {
                    throw ScanFailure.exhausted
                }
                guard !url.lastPathComponent.hasPrefix("."), url.pathExtension.lowercased() == suffix else {
                    continue
                }
                guard result.paths.count < budget.limits.databases else {
                    throw ScanFailure.exhausted
                }
                do {
                    let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey])
                    guard values.isRegularFile == true else {
                        result.isComplete = false
                        continue
                    }
                    result.paths.append(url)
                } catch {
                    result.isComplete = false
                }
            }
            if enumerationFailed { result.isComplete = false }
        }
        result.paths.sort { $0.path < $1.path }
        return result
    }

    // MARK: - SQLite Reader

    private struct SQLiteIdleDatabaseState: Equatable {
        let size: UInt64
        let modified: Date
        let fileNumber: UInt64
        let header: Data

        static func read(at url: URL) -> Self? {
            let resolved = url.resolvingSymlinksInPath()
            guard !FileManager.default.fileExists(atPath: resolved.path + "-wal"),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let modified = attributes[.modificationDate] as? Date,
                  let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let handle = try? FileHandle(forReadingFrom: resolved)
            else { return nil }
            defer { try? handle.close() }
            guard let header = try? handle.read(upToCount: 100) else { return nil }
            return Self(size: size, modified: modified, fileNumber: fileNumber, header: header)
        }

        static func immutableURI(for url: URL) -> String? {
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "%?#")
            guard let path = url.path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            return "file:\(path)?immutable=1"
        }
    }

    private enum OpenMode {
        case readOnly
        case immutable
    }

    private struct DatabaseAttempt {
        let source: SourceResult
        let cannotOpen: Bool

        init(_ source: SourceResult, cannotOpen: Bool = false) {
            self.source = source
            self.cannotOpen = cannotOpen
        }
    }

    private enum SQLiteTableSupport {
        case supported
        case foreign
        case unsupported
    }

    private final class SQLProgress {
        let budget: Budget
        var failure: Error?
        var databaseBytes = 0
        var databaseRows = 0

        var payloadLimit: Int {
            guard self.budget.statistics.rows < self.budget.limits.rows,
                  self.databaseRows < self.budget.limits.rowsPerDatabase else { return 0 }
            return min(
                self.budget.limits.blobBytes,
                self.budget.limits.databaseBytes - self.databaseBytes,
                self.budget.limits.bytes - self.budget.statistics.attemptedBytes)
        }

        init(budget: Budget) {
            self.budget = budget
        }

        func advance() -> Int32 {
            do {
                try self.budget.check()
                return 0
            } catch {
                self.failure = error
                return 1
            }
        }
    }

    private final class StepScanProgress {
        let progress: SQLProgress

        var payloadLimit: Int {
            let budget = self.progress.budget
            guard budget.statistics.rows < budget.limits.rows,
                  self.progress.databaseBytes < budget.limits.databaseBytes,
                  budget.statistics.attemptedBytes < budget.limits.bytes
            else { return 0 }
            return min(
                budget.limits.blobBytes,
                budget.limits.databaseBytes - self.progress.databaseBytes,
                budget.limits.bytes - budget.statistics.attemptedBytes)
        }

        init(progress: SQLProgress) {
            self.progress = progress
        }
    }

    private struct SQLitePayload {
        let byteCount: Int
        private let pointer: UnsafeRawPointer?

        init(statement: OpaquePointer) {
            let isBlob = sqlite3_column_type(statement, 2) == SQLITE_BLOB
            self.pointer = isBlob ? sqlite3_column_blob(statement, 2) : nil
            self.byteCount = isBlob ? Int(sqlite3_column_bytes(statement, 2)) : 0
        }

        func copy(declaredCount: Int, limit: Int) -> [UInt8]? {
            guard self.byteCount > 0,
                  self.byteCount == declaredCount,
                  self.byteCount <= limit,
                  let pointer = self.pointer
            else { return nil }
            return Array(UnsafeBufferPointer(
                start: pointer.assumingMemoryBound(to: UInt8.self),
                count: self.byteCount))
        }
    }

    private struct PendingTimestampRow {
        let row: Int64
        let stepUUID: String
        let turn: AntigravityProtoReader.ParsedTurn
    }

    private struct StepOccurrence {
        let row: Int64
        let timestampMs: Int64?
        let botID: String?
    }

    private struct ParsedRows {
        var source: SourceResult
        var pendingTimestampRows: [PendingTimestampRow]
        var stepOccurrences: [String: [StepOccurrence]]
        var botIDUses: [String: Int]
    }

    private struct ExactStepTimestamp {
        let stepUUID: String
        let timestampMs: Int64
    }

    private struct StepTimestampScan {
        let timestamps: [String: [Int64]]
        let byBotID: [String: ExactStepTimestamp]
        let ambiguousBotIDs: Set<String>
        let isComplete: Bool
    }

    private static func readDatabases(_ paths: [URL], budget: Budget) throws -> SourceResult {
        var result = SourceResult()
        for url in paths {
            do {
                try budget.check()
                budget.statistics.files += 1
                guard budget.statistics.files <= budget.limits.databases else { throw ScanFailure.exhausted }
                budget.beginDatabase()
                let source = try self.readDatabase(url, budget: budget)
                result.events.append(contentsOf: source.events)
                result.isComplete = result.isComplete && source.isComplete
                result.containsHistorySource = result.containsHistorySource || source.containsHistorySource
                result.evidenceIsUnstable = result.evidenceIsUnstable || source.evidenceIsUnstable
            } catch ScanFailure.schemaExhausted {
                result.isComplete = false
            }
        }
        return result
    }

    private static func readDatabase(_ url: URL, budget: Budget) throws -> SourceResult {
        let attempt = try self.readDatabase(url, budget: budget, mode: .readOnly)
        guard attempt.cannotOpen, let before = SQLiteIdleDatabaseState.read(at: url) else {
            return attempt.source
        }
        budget.statistics.immutableFallbacks += 1
        var source = try self.readDatabase(url, budget: budget, mode: .immutable).source
        guard SQLiteIdleDatabaseState.read(at: url) == before else {
            source.isComplete = false
            source.evidenceIsUnstable = true
            return source
        }
        return source
    }

    private static func openDatabase(
        _ url: URL,
        mode: OpenMode,
        budget: Budget
    ) -> (status: Int32, database: OpaquePointer?) {
        var database: OpaquePointer?
        let status: Int32
        switch mode {
        case .readOnly:
            status = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        case .immutable:
            if let uri = SQLiteIdleDatabaseState.immutableURI(for: url) {
                status = sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            } else {
                status = SQLITE_CANTOPEN
            }
        }
        if database != nil {
            budget.statistics.sqliteHandlesOpened += 1
        }
        guard status == SQLITE_OK, let opened = database else {
            if let leftover = database, sqlite3_close(leftover) == SQLITE_OK {
                budget.statistics.sqliteHandlesClosed += 1
            }
            return (status, nil)
        }
        return (status, opened)
    }

    private static func readDatabase(_ url: URL, budget: Budget, mode: OpenMode) throws -> DatabaseAttempt {
        let opened = self.openDatabase(url, mode: mode, budget: budget)
        guard let database = opened.database else {
            return DatabaseAttempt(SourceResult(isComplete: false), cannotOpen: opened.status == SQLITE_CANTOPEN)
        }
        defer {
            if sqlite3_close(database) == SQLITE_OK {
                budget.statistics.sqliteHandlesClosed += 1
            }
        }
        let progress = SQLProgress(budget: budget)
        let maximumValueBytes = min(budget.limits.blobBytes, 16 * 1024 * 1024) + 1024
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, Int32(min(maximumValueBytes, 64 * 1024)))
        let registered = sqlite3_create_function_v2(
            database,
            "antigravity_payload_limit",
            0,
            SQLITE_UTF8,
            Unmanaged.passUnretained(progress).toOpaque(),
            { context, _, _ in
                guard let context = context, let pointer = sqlite3_user_data(context) else { return }
                let progress = Unmanaged<SQLProgress>.fromOpaque(pointer).takeUnretainedValue()
                sqlite3_result_int64(context, Int64(progress.payloadLimit))
            },
            nil,
            nil,
            nil)
        guard registered == SQLITE_OK else { return DatabaseAttempt(SourceResult(isComplete: false)) }
        sqlite3_progress_handler(
            database,
            1000,
            { pointer in
                guard let pointer = pointer else { return 1 }
                return Unmanaged<SQLProgress>.fromOpaque(pointer).takeUnretainedValue().advance()
            },
            Unmanaged.passUnretained(progress).toOpaque())
        defer {
            withExtendedLifetime(progress) {
                sqlite3_progress_handler(database, 0, nil, nil)
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            }
        }

        let began = sqlite3_exec(database, "BEGIN DEFERRED", nil, nil, nil)
        guard began == SQLITE_OK else {
            if let failure = progress.failure { throw failure }
            return DatabaseAttempt(SourceResult(isComplete: false), cannotOpen: began == SQLITE_CANTOPEN)
        }

        let support = try self.inspectSQLiteTableSupport(database, budget: budget)
        if let failure = progress.failure { throw failure }
        switch support {
        case .supported:
            break
        case .foreign:
            budget.statistics.foreignDatabases += 1
            return DatabaseAttempt(SourceResult())
        case .unsupported:
            return DatabaseAttempt(
                SourceResult(isComplete: false),
                cannotOpen: sqlite3_errcode(database) == SQLITE_CANTOPEN)
        }

        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, Int32(maximumValueBytes))
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = """
        SELECT idx, CASE WHEN typeof(data) = 'blob' THEN length(data) END,
            CASE WHEN typeof(data) = 'blob' AND length(data) <= antigravity_payload_limit() THEN data END
        FROM main.gen_metadata NOT INDEXED LIMIT ?
        """
        let prepared = sqlite3_prepare_v2(database, query, -1, &statement, nil)
        if let failure = progress.failure { throw failure }
        guard prepared == SQLITE_OK, let activeStatement = statement else {
            return DatabaseAttempt(SourceResult(isComplete: false), cannotOpen: prepared == SQLITE_CANTOPEN)
        }
        sqlite3_bind_int64(activeStatement, 1, Int64(min(budget.limits.rowsPerDatabase, 10_000) + 1))
        let session = url.deletingPathExtension().lastPathComponent
        var rows = try self.readRows(activeStatement, session: session, progress: progress)
        if !rows.pendingTimestampRows.isEmpty {
            guard rows.source.isComplete else { return DatabaseAttempt(rows.source) }
            sqlite3_finalize(activeStatement)
            statement = nil
            let hasSteps = try self.inspectSQLiteTableSupport(
                database,
                table: "steps",
                payloadColumn: "metadata",
                budget: budget) == .supported
            if let failure = progress.failure { throw failure }
            if hasSteps {
                var neededStepOccurrences: [String: [StepOccurrence]] = [:]
                for stepUUID in Set(rows.pendingTimestampRows.map(\.stepUUID)) {
                    neededStepOccurrences[stepUUID] = rows.stepOccurrences[stepUUID] ?? []
                }
                let stepScan = try self.readStepTimestamps(
                    database,
                    neededStepOccurrences: neededStepOccurrences,
                    progress: progress)
                guard stepScan.isComplete,
                      self.embeddedTimestampsAgree(neededStepOccurrences, with: stepScan, botIDUses: rows.botIDUses)
                else {
                    rows.source.isComplete = false
                    return DatabaseAttempt(rows.source)
                }
                let recoveredCount = self.appendRecoveredEvents(
                    to: &rows,
                    session: session,
                    stepScan: stepScan)
                if recoveredCount < rows.pendingTimestampRows.count {
                    rows.source.isComplete = false
                }
            } else {
                rows.source.isComplete = false
            }
        }
        return DatabaseAttempt(rows.source)
    }

    private static func inspectSQLiteTableSupport(
        _ database: OpaquePointer,
        table: String = "gen_metadata",
        payloadColumn: String = "data",
        budget: Budget
    ) throws -> SQLiteTableSupport {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = "SELECT name, type, rootpage FROM main.sqlite_master LIMIT ?"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let active = statement
        else { return .unsupported }
        let cap = min(budget.limits.schemaEntries, 128)
        sqlite3_bind_int64(active, 1, Int64(cap + 1))
        var entries = 0
        while true {
            try budget.check()
            let step = sqlite3_step(active)
            if step == SQLITE_DONE { return entries > 0 && entries <= cap ? .foreign : .unsupported }
            guard step == SQLITE_ROW else { return .unsupported }
            entries += 1
            budget.statistics.schemaEntries += 1
            guard entries <= budget.limits.schemaEntries else { throw ScanFailure.schemaExhausted }
            guard let name = try self.schemaText(active, column: 0, budget: budget),
                  let type = try self.schemaText(active, column: 1, budget: budget)
            else { return .unsupported }
            guard name.lowercased() == table else { continue }
            guard type == "table",
                  sqlite3_column_type(active, 2) == SQLITE_INTEGER,
                  sqlite3_column_int64(active, 2) > 0
            else { return .unsupported }
            return try self.hasStoredSQLiteColumns(
                database,
                table: table,
                payloadColumn: payloadColumn,
                budget: budget) ? .supported : .unsupported
        }
    }

    private static func hasStoredSQLiteColumns(
        _ database: OpaquePointer,
        table: String,
        payloadColumn: String,
        budget: Budget
    ) throws -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "PRAGMA main.table_xinfo('\(table)')", -1, &statement, nil) == SQLITE_OK,
              let active = statement,
              sqlite3_column_count(active) >= 7
        else { return false }
        var columns = Set<String>()
        var count = 0
        while true {
            try budget.check()
            let step = sqlite3_step(active)
            if step == SQLITE_DONE { return columns.isSuperset(of: ["idx", payloadColumn]) }
            guard step == SQLITE_ROW else { return false }
            count += 1
            budget.statistics.schemaColumns += 1
            guard count <= min(budget.limits.schemaColumns, 64) else { throw ScanFailure.schemaExhausted }
            guard sqlite3_column_type(active, 6) == SQLITE_INTEGER,
                  sqlite3_column_int(active, 6) == 0
            else { return false }
            guard let name = try self.schemaText(active, column: 1, budget: budget) else { return false }
            _ = try self.schemaText(active, column: 2, budget: budget)
            _ = try self.schemaText(active, column: 4, budget: budget)
            columns.insert(name.lowercased())
        }
    }

    private static func schemaText(_ statement: OpaquePointer, column: Int32, budget: Budget) throws -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let pointer = sqlite3_column_text(statement, column)
        else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        try budget.chargeSchemaBytes(count)
        return String(bytes: UnsafeBufferPointer(start: pointer, count: count), encoding: .utf8)
    }

    private static func readRows(
        _ statement: OpaquePointer,
        session: String,
        progress: SQLProgress
    ) throws -> ParsedRows {
        let budget = progress.budget
        var result = SourceResult(containsHistorySource: true)
        var pendingTimestampRows: [PendingTimestampRow] = []
        var stepOccurrences: [String: [StepOccurrence]] = [:]
        var botIDUses: [String: Int] = [:]
        while true {
            try budget.check()
            let step = sqlite3_step(statement)
            if let failure = progress.failure { throw failure }
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                result.isComplete = false
                break
            }
            let payload = SQLitePayload(statement: statement)
            budget.statistics.materializedPayloadBytes += payload.byteCount
            progress.databaseRows += 1
            try budget.chargeRow()
            let count = Int(sqlite3_column_int64(statement, 1))
            let attemptedBytes = max(count, payload.byteCount)
            try budget.chargeBytes(attemptedBytes)
            guard progress.databaseRows <= budget.limits.rowsPerDatabase,
                  attemptedBytes <= budget.limits.databaseBytes - progress.databaseBytes
            else {
                throw ScanFailure.exhausted
            }
            progress.databaseBytes += attemptedBytes
            guard count > 0,
                  count <= budget.limits.blobBytes,
                  sqlite3_column_type(statement, 0) == SQLITE_INTEGER
            else {
                result.isComplete = false
                continue
            }
            let row = sqlite3_column_int64(statement, 0)
            guard row >= 0,
                  let bytes = payload.copy(declaredCount: count, limit: budget.limits.blobBytes),
                  let turn = try AntigravityProtoReader.parseTurn(bytes, checkCancellation: budget.check)
            else {
                result.isComplete = false
                continue
            }
            if let botID = turn.usage?.botID {
                botIDUses[botID, default: 0] += 1
            }
            if let stepUUID = turn.stepUUID {
                stepOccurrences[stepUUID, default: []].append(StepOccurrence(
                    row: row,
                    timestampMs: turn.timestampMs,
                    botID: turn.usage?.botID))
            }
            if turn.timestampMs == nil, let stepUUID = turn.stepUUID {
                pendingTimestampRows.append(PendingTimestampRow(row: row, stepUUID: stepUUID, turn: turn))
                continue
            }
            guard let event = Event(session: session, row: row, turn: turn, cacheWrite: 0) else {
                result.isComplete = false
                continue
            }
            result.events.append(event)
        }
        return ParsedRows(
            source: result,
            pendingTimestampRows: pendingTimestampRows,
            stepOccurrences: stepOccurrences,
            botIDUses: botIDUses)
    }

    private static func readStepTimestamps(
        _ database: OpaquePointer,
        neededStepOccurrences: [String: [StepOccurrence]],
        progress: SQLProgress
    ) throws -> StepTimestampScan {
        guard !neededStepOccurrences.isEmpty else {
            return StepTimestampScan(timestamps: [:], byBotID: [:], ambiguousBotIDs: [], isComplete: true)
        }
        let stepProgress = StepScanProgress(progress: progress)
        let registered = sqlite3_create_function_v2(
            database,
            "antigravity_step_payload_limit",
            0,
            SQLITE_UTF8,
            Unmanaged.passUnretained(stepProgress).toOpaque(),
            { context, _, _ in
                guard let context = context, let pointer = sqlite3_user_data(context) else { return }
                let progress = Unmanaged<StepScanProgress>.fromOpaque(pointer).takeUnretainedValue()
                sqlite3_result_int64(context, Int64(progress.payloadLimit))
            },
            nil,
            nil,
            nil)
        guard registered == SQLITE_OK else {
            return StepTimestampScan(timestamps: [:], byBotID: [:], ambiguousBotIDs: [], isComplete: false)
        }
        var statement: OpaquePointer?
        defer {
            withExtendedLifetime(stepProgress) {
                sqlite3_finalize(statement)
                sqlite3_create_function_v2(
                    database,
                    "antigravity_step_payload_limit",
                    0,
                    SQLITE_UTF8,
                    nil,
                    nil,
                    nil,
                    nil,
                    nil)
            }
        }
        // Only `steps.metadata` is read for timestamp recovery — `step_payload` (conversation text) is never queried.
        let query = """
        SELECT idx, CASE WHEN typeof(metadata) = 'blob' THEN length(metadata) END,
            CASE WHEN typeof(metadata) = 'blob'
                AND length(metadata) <= antigravity_step_payload_limit() THEN metadata END
        FROM main.steps NOT INDEXED
        """
        let prepared = sqlite3_prepare_v2(database, query, -1, &statement, nil)
        if let failure = progress.failure { throw failure }
        guard prepared == SQLITE_OK, let active = statement else {
            return StepTimestampScan(timestamps: [:], byBotID: [:], ambiguousBotIDs: [], isComplete: false)
        }
        var stepTimestamps: [String: [StepOccurrence]] = [:]
        var exactByBotID: [String: ExactStepTimestamp] = [:]
        var ambiguousBotIDs = Set<String>()
        var isComplete = false
        var rowsAreValid = true
        var sawUnidentifiedRows = false
        while true {
            try progress.budget.check()
            let step = sqlite3_step(active)
            if let failure = progress.failure { throw failure }
            if step == SQLITE_DONE {
                isComplete = true
                break
            }
            guard step == SQLITE_ROW else { break }
            let payload = SQLitePayload(statement: active)
            progress.budget.statistics.materializedPayloadBytes += payload.byteCount
            try progress.budget.chargeRow()
            let count = Int(sqlite3_column_int64(active, 1))
            let attemptedBytes = max(count, payload.byteCount)
            try progress.budget.chargeBytes(attemptedBytes)
            guard attemptedBytes <= progress.budget.limits.databaseBytes - progress.databaseBytes else {
                throw ScanFailure.exhausted
            }
            progress.databaseBytes += attemptedBytes
            guard count > 0,
                  count <= progress.budget.limits.blobBytes,
                  sqlite3_column_type(active, 0) == SQLITE_INTEGER,
                  sqlite3_column_int64(active, 0) >= 0,
                  let bytes = payload.copy(declaredCount: count, limit: progress.budget.limits.blobBytes),
                  let parsed = try AntigravityProtoReader.parseStepMetadata(bytes, checkCancellation: progress.budget.check)
            else {
                rowsAreValid = false
                continue
            }
            if let botID = parsed.botID {
                self.recordExactBotID(
                    botID,
                    stepUUID: parsed.stepUUID,
                    timestampMs: parsed.timestampMs,
                    exact: &exactByBotID,
                    ambiguous: &ambiguousBotIDs)
            }
            guard let stepUUID = parsed.stepUUID else {
                sawUnidentifiedRows = true
                continue
            }
            if neededStepOccurrences[stepUUID] != nil {
                stepTimestamps[stepUUID, default: []].append(StepOccurrence(
                    row: sqlite3_column_int64(active, 0),
                    timestampMs: parsed.timestampMs,
                    botID: parsed.botID))
            }
        }
        let resolved = self.resolveStepTimestamps(
            stepTimestamps,
            neededStepOccurrences: neededStepOccurrences,
            ambiguousBotIDs: ambiguousBotIDs,
            unidentifiedRowsPresent: sawUnidentifiedRows)
        return StepTimestampScan(
            timestamps: resolved,
            byBotID: exactByBotID,
            ambiguousBotIDs: ambiguousBotIDs,
            isComplete: isComplete && rowsAreValid)
    }

    private static func recordExactBotID(
        _ botID: String,
        stepUUID: String?,
        timestampMs: Int64?,
        exact: inout [String: ExactStepTimestamp],
        ambiguous: inout Set<String>
    ) {
        guard !ambiguous.contains(botID) else { return }
        guard let stepUUID = stepUUID, let timestampMs = timestampMs else {
            exact.removeValue(forKey: botID)
            ambiguous.insert(botID)
            return
        }
        if let existing = exact[botID] {
            if existing.timestampMs != timestampMs || existing.stepUUID != stepUUID {
                exact.removeValue(forKey: botID)
                ambiguous.insert(botID)
            }
        } else {
            exact[botID] = ExactStepTimestamp(stepUUID: stepUUID, timestampMs: timestampMs)
        }
    }

    private static func embeddedTimestampsAgree(
        _ occurrences: [String: [StepOccurrence]],
        with stepScan: StepTimestampScan,
        botIDUses: [String: Int]
    ) -> Bool {
        for (stepUUID, rows) in occurrences {
            for row in rows {
                guard let timestampMs = row.timestampMs, let botID = row.botID else { continue }
                guard !stepScan.ambiguousBotIDs.contains(botID) else { return false }
                if let exact = stepScan.byBotID[botID],
                   exact.stepUUID != stepUUID || (botIDUses[botID] == 1 && exact.timestampMs != timestampMs)
                {
                    return false
                }
            }
        }
        return true
    }

    private static func resolveStepTimestamps(
        _ stepTimestamps: [String: [StepOccurrence]],
        neededStepOccurrences: [String: [StepOccurrence]],
        ambiguousBotIDs: Set<String>,
        unidentifiedRowsPresent: Bool
    ) -> [String: [Int64]] {
        var resolved: [String: [Int64]] = [:]
        for (stepUUID, timestamps) in stepTimestamps {
            guard let occurrences = neededStepOccurrences[stepUUID] else { continue }
            let sortedOccurrences = occurrences.sorted { $0.row < $1.row }
            guard Set(sortedOccurrences.map(\.row)).count == sortedOccurrences.count else { continue }
            let neededCount = sortedOccurrences.count
            let sorted = timestamps.sorted { $0.row < $1.row }
            guard !zip(sorted, sorted.dropFirst()).contains(where: { $0.0.row == $0.1.row }) else { continue }
            let orderedTimestamps: [Int64?] = sorted.map { step in
                step.botID.map { ambiguousBotIDs.contains($0) } == true ? nil : step.timestampMs
            }
            let selected: [Int64]
            if orderedTimestamps.count == 1,
               neededCount == 1 || !unidentifiedRowsPresent,
               let sharedTimestamp = orderedTimestamps[0]
            {
                selected = Array(repeating: sharedTimestamp, count: neededCount)
            } else {
                guard orderedTimestamps.count >= neededCount else { continue }
                let candidates = orderedTimestamps.prefix(neededCount)
                guard candidates.allSatisfy({ $0 != nil }) else { continue }
                selected = candidates.compactMap { $0 }
            }
            guard zip(sortedOccurrences, selected).allSatisfy({ $0.0.timestampMs == nil || $0.0.timestampMs == $0.1 }) else {
                continue
            }
            resolved[stepUUID] = selected
        }
        return resolved
    }

    private static func appendRecoveredEvents(
        to rows: inout ParsedRows,
        session: String,
        stepScan: StepTimestampScan
    ) -> Int {
        var occurrenceOffsets: [String: [Int64: Int]] = [:]
        for (stepUUID, occurrences) in rows.stepOccurrences {
            let sorted = occurrences.map(\.row).sorted()
            guard Set(sorted).count == sorted.count else { continue }
            occurrenceOffsets[stepUUID] = Dictionary(
                uniqueKeysWithValues: sorted.enumerated().map { ($0.element, $0.offset) })
        }
        var recoveredCount = 0
        for pending in rows.pendingTimestampRows.sorted(by: { $0.row < $1.row }) {
            if let botID = pending.turn.usage?.botID {
                if stepScan.ambiguousBotIDs.contains(botID) {
                    continue
                }
                if let exact = stepScan.byBotID[botID] {
                    guard exact.stepUUID == pending.stepUUID else { continue }
                }
                if rows.botIDUses[botID] == 1, let exact = stepScan.byBotID[botID] {
                    var turn = pending.turn
                    turn.timestampMs = exact.timestampMs
                    if let event = Event(session: session, row: pending.row, turn: turn, cacheWrite: 0) {
                        rows.source.events.append(event)
                        recoveredCount += 1
                    }
                    continue
                }
            }
            guard let timestamps = stepScan.timestamps[pending.stepUUID],
                  let offset = occurrenceOffsets[pending.stepUUID]?[pending.row],
                  timestamps.indices.contains(offset)
            else { continue }
            var turn = pending.turn
            turn.timestampMs = timestamps[offset]
            if let event = Event(session: session, row: pending.row, turn: turn, cacheWrite: 0) {
                rows.source.events.append(event)
                recoveredCount += 1
            }
        }
        rows.source.events.sort { $0.row < $1.row }
        return recoveredCount
    }

    // MARK: - Tokscale JSONL Fallback

    private struct JSONLSession {
        var id: String?
        var model: String?
        var line: Int64 = 0
    }

    private static func readJSONL(_ paths: [URL], budget: Budget) throws -> SourceResult {
        var result = SourceResult()
        for url in paths {
            try budget.check()
            budget.statistics.files += 1
            guard budget.statistics.files <= budget.limits.databases else { throw ScanFailure.exhausted }
            let source = try self.readJSONLFile(url, budget: budget)
            result.events.append(contentsOf: source.events)
            result.isComplete = result.isComplete && source.isComplete
            result.containsHistorySource = result.containsHistorySource || source.containsHistorySource
        }
        return result
    }

    private static func readJSONLFile(_ url: URL, budget: Budget) throws -> SourceResult {
        let values: URLResourceValues
        do {
            values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        } catch {
            return SourceResult(isComplete: false)
        }
        guard values.isRegularFile == true, let size = values.fileSize else {
            return SourceResult(isComplete: false)
        }
        if size > budget.limits.databaseBytes || size > budget.limits.bytes - budget.statistics.attemptedBytes {
            try budget.chargeBytes(size)
            throw ScanFailure.exhausted
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return SourceResult(isComplete: false)
        }
        defer { try? handle.close() }
        var result = SourceResult()
        var session = JSONLSession()
        var line: [UInt8] = []
        var fileBytes = 0
        while true {
            try budget.check()
            let remaining = min(
                budget.limits.databaseBytes - fileBytes,
                budget.limits.bytes - budget.statistics.attemptedBytes)
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: min(65536, remaining + 1)) ?? Data()
            } catch {
                result.isComplete = false
                break
            }
            if chunk.isEmpty { break }
            try budget.chargeBytes(chunk.count)
            fileBytes += chunk.count
            guard fileBytes <= budget.limits.databaseBytes else { throw ScanFailure.exhausted }
            for (index, byte) in chunk.enumerated() {
                if index % 4096 == 0 { try budget.check() }
                if byte == 10 {
                    try self.consumeJSONLLine(line, session: &session, result: &result, budget: budget)
                    line.removeAll(keepingCapacity: true)
                } else {
                    guard line.count < budget.limits.blobBytes else { throw ScanFailure.exhausted }
                    line.append(byte)
                }
            }
        }
        if !line.isEmpty {
            try self.consumeJSONLLine(line, session: &session, result: &result, budget: budget)
        }
        result.containsHistorySource = session.id != nil
        if session.id == nil { result.isComplete = false }
        return result
    }

    private static func consumeJSONLLine(
        _ line: [UInt8],
        session: inout JSONLSession,
        result: inout SourceResult,
        budget: Budget
    ) throws {
        try budget.chargeRow()
        session.line += 1
        guard session.line <= budget.limits.rowsPerDatabase else { throw ScanFailure.exhausted }
        if line.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) { return }
        guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
            result.isComplete = false
            return
        }
        do {
            guard let type = json["type"] as? String else { throw ScanFailure.invalid }
            if type == "session_meta" {
                let id = try self.optionalString(json, keys: ["sessionId"])
                guard let id = id, session.id == nil || session.id == id else { throw ScanFailure.invalid }
                session.id = id
                session.model = try self.optionalString(json, keys: ["modelId", "model_id"])
                return
            }
            guard type == "usage" else { throw ScanFailure.invalid }
            let id = try self.optionalString(json, keys: ["sessionId"]) ?? session.id
            guard let validID = id,
                  session.id == nil || session.id == validID,
                  let timestamp = try self.optionalTimestamp(json["timestamp"])
            else { throw ScanFailure.invalid }
            var usage = AntigravityProtoReader.ParsedUsage()
            usage.newInput = try self.jsonCounter(json, keys: ["input"], required: true)
            usage.output = try self.jsonCounter(json, keys: ["output"], required: true)
            usage.cacheRead = try self.jsonCounter(json, keys: ["cacheRead", "cache_read"])
            usage.reasoning = try self.jsonCounter(json, keys: ["reasoning"])
            // JSONL does not establish whether `output` already includes `reasoning`.
            guard usage.reasoning == 0 else { throw ScanFailure.invalid }
            usage.responseID = try self.optionalString(json, keys: ["responseId", "response_id"])
            let write = try self.jsonCounter(json, keys: ["cacheWrite", "cache_write"])
            let model = try self.optionalString(json, keys: ["modelId", "model_id"]) ?? session.model
            let turn = AntigravityProtoReader.ParsedTurn(usage: usage, timestampMs: timestamp, model: model)
            guard let event = Event(session: validID, row: session.line, turn: turn, cacheWrite: write) else {
                throw ScanFailure.invalid
            }
            session.id = validID
            result.events.append(event)
        } catch {
            result.isComplete = false
        }
    }

    private static func exactNonnegativeInt(_ value: Any) throws -> Int {
        guard let number = value as? NSNumber else { throw ScanFailure.invalid }
        // Reject booleans bridged to NSNumber.
        if CFGetTypeID(number) == CFBooleanGetTypeID() { throw ScanFailure.invalid }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite, doubleValue >= 0, doubleValue.rounded() == doubleValue,
              let exact = Int(exactly: doubleValue)
        else { throw ScanFailure.invalid }
        return exact
    }

    private static func jsonCounter(_ json: [String: Any], keys: [String], required: Bool = false) throws -> Int {
        var counter: Int?
        for key in keys {
            guard let value = json[key] else { continue }
            let integer = try self.exactNonnegativeInt(value)
            guard counter == nil || counter == integer else { throw ScanFailure.invalid }
            counter = integer
        }
        guard !required || counter != nil else { throw ScanFailure.invalid }
        return counter ?? 0
    }

    private static func optionalString(_ json: [String: Any], keys: [String]) throws -> String? {
        var text: String?
        for key in keys {
            guard let value = json[key], !(value is NSNull) else { continue }
            guard let string = value as? String else { throw ScanFailure.invalid }
            if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard text == nil || text == string else { throw ScanFailure.invalid }
            text = string
        }
        return text
    }

    private static func optionalTimestamp(_ value: Any?) throws -> Int64? {
        guard let value = value, !(value is NSNull) else { return nil }
        let timestamp = try self.exactNonnegativeInt(value)
        guard timestamp > 0, timestamp <= 253_402_300_799_999 else { throw ScanFailure.invalid }
        return Int64(timestamp)
    }
}

/// Built-in public API pricing for Antigravity local usage estimation.
///
/// Covers published Claude, GPT-OSS (Vertex MaaS), OpenAI GPT, and Gemini 2.5/3.x rates.
/// Models without published API pricing (such as Gemini 4 Carbon / Argon) intentionally
/// return `nil` so only their exact token counts are shown.
enum AntigravityBuiltInPricing {
    struct RateSchedule {
        let inputPerMillion: Double
        let outputPerMillion: Double
        let cacheReadPerMillion: Double?
        let cacheWritePerMillion: Double?
        let thresholdTokens: Int?
        let inputAbovePerMillion: Double?
        let outputAbovePerMillion: Double?
        let cacheReadAbovePerMillion: Double?
        let cacheWriteAbovePerMillion: Double?

        init(
            input: Double,
            output: Double,
            cacheRead: Double? = nil,
            cacheWrite: Double? = nil,
            threshold: Int? = nil,
            inputAbove: Double? = nil,
            outputAbove: Double? = nil,
            cacheReadAbove: Double? = nil,
            cacheWriteAbove: Double? = nil
        ) {
            self.inputPerMillion = input
            self.outputPerMillion = output
            self.cacheReadPerMillion = cacheRead
            self.cacheWritePerMillion = cacheWrite
            self.thresholdTokens = threshold
            self.inputAbovePerMillion = inputAbove
            self.outputAbovePerMillion = outputAbove
            self.cacheReadAbovePerMillion = cacheReadAbove
            self.cacheWriteAbovePerMillion = cacheWriteAbove
        }

        func costUSD(
            inputTokens: Int,
            cacheReadTokens: Int,
            cacheWriteTokens: Int,
            outputTokens: Int
        ) -> Double {
            let unit = 1_000_000.0
            let input = max(0, inputTokens)
            let cacheRead = max(0, cacheReadTokens)
            let cacheWrite = max(0, cacheWriteTokens)
            let output = max(0, outputTokens)
            let usesLongContext = self.thresholdTokens.map { threshold in
                AntigravityLocalUsage.Event.checkedSum([input, cacheRead, cacheWrite]).map { $0 > threshold } ?? true
            } ?? false

            let inRate = (usesLongContext ? (self.inputAbovePerMillion ?? self.inputPerMillion) : self.inputPerMillion) / unit
            let readBase = self.cacheReadPerMillion ?? self.inputPerMillion
            let readRate = (usesLongContext ? (self.cacheReadAbovePerMillion ?? readBase) : readBase) / unit
            let writeBase = self.cacheWritePerMillion ?? self.inputPerMillion
            let writeRate = (usesLongContext ? (self.cacheWriteAbovePerMillion ?? writeBase) : writeBase) / unit
            let outRate = (usesLongContext ? (self.outputAbovePerMillion ?? self.outputPerMillion) : self.outputPerMillion) / unit

            return Double(input) * inRate
                + Double(cacheRead) * readRate
                + Double(cacheWrite) * writeRate
                + Double(output) * outRate
        }
    }

    private static let routingVariantSuffixes = ["-tiered", "-low", "-thinking"]

    private static let antigravityAliases: [String: String] = [
        "gemini-pro-default": "gemini-3.1-pro-preview",
        "gemini-pro-agent": "gemini-3.1-pro-preview",
        "gemini-3.1-pro": "gemini-3.1-pro-preview",
        "gemini-3.1-pro-high": "gemini-3.1-pro-preview",
        "gemini-3.1-pro-low": "gemini-3.1-pro-preview",
        "gemini-3.7-flash-safety-le": "gemini-3.7-flash",
    ]

    private static let claudeFullContextCutoff = Date(timeIntervalSince1970: 1_773_360_000)
    private static let geminiFlashIntroCutoff = Date(timeIntervalSince1970: 1_798_761_600) // 2027-01-01 00:00 UTC

    private static let claudeHistoricalLongContext: [String: RateSchedule] = [
        "claude-opus-4-6": RateSchedule(
            input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25,
            threshold: 200_000, inputAbove: 10, outputAbove: 37.5, cacheReadAbove: 1.0, cacheWriteAbove: 12.5),
        "claude-sonnet-4-6": RateSchedule(
            input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75,
            threshold: 200_000, inputAbove: 6, outputAbove: 22.5, cacheReadAbove: 0.6, cacheWriteAbove: 7.5),
    ]

    private static let rates: [String: RateSchedule] = [
        // Anthropic Claude (upstream CostUsagePricing)
        "claude-haiku-4-5": RateSchedule(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25),
        "claude-haiku-4-5-20251001": RateSchedule(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25),
        "claude-sonnet-4-20250514": RateSchedule(
            input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75,
            threshold: 200_000, inputAbove: 6, outputAbove: 22.5, cacheReadAbove: 0.6, cacheWriteAbove: 7.5),
        "claude-sonnet-4-5": RateSchedule(
            input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75,
            threshold: 200_000, inputAbove: 6, outputAbove: 22.5, cacheReadAbove: 0.6, cacheWriteAbove: 7.5),
        "claude-sonnet-4-5-20250929": RateSchedule(
            input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75,
            threshold: 200_000, inputAbove: 6, outputAbove: 22.5, cacheReadAbove: 0.6, cacheWriteAbove: 7.5),
        "claude-sonnet-4-6": RateSchedule(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        "claude-opus-4-20250514": RateSchedule(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75),
        "claude-opus-4-1": RateSchedule(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75),
        "claude-opus-4-5": RateSchedule(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-5-20251101": RateSchedule(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-6": RateSchedule(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-6-20260205": RateSchedule(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-7": RateSchedule(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-opus-4-8": RateSchedule(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        "claude-fable-5": RateSchedule(input: 10, output: 50, cacheRead: 1.0, cacheWrite: 12.5),
        "claude-mythos-5": RateSchedule(input: 10, output: 50, cacheRead: 1.0, cacheWrite: 12.5),
        "claude-mythos-5-1": RateSchedule(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5),
        "claude-mythos-5-2": RateSchedule(input: 8, output: 40, cacheRead: 0.2, cacheWrite: 10),

        // GPT-OSS on Google Vertex MaaS (`openai/gpt-oss-120b-maas`)
        "gpt-oss-120b-medium": RateSchedule(input: 0.09, output: 0.36),
        "openai/gpt-oss-120b-maas": RateSchedule(input: 0.09, output: 0.36),

        // OpenAI GPT public rates
        "gpt-5": RateSchedule(input: 1.25, output: 10, cacheRead: 0.125),
        "gpt-5-mini": RateSchedule(input: 0.25, output: 2, cacheRead: 0.025),
        "gpt-5-nano": RateSchedule(input: 0.05, output: 0.4, cacheRead: 0.005),
        "gpt-5.1": RateSchedule(input: 1.25, output: 10, cacheRead: 0.125),
        "gpt-5.2": RateSchedule(input: 1.75, output: 14, cacheRead: 0.175),
        "gpt-5.4": RateSchedule(
            input: 2.5, output: 15, cacheRead: 0.25,
            threshold: 272_000, inputAbove: 5, outputAbove: 22.5, cacheReadAbove: 0.5),
        "gpt-5.4-mini": RateSchedule(input: 0.75, output: 4.5, cacheRead: 0.075),
        "gpt-5.4-nano": RateSchedule(input: 0.2, output: 1.25, cacheRead: 0.02),
        "gpt-5.5": RateSchedule(
            input: 5, output: 30, cacheRead: 0.5,
            threshold: 272_000, inputAbove: 10, outputAbove: 45, cacheReadAbove: 1.0),
        "gpt-5.6-sol": RateSchedule(
            input: 4, output: 20, cacheRead: 0.4, cacheWrite: 5,
            threshold: 272_000, inputAbove: 8, outputAbove: 30, cacheReadAbove: 0.8, cacheWriteAbove: 10),
        "gpt-5.6-terra": RateSchedule(
            input: 2, output: 12, cacheRead: 0.2, cacheWrite: 2.5,
            threshold: 272_000, inputAbove: 4, outputAbove: 18, cacheReadAbove: 0.4, cacheWriteAbove: 5),
        "gpt-5.6-luna": RateSchedule(
            input: 0.2, output: 1.2, cacheRead: 0.02, cacheWrite: 0.25,
            threshold: 272_000, inputAbove: 0.4, outputAbove: 1.8, cacheReadAbove: 0.04, cacheWriteAbove: 0.5),
        "gpt-6-astra": RateSchedule(
            input: 10, output: 50, cacheRead: 1.0, cacheWrite: 12.5,
            threshold: 272_000, inputAbove: 20, outputAbove: 75, cacheReadAbove: 2.0, cacheWriteAbove: 25),
        "gpt-6-sol": RateSchedule(
            input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5,
            threshold: 272_000, inputAbove: 4, outputAbove: 15, cacheReadAbove: 0.4, cacheWriteAbove: 5),
        "gpt-6-luna": RateSchedule(
            input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125,
            threshold: 272_000, inputAbove: 0.2, outputAbove: 0.75, cacheReadAbove: 0.02, cacheWriteAbove: 0.25),
        "gpt-6.1-sol": RateSchedule(
            input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2.5,
            threshold: 272_000, inputAbove: 4, outputAbove: 15, cacheReadAbove: 0.2, cacheWriteAbove: 5),
        "gpt-6.1-terra": RateSchedule(
            input: 1, output: 5, cacheRead: 0.05, cacheWrite: 1.25,
            threshold: 272_000, inputAbove: 2, outputAbove: 7.5, cacheReadAbove: 0.1, cacheWriteAbove: 2.5),

        // Google Gemini 2.5 & 3.x published rates (Gemini 4 series intentionally omitted -> token-only)
        "gemini-2.5-pro": RateSchedule(
            input: 1.25, output: 10, cacheRead: 0.125,
            threshold: 200_000, inputAbove: 2.5, outputAbove: 15, cacheReadAbove: 0.25),
        "gemini-2.5-flash": RateSchedule(input: 0.3, output: 2.5, cacheRead: 0.03),
        "gemini-2.5-flash-lite": RateSchedule(input: 0.1, output: 0.4, cacheRead: 0.01),
        "gemini-3-pro-preview": RateSchedule(
            input: 2.0, output: 12.0, cacheRead: 0.2,
            threshold: 200_000, inputAbove: 4.0, outputAbove: 18.0, cacheReadAbove: 0.4),
        "gemini-3.1-pro-preview": RateSchedule(
            input: 2.0, output: 12.0, cacheRead: 0.2,
            threshold: 200_000, inputAbove: 4.0, outputAbove: 18.0, cacheReadAbove: 0.4),
        "gemini-3-flash-preview": RateSchedule(input: 0.5, output: 3.0, cacheRead: 0.05),
        "gemini-3.7-flash": RateSchedule(input: 1.5, output: 7.5, cacheRead: 0.15),
        "gemini-3.8-flash": RateSchedule(input: 1.5, output: 7.5, cacheRead: 0.15),
    ]

    static func pricingBaseModelID(for model: String) -> String? {
        let lowered = model.lowercased()
        if let alias = self.antigravityAliases[lowered] { return alias }
        guard let suffix = self.routingVariantSuffixes.first(where: { lowered.hasSuffix($0) }) else { return nil }
        let base = String(model.dropLast(suffix.count))
        guard !base.isEmpty else { return nil }
        return self.antigravityAliases[base.lowercased()] ?? base
    }

    static func normalizeVendorModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("openai/") && trimmed != "openai/gpt-oss-120b-maas" {
            trimmed = String(trimmed.dropFirst("openai/".count))
        }
        if trimmed.hasPrefix("google/") {
            trimmed = String(trimmed.dropFirst("google/".count))
        }
        if trimmed.hasPrefix("anthropic/") {
            trimmed = String(trimmed.dropFirst("anthropic/".count))
        }
        if trimmed.hasPrefix("anthropic.") {
            trimmed = String(trimmed.dropFirst("anthropic.".count))
        }
        if let lastDot = trimmed.lastIndex(of: "."), trimmed.contains("claude-") {
            let tail = String(trimmed[trimmed.index(after: lastDot)...])
            if tail.hasPrefix("claude-") { trimmed = tail }
        }
        if let vRange = trimmed.range(of: #"-v\d+:\d+$"#, options: .regularExpression) {
            trimmed.removeSubrange(vRange)
        }
        if trimmed == "gpt-5.6" { return "gpt-5.6-sol" }
        if self.rates[trimmed] != nil { return trimmed }
        if let baseRange = trimmed.range(of: #"-\d{8}$"#, options: .regularExpression) {
            let base = String(trimmed[..<baseRange.lowerBound])
            if self.rates[base] != nil { return base }
        }
        if let datedRange = trimmed.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            let base = String(trimmed[..<datedRange.lowerBound])
            if self.rates[base] != nil { return base }
        }
        return trimmed
    }

    static func schedule(for rawModel: String, date: Date?) -> RateSchedule? {
        let candidates = [rawModel] + [self.pricingBaseModelID(for: rawModel)].compactMap { $0 }
        for candidate in candidates {
            let key = self.normalizeVendorModel(candidate)
            if let date = date,
               date < self.claudeFullContextCutoff,
               let historical = self.claudeHistoricalLongContext[key]
            {
                return historical
            }
            if (key == "gemini-3.7-flash" || key == "gemini-3.8-flash"),
               let date = date,
               date < self.geminiFlashIntroCutoff
            {
                return RateSchedule(input: 0.75, output: 3.75, cacheRead: 0.075)
            }
            if let found = self.rates[key] {
                return found
            }
        }
        return nil
    }

    static func costUSD(
        model: String,
        date: Date?,
        inputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        outputTokens: Int
    ) -> Double? {
        guard let schedule = self.schedule(for: model, date: date) else { return nil }
        return schedule.costUSD(
            inputTokens: inputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            outputTokens: outputTokens)
    }
}
