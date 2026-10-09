@preconcurrency import AppKit
import SwiftUI

enum NativeMenuLayout {
    /// Width of every hosted row; NSMenu sizes itself to its widest item.
    static let width: CGFloat = 340
    static let inset: CGFloat = 16
}

struct NativeMenuOverviewRow: Identifiable, Hashable {
    let id: String
    let providerID: String
    let title: String
    let account: String?
    let usedPercent: Double?
    let quotaLabel: String?
    let health: ProviderServiceHealth
    let hasError: Bool
    var resetsAt: Date? = nil
    /// Shown instead of a gauge for prepaid providers without a quota window.
    var balanceText: String? = nil

    var remainingPercent: Double? { usedPercent.map { max(0, min(100, 100 - $0)) } }
}

/// Hairline divider inset like native menu separators.
private struct MenuHairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
            .padding(.horizontal, NativeMenuLayout.inset)
    }
}

struct NativeMenuHeaderView: View {
    let title: String
    let subtitle: String
    let providerID: String?
    let health: ProviderServiceHealth?
    let refreshing: Bool
    var planLabel: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let providerID = providerID {
                ProviderBadge(providerID: providerID, size: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.system(size: providerID == nil ? 13 : 14, weight: .semibold))
                        .lineLimit(1)
                    if let plan = planLabel, !plan.isEmpty {
                        Text(plan.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.6)
                            .foregroundColor(providerID.map(ProviderBrand.color(for:)) ?? .accentColor)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if refreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .accessibilityLabel(Text(L("Refreshing providers")))
            } else if let health = health, health.isIncident {
                HStack(spacing: 4) {
                    Circle().fill(DS.healthColor(health)).frame(width: 6, height: 6)
                    Text(health.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.healthColor(health))
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, NativeMenuLayout.inset)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(width: NativeMenuLayout.width)
    }
}

struct NativeMenuOverviewView: View {
    let rows: [NativeMenuOverviewRow]
    let totalCount: Int
    let quotaPresentation: MenuQuotaPresentation
    let showAccount: Bool
    let showStatus: Bool
    /// Rows whose quota just reset; their gauges play the fill-and-glow.
    var celebrating: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                emptyState
            } else {
                // Batteries-widget layout: one gauge per provider, side by side.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4, alignment: .top),
                                         count: min(4, max(rows.count, 3))),
                          alignment: .center, spacing: 14) {
                    ForEach(rows) { row in
                        gaugeTile(row)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }

            if totalCount > rows.count {
                Text(L("%d more in Providers", totalCount - rows.count))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, NativeMenuLayout.inset)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: NativeMenuLayout.width)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundColor(.secondary)
            Text(L("No providers enabled yet"))
                .font(.system(size: 13, weight: .medium))
            Text(L("Choose Set Up Providers… below to connect Claude, Codex, DeepSeek or another service."))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, NativeMenuLayout.inset)
        .padding(.vertical, 16)
    }

    private func gaugeTile(_ row: NativeMenuOverviewRow) -> some View {
        VStack(spacing: 6) {
            ZStack {
                let remaining = row.hasError ? nil : row.remainingPercent
                let shown = remaining.map { quotaPresentation == .used ? 100 - $0 : $0 } ?? 0
                AnimatedQuotaRing(percent: shown, color: DS.toneNSColor(remaining: remaining),
                                  lineWidth: 5, diameter: 50,
                                  celebrate: remaining != nil && celebrating.contains(row.id))
                    .frame(width: 50 + QuotaRingLayerView.glowMargin * 2,
                           height: 50 + QuotaRingLayerView.glowMargin * 2)
                    .padding(-QuotaRingLayerView.glowMargin)
                    // A new identity recreates the ring, which replays the
                    // animation when a reset arrives with the menu open.
                    .id("\(row.id)-\(celebrating.contains(row.id))")
                if row.hasError {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(Color(nsColor: .systemRed))
                } else {
                    ProviderLogoView(providerID: row.providerID, size: 20,
                                     tint: ProviderBrand.logoTint(for: row.providerID))
                }
            }
            .frame(width: 50, height: 50)

            value(row)
                .frame(height: 20)

            VStack(spacing: 1) {
                HStack(spacing: 3) {
                    Text(row.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if showStatus, row.health.isIncident {
                        Circle().fill(DS.healthColor(row.health)).frame(width: 5, height: 5)
                    }
                }
                Text(caption(row))
                    .font(.system(size: 10))
                    .foregroundColor(row.hasError ? Color(nsColor: .systemRed) : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func caption(_ row: NativeMenuOverviewRow) -> String {
        if row.hasError { return L("Connection error") }
        if row.remainingPercent == nil { return row.balanceText != nil ? L("Balance") : "—" }
        if let resetsAt = row.resetsAt, let countdown = DS.countdown(to: resetsAt) {
            return L("Resets in %@", countdown)
        }
        return row.quotaLabel ?? ""
    }

    @ViewBuilder
    private func value(_ row: NativeMenuOverviewRow) -> some View {
        if let remaining = row.remainingPercent, !row.hasError {
            let shown = quotaPresentation == .used ? 100 - remaining : remaining
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(String(format: "%.0f", shown))
                    .font(.system(size: 19, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundColor(remaining < 15 ? Color(nsColor: .systemRed) : .primary)
                Text("%")
                    .font(.system(size: 11, weight: .light, design: .rounded))
                    .foregroundColor(.secondary)
            }
        } else if let balance = row.balanceText {
            Text(balance)
                .font(.system(size: 15, weight: .light, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        } else {
            Text("—")
                .font(.system(size: 17, weight: .light, design: .rounded))
                .foregroundColor(.secondary)
        }
    }
}

struct NativeMenuProviderCardView: View {
    let snapshot: ProviderSnapshot
    let dashboard: ProviderDashboard
    let showAccount: Bool
    let showMetrics: Bool
    let showResetTime: Bool
    let showStatus: Bool
    let quotaPresentation: MenuQuotaPresentation

    private var tint: Color { ProviderBrand.color(for: snapshot.provider) }
    private var visibleMetrics: [DashboardMetric] {
        Array(dashboard.metrics.filter { !DS.isPlaceholder($0) }.prefix(4))
    }
    private var quotas: [DashboardQuotaLane] { Array(dashboard.quotas.prefix(4)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showStatus, let status = dashboard.serviceStatus, status.health.isIncident {
                notice(symbol: status.health.symbolName, tint: DS.healthColor(status.health),
                       text: "\(status.health.title) · \(status.displayText)")
            }
            if let error = dashboard.errorMessage {
                notice(symbol: "exclamationmark.triangle.fill", tint: Color(nsColor: .systemRed), text: error)
            }

            if let primary = quotas.first {
                heroQuota(primary)
                    .padding(.horizontal, NativeMenuLayout.inset)
                    .padding(.vertical, 12)
            }
            if quotas.count > 1 {
                VStack(spacing: 10) {
                    ForEach(quotas.dropFirst()) { lane in
                        compactQuota(lane)
                    }
                }
                .padding(.horizontal, NativeMenuLayout.inset)
                .padding(.bottom, 12)
            }

            if showMetrics, !visibleMetrics.isEmpty {
                MenuHairline()
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                          alignment: .leading, spacing: 12) {
                    ForEach(visibleMetrics) { metric in
                        metricCell(metric)
                    }
                }
                .padding(.horizontal, NativeMenuLayout.inset)
                .padding(.vertical, 12)
            }

            footer
        }
        .frame(width: NativeMenuLayout.width)
    }

    private func heroQuota(_ lane: DashboardQuotaLane) -> some View {
        HStack(spacing: 16) {
            UsageRing(remaining: lane.remainingPercent, size: 78, lineWidth: 7,
                      showsUsed: quotaPresentation == .used, tint: tint, numeralWeight: .light)
            VStack(alignment: .leading, spacing: 4) {
                Text(lane.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(quotaPresentation == .used
                     ? L("%@%% used", String(format: "%.0f", lane.usedPercent))
                     : L("%@%% remaining", String(format: "%.0f", lane.remainingPercent)))
                    .font(.system(size: 11))
                    .foregroundColor(lane.remainingPercent < 15 ? Color(nsColor: .systemRed) : .secondary)
                if showResetTime {
                    if let resetsAt = lane.resetsAt, let countdown = DS.countdown(to: resetsAt) {
                        Label(L("Resets in %@", countdown), systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else if let reset = lane.resetText {
                        Label(reset, systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    if let pace = lane.paceDescription() {
                        Label(pace, systemImage: "speedometer")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.tone(remaining: lane.remainingPercent))
                            .lineLimit(2)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func compactQuota(_ lane: DashboardQuotaLane) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(lane.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if showResetTime, let resetsAt = lane.resetsAt, let countdown = DS.countdown(to: resetsAt) {
                    Text(countdown)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 4)
                Text(String(format: "%.0f%%", quotaPresentation == .used ? lane.usedPercent : lane.remainingPercent))
                    .font(.system(size: 13, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundColor(lane.remainingPercent < 15 ? Color(nsColor: .systemRed) : .primary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.14))
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(3, geometry.size.width * CGFloat(
                            (quotaPresentation == .used ? lane.usedPercent : lane.remainingPercent) / 100)))
                }
            }
            .frame(height: 3)
        }
        .accessibilityElement(children: .combine)
    }

    private func metricCell(_ metric: DashboardMetric) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metric.title)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(metric.value)
                .font(.system(size: 18, weight: .light, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var footer: some View {
        let hasMore = dashboard.metrics.count > 4 || dashboard.quotas.count > 4
        MenuHairline()
        if let breakdown = dashboard.claudeProductBreakdown {
            ClaudeProductBreakdownView(breakdown: breakdown, compact: true)
                .padding(.horizontal, NativeMenuLayout.inset)
                .padding(.vertical, 10)
            MenuHairline()
        }
        VStack(alignment: .leading, spacing: 5) {
            if let credit = dashboard.claudeIncludedCredit {
                ClaudeIncludedCreditView(credit: credit, compact: true)
            }
            SubscriptionTimingView(dashboard: dashboard, compact: true)
            if snapshot.provider == "claude" {
                Label(dashboard.hasClaudeSharedQuota
                      ? L("Quota · all devices including web chat")
                      : L("Shared quota unavailable"),
                      systemImage: "laptopcomputer.and.iphone")
                if showMetrics {
                    Label(L("Tokens & cost · local logs only"), systemImage: "internaldrive")
                }
            }
            if hasMore {
                Text(L("More information is available in Detailed Dashboard"))
            }
        }
        .font(.system(size: 10))
        .foregroundColor(.secondary)
        .padding(.horizontal, NativeMenuLayout.inset)
        .padding(.vertical, 10)
    }

    private func notice(symbol: String, tint: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
        }
        .foregroundColor(tint)
        .padding(.horizontal, NativeMenuLayout.inset)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }
}
