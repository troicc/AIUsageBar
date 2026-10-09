import Foundation

extension L10nTable {
    /// Simplified Chinese for the dashboard strings. Keys are the exact English text.
    static let dashboard: [String: String] = [
        // Provider detail popover
        "This provider account is no longer enabled.": "此服务商账号已不再启用。",
        "Plan · %@": "套餐 · %@",
        "Subscription plan: %@": "订阅套餐：%@",
        "Refreshing provider usage": "正在刷新服务商用量",
        "Local model usage · estimated API cost, not your bill. Partial estimates show known costs; fully unknown costs appear as gaps. Claude excludes other models; logs cannot verify the billing account.":
            "本地模型用量 · 估算的 API 费用，并非你的账单。部分估算仅显示已知费用；完全未知的费用显示为空缺。Claude 不含其他模型；日志无法核实计费账号。",
        "Each chart is labeled and scaled independently.": "每个图表单独标注并独立缩放。",
        "Refreshing…": "正在刷新…",
        "Refresh": "刷新",
        "Web dashboard": "网页控制台",
        "Open status page": "打开状态页",
        "Status Page": "状态页",
        "Open provider settings": "打开服务商设置",
        "Provider Settings": "服务商设置",
        "%.0f%% used · %.0f%% left": "已用 %.0f%% · 剩余 %.0f%%",
        "%.0f percent used": "已用百分之 %.0f",
        "Top model · 10d": "最常用模型 · 10 天",
        "Top model · Today": "最常用模型 · 今日",
        "Ranked by tokens. 10d includes today and the previous 9 local calendar days; Today starts at local midnight. Missing model breakdowns are not guessed.":
            "按 Token 数排序。10 天包括今日及之前 9 个本地自然日；今日从本地午夜开始计算。缺失的模型明细不会被推测。",
        "No model data": "无模型数据",
        "No dated model usage is available for this period.": "此期间没有带日期的模型用量。",

        // History charts
        "No data": "无数据",
        "%@ points from %@ to %@": "%@ 个数据点，从 %@ 到 %@",
        "latest %@%@": "最新 %@%@",
        "peak %@ on %@": "峰值 %@（%@）",
        "some costs are partial estimates": "部分费用为部分估算",
        ", ": "，",
        "No known prices": "无已知价格",
        "Partial estimate; known costs only": "部分估算；仅含已知费用",
        "Unpriced: %@": "未定价：%@",
        "Some costs unavailable": "部分费用不可用",
        "Latest %@": "最新 %@",
        "Partial estimates · known costs only": "部分估算 · 仅含已知费用",
        "Daily tokens": "每日 Token",
        "Daily estimated cost": "每日估算费用",
        "Daily cost": "每日费用",
        "Daily requests": "每日请求数",
        "Hourly tokens": "每小时 Token",
        "Daily estimated spend": "每日估算花费",
        "5h quota used": "5 小时额度已用",
        "Tokens": "Token",
        "Cost": "费用",
        "Requests": "请求数",

        // All Providers
        "All Providers": "所有服务商",
        "%d enabled accounts": "%d 个已启用账号",
        "No enabled providers. Add a provider in Settings.": "没有已启用的服务商。请在设置中添加服务商。",
        "Settings": "设置",
        "Open web dashboard": "打开网页控制台",

        // Usage value
        "Local usage value · 30d": "本地用量价值 · 30 天",
        "Usage value · 30d": "用量价值 · 30 天",
        "Local Claude Code logs only; web chats are excluded. API equivalent ÷ monthly fee, not total subscription value or a bill. Logs cannot verify the billing account.":
            "仅统计本地 Claude Code 日志，不含网页聊天。API 等价费用 ÷ 月费，并非订阅的全部价值，也不是账单。日志无法核实计费账号。",
        "API equivalent from local logs ÷ monthly fee. Not a bill or quota; logs cannot verify the billing account.":
            "本地日志的 API 等价费用 ÷ 月费。并非账单或额度；日志无法核实计费账号。",
        "Partial estimate · known costs only": "部分估算 · 仅含已知费用",
        "USD/CNY %@ · %@ · reference rate": "USD/CNY %@ · %@ · 参考汇率",
        "Exchange rate unavailable · showing USD": "汇率不可用 · 以 USD 显示",
        "Models · 30d (%d)": "模型 · 30 天（%d）",
        "API equivalent": "API 等价费用",
        "of monthly fee": "相当于月费",
        "No paid subscription": "无付费订阅",
        "Set monthly fee": "设置月费",
        "Cost unavailable": "费用不可用",
        "Subscription": "订阅",
        "Not set": "未设置",
        "/ mo": "/ 月",
        "Done": "完成",
        "Edit": "编辑",
        "Monthly fee · USD": "月费 · USD",
        "Use default": "使用默认值",
        "Monthly fee": "月费",
        "Monthly subscription in US dollars": "以美元计的每月订阅费",
        "Enter what you pay in USD per month. For annual billing, use the monthly average. Saved for this account.":
            "输入你每月支付的美元金额。按年计费请填写月均金额。仅为此账号保存。",
        "Enter a nonnegative USD amount with up to 2 decimal places.": "请输入不小于 0 的美元金额，最多 2 位小数。",
        "No model breakdown available for the last 30 days.": "近 30 天没有可用的模型明细。",
        "Total tokens include cached tokens when reported. Costs use the prices available in local usage data.":
            "总 Token 数包含已报告的缓存 Token。费用按本地用量数据中可用的价格计算。",
        "%@ tokens": "%@ Token",
        "Tokens unavailable": "Token 数不可用",
        "%.0f total tokens": "共 %.0f 个 Token",
        "partial estimate": "部分估算",
        "No price available": "无可用价格",
        "Unavailable": "不可用",

        // Claude quota history
        "Shared by web, desktop and Claude Code on this account. Web chat has no separate token or cost breakdown here.":
            "此账号的网页版、桌面版和 Claude Code 共用额度。此处不单独列出网页聊天的 Token 或费用明细。",
        "Shared quota unavailable. Local logs do not include web chat tokens or costs.":
            "共享额度不可用。本地日志不包含网页聊天的 Token 或费用。",
        "Quota window": "额度周期",
        "%@ · used": "%@ · 已用",
        "24h ago": "24 小时前",
        "Now": "现在",
        "Last sample: %@ · %d observations": "最近采样：%@ · %d 次观测",
        "Sampled account quota, including web chat. Breaks mark resets, decreases or gaps over 1 hour. Not tokens or cost.":
            "采样的账号额度，包含网页聊天。断点表示重置、下降或超过 1 小时的空缺。并非 Token 数或费用。",
        "History begins with successful refreshes. No samples in the last 24 hours.":
            "历史从成功刷新后开始记录。近 24 小时没有采样。",
        "Quota trend · 24h": "额度趋势 · 24 小时",
        "%.1f%% used": "已用 %.1f%%",
        "%@ shared quota trend, 0 to 100 percent, last 24 hours": "%@ 共享额度趋势，0 到 100%%，近 24 小时",
        "%d observations": "%d 次观测",

        // Quota windows and resets
        "Quota": "额度",
        "5 hours": "5 小时",
        "Daily": "每日",
        "Weekly": "每周",
        "Monthly": "每月",
        "%d days": "%d 天",
        "%d hours": "%d 小时",
        "%d minutes": "%d 分钟",
        "Reset pending": "等待重置",
        "Resets in %@": "%@后重置",
    ]
}
