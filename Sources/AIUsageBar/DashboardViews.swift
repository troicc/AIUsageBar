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

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    statusContent
                    if dashboard.id == "claude" {
                        quotaContent
                        ClaudeQuotaCoverageView(dashboard: dashboard)
                        ClaudeQuotaHistoryView(dashboard: dashboard)
                    }
                    SubscriptionTimingView(dashboard: dashboard)
                    metricsContent
                    DashboardTopModelsView(dashboard: dashboard)
                        .foregroundColor(.secondary)
                    if dashboard.id != "claude" { quotaContent }
                    ProviderUsageValueView(dashboard: dashboard)
                    historyContent
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(14)
            }
            Divider()
            actionBar
        }
        .frame(width: 390, height: 560)
        .background(Color(nsColor: NSColor.windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(ProviderBrand.color(for: dashboard.id).opacity(0.14))
                Image(systemName: ProviderBrand.symbol(for: dashboard.id))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(ProviderBrand.color(for: dashboard.id))
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(dashboard.title)
                    .font(.system(size: 15, weight: .semibold))
                if let account = dashboard.accountLabel {
                    Text(account)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .help(account)
                }
                if let plan = dashboard.planLabel {
                    Text(L("Plan · %@", plan))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .help(L("Subscription plan: %@", plan))
                }
                Text(dashboard.updatedText)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text(L("Refreshing provider usage")))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var statusContent: some View {
        if let status = dashboard.serviceStatus, status.health != .unknown {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: status.health.symbolName)
                    .foregroundColor(serviceHealthColor(status.health))
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.health.title)
                        .font(.system(size: 11, weight: .semibold))
                    if status.health.isIncident {
                        Text(status.displayText)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 8).fill(serviceHealthColor(status.health).opacity(0.10)))
        }
        if let error = dashboard.errorMessage {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(error)
                    .font(.system(size: 10, weight: .medium))
                Spacer()
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
        }
    }

    @ViewBuilder
    private var metricsContent: some View {
        if !dashboard.metrics.isEmpty {
            ProviderDetailSectionTitle(title: dashboard.summarySectionTitle, symbol: "rectangle.grid.2x2")
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(dashboard.metrics) { metric in
                    ProviderDetailMetricCell(metric: metric)
                }
            }
        }
    }

    @ViewBuilder
    private var quotaContent: some View {
        if !dashboard.quotas.isEmpty {
            ProviderDetailSectionTitle(title: dashboard.quotaSectionTitle, symbol: "gauge")
            VStack(spacing: 10) {
                ForEach(dashboard.quotas) { lane in
                    ProviderDetailQuotaRow(
                        lane: lane,
                        color: ProviderBrand.color(for: dashboard.id))
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
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            VStack(spacing: 14) {
                ForEach(series) { item in
                    ProviderHistorySeriesView(series: item)
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
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
        .font(.system(size: 11, weight: .medium))
        .buttonStyle(BorderlessButtonStyle())
        .padding(.horizontal, 14)
        .frame(height: 42)
    }
}

struct ProviderDetailSectionTitle: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
    }
}

struct ProviderDetailQuotaRow: View {
    let lane: DashboardQuotaLane
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(lane.title)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(L("%.0f%% used · %.0f%% left", lane.usedPercent, lane.remainingPercent))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(lane.usedPercent / 100))
                }
            }
            .frame(height: 6)
            let details = [lane.resetText, lane.paceDescription()].compactMap { $0 }
            if !details.isEmpty {
                Text(details.joined(separator: " · "))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(nsColor: NSColor.controlBackgroundColor)))
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
            Text(title).font(.system(size: 10, weight: .medium))
            Spacer(minLength: 4)
            Text(model ?? L("No model data"))
                .font(.system(size: 11, weight: .semibold))
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
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(metric.value)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                        if let subtitle = metric.subtitle {
                            Text(subtitle)
                                .help(subtitle)
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color(nsColor: NSColor.controlBackgroundColor)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}
