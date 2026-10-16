import Foundation

/// Official per-product share of this week's Claude usage, as shown under
/// claude.ai → Settings → Usage ("This week's usage by product").
struct ClaudeProductBreakdown: Hashable {
    struct Row: Hashable, Identifiable {
        let key: String
        let title: String
        let percent: Double
        var id: String { key }
    }

    let rows: [Row]
    let windowStartedAt: Date?
    let asOf: Date?
}

/// Promotional "Included credit" on the Claude account.
struct ClaudeIncludedCredit: Hashable {
    let limitDollars: Double
    let remainingDollars: Double
    let expiresAt: Date?
}

struct ClaudeAccountUsage: Hashable {
    var breakdown: ClaudeProductBreakdown?
    var includedCredit: ClaudeIncludedCredit?
    /// When the organization's subscription started (the OAuth profile's
    /// `subscription_created_at`). Not a renewal date: renewals are estimated
    /// from it by whole months, and a plan change can move the real cycle.
    var subscriptionStartedAt: Date?

    /// Reads the subscription start from the Claude OAuth profile response.
    static func subscriptionStart(fromProfile data: Data) -> Date? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let organization = root["organization"] as? [String: Any],
              let text = organization["subscription_created_at"] as? String
        else { return nil }
        return FlexibleDate.iso8601(text)
    }

    /// Parses the subscription usage response of the Claude OAuth API.
    static func parse(_ data: Data) -> ClaudeAccountUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var result = ClaudeAccountUsage()
        if let breakdown = root["seven_day_breakdown"] as? [String: Any],
           let rows = breakdown["rows"] as? [[String: Any]]
        {
            let parsed = rows.compactMap { row -> ClaudeProductBreakdown.Row? in
                guard let key = row["key"] as? String,
                      let percent = (row["percent"] as? NSNumber)?.doubleValue, percent.isFinite
                else { return nil }
                let title = (row["display_name"] as? String) ?? key
                return ClaudeProductBreakdown.Row(key: key, title: title, percent: max(0, min(100, percent)))
            }
            if !parsed.isEmpty {
                result.breakdown = ClaudeProductBreakdown(
                    rows: parsed,
                    windowStartedAt: (breakdown["window_started_at"] as? String).flatMap(FlexibleDate.iso8601),
                    asOf: (breakdown["as_of"] as? String).flatMap(FlexibleDate.iso8601))
            }
        }
        // The included-credit allowance appears under a code-named key; it is
        // the window that carries dollar amounts.
        for value in root.values {
            guard let window = value as? [String: Any],
                  let limit = (window["limit_dollars"] as? NSNumber)?.doubleValue, limit > 0,
                  let remaining = (window["remaining_dollars"] as? NSNumber)?.doubleValue
            else { continue }
            result.includedCredit = ClaudeIncludedCredit(
                limitDollars: limit,
                remainingDollars: max(0, remaining),
                expiresAt: (window["resets_at"] as? String).flatMap(FlexibleDate.iso8601))
            break
        }
        return result.breakdown == nil && result.includedCredit == nil ? nil : result
    }
}

/// Reads the official account usage with the sign-in Claude Code already
/// stored in the login keychain. Read-only; the token is sent only to
/// api.anthropic.com, only while the user is viewing Claude (submenu,
/// detail or all-providers popover) and at most every 15 minutes.
/// If the user denies the keychain prompt, the app stops asking until next launch.
actor ClaudeAccountUsageClient {
    private static let keychainService = "Claude Code-credentials"
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let profileEndpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    /// Fetched only when Claude is being looked at, and at most this often.
    private let cacheLifetime: TimeInterval = 15 * 60
    /// The subscription start rarely changes; the profile is read once a day.
    private let profileLifetime: TimeInterval = 24 * 3600
    private var cached: (fetchedAt: Date, usage: ClaudeAccountUsage?)?
    private var profile: (fetchedAt: Date, startedAt: Date?)?
    private var accessDenied = false

    func usage(now: Date = Date()) async -> ClaudeAccountUsage? {
        if let cached = cached, now.timeIntervalSince(cached.fetchedAt) < cacheLifetime {
            return cached.usage
        }
        guard !accessDenied, let token = readAccessToken(now: now),
              let data = await get(Self.endpoint, token: token) else { return cached?.usage }
        var usage = ClaudeAccountUsage.parse(data)
        if profile.map({ now.timeIntervalSince($0.fetchedAt) >= profileLifetime }) ?? true,
           let data = await get(Self.profileEndpoint, token: token)
        {
            profile = (now, ClaudeAccountUsage.subscriptionStart(fromProfile: data))
        }
        if let started = profile?.startedAt {
            if usage == nil { usage = ClaudeAccountUsage() }
            usage?.subscriptionStartedAt = started
        }
        cached = (now, usage)
        return usage
    }

    private func get(_ url: URL, token: String) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // Pinned to the Claude Code release installed when this was set
        // (2026-10-09); intentionally not updated automatically.
        request.setValue("claude-code/2.1.295", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// Reads through `/usr/bin/security`, the tool Claude Code itself uses to
    /// write this item. The item's access list already trusts it, so neither
    /// Claude Code's token refreshes (which rewrite the item and drop apps the
    /// user allowed) nor rebuilds of this ad-hoc signed app prompt again.
    private func readAccessToken(now: Date) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", Self.keychainService, "-w"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // 44 is errSecItemNotFound (not signed in yet); anything else means
        // the user denied or cancelled the prompt.
        guard process.terminationStatus == 0 else {
            if process.terminationStatus != 44 { accessDenied = true }
            return nil
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        // Claude Code refreshes its own token; an expired one would only fail.
        if let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
           Date(timeIntervalSince1970: expires / 1000) <= now
        {
            return nil
        }
        return token
    }
}
