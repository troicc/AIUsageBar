@preconcurrency import AppKit
import SwiftUI

struct LiveProviderDetailPopoverView: View {
    @ObservedObject var store: DashboardStore
    let snapshotID: String
    /// Told the height the panel needs, so the popover can fit it.
    var onHeight: ((CGFloat) -> Void)? = nil

    var body: some View {
        Group {
            if let snapshot = store.snapshots.first(where: { $0.id == snapshotID }) {
                ProviderDetailPopoverView(
                    dashboard: store.dashboard(for: snapshot),
                    isRefreshing: store.isRefreshing,
                    refresh: { Task { await store.refresh() } },
                    openDashboard: { store.openDashboardURL() },
                    openStatus: { store.openStatusURL() },
                    openSettings: { store.onOpenSettings?() },
                    onHeight: onHeight)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.xmark")
                        .font(.system(size: 30))
                    Text(L("This provider account is no longer enabled."))
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.secondary)
                .frame(width: 390, height: 560)
                .background(Color(nsColor: NSColor.windowBackgroundColor))
            }
        }
        .task {
            guard let snapshot = store.snapshots.first(where: { $0.id == snapshotID }) else { return }
            await store.enrich(snapshot)
        }
    }
}

struct ProviderDetailPopoverView: View {
    let dashboard: ProviderDashboard
    let isRefreshing: Bool
    let refresh: () -> Void
    let openDashboard: () -> Void
    let openStatus: () -> Void
    let openSettings: () -> Void
    /// The most the panel grows to; shorter content gets a shorter panel.
    /// The gallery passes a large value to render all of it.
    var height: CGFloat = 560
    var onHeight: ((CGFloat) -> Void)? = nil
    @State private var headerHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    /// Fits the content until it reaches `height`, then scrolls.
    private var fittedHeight: CGFloat {
        contentHeight > 0 ? min(height, (headerHeight + contentHeight).rounded(.up)) : height
    }

    private var tint: Color { ProviderBrand.color(for: dashboard.id) }

    /// One surface, no cards: sections are set apart by a hairline and a
    /// title, and the numbers carry the hierarchy.
    var body: some View {
        VStack(spacing: 0) {
            header
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: DetailHeaderHeightKey.self, value: proxy.size.height)
                })
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    statusContent
                    balanceHero
                    quotaContent
                    if dashboard.id == "claude" || dashboard.id == "antigravity" {
                        ClaudeQuotaHistoryView(dashboard: dashboard, showsHeadline: false)
                        ClaudeUsageInsightsSection(dashboard: dashboard)
                    }
                    metricsContent
                    ProviderUsageValueView(dashboard: dashboard)
                    SubscriptionTimingView(dashboard: dashboard)
                    historyContent
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 22)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: DetailContentHeightKey.self, value: proxy.size.height)
                })
            }
        }
        .frame(width: 390, height: fittedHeight)
        .background(Color(nsColor: NSColor.windowBackgroundColor))
        .onPreferenceChange(DetailHeaderHeightKey.self) { headerHeight = $0 }
        .onPreferenceChange(DetailContentHeightKey.self) { contentHeight = $0 }
        .onChange(of: fittedHeight) { onHeight?($0) }
    }

    // MARK: Header

    private var account: String? {
        dashboard.accountLabel.flatMap { $0 == "Default" ? nil : $0 }
    }

    /// Identity on the left, the actions as quiet icons on the right.
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ProviderBadge(providerID: dashboard.id, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(dashboard.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    if let plan = dashboard.planLabel, !plan.isEmpty {
                        Text(plan.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.6)
                            .foregroundColor(tint)
                            .help(L("Subscription plan: %@", plan))
                    }
                    if let health = dashboard.serviceStatus?.health, health != .unknown {
                        DSHealthDot(health: health, size: 6)
                            .help(health == .operational ? L("All systems normal")
                                  : dashboard.serviceStatus?.displayText ?? health.title)
                    }
                }
                // Only the account shortens; the freshness always shows.
                HStack(spacing: 0) {
                    if let account = account {
                        Text(account)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(account)
                        Text(" · ")
                    }
                    Text(dashboard.updatedText)
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 28, height: 28)
                        .accessibilityLabel(Text(L("Refreshing provider usage")))
                } else {
                    DetailIconButton(symbol: "arrow.clockwise", help: L("Refresh"), action: refresh)
                        .keyboardShortcut("r", modifiers: .command)
                }
                if dashboard.dashboardURL != nil {
                    DetailIconButton(symbol: "arrow.up.right", help: L("Web dashboard"), action: openDashboard)
                }
                if dashboard.statusURL != nil {
                    DetailIconButton(symbol: "waveform.path.ecg", help: L("Status Page"), action: openStatus)
                }
                DetailIconButton(symbol: "gearshape", help: L("Provider Settings"), action: openSettings)
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: Sections

    /// Incidents and connection errors: a colored line, not a box.
    @ViewBuilder
    private var statusContent: some View {
        if let status = dashboard.serviceStatus, status.health.isIncident {
            notice(symbol: status.health.symbolName, tint: DS.healthColor(status.health),
                   title: status.health.title, detail: status.displayText)
        }
        if let error = dashboard.errorMessage {
            notice(symbol: "exclamationmark.triangle.fill", tint: Color(nsColor: .systemRed),
                   title: error, detail: nil)
        }
    }

    private func notice(symbol: String, tint: Color, title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(tint)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    private var balanceMetric: DashboardMetric? {
        guard dashboard.quotas.isEmpty else { return nil }
        return dashboard.metrics.first { $0.id == "balance" && !DS.isPlaceholder($0) }
    }

    /// Prepaid providers have no quota window; their balance is the headline.
    @ViewBuilder
    private var balanceHero: some View {
        if let balance = balanceMetric {
            DSSectionHeader(title: balance.title)
            VStack(alignment: .leading, spacing: 4) {
                Text(balance.value)
                    .font(.system(size: 34, weight: .light, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let subtitle = balance.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var quotaContent: some View {
        if !dashboard.quotas.isEmpty {
            DSSectionHeader(
                title: dashboard.quotaSectionTitle,
                info: dashboard.id == "claude"
                    ? ClaudeQuotaCoverageView.note(for: dashboard)
                    : dashboard.id == "antigravity"
                    ? L("Subscription quota shared across Antigravity on all devices. Token and cost figures below read local conversation databases on this Mac only.")
                    : nil)
            VStack(spacing: 16) {
                ForEach(dashboard.quotas) { lane in
                    ProviderDetailQuotaRow(lane: lane, color: tint)
                }
            }
        } else if dashboard.id == "claude" {
            ClaudeQuotaCoverageView(dashboard: dashboard)
        }
    }

    @ViewBuilder
    private var metricsContent: some View {
        let visible = dashboard.metrics.filter { !DS.isPlaceholder($0) && $0.id != balanceMetric?.id }
        if !dashboard.metrics.isEmpty && !(visible.isEmpty && balanceMetric != nil) {
            DSSectionHeader(title: dashboard.summarySectionTitle)
            if visible.isEmpty {
                Text(dashboard.metrics.compactMap(\.subtitle).first ?? L("No usage data yet"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)],
                          alignment: .leading, spacing: 16) {
                    ForEach(visible) { metric in
                        ProviderDetailMetricCell(metric: metric)
                    }
                }
            }
        }
        DashboardTopModelsView(dashboard: dashboard)
    }

    @ViewBuilder
    private var historyContent: some View {
        let series = dashboardHistorySeries(for: dashboard)
        if !series.isEmpty {
            DSSectionHeader(title: dashboard.historySectionTitle, info: L(
                dashboard.id == "antigravity"
                ? "Local Antigravity conversation history · estimated public API cost, not a Google charge. Models without public prices show token counts only."
                : dashboard.id == "claude" || dashboard.id == "codex"
                ? "Local model usage · estimated API cost, not your bill. Partial estimates show known costs; fully unknown costs appear as gaps. Claude excludes other models; logs cannot verify the billing account."
                : "Each chart is labeled and scaled independently."))
            VStack(spacing: 22) {
                ForEach(series) { item in
                    ProviderHistorySeriesView(series: item)
                }
            }
        }
    }
}

private struct DetailHeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct DetailContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A borderless icon action; a faint circle shows on hover.
private struct DetailIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundColor(hovering ? .primary : .secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

struct ProviderDetailSectionTitle: View {
    let title: String
    var info: String? = nil

    var body: some View {
        DSSectionHeader(title: title, info: info)
    }
}

/// One quota window: name and what is left, a slim bar, then the reset
/// and pace in small print.
struct ProviderDetailQuotaRow: View {
    let lane: DashboardQuotaLane
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(lane.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(String(format: "%.0f", lane.remainingPercent))
                        .font(.system(size: 20, weight: .light, design: .rounded).monospacedDigit())
                        .foregroundColor(lane.remainingPercent < 15 ? Color(nsColor: .systemRed) : .primary)
                    Text("%")
                        .font(.system(size: 11, weight: .light, design: .rounded))
                        .foregroundColor(.secondary)
                }
                Text(L("left"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            bar
            let details = [lane.resetsAt.flatMap { DS.countdown(to: $0) }.map { L("Resets in %@", $0) } ?? lane.resetText,
                           lane.paceDescription()].compactMap { $0 }
            if !details.isEmpty {
                Text(details.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(L("%.0f percent used", lane.usedPercent)))
    }

    /// In the provider's color; red only when almost nothing is left.
    private var bar: some View {
        let low = lane.remainingPercent < 15
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(low ? Color(nsColor: .systemRed) : color)
                    .frame(width: max(4, geometry.size.width * CGFloat(max(0, min(100, lane.remainingPercent)) / 100)))
                    .opacity(lane.remainingPercent <= 0 ? 0 : 1)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

struct CompactProminentButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundColor(.white)
            .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(configuration.isPressed ? 0.72 : 0.96)))
    }
}

func currencyNumber(_ value: Double, code: String?) -> String {
    guard let rawCode = code?.uppercased(), rawCode.count == 3 else {
        return String(format: "%.2f", value)
    }
    return CurrencyDisplay().format(value, source: rawCode)
}

func compactNumber(_ value: Double) -> String {
    let absolute = abs(value)
    if absolute >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
    if absolute >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
    if absolute >= 1_000 { return String(format: "%.1fK", value / 1_000) }
    return String(format: "%.0f", value)
}

func serviceHealthColor(_ health: ProviderServiceHealth) -> Color {
    switch health {
    case .unknown: return .secondary
    case .operational: return .green
    case .degraded: return .orange
    case .outage: return .red
    }
}


struct DashboardTopModelsView: View {
    let dashboard: ProviderDashboard

    var body: some View {
        if dashboard.showsTopModels {
            VStack(alignment: .leading, spacing: 6) {
                modelRow(L("Top model · 10d"), model: dashboard.topModel10Days)
                modelRow(L("Top model · Today"), model: dashboard.topModelToday)
            }
            .help(L("Ranked by tokens. 10d includes today and the previous 9 local calendar days; Today starts at local midnight. Missing model breakdowns are not guessed."))
        }
    }

    private func modelRow(_ title: String, model: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer(minLength: 4)
            Text(model ?? L("No model data"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(model == nil ? .secondary : .primary)
                .lineLimit(1)
                .help(model ?? L("No dated model usage is available for this period."))
        }
        .accessibilityElement(children: .combine)
    }
}


struct ProviderDetailMetricCell: View {
    let metric: DashboardMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(metric.title)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(metric.value)
                .font(.system(size: 22, weight: .light, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let subtitle = metric.subtitle {
                Text(subtitle)
                    .help(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
