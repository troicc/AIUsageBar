@preconcurrency import AppKit
import SwiftUI

enum NativeMenuLayout {
    /// Width of every hosted row; NSMenu sizes itself to its widest item.
    static let width: CGFloat = 340
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

struct NativeMenuHeaderView: View {
    let title: String
    let subtitle: String
    let providerID: String?
    let health: ProviderServiceHealth?
    let refreshing: Bool
    var planLabel: String? = nil

    var body: some View {
        HStack(spacing: 11) {
            ProviderBadge(providerID: providerID, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if let plan = planLabel, !plan.isEmpty {
                        DSChip(text: plan, tint: providerID.map(ProviderBrand.color(for:)) ?? .accentColor)
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
                    .scaleEffect(0.75)
                    .accessibilityLabel(Text(L("Refreshing providers")))
            } else if let health = health, health != .unknown {
                DSChip(
                    text: health == .operational ? L("All systems normal") : health.title,
                    symbol: health.symbolName,
                    tint: DS.healthColor(health))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(width: NativeMenuLayout.width)
    }
}

struct NativeMenuOverviewView: View {
    let rows: [NativeMenuOverviewRow]
    let totalCount: Int
    let quotaPresentation: MenuQuotaPresentation
    let showAccount: Bool
    let showStatus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider().padding(.leading, 52).opacity(0.6)
                        }
                        rowView(row)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.045)))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            }

            if totalCount > rows.count {
                Text(L("%d more in Providers", totalCount - rows.count))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .frame(width: NativeMenuLayout.width)
    }

    private var emptyState: some View {
        DSCard(padding: 16) {
            VStack(spacing: 6) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundColor(.accentColor)
                Text(L("No providers enabled yet"))
                    .font(.system(size: 13, weight: .semibold))
                Text(L("Choose Set Up Providers… below to connect Claude, Codex, DeepSeek or another service."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func rowView(_ row: NativeMenuOverviewRow) -> some View {
        HStack(spacing: 11) {
            ProviderBadge(providerID: row.providerID, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(row.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if showStatus, row.hasError || row.health.isIncident {
                        DSHealthDot(health: row.hasError ? .outage : row.health, size: 6)
                    }
                }
                // "Default" is the placeholder label of an unnamed token account.
                if showAccount, let account = row.account, account != "Default" {
                    Text(account)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 4) {
                    if row.hasError {
                        DSChip(text: L("Connection error"), symbol: "exclamationmark.triangle.fill",
                               tint: Color(nsColor: .systemRed))
                    } else {
                        if let label = row.quotaLabel {
                            DSChip(text: label)
                        }
                        if let resetsAt = row.resetsAt, let countdown = DS.countdown(to: resetsAt) {
                            DSChip(text: L("Resets in %@", countdown), symbol: "arrow.clockwise")
                        }
                    }
                }
            }
            Spacer(minLength: 6)
            trailing(row)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func trailing(_ row: NativeMenuOverviewRow) -> some View {
        if row.usedPercent != nil {
            UsageRing(remaining: row.remainingPercent, size: 42, lineWidth: 4.5,
                      showsUsed: quotaPresentation == .used)
        } else if let balance = row.balanceText {
            VStack(alignment: .trailing, spacing: 1) {
                Text(balance)
                    .font(DS.numeral(15, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(L("Balance"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        } else {
            UsageRing(remaining: nil, size: 42, lineWidth: 4.5)
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
        VStack(alignment: .leading, spacing: 10) {
            if showStatus, let status = dashboard.serviceStatus, status.health.isIncident {
                banner(symbol: status.health.symbolName, tint: DS.healthColor(status.health),
                       title: status.health.title, detail: status.displayText)
            }
            if let error = dashboard.errorMessage {
                banner(symbol: "exclamationmark.triangle.fill", tint: Color(nsColor: .systemRed),
                       title: L("Connection error"), detail: error)
            }

            if let primary = quotas.first {
                heroQuota(primary)
            }
            if quotas.count > 1 {
                DSCard(padding: 10) {
                    VStack(spacing: 9) {
                        ForEach(quotas.dropFirst()) { lane in
                            compactQuota(lane)
                        }
                    }
                }
            }

            if showMetrics, !visibleMetrics.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                          alignment: .leading, spacing: 8) {
                    ForEach(visibleMetrics) { metric in
                        metricTile(metric)
                    }
                }
            }

            footer
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(width: NativeMenuLayout.width)
    }

    private func heroQuota(_ lane: DashboardQuotaLane) -> some View {
        DSCard(padding: 12) {
            HStack(spacing: 14) {
                UsageRing(remaining: lane.remainingPercent, size: 64, lineWidth: 6.5,
                          showsUsed: quotaPresentation == .used)
                VStack(alignment: .leading, spacing: 4) {
                    Text(lane.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(quotaPresentation == .used
                         ? L("%@%% used", String(format: "%.0f", lane.usedPercent))
                         : L("%@%% remaining", String(format: "%.0f", lane.remainingPercent)))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    if showResetTime {
                        HStack(spacing: 4) {
                            if let resetsAt = lane.resetsAt, let countdown = DS.countdown(to: resetsAt) {
                                DSChip(text: L("Resets in %@", countdown), symbol: "arrow.clockwise")
                            } else if let reset = lane.resetText {
                                DSChip(text: reset, symbol: "arrow.clockwise")
                            }
                        }
                        if let pace = lane.paceDescription() {
                            Text(pace)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(DS.tone(remaining: lane.remainingPercent))
                                .lineLimit(2)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func compactQuota(_ lane: DashboardQuotaLane) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(lane.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if showResetTime, let resetsAt = lane.resetsAt, let countdown = DS.countdown(to: resetsAt) {
                    Text(L("Resets in %@", countdown))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Text(String(format: "%.0f%%", quotaPresentation == .used ? lane.usedPercent : lane.remainingPercent))
                    .font(DS.numeral(12, weight: .bold))
                    .foregroundColor(DS.tone(remaining: lane.remainingPercent))
            }
            UsageBar(fill: quotaPresentation == .used ? lane.usedPercent : lane.remainingPercent,
                     remaining: lane.remainingPercent, height: 5)
        }
        .accessibilityElement(children: .combine)
    }

    private func metricTile(_ metric: DashboardMetric) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metric.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(metric.value)
                .font(DS.numeral(16, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous)
                .fill(Color.primary.opacity(0.045)))
        .overlay(
            RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var footer: some View {
        let hasMore = dashboard.metrics.count > 4 || dashboard.quotas.count > 4
        let subscription = SubscriptionTimingView(dashboard: dashboard, compact: true)
        VStack(alignment: .leading, spacing: 5) {
            subscription
            if snapshot.provider == "claude" {
                Label(dashboard.hasClaudeSharedQuota
                      ? L("Quota · all devices including web chat")
                      : L("Shared quota unavailable"),
                      systemImage: "laptopcomputer.and.iphone")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                if showMetrics {
                    Label(L("Tokens & cost · local logs only"), systemImage: "internaldrive")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            if hasMore {
                Text(L("More information is available in Detailed Dashboard"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func banner(symbol: String, tint: Color, title: String, detail: String) -> some View {
        DSCard(padding: 10, tint: tint) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }
            }
        }
    }
}
