@preconcurrency import AppKit
import SwiftUI


struct AllProvidersDashboardView: View {
    @ObservedObject var store: DashboardStore

    var body: some View {
        AllProvidersContentView(entries: store.snapshots.map { AllProviderEntry(id: $0.id, dashboard: store.dashboard(for: $0)) },
            isRefreshing: store.isRefreshing, error: store.lastError,
            refresh: { Task { await store.refresh() } }, openSettings: { store.onOpenSettings?() })
    }
}

struct AllProviderEntry: Identifiable {
    let id: String
    let dashboard: ProviderDashboard
}

/// Shared production content used by the anchored popover and visual QA.
struct AllProvidersContentView: View {
    let entries: [AllProviderEntry]
    let isRefreshing: Bool
    let error: String?
    let refresh: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let error = error {
                        DSCard(padding: 10, tint: Color(nsColor: .systemOrange)) {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                        }
                    }
                    if entries.isEmpty {
                        Text(L("No enabled providers. Add a provider in Settings."))
                            .foregroundColor(.secondary).padding()
                    } else if entries.count > 1 {
                        summaryStrip
                    }
                    ForEach(entries) { entry in
                        AllProviderCard(dashboard: entry.dashboard)
                    }
                }.padding(16)
            }
            Divider().opacity(0.6)
            HStack {
                Button(action: refresh) { Label(L("Refresh"), systemImage: "arrow.clockwise") }
                    .disabled(isRefreshing)
                Spacer()
                Button(action: openSettings) { Label(L("Settings"), systemImage: "gearshape") }
            }
            .buttonStyle(.bordered)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 16)
            .frame(height: 48)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            ProviderBadge(providerID: nil, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("All Providers")).font(.system(size: 18, weight: .bold))
                Text(L("%d enabled accounts", entries.count))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            if isRefreshing { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(LinearGradient(colors: [Color.accentColor.opacity(0.14), Color.accentColor.opacity(0)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    /// One ring per provider for its tightest window: the at-a-glance row.
    private var summaryStrip: some View {
        DSCard(padding: 12) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(entries.prefix(6)) { entry in
                    let lane = entry.dashboard.quotas.min { $0.remainingPercent < $1.remainingPercent }
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottomTrailing) {
                            UsageRing(remaining: lane?.remainingPercent, size: 54, lineWidth: 5.5)
                            ProviderBadge(providerID: entry.dashboard.id, size: 18)
                                .offset(x: 4, y: 4)
                        }
                        Text(entry.dashboard.title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Text(lane?.title ?? L("No quota"))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct AllProviderCard: View {
    let dashboard: ProviderDashboard

    private var tint: Color { ProviderBrand.color(for: dashboard.id) }
    private var visibleMetrics: [DashboardMetric] { dashboard.metrics.filter { !DS.isPlaceholder($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = dashboard.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: .systemRed))
            }
            if let status = dashboard.serviceStatus, status.health.isIncident {
                Label(status.displayText, systemImage: status.health.symbolName)
                    .font(.system(size: 11))
                    .foregroundColor(DS.healthColor(status.health))
            }
            if dashboard.id == "claude" {
                claudeQuotaContent
                ProviderDetailSectionTitle(title: dashboard.summarySectionTitle, symbol: "rectangle.grid.2x2")
            }
            if !visibleMetrics.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), spacing: 8, alignment: .leading)],
                          alignment: .leading, spacing: 8) {
                    ForEach(visibleMetrics) { metric in
                        AllProviderMetricView(metric: metric)
                    }
                }
            }
            if dashboard.id != "claude" {
                ForEach(dashboard.quotas) { lane in
                    ProviderDetailQuotaRow(lane: lane, color: tint, framed: false)
                }
            }
            DashboardTopModelsView(dashboard: dashboard)
            SubscriptionTimingView(dashboard: dashboard)
            ProviderUsageValueView(dashboard: dashboard)
            if !dashboard.history.isEmpty {
                DisclosureGroup(dashboard.historySectionTitle) {
                    VStack(spacing: 10) {
                        ForEach(dashboardHistorySeries(for: dashboard)) { item in
                            ProviderHistorySeriesView(series: item)
                        }
                    }.padding(.top, 8)
                }.font(.system(size: 12, weight: .medium))
            }
        }
        .padding(16)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.10), tint.opacity(0)],
                                         startPoint: .topLeading, endPoint: .center))
            })
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private var claudeQuotaContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProviderDetailSectionTitle(title: dashboard.quotaSectionTitle, symbol: "gauge")
            ForEach(dashboard.quotas) { lane in
                ProviderDetailQuotaRow(lane: lane, color: tint, framed: false)
            }
            ClaudeQuotaCoverageView(dashboard: dashboard)
            ClaudeQuotaHistoryView(dashboard: dashboard)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ProviderBadge(providerID: dashboard.id, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(dashboard.title).font(.system(size: 16, weight: .bold))
                    if let plan = dashboard.planLabel {
                        DSChip(text: plan, tint: tint)
                    }
                    if let status = dashboard.serviceStatus, status.health != .unknown {
                        DSHealthDot(health: status.health)
                            .help(status.displayText)
                    }
                }
                Text([dashboard.accountLabel.flatMap { $0 == "Default" ? nil : $0 }, dashboard.updatedText]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            if let lane = dashboard.quotas.min(by: { $0.remainingPercent < $1.remainingPercent }) {
                UsageRing(remaining: lane.remainingPercent, size: 50, lineWidth: 5)
                    .help(lane.title)
            }
            if let url = dashboard.dashboardURL {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 14))
                }
                .help(L("Open web dashboard"))
            }
        }
    }
}

struct AllProviderMetricView: View {
    let metric: DashboardMetric

    var body: some View {
        ProviderDetailMetricCell(metric: metric)
    }
}
