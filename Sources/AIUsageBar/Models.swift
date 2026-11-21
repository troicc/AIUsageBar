import Foundation

struct ProviderSnapshot: Decodable, Hashable, Identifiable {
    let provider: String
    let version: String?
    let source: String?
    let status: ProviderStatus?
    let usage: UsageSnapshot?
    let credits: CreditsSnapshot?
    let account: String?
    let plan: String?
    let error: ProviderError?
    let rawJSON: String?
    // Display-only fallback: do not re-key existing local history when CLI metadata appears.
    var cliAccountStatus: ClaudeCLIAccountStatus? = nil
    /// Antigravity: the quota pool used most lately (from local quota
    /// history), which represents the account in compact UI.
    var preferredQuotaPoolID: String? = nil

    init(
        provider: String,
        version: String?,
        source: String?,
        status: ProviderStatus?,
        usage: UsageSnapshot?,
        credits: CreditsSnapshot?,
        account: String?,
        plan: String?,
        error: ProviderError?,
        rawJSON: String?)
    {
        self.provider = provider
        self.version = version
        self.source = source
        self.status = status
        self.usage = usage
        self.credits = credits
        self.account = account
        self.plan = plan
        self.error = error
        self.rawJSON = rawJSON
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try container.decode(String.self, forKey: .provider)
        self.version = try? container.decodeIfPresent(String.self, forKey: .version)
        self.source = try? container.decodeIfPresent(String.self, forKey: .source)
        self.status = try? container.decodeIfPresent(ProviderStatus.self, forKey: .status)
        self.usage = try? container.decodeIfPresent(UsageSnapshot.self, forKey: .usage)
        self.credits = try? container.decodeIfPresent(CreditsSnapshot.self, forKey: .credits)
        self.account = try? container.decodeIfPresent(String.self, forKey: .account)
        self.plan = try? container.decodeIfPresent(String.self, forKey: .plan)
        self.error = try? container.decodeIfPresent(ProviderError.self, forKey: .error)
        self.rawJSON = nil
    }

    private enum CodingKeys: String, CodingKey {
        case provider, version, source, status, usage, credits, account, plan, error
    }

    var id: String {
        let providerComponent = provider.lowercased()
        let accountComponent = accountName?.lowercased() ?? "default"
        if let organization = accountOrganizationName {
            return "\(providerComponent)::\(accountComponent)::\(organization.lowercased())"
        }
        return "\(providerComponent)::\(accountComponent)"
    }

    var accountDisplayName: String? {
        switch (accountName, accountOrganizationName) {
        case let (account?, organization?) where account.caseInsensitiveCompare(organization) != .orderedSame:
            return "\(account) · \(organization)"
        case let (account?, _):
            return account
        case let (_, organization?):
            return organization
        default:
            return cliAccountStatus?.email
        }
    }

    var planDisplayName: String? {
        if let explicit = Self.firstNonEmpty([plan]) { return explicit }
        guard ["claude", "codex"].contains(provider.lowercased()) else { return nil }
        guard let value = Self.firstNonEmpty([
            usage?.identity?.loginMethod, usage?.loginMethod, cliAccountStatus?.subscriptionType,
        ]) else { return nil }
        let key = value.lowercased().replacingOccurrences(of: "claude ", with: "")
            .replacingOccurrences(of: "chatgpt ", with: "")
        let names = ["free": "Free", "pro": "Pro", "plus": "Plus", "prolite": "Pro Lite",
                     "max": "Max", "max5x": "Max 5x", "max20x": "Max 20x",
                     "max 5x": "Max 5x", "max 20x": "Max 20x", "team": "Team",
                     "business": "Business", "enterprise": "Enterprise", "edu": "Edu"]
        // loginMethod also carries authentication mechanisms; these are not plans.
        return names[key]
    }

    private var accountName: String? {
        Self.firstNonEmpty([
            usage?.identity?.accountEmail,
            usage?.accountEmail,
            account,
        ])
    }

    private var accountOrganizationName: String? {
        Self.firstNonEmpty([
            usage?.identity?.accountOrganization,
            usage?.accountOrganization,
        ])
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    var displayName: String {
        ProviderCatalog.displayName(for: provider)
    }

    var maximumUsedPercent: Double? {
        // DeepSeek API-key mode exposes a balance sentinel, not a real quota window.
        if provider == "deepseek" { return nil }
        let values = [usage?.primary?.usedPercent, usage?.secondary?.usedPercent, usage?.tertiary?.usedPercent]
            .compactMap { $0 }
        return values.max()
    }

    /// The single quota that should represent this provider in compact UI.
    /// The five-hour window always wins when there is one: the countdown shown
    /// beside it is that window's reset, and a nearly spent weekly or MCP
    /// window must not replace it simply because it is numerically larger.
    var headlineQuotaWindow: RateWindow? {
        guard provider != "deepseek" else { return nil }
        if provider == "antigravity", let headline = antigravityHeadline { return headline.window }
        let windows = [usage?.primary, usage?.secondary, usage?.tertiary].compactMap { $0 }
        if let fiveHour = windows.first(where: { window in
            guard let minutes = window.windowMinutes else { return false }
            return abs(minutes - 300) <= 1
        }) {
            return fiveHour
        }
        guard provider == "zai" else {
            return windows.max {
                ($0.usedPercent ?? -1) < ($1.usedPercent ?? -1)
            }
        }
        // Older engine payloads omit windowMinutes but put the main allowance
        // in primary. Secondary is commonly MCP and is not a safe fallback.
        return usage?.primary
    }

    var headlineUsedPercent: Double? {
        headlineQuotaWindow?.usedPercent
    }

    var headlineQuotaLabel: String? {
        if provider == "antigravity" { return antigravityHeadline?.laneTitle.map { L($0) } }
        guard provider == "zai", headlineQuotaWindow != nil else { return nil }
        return "5h"
    }

    /// Antigravity has a separate quota per model group (Gemini, Claude/GPT,
    /// Gemini Argon). The account is represented by the group in use: the one
    /// used most lately, else the one with the most 5-hour usage now, else the
    /// first. Within it, the 5-hour window, as for Claude. A group that is
    /// spent but not used no longer stands for the whole account.
    var antigravityHeadline: AntigravityQuotaWindow? {
        let windows = antigravityQuotaWindows
        guard let first = windows.first else { return nil }
        let pool = preferredQuotaPoolID.flatMap { id in windows.contains { $0.poolID == id } ? id : nil }
            ?? windows.filter { $0.windowID == "five-hour" && ($0.window.usedPercent ?? 0) > 0 }
                .max { ($0.window.usedPercent ?? 0) < ($1.window.usedPercent ?? 0) }?.poolID
            ?? first.poolID
        let inPool = windows.filter { $0.poolID == pool }
        return inPool.first { $0.windowID == "five-hour" } ?? inPool.first
    }

    var isFailed: Bool { error != nil }

    /// True when a quota window started over between two observations of
    /// the same account: its reset time moved to a new window, or usage fell
    /// sharply (a reset card keeps the reset time), and the used share dropped.
    static func quotaDidReset(from old: ProviderSnapshot, to new: ProviderSnapshot) -> Bool {
        guard old.id == new.id, new.error == nil else { return false }
        let oldWindows = [old.usage?.primary, old.usage?.secondary, old.usage?.tertiary].compactMap { $0 }
        let newWindows = [new.usage?.primary, new.usage?.secondary, new.usage?.tertiary].compactMap { $0 }
        for next in newWindows {
            guard let previous = oldWindows.first(where: { $0.windowMinutes == next.windowMinutes }),
                  let before = previous.usedPercent, let after = next.usedPercent,
                  before - after >= 5
            else { continue }
            if let oldReset = previous.resetsAt, let newReset = next.resetsAt,
               newReset.timeIntervalSince(oldReset) > 600 {
                return true
            }
            if before - after >= 25 { return true }
        }
        return false
    }
}

enum StableIdentifier {
    static func hash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

struct ProviderStatus: Decodable, Hashable {
    let indicator: String?
    let description: String?
    let updatedAt: Date?
    let url: URL?
}

enum ProviderServiceHealth: Int, Hashable, Comparable {
    case unknown = 0
    case operational = 1
    case degraded = 2
    case outage = 3

    static func < (lhs: ProviderServiceHealth, rhs: ProviderServiceHealth) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .unknown: return L("Status unavailable")
        case .operational: return L("Operational")
        case .degraded: return L("Degraded service")
        case .outage: return L("Service outage")
        }
    }

    var symbolName: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .operational: return "checkmark.circle.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .outage: return "xmark.octagon.fill"
        }
    }

    var isIncident: Bool { self == .degraded || self == .outage }
}

extension ProviderStatus {
    var health: ProviderServiceHealth {
        let normalizedIndicator = indicator?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if ["critical", "major"].contains(normalizedIndicator) { return .outage }
        if ["minor", "degraded", "maintenance", "warning"].contains(normalizedIndicator) { return .degraded }
        if ["none", "operational", "ok", "up"].contains(normalizedIndicator) { return .operational }

        let normalized = [indicator, description]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        guard !normalized.isEmpty else { return .unknown }
        if ["critical", "major", "outage", "down", "unavailable"].contains(where: normalized.contains) {
            return .outage
        }
        if ["minor", "degraded", "maintenance", "warning", "partial"].contains(where: normalized.contains) {
            return .degraded
        }
        if ["operational", "available", "all systems"].contains(where: normalized.contains) {
            return .operational
        }
        return .unknown
    }

    var displayText: String {
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? health.title : trimmed
    }
}

extension ProviderSnapshot {
    var serviceHealth: ProviderServiceHealth { status?.health ?? .unknown }
    var hasVisibleAlert: Bool { error != nil || serviceHealth.isIncident }
}

struct ClaudeCLIAccountStatus: Decodable, Hashable {
    let loggedIn: Bool
    let authMethod: String?
    let apiProvider: String?
    let email: String?
    let subscriptionType: String?

    static func enrich(_ snapshots: [ProviderSnapshot], json: String) -> [ProviderSnapshot] {
        guard snapshots.filter({ $0.provider == "claude" }).count == 1,
              let data = json.data(using: .utf8),
              let status = try? JSONDecoder().decode(Self.self, from: data),
              status.loggedIn, status.authMethod == "claude.ai", status.apiProvider == "firstParty",
              let email = status.email, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return snapshots }
        return snapshots.map { snapshot in
            guard snapshot.provider == "claude", snapshot.source == "claude", snapshot.error == nil,
                  snapshot.usage != nil else { return snapshot }
            let reportedEmail = snapshot.usage?.identity?.accountEmail ?? snapshot.usage?.accountEmail ?? snapshot.account
            if let reportedEmail = reportedEmail,
               reportedEmail.caseInsensitiveCompare(email) != .orderedSame { return snapshot }
            var result = snapshot
            result.cliAccountStatus = status
            return result
        }
    }
}

struct UsageSnapshot: Decodable, Hashable {
    let primary: RateWindow?
    let secondary: RateWindow?
    let tertiary: RateWindow?
    let updatedAt: Date?
    let identity: UsageIdentity?
    let accountEmail: String?
    let accountOrganization: String?
    let loginMethod: String?
    var subscriptionExpiresAt: Date? = nil
    var subscriptionRenewsAt: Date? = nil

    private enum CodingKeys: String, CodingKey {
        case primary, secondary, tertiary, updatedAt, identity, accountEmail, accountOrganization, loginMethod
        case subscriptionExpiresAt, subscriptionRenewsAt
    }

    init(primary: RateWindow?, secondary: RateWindow?, tertiary: RateWindow?, updatedAt: Date?,
         identity: UsageIdentity?, accountEmail: String?, accountOrganization: String?, loginMethod: String?,
         subscriptionExpiresAt: Date? = nil, subscriptionRenewsAt: Date? = nil) {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.updatedAt = updatedAt
        self.identity = identity
        self.accountEmail = accountEmail
        self.accountOrganization = accountOrganization
        self.loginMethod = loginMethod
        self.subscriptionExpiresAt = subscriptionExpiresAt
        self.subscriptionRenewsAt = subscriptionRenewsAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        primary = try c.decodeIfPresent(RateWindow.self, forKey: .primary)
        secondary = try c.decodeIfPresent(RateWindow.self, forKey: .secondary)
        tertiary = try c.decodeIfPresent(RateWindow.self, forKey: .tertiary)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        identity = try c.decodeIfPresent(UsageIdentity.self, forKey: .identity)
        accountEmail = try c.decodeIfPresent(String.self, forKey: .accountEmail)
        accountOrganization = try c.decodeIfPresent(String.self, forKey: .accountOrganization)
        loginMethod = try c.decodeIfPresent(String.self, forKey: .loginMethod)
        // Optional billing metadata must not discard otherwise valid quota data.
        subscriptionExpiresAt = try? c.decodeIfPresent(Date.self, forKey: .subscriptionExpiresAt)
        subscriptionRenewsAt = try? c.decodeIfPresent(Date.self, forKey: .subscriptionRenewsAt)
    }
}

struct UsageIdentity: Decodable, Hashable {
    let providerID: String?
    let accountEmail: String?
    let accountOrganization: String?
    let loginMethod: String?
}

struct RateWindow: Decodable, Hashable {
    let usedPercent: Double?
    let windowMinutes: Double?
    let resetsAt: Date?

    var remainingPercent: Double? {
        guard let usedPercent = usedPercent else { return nil }
        return max(0, min(100, 100 - usedPercent))
    }
}

struct CreditsSnapshot: Decodable, Hashable {
    let remaining: Double?
    let updatedAt: Date?
    let hasCredits: Bool?
    let unlimited: Bool?
}

struct ProviderError: Decodable, Hashable {
    let message: String?
    let code: String?

    init(message: String?, code: String? = nil) {
        self.message = message
        self.code = code
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let message = try? single.decode(String.self)
        {
            self.init(message: message)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let message = (try? container.decode(String.self, forKey: .message)) ??
            (try? container.decode(String.self, forKey: .error))
        let code = try? container.decode(String.self, forKey: .code)
        self.init(message: message, code: code)
    }

    private enum CodingKeys: String, CodingKey {
        case message, error, code
    }
}

struct ProviderDescriptor: Hashable, Identifiable {
    let id: String
    let name: String
    let enabled: Bool
}

enum ProviderCatalog {
    // Exact stable IDs registered by CodexBar v0.46.0. The settings UI normally
    // obtains names dynamically from `config providers`; this table is only a
    // fallback for snapshots and older text output.
    private static let names: [String: String] = [
        "codex": "Codex",
        "openai": "OpenAI",
        "azureopenai": "Azure OpenAI",
        "claude": "Claude",
        "clinepass": "ClinePass",
        "cursor": "Cursor",
        "opencode": "OpenCode",
        "opencodego": "OpenCode Go",
        "alibaba": "Alibaba Coding Plan",
        "alibabatokenplan": "Alibaba Token Plan",
        "qwencloud": "Qwen Cloud",
        "factory": "Droid / Factory",
        "gemini": "Gemini",
        "antigravity": "Antigravity",
        "copilot": "GitHub Copilot",
        "devin": "Devin",
        "zai": "z.ai",
        "minimax": "MiniMax",
        "manus": "Manus",
        "kimi": "Kimi",
        "kilo": "Kilo",
        "kiro": "Kiro",
        "vertexai": "Vertex AI",
        "augment": "Augment",
        "jetbrains": "JetBrains AI",
        "moonshot": "Moonshot / Kimi API",
        "amp": "Amp",
        "t3chat": "T3 Chat",
        "ollama": "Ollama",
        "synthetic": "Synthetic",
        "warp": "Warp",
        "openrouter": "OpenRouter",
        "elevenlabs": "ElevenLabs",
        "windsurf": "Windsurf",
        "zed": "Zed",
        "perplexity": "Perplexity",
        "mimo": "Xiaomi MiMo",
        "doubao": "Doubao",
        "sakana": "Sakana AI",
        "abacus": "Abacus AI",
        "mistral": "Mistral",
        "deepseek": "DeepSeek",
        "deepinfra": "DeepInfra",
        "codebuff": "Codebuff",
        "crof": "Crof",
        "venice": "Venice",
        "commandcode": "Command Code",
        "qoder": "Qoder",
        "stepfun": "StepFun",
        "bedrock": "AWS Bedrock",
        "grok": "Grok",
        "groq": "GroqCloud",
        "llmproxy": "LLM Proxy",
        "litellm": "LiteLLM",
        "deepgram": "Deepgram",
        "poe": "Poe",
        "chutes": "Chutes",
        "neuralwatt": "Neuralwatt",
        "clawrouter": "ClawRouter",
        "longcat": "LongCat",
        "sub2api": "sub2api",
        "wayfinder": "Wayfinder",
        "zenmux": "ZenMux",
        "aiand": "AIand",
        "zoommate": "ZoomMate",

        // Compatibility aliases retained for older local configs and future engine
        // snapshots. They do not replace the exact IDs above.
        "azure-openai": "Azure OpenAI",
        "opencode-go": "OpenCode Go",
        "alibaba-token-plan": "Alibaba Token Plan",
        "qwen-cloud": "Qwen Cloud",
        "droid": "Droid / Factory",
        "vertex": "Vertex AI",
        "command-code": "Command Code",
        "xai": "xAI",
    ]

    static func displayName(for id: String) -> String {
        names[id] ?? id
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    static func documentationURL(for id: String) -> URL {
        let slugs: [String: String] = [
            "azureopenai": "azure-openai",
            "opencodego": "opencode",
            "alibaba": "alibaba-coding-plan",
            "alibabatokenplan": "alibaba-token-plan",
            "qwencloud": "qwen-cloud",
            "commandcode": "command-code",
            "llmproxy": "llm-proxy",
        ]
        let slug = slugs[id] ?? id
        return URL(string: "https://github.com/steipete/CodexBar/blob/main/docs/\(slug).md")!
    }

    static func dashboardURL(for id: String) -> URL? {
        let urls: [String: String] = [
            "codex": "https://chatgpt.com/codex/settings/usage",
            "openai": "https://platform.openai.com/usage",
            "claude": "https://console.anthropic.com/settings/usage",
            "cursor": "https://www.cursor.com/settings",
            "gemini": "https://aistudio.google.com/usage",
            "copilot": "https://github.com/settings/copilot",
            "zai": "https://z.ai/manage-apikey/apikey-list",
            "minimax": "https://platform.minimax.io/user-center/payment/billing",
            "openrouter": "https://openrouter.ai/activity",
            "deepseek": "https://platform.deepseek.com/usage",
            "moonshot": "https://platform.kimi.ai/",
            "mimo": "https://platform.xiaomimimo.com/",
            "mistral": "https://console.mistral.ai/usage",
            "bedrock": "https://console.aws.amazon.com/cost-management/home",
        ]
        return urls[id].flatMap(URL.init(string:))
    }

    static func statusURL(for id: String) -> URL? {
        let urls: [String: String] = [
            "codex": "https://status.openai.com",
            "openai": "https://status.openai.com",
            "claude": "https://status.anthropic.com",
            "cursor": "https://status.cursor.com",
            "gemini": "https://status.cloud.google.com",
            "copilot": "https://www.githubstatus.com",
            "zai": "https://status.z.ai",
            "openrouter": "https://status.openrouter.ai",
            "bedrock": "https://health.aws.amazon.com/health/status",
        ]
        return urls[id].flatMap(URL.init(string:))
    }
}

enum JSONCoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatters = ISO8601DateFormatter.compatibleFormatters
            for formatter in formatters {
                if let date = formatter.date(from: value) { return date }
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date: \(value)")
        }
        return decoder
    }()
}

private extension ISO8601DateFormatter {
    static let compatibleFormatters: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        return [fractional, regular]
    }()
}

// MARK: - Antigravity quota windows

struct AntigravityQuotaWindow {
    let poolID: String
    let poolTitle: String
    let windowID: String
    let windowTitle: String
    let window: RateWindow
    /// The engine's title for this window (as the quota list shows it), when it reported one.
    var laneTitle: String? = nil
}

extension ProviderSnapshot {
    var antigravityQuotaAccountKey: String? {
        guard provider == "antigravity" else { return nil }
        let email = [usage?.identity?.accountEmail, usage?.accountEmail, account]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .first { !$0.isEmpty }
        let org = (usage?.identity?.accountOrganization ?? usage?.accountOrganization ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let email = email {
            return StableIdentifier.hash("antigravity::\(email)::\(org)")
        }
        // Local CLI (`agy -p /usage`) and local language-server probes carry no
        // email; OAuth and admin sources identify their account via email.
        let lowerSource = source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !lowerSource.contains("oauth"), !lowerSource.contains("admin") else { return nil }
        return StableIdentifier.hash("antigravity::local")
    }

    var antigravityQuotaWindows: [AntigravityQuotaWindow] {
        guard provider == "antigravity", source?.lowercased().contains("admin") != true else { return [] }
        var extracted: [AntigravityQuotaWindow] = []
        var seen = Set<String>()

        if let raw = rawJSON,
           let data = raw.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let usageDict = (root["usage"] as? [String: Any]) ?? JSONKeys.normalizedDictionary(root)["usage"] as? [String: Any],
           let extra = (usageDict["extraRateWindows"] as? [[String: Any]])
               ?? (JSONKeys.normalizedDictionary(usageDict)["extraratewindows"] as? [[String: Any]])
        {
            for entry in extra {
                if (entry["usageKnown"] as? Bool) == false { continue }
                guard let id = entry["id"] as? String,
                      let title = entry["title"] as? String,
                      let windowDict = entry["window"] as? [String: Any],
                      let windowData = try? JSONSerialization.data(withJSONObject: windowDict),
                      let rate = try? JSONCoding.decoder.decode(RateWindow.self, from: windowData),
                      let percent = rate.usedPercent, percent.isFinite, (0...100).contains(percent),
                      let cadence = Self.antigravityCadence(window: rate, id: id, title: title),
                      let pool = Self.antigravityPool(id: id, title: title)
                else { continue }
                let composite = "\(pool.id)::\(cadence.id)"
                guard seen.insert(composite).inserted else { continue }
                extracted.append(AntigravityQuotaWindow(
                    poolID: pool.id,
                    poolTitle: pool.title,
                    windowID: cadence.id,
                    windowTitle: cadence.title,
                    window: rate,
                    laneTitle: AntigravityQuotaNaming.title(id: id, title: title)))
            }
        }

        if !extracted.isEmpty { return extracted }

        // Fallback for legacy/model-quota payloads that only populate primary
        // (Gemini representative) and secondary (Claude/GPT representative).
        let referenceTime = usage?.updatedAt ?? Date()
        let fallbacks: [(String, String, RateWindow?)] = [
            ("gemini", L("Gemini"), usage?.primary),
            ("claude-gpt", L("Claude/GPT"), usage?.secondary),
        ]
        for (poolID, poolTitle, candidate) in fallbacks {
            guard let rate = candidate,
                  let percent = rate.usedPercent, percent.isFinite, (0...100).contains(percent)
            else { continue }
            let cadence: (id: String, title: String)
            if let minutes = rate.windowMinutes {
                if abs(minutes - 10080) <= 1 {
                    cadence = ("weekly", L("Weekly"))
                } else if abs(minutes - 300) <= 1 {
                    cadence = ("five-hour", L("5 hours"))
                } else {
                    continue
                }
            } else if let resetsAt = rate.resetsAt, resetsAt.timeIntervalSince(referenceTime) > 86_400 {
                cadence = ("weekly", L("Weekly"))
            } else {
                cadence = ("five-hour", L("5 hours"))
            }
            let composite = "\(poolID)::\(cadence.id)"
            guard seen.insert(composite).inserted else { continue }
            extracted.append(AntigravityQuotaWindow(
                poolID: poolID,
                poolTitle: poolTitle,
                windowID: cadence.id,
                windowTitle: cadence.title,
                window: rate))
        }
        return extracted
    }

    private static func antigravityCadence(window: RateWindow, id: String, title: String) -> (id: String, title: String)? {
        if let minutes = window.windowMinutes {
            if abs(minutes - 300) <= 1 { return ("five-hour", L("5 hours")) }
            if abs(minutes - 10080) <= 1 { return ("weekly", L("Weekly")) }
        }
        let combined = "\(title) \(id)".lowercased().replacingOccurrences(of: "_", with: "-")
        if combined.contains("5-hour") || combined.contains("5h") || combined.contains("five-hour")
            || combined.contains("five hour") || combined.contains("session")
        {
            return ("five-hour", L("5 hours"))
        }
        if combined.contains("weekly") {
            return ("weekly", L("Weekly"))
        }
        return nil
    }

    private static func antigravityPool(id: String, title: String) -> (id: String, title: String)? {
        if let pool = AntigravityQuotaNaming.pool(id: id, title: title) { return pool }
        let combined = "\(title) \(id)".lowercased()
        if combined.contains("gemini") {
            return ("gemini", L("Gemini"))
        }
        if combined.contains("claude") || combined.contains("gpt") {
            return ("claude-gpt", L("Claude/GPT"))
        }
        guard id.lowercased().hasPrefix("antigravity-quota-summary-") else { return nil }
        var base = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" 5-hour", " weekly", " 5 hours", " Weekly"] where base.lowercased().hasSuffix(suffix.lowercased()) {
            base = String(base.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let slug = base.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !slug.isEmpty else { return nil }
        return (slug, base.isEmpty ? L("Quota") : base)
    }
}

/// Antigravity's quota groups, read from the engine's window ids
/// (`antigravity-quota-summary-<bucket>`): `gemini-5h`, `gemini-weekly`,
/// `3p-5h`, `3p-weekly`, and separate model groups such as Gemini 4 Argon
/// (`gemini-argon-wtu-weekly`), which the engine also titles "Gemini weekly".
enum AntigravityQuotaNaming {
    private static let prefix = "antigravity-quota-summary-"

    /// The bucket without the prefix and the cadence suffix: `gemini`, `3p`, `gemini-argon-wtu`.
    static func bucketGroup(id: String) -> String? {
        let lower = id.lowercased()
        guard lower.hasPrefix(prefix) else { return nil }
        var bucket = String(lower.dropFirst(prefix.count))
        for suffix in ["-5h", "-weekly", "-five-hour"] where bucket.hasSuffix(suffix) {
            bucket = String(bucket.dropLast(suffix.count))
            break
        }
        return bucket.isEmpty ? nil : bucket
    }

    static func pool(id: String, title: String) -> (id: String, title: String)? {
        guard let group = bucketGroup(id: id) else { return nil }
        if group.contains("argon") { return ("gemini-argon", L("Gemini Argon")) }
        if group == "gemini" { return ("gemini", L("Gemini")) }
        if group == "3p" { return ("claude-gpt", L("Claude/GPT")) }
        return nil
    }

    /// The engine's title, naming the Argon group so it is not a second "Gemini weekly".
    static func title(id: String, title: String) -> String {
        guard let group = bucketGroup(id: id), group.contains("argon"),
              !title.lowercased().contains("argon") else { return title }
        let lower = id.lowercased()
        return lower.hasSuffix("-5h") || lower.hasSuffix("-five-hour") ? "Gemini Argon 5-hour" : "Gemini Argon weekly"
    }
}
