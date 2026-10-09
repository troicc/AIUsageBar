import Foundation

extension L10nTable {
    /// Simplified Chinese for the menu strings. Keys are the exact English text.
    static let menu: [String: String] = [
        // Status item
        "Refreshing": "正在刷新",
        "Refresh failed": "刷新失败",
        "Refresh failed; showing saved data": "刷新失败；显示已保存的数据",
        "Provider needs attention": "服务商需要关注",
        "%.0f percent used": "已用百分之 %.0f",
        "Usage unavailable": "用量不可用",
        "AIUsageBar — Refreshing…": "AIUsageBar — 正在刷新…",
        "Refresh failed: %@": "刷新失败：%@",
        "Refresh failed — showing saved data: %@": "刷新失败 — 显示已保存的数据：%@",
        "AIUsageBar — no providers enabled": "AIUsageBar — 未启用任何服务商",
        "%.0f%% used": "已用 %.0f%%",

        // Menus
        "Set Up Providers…": "设置服务商…",
        "Providers": "服务商",
        "Open All Provider Details…": "打开所有服务商详情…",
        "Open Detailed Dashboard…": "打开详细面板…",
        "Usage Dashboard": "用量网页控制台",
        "Status Page": "状态页",
        "Authentication & Accounts…": "认证与账号…",
        "Fix Authentication…": "修复认证…",
        "Refreshing…": "正在刷新…",
        "Refresh Now": "立即刷新",
        "Settings…": "设置…",
        "Check for Updates…": "检查更新…",
        "Quit AIUsageBar": "退出 AIUsageBar",
        "About AIUsageBar": "关于 AIUsageBar",
        "Refreshing provider usage…": "正在刷新服务商用量…",
        "Refresh failed — showing saved data": "刷新失败 — 显示已保存的数据",
        "Updated %@ · %d enabled": "%@ 已更新 · 已启用 %d 个",
        "%d enabled providers": "已启用 %d 个服务商",

        // Menu rows
        "Refreshing providers": "正在刷新服务商",
        "OVERVIEW": "概览",
        "%d enabled": "已启用 %d 个",
        "No providers enabled yet": "尚未启用任何服务商",
        "Choose Set Up Providers… below to connect Claude, Codex, DeepSeek or another service.":
            "选择下方的“设置服务商…”以连接 Claude、Codex、DeepSeek 或其他服务。",
        "Connection error": "连接错误",
        "%d more in Providers": "另有 %d 个，见“服务商”",
        "Plan · %@": "套餐 · %@",
        "Quota · all devices including web chat": "额度 · 所有设备（含网页聊天）",
        "Shared quota unavailable": "共享额度不可用",
        "Tokens & cost · local logs only": "Token 与费用 · 仅限本地日志",
        "More information is available in Detailed Dashboard": "更多信息请在详细面板中查看",

        // Notifications
        "%@ needs attention": "%@ 需要关注",
        "%@ recovered": "%@ 已恢复",
        "Provider access is available again.": "服务商已恢复可用。",
        "%@ quota depleted": "%@ 额度已用尽",
        "%@ quota warning": "%@ 额度提醒",
        "%@ usage reached %.0f%%.": "%@ 用量已达 %.0f%%。",

        // Updates and windows
        "Updates are not configured in this build": "此版本未配置更新",
        "Download a newer release manually until the signed update channel is enabled.":
            "在启用签名更新通道之前，请手动下载新版本。",
        "OK": "好",
        "AIUsageBar Settings": "AIUsageBar 设置",

        // Usage engine errors
        "The bundled usage engine is missing.": "缺少内置的用量引擎。",
        "Could not launch the usage engine: %@": "无法启动用量引擎：%@",
        "The usage engine exited with code %d: %@": "用量引擎已退出，代码 %d：%@",
        "The usage engine returned invalid JSON: %@": "用量引擎返回了无效的 JSON：%@",
        "Configuration was not applied; the previous configuration was restored: %@":
            "配置未应用，已恢复之前的配置：%@",
        "Configuration update failed (%@) and the previous configuration could not be restored (%@).":
            "配置更新失败（%@），且无法恢复之前的配置（%@）。",
        "Provider verification completed successfully.": "服务商验证成功。",
        "Timed out after %d seconds": "%d 秒后超时",

        // Provider config errors
        "The provider config root is not a JSON object.": "服务商配置的根节点不是 JSON 对象。",
        "%@ does not store a credential in the provider config file.": "%@ 不在服务商配置文件中存储凭据。",
        "%@ is required.": "必须填写%@。",
        "Enter at least one provider configuration value.": "请至少输入一项服务商配置。",
        "%@ has no token-account configuration.": "%@ 没有 Token 账号配置。",
        "The configured account %@ could not be found.": "找不到已配置的账号 %@。",
        "Base URL": "基础 URL",
        "Workspace ID": "工作区 ID",

        // Dashboard notices
        "Account identity unavailable. History starts after this account can be identified.":
            "无法识别账号身份。识别此账号后才开始记录历史。",
    ]
}
