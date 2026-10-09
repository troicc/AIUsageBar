@preconcurrency import AppKit
import SwiftUI

struct LiveProviderDetailPopoverView: View {
    @ObservedObject var store: DashboardStore
    let snapshotID: String

    var body: some View {
        Group {
            if let snapshot = store.snapshots.first(where: { $0.id == snapshotID }) {
                ProviderDetailPopoverView(
                    dashboard: store.dashboard(for: snapshot),
                    isRefreshing: store.isRefreshing,
                    refresh: { Task { await store.refresh() } },
                    openDashboard: { store.openDashboardURL() },
                    openStatus: { store.openStatusURL() },
                    openSettings: { store.onOpenSettings?() })
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

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    private var tint: Color { ProviderBrand.color(for: dashboard.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    statusContent
                    if dashboard.id == "claude" {
                        quotaContent
                        ClaudeQuotaCoverageView(dashboard: dashboard)
                        ClaudeQuotaHistoryView(dashboard: dashboard)
                    }
                    balanceHero
                    if dashboard.id != "claude" { quotaContent }
                    metricsContent
                    DashboardTopModelsView(dashboard: dashboard)
                    ProviderUsageValueView(dashboard: dashboard)
                    SubscriptionTimingView(dashboard: dashboard)
                    historyContent
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(14)
            }
            Divider().opacity(0.6)
            actionBar
        }
        .frame(width: 390, height: 560)
        .background(Color(nsColor: NSColor.windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            ProviderBadge(providerID: dashboard.id, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(dashboard.title)
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(1)
                    if let plan = dashboard.planLabel {
                        DSChip(text: plan, tint: tint)
                            .help(L("Subscription plan: %@", plan))
                    }
                }
                if let account = dashboard.accountLabel, account != "Default" {
                    Text(account)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(account)
                }
                Text(dashboard.updatedText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 6)
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text(L("Refreshing provider usage")))
            } else if let health = dashboard.serviceStatus?.health, health == .operational {
                DSChip(text: L("All systems normal"), symbol: health.symbolName, tint: DS.healthColor(health))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            LinearGradient(colors: [tint.opacity(0.16), tint.opacity(0.0)],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    @ViewBuilder
    private var statusContent: some View {
        if let status = dashboard.serviceStatus, status.health.isIncident {
            DSCard(padding: 10, tint: DS.healthColor(status.health)) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: status.health.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.healthColor(status.health))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.health.title)
                            .font(.system(size: 12, weight: .semibold))
                        Text(status.displayText)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        if let error = dashboard.errorMessage {
            DSCard(padding: 10, tint: Color(nsColor: .systemRed)) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(Color(nsColor: .systemRed))
                    Text(error)
                        .font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var balanceMetric: DashboardMetric? {
        guard dashboard.quotas.isEmpty else { return nil }
        return dashboard.metrics.first { $0.id == "balance" && !DS.isPlaceholder($0) }
    }

    /// Prepaid providers have no quota window; their balance is the headline.
    @ViewBuilder
    private var balanceHero: some View {
        if let balance = balanceMetric {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(balance.title, systemImage: "creditcard.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text(balance.value)
                        .font(DS.numeral(32, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let subtitle = balance.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: balance.value.contains("¥") || balance.value.contains("￥")
                      ? "yensign.circle.fill" : "dollarsign.circle.fill")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.white, tint)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.06)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(
                RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                    .strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var metricsContent: some View {
        let visible = dashboard.metrics.filter { !DS.isPlaceholder($0) && $0.id != balanceMetric?.id }
        if !dashboard.metrics.isEmpty {
            ProviderDetailSectionTitle(title: dashboard.summarySectionTitle, symbol: "rectangle.grid.2x2")
            if visible.isEmpty {
                Text(dashboard.metrics.compactMap(\.subtitle).first ?? L("No usage data yet"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(visible) { metric in
                        ProviderDetailMetricCell(metric: metric)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var quotaContent: some View {
        if !dashboard.quotas.isEmpty {
            ProviderDetailSectionTitle(title: dashboard.quotaSectionTitle, symbol: "gauge")
            let rings = Array(dashboard.quotas.prefix(3))
            DSCard(padding: 12) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(rings) { lane in
                        VStack(spacing: 6) {
                            UsageRing(remaining: lane.remainingPercent, size: 70, lineWidth: 7)
                            Text(lane.title)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            if let resetsAt = lane.resetsAt, let countdown = DS.countdown(to: resetsAt) {
                                Text(L("Resets in %@", countdown))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if let pace = rings.compactMap({ lane in lane.paceDescription().map { (lane, $0) } }).first {
                Label(pace.1, systemImage: "speedometer")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.tone(remaining: pace.0.remainingPercent))
            }
            if dashboard.quotas.count > rings.count {
                VStack(spacing: 8) {
                    ForEach(dashboard.quotas.dropFirst(rings.count)) { lane in
                        ProviderDetailQuotaRow(lane: lane, color: tint)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        let series = dashboardHistorySeries(for: dashboard)
        if !series.isEmpty {
            ProviderDetailSectionTitle(title: dashboard.historySectionTitle, symbol: "chart.xyaxis.line")
            Text(L(dashboard.id == "claude" || dashboard.id == "codex"
                ? "Local model usage · estimated API cost, not your bill. Partial estimates show known costs; fully unknown costs appear as gaps. Claude excludes other models; logs cannot verify the billing account."
                : "Each chart is labeled and scaled independently."))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 12) {
                ForEach(series) { item in
                    ProviderHistorySeriesView(series: item)
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button(action: refresh) {
                Label(L(isRefreshing ? "Refreshing…" : "Refresh"), systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(isRefreshing)
            Button(action: openDashboard) {
                Label(L("Web dashboard"), systemImage: "arrow.up.right.square")
            }
            .disabled(dashboard.dashboardURL == nil)
            Spacer()
            if dashboard.statusURL != nil {
                Button(action: openStatus) {
                    Image(systemName: "waveform.path.ecg")
                }
                .help(L("Open status page"))
                .accessibilityLabel(Text(L("Status Page")))
            }
            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            .help(L("Open provider settings"))
            .accessibilityLabel(Text(L("Provider Settings")))
        }
        .font(.system(size: 12, weight: .medium))
        .controlSize(.regular)
        .buttonStyle(.bordered)
        .padding(.horizontal, 14)
        .frame(height: 46)
    }
}

struct ProviderDetailSectionTitle: View {
    let title: String
    let symbol: String

    var body: some View {
        DSSectionLabel(title: title, symbol: symbol)
    }
}

struct ProviderDetailQuotaRow: View {
    let lane: DashboardQuotaLane
    let color: Color
    /// Draw its own tile; off when the row already sits inside a card.
    var framed = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(lane.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(String(format: "%.0f%%", lane.remainingPercent))
                    .font(DS.numeral(13, weight: .bold))
                    .foregroundColor(DS.tone(remaining: lane.remainingPercent))
                Text(L("left"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            UsageBar(fill: lane.remainingPercent, remaining: lane.remainingPercent, height: 6)
            let details = [lane.resetsAt.flatMap { DS.countdown(to: $0) }.map { L("Resets in %@", $0) } ?? lane.resetText,
                           lane.paceDescription()].compactMap { $0 }
            if !details.isEmpty {
                Text(details.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(framed ? 11 : 0)
        .background(
            RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous)
                .fill(Color.primary.opacity(framed ? 0.045 : 0)))
        .overlay(
            RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(framed ? 0.08 : 0), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(L("%.0f percent used", lane.usedPercent)))
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
            Label(title, systemImage: "cpu")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Spacer(minLength: 4)
            Text(model ?? L("No model data"))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
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
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(metric.value)
                .font(DS.numeral(19, weight: .bold))
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
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous)
                .fill(Color.primary.opacity(0.045)))
        .overlay(
            RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}
