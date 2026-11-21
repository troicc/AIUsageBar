import Foundation
import SQLite3

func require(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    guard condition() else {
        fputs("Antigravity local usage regression failed (line \(line)): \(message)\n", stderr)
        exit(1)
    }
}

func pbUnsigned(_ value: UInt64) -> [UInt8] {
    var current = value
    var bytes: [UInt8] = []
    while current >= 128 {
        bytes.append(UInt8(current & 0x7F) | 0x80)
        current >>= 7
    }
    bytes.append(UInt8(current))
    return bytes
}

func pbVarint(_ field: Int, _ value: UInt64) -> [UInt8] {
    pbUnsigned(UInt64(field << 3)) + pbUnsigned(value)
}

func pbMessage(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
    pbUnsigned(UInt64((field << 3) | 2)) + pbUnsigned(UInt64(payload.count)) + payload
}

func makeGenBlob(
    stepUUID: String? = nil,
    botID: String? = nil,
    model: String? = "gemini-4-carbon",
    label: String? = nil,
    modelEnumID: UInt64 = 1427,
    input: UInt64 = 100,
    output: UInt64 = 30,
    cacheRead: UInt64 = 50,
    reasoning: UInt64 = 7,
    responseID: String? = nil,
    seconds: UInt64? = 1_794_970_000
) -> [UInt8] {
    var root: [UInt8] = []
    if let stepUUID = stepUUID {
        root += pbMessage(4, Array(stepUUID.utf8))
    }
    var usage = pbVarint(1, modelEnumID)
        + pbVarint(2, input)
        + pbVarint(5, cacheRead)
        + pbVarint(9, reasoning)
        + pbVarint(10, output)
    if let botID = botID {
        usage += pbMessage(7, Array(botID.utf8))
    }
    if let responseID = responseID {
        usage += pbMessage(11, Array(responseID.utf8))
    }
    var chat = pbMessage(4, usage)
    if let seconds = seconds {
        chat += pbMessage(9, pbMessage(4, pbVarint(1, seconds) + pbVarint(2, 250_000_000)))
    }
    if let model = model {
        chat += pbMessage(19, Array(model.utf8))
    }
    if let label = label {
        chat += pbMessage(21, Array(label.utf8))
    }
    root += pbMessage(1, chat)
    return root
}

func makeStepMetadataBlob(stepUUID: String?, botID: String?, seconds: UInt64) -> [UInt8] {
    var meta = pbMessage(1, pbVarint(1, seconds) + pbVarint(2, 125_000_000))
    if let botID = botID {
        meta += pbMessage(9, pbMessage(7, Array(botID.utf8)))
    }
    if let stepUUID = stepUUID {
        meta += pbMessage(12, Array(stepUUID.utf8))
    }
    return meta
}

func writeSQLiteDB(
    at url: URL,
    genBlobs: [[UInt8]],
    stepBlobs: [[UInt8]]? = nil,
    foreignOnly: Bool = false
) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var db: OpaquePointer?
    require(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, "open failed")
    defer { sqlite3_close(db) }

    if foreignOnly {
        require(sqlite3_exec(db, "CREATE TABLE conversation_summaries (id TEXT PRIMARY KEY, title TEXT)", nil, nil, nil) == SQLITE_OK, "foreign create failed")
        return
    }
    require(sqlite3_exec(db, "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB, size INTEGER NOT NULL DEFAULT 0)", nil, nil, nil) == SQLITE_OK, "create gen_metadata failed")
    for (index, blob) in genBlobs.enumerated() {
        var stmt: OpaquePointer?
        require(sqlite3_prepare_v2(db, "INSERT INTO gen_metadata (idx, data, size) VALUES (?, ?, ?)", -1, &stmt, nil) == SQLITE_OK, "prepare insert failed")
        sqlite3_bind_int64(stmt, 1, Int64(index))
        _ = blob.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(blob.count), nil)
        }
        sqlite3_bind_int64(stmt, 3, Int64(blob.count))
        require(sqlite3_step(stmt) == SQLITE_DONE, "insert gen_metadata failed")
        sqlite3_finalize(stmt)
    }
    if let stepBlobs = stepBlobs {
        require(sqlite3_exec(db, "CREATE TABLE steps (idx INTEGER PRIMARY KEY, metadata BLOB, step_payload BLOB)", nil, nil, nil) == SQLITE_OK, "create steps failed")
        for (index, blob) in stepBlobs.enumerated() {
            var stmt: OpaquePointer?
            require(sqlite3_prepare_v2(db, "INSERT INTO steps (idx, metadata) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK, "prepare step insert failed")
            sqlite3_bind_int64(stmt, 1, Int64(index))
            _ = blob.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(blob.count), nil)
            }
            require(sqlite3_step(stmt) == SQLITE_DONE, "insert step failed")
            sqlite3_finalize(stmt)
        }
    }
}

var utcCalendar = Calendar(identifier: .gregorian)
utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
let fixedNow = Date(timeIntervalSince1970: 1_794_980_000) // 2026-11-18 UTC
let twoDaysAgoSeconds: UInt64 = 1_794_800_000 // 2026-11-16 UTC
let todaySeconds: UInt64 = 1_794_970_000 // 2026-11-18 UTC

let root = FileManager.default.temporaryDirectory.appendingPathComponent("ag-local-regression-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

// 1. Handwritten upstream protobuf byte sequence: modelID 11 excluded, 100 + 50 + 30 + 7 = 187.
do {
    let literalBytes: [UInt8] = [
        0x0A, 0x1B, 0x22, 0x0A, 0x08, 0x0B, 0x10, 0x64, 0x28, 0x32, 0x48, 0x1E, 0x50, 0x07,
        0x4A, 0x0D, 0x22, 0x0B, 0x08, 0xC0, 0xCD, 0xC0, 0xD4, 0x06, 0x10, 0x80, 0xE5, 0x9A, 0x77,
    ]
    let turn = try! AntigravityProtoReader.parseTurn(literalBytes)
    require(turn?.usage?.modelID == 11, "model enum ID mismatch")
    require(turn?.usage?.newInput == 100, "input mismatch")
    require(turn?.usage?.cacheRead == 50, "cacheRead mismatch")
    require(turn?.usage?.reasoning == 30, "reasoning mismatch")
    require(turn?.usage?.output == 7, "output mismatch")
}

// 2. Step-metadata timestamp recovery (agy 1.2+/1.5.10 layout), foreign DB skip, Gemini 4 token-only UI behavior.
do {
    let home = root.appendingPathComponent("home-gemini4", isDirectory: true)
    let convDir = home.appendingPathComponent(".gemini/antigravity-cli/conversations", isDirectory: true)
    let appDir = home.appendingPathComponent(".gemini/antigravity", isDirectory: true)

    writeSQLiteDB(
        at: appDir.appendingPathComponent("conversation_summaries.db"),
        genBlobs: [],
        foreignOnly: true)

    writeSQLiteDB(
        at: convDir.appendingPathComponent("session-1.db"),
        genBlobs: [
            makeGenBlob(stepUUID: "uuid-1", botID: "bot-1", model: "gemini-4-carbon", input: 1000, output: 200, cacheRead: 3000, reasoning: 300, responseID: "r1", seconds: nil),
            makeGenBlob(stepUUID: "uuid-2", botID: "bot-2", model: "gemini-4-argon", input: 500, output: 100, cacheRead: 0, reasoning: 50, responseID: "r2", seconds: nil),
        ],
        stepBlobs: [
            makeStepMetadataBlob(stepUUID: "uuid-1", botID: "bot-1", seconds: twoDaysAgoSeconds),
            makeStepMetadataBlob(stepUUID: "uuid-2", botID: "bot-2", seconds: todaySeconds),
        ])

    // Exact duplicate copy in secondary root must deduplicate cleanly.
    writeSQLiteDB(
        at: appDir.appendingPathComponent("conversations/session-1.db"),
        genBlobs: [
            makeGenBlob(stepUUID: "uuid-1", botID: "bot-1", model: "gemini-4-carbon", input: 1000, output: 200, cacheRead: 3000, reasoning: 300, responseID: "r1", seconds: nil),
            makeGenBlob(stepUUID: "uuid-2", botID: "bot-2", model: "gemini-4-argon", input: 500, output: 100, cacheRead: 0, reasoning: 50, responseID: "r2", seconds: nil),
        ],
        stepBlobs: [
            makeStepMetadataBlob(stepUUID: "uuid-1", botID: "bot-1", seconds: twoDaysAgoSeconds),
            makeStepMetadataBlob(stepUUID: "uuid-2", botID: "bot-2", seconds: todaySeconds),
        ])

    let context = AntigravityLocalUsage.Context(environment: ["HOME": home.path])
    let scan = AntigravityLocalUsage.scan(context: context, now: fixedNow, calendar: utcCalendar)
    require(scan.coverage == .complete, "expected complete scan")
    require(scan.statistics.foreignDatabases == 1, "foreign DB should be counted and skipped")
    require(scan.statistics.sqliteHandlesOpened == scan.statistics.sqliteHandlesClosed, "SQLite handles leaked")

    guard let payload = scan.payload else {
        require(false, "expected payload")
        fatalError()
    }
    require(payload.last30DaysTokens == 5150, "expected deduplicated 4500 + 650 = 5150 tokens, got \(String(describing: payload.last30DaysTokens))")
    require(payload.sessionTokens == 650, "expected today tokens = 650")
    require(payload.last30DaysCostUSD == nil, "Gemini 4 models must stay unpriced")
    require(payload.last30DaysCostEstimate.knownCost == nil, "Gemini 4 knownCost must be nil")
    require(payload.last30DaysCostEstimate.unpricedModels == ["gemini-4-argon", "gemini-4-carbon"], "unpriced models list mismatch")

    let json = AntigravityLocalUsage.supplementJSON(environment: ["HOME": home.path], now: fixedNow, calendar: utcCalendar)
    let snapshot = ProviderSnapshot(
        provider: "antigravity", version: nil, source: "cli", status: nil,
        usage: nil, credits: nil, account: "user@example.com", plan: "Pro", error: nil, rawJSON: "{}")
    let dashboard = DashboardParser.dashboard(snapshot: snapshot, supplementalJSON: json)
    require(dashboard.summarySectionTitle == "Local usage", "summary title mismatch")
    require(dashboard.historySectionTitle == "Local usage history", "history title mismatch")
    // Gap day 2026-11-17 must NOT invent a $0 spend point when all models are unpriced.
    require(dashboard.history.count == 3, "expected 3 continuous days (16, 17, 18), got \(dashboard.history.count)")
    require(dashboard.history.map(\.tokens) == [4500, 0, 650], "daily token points mismatch: \(dashboard.history.map(\.tokens))")
    require(dashboard.history.allSatisfy { $0.spend == nil }, "token-only Antigravity history must not invent $0 spend points")

    let ledger = LocalTokenHistoryStore(storageDirectory: root.appendingPathComponent("ledger-1"), calendar: utcCalendar)
    _ = ledger.record(snapshot: snapshot, supplementalJSON: json, now: fixedNow)
    let report = ledger.report(accountID: nil, range: .thirtyDays, now: fixedNow)
    require(report.totalTokens == 5150, "ledger total mismatch")
    require(report.components.input == 1500, "ledger input component mismatch")
    require(report.components.output == 650, "ledger output+reasoning component mismatch")
    require(report.components.cacheRead == 3000, "ledger cacheRead component mismatch")
    require(report.components.cacheCreation == 0, "ledger cacheCreation component mismatch")
}

// 3. Built-in pricing for Claude, GPT-OSS (Vertex), and Gemini 3.1 Pro alongside Gemini 4 partial cost.
do {
    let home = root.appendingPathComponent("home-priced", isDirectory: true)
    let convDir = home.appendingPathComponent(".gemini/antigravity-cli/conversations", isDirectory: true)
    writeSQLiteDB(
        at: convDir.appendingPathComponent("priced.db"),
        genBlobs: [
            // claude-opus-4-6-thinking -> claude-opus-4-6 ($5 in, $0.5 cacheRead, $25 out):
            // 1000*5e-6 + 2000*0.5e-6 + (300+100)*25e-6 = 0.005 + 0.001 + 0.010 = 0.016
            makeGenBlob(model: "claude-opus-4-6-thinking", input: 1000, output: 300, cacheRead: 2000, reasoning: 100, responseID: "c1", seconds: todaySeconds),
            // gpt-oss-120b-medium -> $0.09 in, $0.36 out (cacheRead uses input rate 0.09):
            // 100*0.09e-6 + 50*0.09e-6 + 37*0.36e-6 = 0.000009 + 0.0000045 + 0.00001332 = 0.00002682
            makeGenBlob(model: "gpt-oss-120b-medium", input: 100, output: 30, cacheRead: 50, reasoning: 7, responseID: "g1", seconds: todaySeconds),
            // gemini-3.1-pro-low -> gemini-3.1-pro-preview ($2 in, $0.2 cacheRead, $12 out):
            // 1000*2e-6 + 1000*0.2e-6 + 500*12e-6 = 0.002 + 0.0002 + 0.006 = 0.0082
            makeGenBlob(model: "gemini-3.1-pro-low", input: 1000, output: 400, cacheRead: 1000, reasoning: 100, responseID: "m1", seconds: todaySeconds),
            // Unpriced Gemini 4 Carbon
            makeGenBlob(model: "gemini-4-carbon", input: 500, output: 50, cacheRead: 0, reasoning: 0, responseID: "u1", seconds: todaySeconds),
        ])

    let json = AntigravityLocalUsage.supplementJSON(environment: ["HOME": home.path], now: fixedNow, calendar: utcCalendar)
    let payload = CostHistoryPayloadParser.payload(provider: "antigravity", fromJSON: json)!
    let expectedKnown = 0.016 + 0.00002682 + 0.0082
    let actualKnown = payload.last30DaysCostEstimate.knownCost ?? .nan
    require(abs(actualKnown - expectedKnown) < 1e-10, "priced subtotal mismatch: \(actualKnown) vs \(expectedKnown)")
    require(payload.last30DaysCostEstimate.isPartial, "mixed priced + Gemini 4 must be marked partial")
    require(payload.last30DaysCostEstimate.unpricedModels == ["gemini-4-carbon"], "expected only gemini-4-carbon unpriced")
}

// 4. Contradictory copied rows are withheld rather than publishing corrupted totals.
do {
    let home = root.appendingPathComponent("home-conflict", isDirectory: true)
    writeSQLiteDB(
        at: home.appendingPathComponent(".gemini/antigravity-cli/conversations/dup.db"),
        genBlobs: [makeGenBlob(model: "claude-sonnet-4-6", input: 100, seconds: todaySeconds)])
    writeSQLiteDB(
        at: home.appendingPathComponent(".gemini/antigravity/dup.db"),
        genBlobs: [makeGenBlob(model: "claude-sonnet-4-6", input: 999, seconds: todaySeconds)])
    let scan = AntigravityLocalUsage.scan(
        context: .init(environment: ["HOME": home.path]),
        now: fixedNow,
        calendar: utcCalendar)
    require(scan.evidenceIsContradicted, "contradictory copy must flag contradiction")
    require(scan.payload == nil, "contradictory copy must not publish payload")
}

// 5. Tokscale JSONL cache fallback when no SQLite databases exist.
do {
    let home = root.appendingPathComponent("home-jsonl", isDirectory: true)
    let cacheDir = home.appendingPathComponent(".config/tokscale/antigravity-cache/sessions", isDirectory: true)
    try! FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    let lines = [
        #"{"type":"session_meta","sessionId":"s1","modelId":"claude-sonnet-4-6"}"#,
        #"{"type":"usage","sessionId":"s1","input":1000,"output":200,"cacheRead":500,"cacheWrite":0,"reasoning":0,"timestamp":1794970000000}"#,
    ].joined(separator: "\n") + "\n"
    try! lines.write(to: cacheDir.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
    let scan = AntigravityLocalUsage.scan(
        context: .init(environment: ["HOME": home.path]),
        now: fixedNow,
        calendar: utcCalendar)
    require(scan.coverage == .complete, "JSONL fallback should complete")
    require(scan.payload?.last30DaysTokens == 1700, "JSONL token sum mismatch")
    let expected = 1000 * 3e-6 + 500 * 0.3e-6 + 200 * 15e-6
    require(abs((scan.payload?.last30DaysCostUSD ?? .nan) - expected) < 1e-10, "JSONL Claude cost mismatch")
}

// 6. Antigravity duplicate generic 5-hour windows are dropped when matching scoped group windows exist.
do {
    let raw = """
    {"provider":"antigravity","usage":{
      "primary":{"usedPercent":11,"windowMinutes":300,"resetsAt":"2026-11-18T08:00:00Z"},
      "secondary":{"usedPercent":25,"windowMinutes":300,"resetsAt":"2026-11-18T08:00:20Z"},
      "extraRateWindows":[
        {"id":"gemini-5h","title":"Gemini 5-hour","window":{"usedPercent":11,"windowMinutes":300,"resetsAt":"2026-11-18T08:00:00Z"}},
        {"id":"gemini-weekly","title":"Gemini weekly","window":{"usedPercent":4,"windowMinutes":10080,"resetsAt":"2026-11-25T08:00:00Z"}},
        {"id":"claude-gpt-5h","title":"Claude/GPT 5-hour","window":{"usedPercent":25,"windowMinutes":300,"resetsAt":"2026-11-18T08:00:00Z"}},
        {"id":"claude-gpt-weekly","title":"Claude/GPT weekly","window":{"usedPercent":0,"windowMinutes":10080,"resetsAt":"2026-11-25T08:00:00Z"}}
      ]
    }}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try! decoder.decode(ProviderSnapshot.self, from: Data(raw.utf8))
    let snap = ProviderSnapshot(
        provider: decoded.provider, version: decoded.version, source: decoded.source,
        status: decoded.status, usage: decoded.usage, credits: decoded.credits,
        account: decoded.account, plan: decoded.plan, error: decoded.error, rawJSON: raw)
    L10n.language = .simplifiedChinese
    let dash = DashboardParser.dashboard(snapshot: snap)
    L10n.language = .english
    require(dash.quotas.map(\.title) == ["Gemini · 5 小时", "Gemini · 每周", "Claude/GPT · 5 小时", "Claude/GPT · 每周"],
            "expected only the 4 localized scoped Antigravity lanes, got \(dash.quotas.map(\.title))")
}

// 7. Antigravity quota trend pools: local CLI account key, Gemini & Claude/GPT 5h/weekly series,
//    usageKnown filtering, OAuth account isolation, persistence permissions, and server jitter smoothing.
do {
    let quotaDir = root.appendingPathComponent("quota-store", isDirectory: true)
    let store = AntigravityQuotaHistoryStore(storageDirectory: quotaDir)
    let base = ISO8601DateFormatter().date(from: "2026-11-18T06:00:00Z")!

    func makeAntigravitySnapshot(
        updatedISO: String,
        gemini5h: Double,
        geminiWeekly: Double = 4,
        claude5h: Double = 25,
        claudeWeekly: Double = 8,
        source: String = "cli",
        email: String? = nil,
        claudeWeeklyKnown: Bool = true
    ) -> ProviderSnapshot {
        let emailJSON = email.map { "\"accountEmail\":\"\($0)\"," } ?? ""
        let raw = """
        {"provider":"antigravity","source":"\(source)","usage":{
          \(emailJSON)"updatedAt":"\(updatedISO)",
          "primary":{"usedPercent":\(gemini5h),"windowMinutes":300,"resetsAt":"2026-11-18T09:00:00Z"},
          "secondary":{"usedPercent":\(claude5h),"windowMinutes":300,"resetsAt":"2026-11-18T09:00:00Z"},
          "extraRateWindows":[
            {"id":"antigravity-quota-summary-g5","title":"Gemini 5-hour","usageKnown":true,"window":{"usedPercent":\(gemini5h),"windowMinutes":300,"resetsAt":"2026-11-18T09:00:00Z"}},
            {"id":"antigravity-quota-summary-gw","title":"Gemini weekly","usageKnown":true,"window":{"usedPercent":\(geminiWeekly),"windowMinutes":10080,"resetsAt":"2026-11-25T06:00:00Z"}},
            {"id":"antigravity-quota-summary-c5","title":"Claude/GPT 5-hour","usageKnown":true,"window":{"usedPercent":\(claude5h),"windowMinutes":300,"resetsAt":"2026-11-18T09:00:00Z"}},
            {"id":"antigravity-quota-summary-cw","title":"Claude/GPT weekly","usageKnown":\(claudeWeeklyKnown),"window":{"usedPercent":\(claudeWeekly),"windowMinutes":10080,"resetsAt":"2026-11-25T06:00:00Z"}}
          ]
        }}
        """
        let decoded = try! JSONCoding.decoder.decode(ProviderSnapshot.self, from: Data(raw.utf8))
        return ProviderSnapshot(
            provider: decoded.provider, version: decoded.version, source: decoded.source,
            status: decoded.status, usage: decoded.usage, credits: decoded.credits,
            account: decoded.account, plan: decoded.plan, error: decoded.error, rawJSON: raw)
    }

    let first = makeAntigravitySnapshot(updatedISO: "2026-11-18T06:00:00.250Z", gemini5h: 1.0, claudeWeeklyKnown: false)
    let pools1 = store.record(snapshot: first, now: base.addingTimeInterval(1))
    require(pools1.map(\.id) == ["gemini", "claude-gpt"], "expected Gemini and Claude/GPT pools in order")
    require(pools1[0].series.map(\.id) == ["five-hour", "weekly"], "Gemini should have 5h and weekly series")
    require(pools1[1].series.map(\.id) == ["five-hour"], "usageKnown=false bucket must not record")
    require(store.record(snapshot: first, now: base.addingTimeInterval(2)) == pools1, "enrichment repeat must not duplicate")

    // Oscillating Gemini server readings (1.0% <-> 0.04%, i.e. 0.990 <-> 0.9996 remaining)
    // followed by real use to 5.5%: only the net rise above high-water (4.5 pts) counts.
    let timeline: [(Int, Double)] = [(300, 0.04), (600, 1.0), (900, 0.04), (1200, 1.0), (1500, 5.5)]
    var latestPools = pools1
    for (offset, g5) in timeline {
        let t = base.addingTimeInterval(Double(offset))
        let iso = FlexibleDate.iso8601String(t)
        let snap = makeAntigravitySnapshot(updatedISO: iso, gemini5h: g5)
        latestPools = store.record(snapshot: snap, now: t)
    }
    let gemini5hSeries = latestPools[0].series.first { $0.id == "five-hour" }!
    require(gemini5hSeries.samples.count == 6, "all 6 distinct timestamps should persist")
    let consumed = gemini5hSeries.consumedPoints(in: DateInterval(start: base, end: base.addingTimeInterval(1800)))
    require(abs(consumed - 4.5) < 1e-6, "server jitter must not inflate consumedPoints, got \(consumed)")

    // Reload from disk, verify 0600 permissions and no plaintext email.
    let oauthA = makeAntigravitySnapshot(updatedISO: "2026-11-18T06:30:00Z", gemini5h: 42, source: "oauth", email: "alice@example.com")
    let oauthUnidentified = makeAntigravitySnapshot(updatedISO: "2026-11-18T06:30:00Z", gemini5h: 99, source: "oauth", email: nil)
    require(oauthUnidentified.antigravityQuotaAccountKey == nil, "OAuth without email must not fall back to local CLI key")
    require(store.record(snapshot: oauthUnidentified, now: base.addingTimeInterval(2000)).isEmpty, "unidentified OAuth must not record")
    let oauthPools = store.record(snapshot: oauthA, now: base.addingTimeInterval(2000))
    require(oauthPools[0].series[0].samples.count == 1 && oauthPools[0].series[0].samples[0].usedPercent == 42,
            "OAuth account must stay isolated from local CLI history")

    let reloaded = AntigravityQuotaHistoryStore(storageDirectory: quotaDir)
    require(reloaded.record(snapshot: first, now: base.addingTimeInterval(2000))[0].series[0].samples.count == 6,
            "reloaded store should preserve local CLI history")
    let file = quotaDir.appendingPathComponent("antigravity-quota-history-v1.json")
    let attrs = try! FileManager.default.attributesOfItem(atPath: file.path)
    require((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "quota file must be 0600")
    let diskText = String(decoding: try! Data(contentsOf: file), as: UTF8.self)
    require(!diskText.contains("alice@example.com"), "quota file must never store raw email")

    try! Data("corrupt".utf8).write(to: file)
    let broken = AntigravityQuotaHistoryStore(storageDirectory: quotaDir)
    _ = broken.record(snapshot: first, now: base.addingTimeInterval(3000))
    require(broken.persistenceError != nil && (try! Data(contentsOf: file)) == Data("corrupt".utf8),
            "corrupt quota file must be preserved")
}

// 8. What represents an account: idle Antigravity windows are not resets, the
//    Gemini 4 Argon group is its own pool, the pool used most lately is the
//    headline (not a spent pool nobody uses), and the busiest account ranks first.
do {
    let now = ISO8601DateFormatter().date(from: "2026-11-21T07:20:00Z")!
    func iso(_ date: Date) -> String { FlexibleDate.iso8601String(date) }
    func snapshot(_ raw: String) -> ProviderSnapshot {
        let decoded = try! JSONCoding.decoder.decode(ProviderSnapshot.self, from: Data(raw.utf8))
        return ProviderSnapshot(
            provider: decoded.provider, version: decoded.version, source: decoded.source,
            status: decoded.status, usage: decoded.usage, credits: decoded.credits,
            account: decoded.account, plan: decoded.plan, error: decoded.error, rawJSON: raw)
    }
    // The real agy 1.5 report: Claude/GPT weekly nearly spent but unused, Gemini in use.
    let agy = snapshot("""
    {"provider":"antigravity","source":"cli","usage":{"updatedAt":"\(iso(now))",
      "primary":{"usedPercent":37.1,"windowMinutes":10080,"resetsAt":"2026-11-26T07:20:36Z"},
      "secondary":{"usedPercent":99.6,"windowMinutes":10080,"resetsAt":"2026-11-26T07:20:21Z"},
      "extraRateWindows":[
        {"id":"antigravity-quota-summary-gemini-5h","title":"Gemini 5-hour","window":{"usedPercent":4,"windowMinutes":300,"resetsAt":"2026-11-21T12:06:57Z"}},
        {"id":"antigravity-quota-summary-gemini-weekly","title":"Gemini weekly","window":{"usedPercent":37.1,"windowMinutes":10080,"resetsAt":"2026-11-26T07:20:36Z"}},
        {"id":"antigravity-quota-summary-gemini-argon-wtu-weekly","title":"Gemini weekly","window":{"usedPercent":2.1,"windowMinutes":10080,"resetsAt":"2026-11-26T10:42:14Z"}},
        {"id":"antigravity-quota-summary-3p-5h","title":"Claude/GPT 5-hour","window":{"usedPercent":0,"windowMinutes":300,"resetsAt":"2026-11-21T12:20:00Z"}},
        {"id":"antigravity-quota-summary-3p-weekly","title":"Claude/GPT weekly","window":{"usedPercent":99.6,"windowMinutes":10080,"resetsAt":"2026-11-26T07:20:21Z"}}
      ]}}
    """)
    let windows = agy.antigravityQuotaWindows
    require(windows.map { "\($0.poolID)::\($0.windowID)" } == [
        "gemini::five-hour", "gemini::weekly", "gemini-argon::weekly", "claude-gpt::five-hour", "claude-gpt::weekly",
    ], "Argon must be its own pool, got \(windows.map { "\($0.poolID)::\($0.windowID)" })")
    require(windows[2].laneTitle == "Gemini Argon weekly", "Argon window must be named, got \(windows[2].laneTitle ?? "nil")")
    require(DashboardParser.dashboard(snapshot: agy).quotas.contains { $0.title == L("Gemini Argon weekly") },
            "quota list must name the Argon window")

    // No history: the pool with 5-hour usage now, never the spent Claude/GPT weekly.
    require(agy.headlineUsedPercent == 4, "headline must be Gemini 5-hour, got \(agy.headlineUsedPercent ?? -1)")
    require(agy.headlineQuotaLabel == L("Gemini 5-hour"), "headline label must name the window")
    var preferClaude = agy
    preferClaude.preferredQuotaPoolID = "claude-gpt"
    require(preferClaude.headlineUsedPercent == 0 && preferClaude.headlineQuotaLabel == L("Claude/GPT 5-hour"),
            "the pool used most lately must be the headline")
    var argon = agy
    argon.preferredQuotaPoolID = "gemini-argon"
    require(argon.headlineUsedPercent == 2.1, "a weekly-only pool is represented by its weekly window")

    // Idle 5-hour readings (0%, reset one window ahead, moving each refresh) are one
    // stretch without a window, not a reset per refresh; real use then starts one.
    var idle: [ClaudeQuotaSample] = (0..<6).map { index in
        let time = now.addingTimeInterval(Double(index - 6) * 900)
        return ClaudeQuotaSample(timestamp: time, usedPercent: 0, resetsAt: time.addingTimeInterval(5 * 3600 - 2))
    }
    idle.append(ClaudeQuotaSample(timestamp: now, usedPercent: 4, resetsAt: now.addingTimeInterval(5 * 3600 - 300)))
    let normalized = AntigravityQuotaHistoryStore.withoutIdleWindows(idle, duration: 5 * 3600)
    let series = ClaudeQuotaSeries(id: "five-hour", title: "5h", samples: normalized)
    require(normalized.prefix(6).allSatisfy { $0.resetsAt == nil } && normalized[6].resetsAt != nil,
            "idle readings lose their sliding reset time; the started window keeps it")
    require((1..<normalized.count).allSatisfy { !series.hasReset(before: $0) }, "idle stretch must not draw resets")
    require(series.cycles().count == 1, "only the started window is a cycle, got \(series.cycles().count)")
    require(abs(series.consumedPoints(in: DateInterval(start: idle[0].timestamp, end: now)) - 4) < 1e-9,
            "the new window's first reading counts from zero")

    // Pool scores decay with age: 4 points now beat 200 points two days ago.
    let geminiPool = QuotaTrendPool(id: "gemini", title: "Gemini", series: [series])
    let old = now.addingTimeInterval(-50 * 3600)
    let claudeOld = ClaudeQuotaSeries(id: "five-hour", title: "5h", samples: [
        ClaudeQuotaSample(timestamp: old, usedPercent: 0, resetsAt: old.addingTimeInterval(4 * 3600)),
        ClaudeQuotaSample(timestamp: old.addingTimeInterval(600), usedPercent: 100, resetsAt: old.addingTimeInterval(4 * 3600)),
        ClaudeQuotaSample(timestamp: old.addingTimeInterval(5 * 3600), usedPercent: 100, resetsAt: old.addingTimeInterval(9 * 3600)),
    ])
    let pools = [geminiPool, QuotaTrendPool(id: "claude-gpt", title: "Claude/GPT", series: [claudeOld])]
    let scores = ProviderActivity.poolScores(pools, now: now)
    require(ProviderActivity.busiestPool(scores, order: ["gemini", "claude-gpt"]) == "gemini",
            "recent use must outrank older heavy use, got \(scores)")
    require(ProviderActivity.busiestPool(["gemini": 0, "claude-gpt": 0], order: ["gemini", "claude-gpt"]) == nil,
            "no use, no preferred pool")

    // Ranking: used lately first, busiest first; unused ones tightest first.
    let claude = snapshot("""
    {"provider":"claude","usage":{"primary":{"usedPercent":7,"windowMinutes":300}}}
    """)
    let zai = snapshot("""
    {"provider":"zai","usage":{"primary":{"usedPercent":90,"windowMinutes":300}}}
    """)
    let deepseek = snapshot("""
    {"provider":"deepseek","usage":{}}
    """)
    let ranked = ProviderActivity.ranked([deepseek, zai, agy, claude],
                                         scores: [claude.id: 20, agy.id: 5, zai.id: 0])
    require(ranked.map(\.provider) == ["claude", "antigravity", "zai", "deepseek"],
            "ranking must follow recent use, got \(ranked.map(\.provider))")
    require(ProviderActivity.ranked([claude, deepseek, zai], scores: [:]).map(\.provider) == ["zai", "claude", "deepseek"],
            "without use, the tightest quota comes first")

    // Readings store: rises above the high-water mark, resets counted from zero, persisted.
    let activityDir = root.appendingPathComponent("activity", isDirectory: true)
    let activity = ProviderActivityStore(storageDirectory: activityDir)
    func zaiReading(_ used: Double, reset: String) -> ProviderSnapshot {
        snapshot("""
        {"provider":"zai","usage":{"primary":{"usedPercent":\(used),"windowMinutes":300,"resetsAt":"\(reset)"}}}
        """)
    }
    var steps: [ProviderActivity.Step] = []
    for (offset, used, reset) in [(0.0, 10.0, "2026-11-21T09:00:00Z"), (600, 9.5, "2026-11-21T09:00:00Z"),
                                  (1200, 15, "2026-11-21T09:00:00Z"), (9000, 3, "2026-11-21T14:00:00Z")] {
        steps = activity.record(snapshot: zaiReading(used, reset: reset), now: now.addingTimeInterval(offset))
    }
    require(steps.map(\.points) == [5, 3], "expected a 5-point rise and a new window at 3, got \(steps.map(\.points))")
    let reopened = ProviderActivityStore(storageDirectory: activityDir)
    require(reopened.record(snapshot: zaiReading(3, reset: "2026-11-21T14:00:00Z"), now: now.addingTimeInterval(9600))
                .map(\.points) == [5, 3], "activity must survive a restart without new points")
    let activityFile = activityDir.appendingPathComponent("provider-activity-v1.json")
    let activityAttrs = try! FileManager.default.attributesOfItem(atPath: activityFile.path)
    require((activityAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "activity file must be 0600")
    require(!String(decoding: try! Data(contentsOf: activityFile), as: UTF8.self).contains("zai::"),
            "activity file must key accounts by hash")
}

print("Antigravity local usage regression tests passed.")
