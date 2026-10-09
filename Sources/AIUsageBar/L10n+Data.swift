import Foundation

extension L10nTable {
    /// Simplified Chinese for the data strings. Keys are the exact English text.
    static let data: [String: String] = [
        // Relative update times
        "Updated just now": "刚刚更新",
        "Updated %@ ago": "%@前更新",
        "Updated recently": "最近已更新",
        "Refreshing…": "正在刷新…",

        // Dashboard metric titles
        "Today": "今日",
        "Today tokens": "今日 Token",
        "Today cost": "今日费用",
        "Today est. cost": "今日估算费用",
        "Today est.": "今日估算",
        "Today req": "今日请求数",
        "Month tokens": "本月 Token",
        "Month cost": "本月费用",
        "30d tokens": "30 天 Token",
        "30d est. cost": "30 天估算费用",
        "30d est.": "30 天估算",
        "30d spend": "30 天花费",
        "30d requests": "30 天请求数",
        "7d spend": "7 天花费",
        "Tokens & cost": "Token 与费用",
        "Token plan": "Token 套餐",
        "Plan": "套餐",
        "Models": "模型",
        "Cost": "费用",
        "Credits": "额度点数",
        "Balance": "余额",
        "Tokens": "Token",
        "Requests": "请求数",
        "Usage type": "用量类型",

        // Dashboard metric values and subtitles
        "Platform only": "仅限平台",
        "Not exposed": "未提供",
        "Unavailable": "不可用",
        "Quota only": "仅额度",
        "DeepSeek did not return cost data": "DeepSeek 未返回费用数据",
        "Official details require a DeepSeek Platform session": "官方明细需要 DeepSeek Platform 会话",
        "z.ai has no monetary cost summary": "z.ai 不提供金额费用汇总",
        "No model-usage history was returned": "未返回模型用量历史",
        "Local history begins after token usage is observed": "检测到 Token 用量后开始记录本地历史",
        "Quota usage cannot be converted into money": "额度用量无法换算为金额",
        "No monetary balance is exposed": "未提供金额余额",
        "Local coverage since %@": "本地记录始于 %@",
        "%@ requests": "%@ 次请求",
        "Paid %@": "充值 %@",
        "Granted %@": "赠送 %@",
        "Estimated locally since %@": "自 %@ 起本地估算",
        "Estimated locally": "本地估算",
        "%d adjustment interval excluded": "已排除 %d 个调整区间",
        "%d adjustment intervals excluded": "已排除 %d 个调整区间",
        "%d uncertain interval unassigned": "%d 个不确定区间未归属",
        "%d uncertain intervals unassigned": "%d 个不确定区间未归属",
        "Balance-delta estimate": "按余额变化估算",
        "Some usage has no price": "部分用量无价格",
        "Unpriced: %@": "未定价：%@",
        "Partial estimate · %@": "部分估算 · %@",
        "z.ai needs an API token. Open Settings, select z.ai, paste the token, then save and verify.":
            "z.ai 需要 API Token。请打开设置，选择 z.ai，粘贴 Token，然后保存并验证。",

        // Quota windows and pace
        "Quota": "额度",
        "Quotas": "额度",
        "5 hours": "5 小时",
        "Daily": "每日",
        "Weekly": "每周",
        "Monthly": "每月",
        "%d days": "%d 天",
        "%d hours": "%d 小时",
        "%d minutes": "%d 分钟",
        "Quota depleted": "额度已用尽",
        "Window just started": "窗口刚开始",
        "%.0f%% reserve": "余量 %.0f%%",
        "Runs out in %@": "%@后用尽",
        "On pace": "进度正常",
        "%.0f%% over pace": "超出进度 %.0f%%",
        "soon": "很快",

        // Dashboard sections
        "Subscription quota · all devices": "订阅额度 · 所有设备",
        "Local usage": "本地用量",
        "Summary": "概览",
        "Local usage history": "本地用量历史",
        "History": "历史",

        // Service status
        "Status unavailable": "状态不可用",
        "Operational": "运行正常",
        "Degraded service": "服务降级",
        "Service outage": "服务中断",

        // Subscription timing
        "Subscription expires": "订阅到期",
        "Subscription renews": "订阅续费",
        "Expiry date passed": "已过到期日",
        "Renewal date passed": "已过续费日",
        "1 day left": "剩余 1 天",
        "%d days left": "剩余 %d 天",

        // Quota and token history
        "Quota history could not be read; the original file is preserved.": "无法读取额度历史，已保留原始文件。",
        "Quota history could not be saved. Current quotas are still available.": "无法保存额度历史，当前额度仍可查看。",
        "Token history could not be read and was left untouched: %@": "无法读取 Token 历史，文件未作改动：%@",
        "History correction could not preserve its backup: %@": "历史修正无法保留备份：%@",
        "Token history could not be saved: %@": "无法保存 Token 历史：%@",
        "24h": "24 小时",
        "7d": "7 天",
        "30d": "30 天",
        "90d": "90 天",
        "1y": "1 年",
        "All": "全部",

        // Authentication methods
        "API key": "API Key",
        "Multiple token accounts": "多个 Token 账号",
        "Browser session or cookie": "浏览器会话或 Cookie",
        "Provider fields": "服务商字段",
        "API authentication": "API 认证",
        "API token account": "API Token 账号",
        "Browser or session authentication": "浏览器或会话认证",
        "Provider configuration": "服务商配置",
        "Provider-managed authentication": "由服务商管理的认证",
        "Local probe": "本地探测",
        "Augment CLI / browser": "Augment CLI / 浏览器",
        "Local IDE configuration": "本地 IDE 配置",
        "Browser / local cache": "浏览器 / 本地缓存",
        "Zed Keychain session": "Zed 钥匙串会话",
        "AWS credentials / profile": "AWS 凭据 / 配置文件",
        "Grok CLI / browser": "Grok CLI / 浏览器",

        // Authentication field labels and placeholders
        "Paste API key or token": "粘贴 API Key 或 Token",
        "Paste API key": "粘贴 API Key",
        "Cookie or session token": "Cookie 或会话 Token",
        "Paste Cookie header or session token": "粘贴 Cookie 请求头或会话 Token",
        "Cookie or Bearer token": "Cookie 或 Bearer Token",
        "GitHub token": "GitHub Token",
        "Bearer token": "Bearer Token",
        "Kimi auth token": "Kimi 认证 Token",
        "Oasis token": "Oasis Token",
        "Management API key": "管理 API Key",
        "OpenAI project ID (optional)": "OpenAI 项目 ID（可选）",
        "Azure endpoint": "Azure 端点",
        "Deployment name": "部署名称",
        "Workspace ID (optional)": "工作区 ID（可选）",
        "Workspace/project ID (optional)": "工作区/项目 ID（可选）",
        "Project ID (optional)": "项目 ID（可选）",
        "Region (optional)": "区域（可选）",
        "international or china": "international 或 china",
        "global or bigmodel-cn": "global 或 bigmodel-cn",
        "global or china": "global 或 china",
        "Proxy base URL": "代理 Base URL",
        "LiteLLM base URL": "LiteLLM Base URL",
        "Custom base URL (optional)": "自定义 Base URL（可选）",
        "Gateway base URL": "网关 Base URL",
        "Router base URL": "路由 Base URL",
        "Team ID": "团队 ID",

        // Authentication guidance
        "This provider is newer than the bundled authentication catalog. Use its upstream documentation and config file until the catalog is updated.":
            "此服务商比内置认证目录更新。在目录更新前，请参考其上游文档和配置文件。",
        "Uses ~/.codex OAuth credentials or the installed Codex CLI. OpenAI browser extras are optional.":
            "使用 ~/.codex 中的 OAuth 凭据或已安装的 Codex CLI。OpenAI 浏览器附加功能为可选项。",
        "Requires an OpenAI Admin key for organization usage. A normal API key only exposes limited balance data.":
            "查看组织用量需要 OpenAI Admin Key。普通 API Key 只能获取有限的余额数据。",
        "Requires an Azure OpenAI key, endpoint, and deployment name.":
            "需要 Azure OpenAI Key、端点和部署名称。",
        "API mode requires an Anthropic Admin key. OAuth, Claude CLI, and browser-session modes remain available.":
            "API 模式需要 Anthropic Admin Key。OAuth、Claude CLI 和浏览器会话模式仍可使用。",
        "Uses the ClinePass credentials or provider-specific login described in the upstream documentation.":
            "使用 ClinePass 凭据或上游文档中说明的服务商专用登录方式。",
        "Uses a signed-in Cursor browser session. Paste a Cookie header only when automatic browser import is unavailable.":
            "使用已登录的 Cursor 浏览器会话。仅在无法自动从浏览器导入时才粘贴 Cookie 请求头。",
        "Uses the OpenCode web dashboard session.":
            "使用 OpenCode 网页控制台会话。",
        "Uses the OpenCode Go web/local source. A workspace ID is optional.":
            "使用 OpenCode Go 网页/本地数据源。工作区 ID 为可选项。",
        "Supports an Alibaba Coding Plan API key, with browser cookies as an alternative.":
            "支持 Alibaba Coding Plan API Key，也可改用浏览器 Cookie。",
        "Uses Bailian browser or manual cookies.":
            "使用百炼浏览器 Cookie 或手动填写的 Cookie。",
        "Uses Qwen Cloud browser or manual session cookies.":
            "使用 Qwen Cloud 浏览器 Cookie 或手动填写的会话 Cookie。",
        "Uses Factory cookies or a pasted Bearer token.":
            "使用 Factory Cookie 或粘贴的 Bearer Token。",
        "Uses Gemini CLI OAuth credentials; no standalone API key should be saved here.":
            "使用 Gemini CLI 的 OAuth 凭据；请勿在此保存单独的 API Key。",
        "Uses the local Antigravity language server and needs no external credential.":
            "使用本地 Antigravity 语言服务器，无需外部凭据。",
        "Accepts a GitHub/Copilot API token; GitHub device-flow login is also supported.":
            "接受 GitHub/Copilot API Token；也支持 GitHub 设备码登录。",
        "Uses Chrome localStorage or a manual Bearer token.":
            "使用 Chrome localStorage 或手动填写的 Bearer Token。",
        "Uses a z.ai API token. Region and optional workspace/project scoping are preserved.":
            "使用 z.ai API Token。会保留区域以及可选的工作区/项目范围。",
        "Uses a MiniMax Coding Plan API token, or a browser session.":
            "使用 MiniMax Coding Plan API Token 或浏览器会话。",
        "Uses a Manus session_id cookie.":
            "使用 Manus 的 session_id Cookie。",
        "Uses the kimi-auth JWT or a full Cookie header.":
            "使用 kimi-auth JWT 或完整的 Cookie 请求头。",
        "Uses a Kilo API token; the Kilo CLI login remains an automatic fallback.":
            "使用 Kilo API Token；Kilo CLI 登录仍作为自动备用方式。",
        "Requires kiro-cli installed and signed in with AWS Builder ID.":
            "需要已安装 kiro-cli 并使用 AWS Builder ID 登录。",
        "Uses gcloud Application Default Credentials and Cloud Monitoring access.":
            "使用 gcloud 应用默认凭据（ADC）和 Cloud Monitoring 访问权限。",
        "Uses the auggie CLI first and browser cookies as a fallback.":
            "优先使用 auggie CLI，浏览器 Cookie 作为备用。",
        "Reads the local JetBrains AI quota XML file; no key is required.":
            "读取本地 JetBrains AI 额度 XML 文件，无需密钥。",
        "Uses a Moonshot/Kimi API key. Select the matching international or China region.":
            "使用 Moonshot/Kimi API Key。请选择对应的国际或中国区域。",
        "Uses the signed-in Amp settings-page browser session.":
            "使用已登录 Amp 设置页的浏览器会话。",
        "Uses T3 Chat browser cookies.":
            "使用 T3 Chat 浏览器 Cookie。",
        "An API key validates Ollama Cloud access; browser cookies can expose Cloud quota windows.":
            "API Key 用于验证 Ollama Cloud 访问权限；浏览器 Cookie 可获取 Cloud 额度窗口。",
        "Uses a Synthetic API key.": "使用 Synthetic API Key。",
        "Uses a Warp API token.": "使用 Warp API Token。",
        "Uses an OpenRouter API key.": "使用 OpenRouter API Key。",
        "Uses an ElevenLabs API key.": "使用 ElevenLabs API Key。",
        "Uses browser localStorage or the local Windsurf SQLite cache.":
            "使用浏览器 localStorage 或本地 Windsurf SQLite 缓存。",
        "Uses the local Zed editor Keychain session.":
            "使用本地 Zed 编辑器的钥匙串会话。",
        "Uses a Perplexity session token or browser Cookie header.":
            "使用 Perplexity 会话 Token 或浏览器 Cookie 请求头。",
        "Uses Xiaomi MiMo browser cookies.": "使用 Xiaomi MiMo 浏览器 Cookie。",
        "Uses a Volcengine Ark / Doubao API key.": "使用火山方舟 / 豆包 API Key。",
        "Uses a manual Sakana Cookie header.": "使用手动填写的 Sakana Cookie 请求头。",
        "Uses Abacus AI browser cookies.": "使用 Abacus AI 浏览器 Cookie。",
        "Uses Mistral Console Ory session cookies.": "使用 Mistral Console 的 Ory 会话 Cookie。",
        "DeepSeek keys are stored as tokenAccounts, matching the usage engine. The generic config set-api-key command is intentionally not used.":
            "DeepSeek Key 以 tokenAccounts 形式保存，与用量引擎保持一致。此处有意不使用通用的 config set-api-key 命令。",
        "Uses a DeepInfra API key.": "使用 DeepInfra API Key。",
        "Uses a Codebuff API token; codebuff login credentials remain a fallback.":
            "使用 Codebuff API Token；codebuff login 凭据仍作为备用。",
        "Uses a Crof API key.": "使用 Crof API Key。",
        "Venice keys are stored as tokenAccounts, matching the usage engine.":
            "Venice Key 以 tokenAccounts 形式保存，与用量引擎保持一致。",
        "Uses Command Code browser cookies.": "使用 Command Code 浏览器 Cookie。",
        "Uses Qoder browser or manual cookies.": "使用 Qoder 浏览器 Cookie 或手动填写的 Cookie。",
        "Uses a manual Oasis token. Username/password login is handled by the provider flow.":
            "使用手动填写的 Oasis Token。用户名/密码登录由服务商流程处理。",
        "Uses AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, optional session token, or a named AWS profile.":
            "使用 AWS_ACCESS_KEY_ID、AWS_SECRET_ACCESS_KEY、可选的会话 Token，或指定的 AWS 配置文件。",
        "Uses grok login and the Grok CLI billing RPC, with browser-session fallback.":
            "使用 grok login 和 Grok CLI 计费 RPC，浏览器会话作为备用。",
        "Uses a GroqCloud API key.": "使用 GroqCloud API Key。",
        "Requires an API key and the proxy base URL.": "需要 API Key 和代理 Base URL。",
        "Requires a LiteLLM virtual key and proxy base URL.": "需要 LiteLLM 虚拟 Key 和代理 Base URL。",
        "Uses a Deepgram API key. A project ID is optional.": "使用 Deepgram API Key。项目 ID 为可选项。",
        "Uses a Poe API key.": "使用 Poe API Key。",
        "Uses a Chutes API key.": "使用 Chutes API Key。",
        "Uses a Neuralwatt API key.": "使用 Neuralwatt API Key。",
        "Uses a ClawRouter API key. The hosted service is the default; a custom base URL is optional.":
            "使用 ClawRouter API Key。默认使用托管服务；自定义 Base URL 为可选项。",
        "Uses a LongCat API key.": "使用 LongCat API Key。",
        "Requires a gateway key and the self-hosted base URL.": "需要网关 Key 和自托管 Base URL。",
        "Uses a local Wayfinder router gateway.": "使用本地 Wayfinder 路由网关。",
        "Uses a ZenMux Management API key.": "使用 ZenMux 管理 API Key。",
        "Uses an AIand API key.": "使用 AIand API Key。",
        "Uses ZoomMate browser cookies or a captured manual session.":
            "使用 ZoomMate 浏览器 Cookie 或手动捕获的会话。",
        "Requires an xAI Management API key and team ID; inference keys are not accepted.":
            "需要 xAI 管理 API Key 和团队 ID；不接受推理 Key。",
    ]
}
