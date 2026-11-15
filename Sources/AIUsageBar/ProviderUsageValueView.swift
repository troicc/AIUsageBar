import SwiftUI

/// Shared by the provider detail and All Providers, with an account-scoped fee.
struct ProviderUsageValueView: View {
    let dashboard: ProviderDashboard

    var body: some View {
        if let key = dashboard.subscriptionPreferenceKey {
            ProviderUsageValueCard(dashboard: dashboard, preferenceKey: key)
                .id(key)
        }
    }
}

struct ProviderUsageValueCard: View {
    let dashboard: ProviderDashboard
    @AppStorage private var monthlyFee: String
    @AppStorage private var providerFee: String
    /// The subscription date entered for this account, which sets the billing cycle.
    @AppStorage private var subscriptionDate: String
    @ObservedObject private var currency: CurrencySettingsStore
    @State private var modelsExpanded: Bool
    @State private var editingFee = false

    init(dashboard: ProviderDashboard, preferenceKey: String,
         defaults: UserDefaults = .standard, modelsExpanded: Bool = false,
         currency: CurrencySettingsStore = .shared) {
        self.dashboard = dashboard
        _monthlyFee = AppStorage(wrappedValue: "", preferenceKey, store: defaults)
        _providerFee = AppStorage(wrappedValue: "", "subscriptionDefaultUSD.\(dashboard.id)", store: defaults)
        _subscriptionDate = AppStorage(wrappedValue: "", dashboard.subscriptionDatePreferenceKey ?? "", store: defaults)
        self.currency = currency
        _modelsExpanded = State(initialValue: modelsExpanded)
    }

    private var feeText: String { monthlyFee.isEmpty ? providerFee : monthlyFee }
    private var fee: Double? { SubscriptionComparison.monthlyUSD(feeText) }
    private var multiple: Double? {
        SubscriptionComparison.multiple(estimate: total, monthlyUSD: fee)
    }

    /// Counted from the start of the current subscription month when its date
    /// is known; otherwise the last 30 days.
    private var cycle: DateInterval? {
        dashboard.usageCostHistory == nil || dashboard.subscriptionDatePreferenceKey == nil
            ? nil : dashboard.billingCycle(manual: subscriptionDate)
    }

    private var estimate: CostEstimateSummary? {
        guard let cycle = cycle, let history = dashboard.usageCostHistory else { return dashboard.usageCostEstimate }
        return history.costEstimate(since: cycle.start)
    }

    /// Included credit spent by cloud sessions over the same range.
    private var cloud: ClaudeCreditHistory.Spend? {
        dashboard.claudeCreditHistory?.spent(since: cycle?.start ?? Date().addingTimeInterval(-30 * 86_400))
    }

    /// Local logs plus cloud credit; without a local cost it is partial.
    private var total: CostEstimateSummary? {
        guard let cloud = cloud else { return estimate }
        return CostEstimateSummary(knownCost: (estimate?.knownCost ?? 0) + cloud.dollars,
            unpricedModels: estimate?.unpricedModels ?? [],
            hasUnattributedCost: estimate?.knownCost == nil || estimate?.hasUnattributedCost == true)
    }

    private var models: [ModelUsageSummary] {
        guard let cycle = cycle, let history = dashboard.usageCostHistory else { return dashboard.modelUsage }
        return history.modelUsage(since: cycle.start)
    }

    private var title: String {
        let local = dashboard.id == "claude" && cloud == nil
        guard cycle != nil else { return L(local ? "Local usage value · 30d" : "Usage value · 30d") }
        return L(local ? "Local usage value · this billing cycle" : "Usage value · this billing cycle")
    }

    private var cycleText: String? {
        guard let cycle = cycle else { return nil }
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.locale)
        return L("Since %@ · resets with the subscription", cycle.start.formatted(style))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The method note sits behind the ⓘ, like the other sections.
            ProviderDetailSectionTitle(title: title, info: L(cloud != nil
                ? "Local Claude Code logs plus the included cloud credit spent, from its balance at each refresh; web chats are excluded. API equivalent ÷ monthly fee, not total subscription value or a bill."
                : dashboard.id == "claude"
                ? "Local Claude Code logs only; web chats are excluded. API equivalent ÷ monthly fee, not total subscription value or a bill. Logs cannot verify the billing account."
                : "API equivalent from local logs ÷ monthly fee. Not a bill or quota; logs cannot verify the billing account."))
            if let cycleText = cycleText {
                Text(cycleText).font(.system(size: 10)).foregroundColor(.secondary)
            }
            comparison
            subscriptionEditor
            if total?.isPartial == true {
                Text(L("Partial estimate · known costs only"))
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            if currency.selection == .cny {
                Text(currency.quote.map { L("USD/CNY %@ · %@ · reference rate", String(format: "%.4f", $0.rate), $0.date) }
                    ?? L("Exchange rate unavailable · showing USD"))
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
            DisclosureGroup(isExpanded: $modelsExpanded) {
                modelRows.padding(.top, 8)
            } label: {
                Text(cycle != nil ? L("Models · this cycle (%d)", models.count) : L("Models · 30d (%d)", models.count))
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var comparison: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(usageCostText(total, display: currency.display))
                    .font(.system(size: 24, weight: .light, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                if let cloud = cloud {
                    Text(L("Local %@ · cloud %@", usageCostText(estimate, display: currency.display),
                           currency.display.format(cloud.dollars)))
                        .font(.system(size: 10)).foregroundColor(.secondary)
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                        .help(cloud.untrackedDollars > 0
                            ? L("Cloud includes %@ already used when the credit was first read.",
                                currency.display.format(cloud.untrackedDollars))
                            : L("Included credit spent between refreshes."))
                } else {
                    Text(L("API equivalent"))
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                if let multiple = multiple {
                    Text((total?.isPartial == true ? "≥" : "")
                         + String(format: "%.2f×", multiple))
                        .font(.system(size: 24, weight: .light, design: .rounded))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                        .foregroundColor(ProviderBrand.color(for: dashboard.id))
                    Text(L("of monthly fee"))
                        .font(.system(size: 10)).foregroundColor(.secondary)
                } else {
                    Text(L(fee == 0 ? "No paid subscription" : fee == nil ? "Set monthly fee" : "Cost unavailable"))
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
        }
    }

    private var subscriptionEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(L("Subscription"))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Spacer(minLength: 4)
                Text(fee.map { currency.display.format($0) } ?? L("Not set"))
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                Text(L("/ mo")).font(.system(size: 10)).foregroundColor(.secondary)
                Button(L(editingFee ? "Done" : "Edit")) { editingFee.toggle() }
                    .font(.system(size: 10)).buttonStyle(BorderlessButtonStyle())
                    .disabled(editingFee && fee == nil && !feeText.isEmpty)
            }
            if editingFee || (!feeText.isEmpty && fee == nil) {
                HStack {
                    Text(L("Monthly fee · USD")).font(.system(size: 10)).foregroundColor(.secondary)
                    Spacer()
                    if !monthlyFee.isEmpty {
                        Button(L("Use default")) { monthlyFee = ""; editingFee = false }
                            .font(.system(size: 10)).buttonStyle(BorderlessButtonStyle())
                    }
                    TextField(L("Monthly fee"), text: Binding(get: { feeText }, set: { monthlyFee = $0 }))
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.system(size: 11)).multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .accessibilityLabel(Text(L("Monthly subscription in US dollars")))
                    .help(L("Enter what you pay in USD per month. For annual billing, use the monthly average. Saved for this account."))
                }
            }
            if !feeText.isEmpty && fee == nil {
                Text(L("Enter a nonnegative USD amount with up to 2 decimal places."))
                    .font(.system(size: 9)).foregroundColor(.orange)
            }
        }
    }

    @ViewBuilder
    private var modelRows: some View {
        if models.isEmpty {
            Text(L(cycle != nil ? "No model breakdown available for this billing cycle." : "No model breakdown available for the last 30 days."))
                .font(.system(size: 11)).foregroundColor(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(models) { row in
                    ModelUsageValueRow(row: row, display: currency.display)
                }
                Text(L("Total tokens include cached tokens when reported. Costs use the prices available in local usage data."))
                    .font(.system(size: 9)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ModelUsageValueRow: View {
    let row: ModelUsageSummary
    let display: CurrencyDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.name)
                .font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline) {
                Text(row.tokens.map { L("%@ tokens", usageTokenText($0)) } ?? L("Tokens unavailable"))
                    .font(.system(size: 10)).foregroundColor(.secondary)
                    .help(row.tokens.map { L("%.0f total tokens", $0) } ?? L("Tokens unavailable"))
                Spacer(minLength: 8)
                Text(usageCostText(row.cost, display: display))
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .fixedSize()
                    .help(row.cost.knownCost.map { String(format: "%.6f USD", $0)
                        + " · " + L(row.cost.isPartial ? "partial estimate" : "API equivalent") } ?? L("No price available"))
            }
        }
    }
}

private func usageCostText(_ estimate: CostEstimateSummary?, display: CurrencyDisplay) -> String {
    guard let cost = estimate?.knownCost else { return L("Unavailable") }
    return (estimate?.isPartial == true ? "≥" : "") + display.format(cost)
}

private func usageTokenText(_ value: Double) -> String {
    if value >= 1_000_000_000 { return String(format: "%.2fB", value / 1_000_000_000) }
    if value >= 1_000_000 { return String(format: "%.2fM", value / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
    return String(format: "%.0f", value)
}
