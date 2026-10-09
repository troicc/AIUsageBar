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
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2.fill").foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("All Providers")).font(.system(size: 16, weight: .semibold))
                    Text(L("%d enabled accounts", entries.count)).font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                if isRefreshing { ProgressView().controlSize(.small) }
            }.padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let error = error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    if entries.isEmpty {
                        Text(L("No enabled providers. Add a provider in Settings."))
                            .foregroundColor(.secondary).padding()
                    }
                    ForEach(entries) { entry in
                        AllProviderCard(dashboard: entry.dashboard)
                    }
                }.padding(16)
            }
            Divider()
            HStack {
                Button(action: refresh) { Label(L("Refresh"), systemImage: "arrow.clockwise") }
                    .disabled(isRefreshing)
                Spacer()
                Button(action: openSettings) { Label(L("Settings"), systemImage: "gearshape") }
            }
            .buttonStyle(BorderlessButtonStyle())
            .font(.system(size: 12)).padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct AllProviderCard: View {
    let dashboard: ProviderDashboard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = dashboard.errorMessage {
                Text(error).font(.system(size: 11)).foregroundColor(.orange)
            }
            if dashboard.id == "claude" {
                claudeQuotaContent
                ProviderDetailSectionTitle(title: dashboard.summarySectionTitle, symbol: "rectangle.grid.2x2")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(dashboard.metrics) { metric in
                    AllProviderMetricView(metric: metric)
                }
            }
            if dashboard.id != "claude" {
                ForEach(dashboard.quotas) { lane in
                    ProviderDetailQuotaRow(lane: lane, color: ProviderBrand.color(for: dashboard.id))
                }
            }
            DashboardTopModelsView(dashboard: dashboard)
                .foregroundColor(.secondary)
            SubscriptionTimingView(dashboard: dashboard)
            ProviderUsageValueView(dashboard: dashboard)
            if !dashboard.history.isEmpty {
                DisclosureGroup(dashboard.historySectionTitle) {
                    VStack(spacing: 10) {
                        ForEach(dashboardHistorySeries(for: dashboard)) { item in
                            ProviderHistorySeriesView(series: item)
                        }
                    }.padding(.top, 8)
                }.font(.system(size: 11, weight: .medium))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
    private var claudeQuotaContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProviderDetailSectionTitle(title: dashboard.quotaSectionTitle, symbol: "gauge")
            ForEach(dashboard.quotas) { lane in
                ProviderDetailQuotaRow(lane: lane, color: ProviderBrand.color(for: dashboard.id))
            }
            ClaudeQuotaCoverageView(dashboard: dashboard)
            ClaudeQuotaHistoryView(dashboard: dashboard)
        }
    }

    private var header: some View {
            HStack(spacing: 10) {
                Image(systemName: ProviderBrand.symbol(for: dashboard.id))
                    .font(.system(size: 20)).foregroundColor(ProviderBrand.color(for: dashboard.id))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(ProviderBrand.color(for: dashboard.id).opacity(0.12)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(dashboard.title).font(.system(size: 15, weight: .semibold))
                    Text([dashboard.accountLabel, dashboard.updatedText].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                    if let plan = dashboard.planLabel {
                        Text(L("Plan · %@", plan)).font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if let status = dashboard.serviceStatus, status.health != .unknown {
                    Image(systemName: status.health.symbolName).foregroundColor(serviceHealthColor(status.health))
                        .help(status.displayText)
                }
                if let url = dashboard.dashboardURL {
                    Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                        .help(L("Open web dashboard"))
                }
            }
    }

}

struct AllProviderMetricView: View {
    let metric: DashboardMetric
    var body: some View {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(metric.title).font(.system(size: 10)).foregroundColor(.secondary)
                        Text(metric.value).font(.system(size: 20, weight: .semibold, design: .rounded))
                            .lineLimit(1).minimumScaleFactor(0.7)
                        if let subtitle = metric.subtitle {
                            Text(subtitle).font(.system(size: 9)).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .help(subtitle)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
