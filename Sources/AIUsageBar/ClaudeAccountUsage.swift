import Foundation
import Security

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
/// api.anthropic.com. The first read shows the standard keychain prompt;
/// if the user denies it, the app stops asking until next launch.
actor ClaudeAccountUsageClient {
    private static let keychainService = "Claude Code-credentials"
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "AIUsageBar/\(version ?? "dev")"
    }()
    private let cacheLifetime: TimeInterval = 5 * 60
    private var cached: (fetchedAt: Date, usage: ClaudeAccountUsage?)?
    private var accessDenied = false

    func usage(now: Date = Date()) async -> ClaudeAccountUsage? {
        if let cached = cached, now.timeIntervalSince(cached.fetchedAt) < cacheLifetime {
            return cached.usage
        }
        guard !accessDenied, let token = readAccessToken(now: now) else { return cached?.usage }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // Identify honestly; the endpoint does not require a Claude Code agent.
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return cached?.usage }
            let usage = ClaudeAccountUsage.parse(data)
            cached = (now, usage)
            return usage
        } catch {
            return cached?.usage
        }
    }

    private func readAccessToken(now: Date) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecAuthFailed || status == errSecUserCanceled || status == errSecInteractionNotAllowed {
            accessDenied = true
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
