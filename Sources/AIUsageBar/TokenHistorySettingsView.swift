@preconcurrency import AppKit
import SwiftUI


struct TokenHistorySettingsView: View {
    @ObservedObject var dashboardStore: DashboardStore
    @State private var selectedAccountID = ""
    @State private var range: TokenHistoryRange = .thirtyDays
    @State private var exportStatus: String?

    init(dashboardStore: DashboardStore, selectedAccountID: String = "") {
        self.dashboardStore = dashboardStore
        _selectedAccountID = State(initialValue: selectedAccountID)
    }

    private var accountID: String? {
        selectedAccountID.isEmpty ? nil : selectedAccountID
    }

    private var report: TokenHistoryReport {
        // Reading the revision makes this derived report refresh immediately
        // when a provider poll adds or corrects dated token buckets.
        _ = dashboardStore.tokenHistoryRevision
        return dashboardStore.tokenHistoryReport(accountID: accountID, range: range)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsPageTitle(
                    title: L("Usage Data"),
                    subtitle: L("Long-term token history, every available token component, and portable exports"))

                HStack(spacing: 14) {
                    Picker(L("Account"), selection: $selectedAccountID) {
                        Text(L("All providers & accounts")).tag("")
                        ForEach(dashboardStore.tokenHistoryAccounts) { account in
                            Text(account.displayName).tag(account.id)
                        }
                    }
                    .frame(maxWidth: 360)

                    Picker(L("Range"), selection: $range) {
                        ForEach(TokenHistoryRange.allCases) { range in
                            Text(L(range.title)).tag(range)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(maxWidth: 360)
                }

                Text(L("Claude and Codex show local model usage, not official quota consumption or invoices. Claude web chat tokens and costs are not included; web activity is reflected in the shared subscription quota. Other Claude Code models are kept separately and excluded from the combined total to avoid overlap with provider API data. Mixed days without model token counts remain unattributed. Token components appear only when complete."))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if report.recordCount == 0 {
                    TokenHistoryEmptyState()
                } else {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                        spacing: 10)
                    {
                        TokenHistoryStatCard(
                            title: L("%@ tokens", L(range.title)),
                            value: tokenHistoryCompactNumber(report.totalTokens),
                            detail: L("%d dated buckets", report.recordCount))
                        TokenHistoryStatCard(
                            title: L("Today"),
                            value: tokenHistoryCompactNumber(report.todayTokens),
                            detail: L("Local calendar day"))
                        TokenHistoryStatCard(
                            title: L("30 days"),
                            value: tokenHistoryCompactNumber(report.last30DaysTokens),
                            detail: tokenHistoryCoverageDetail(report))
                        TokenHistoryStatCard(
                            title: L("All time"),
                            value: tokenHistoryCompactNumber(report.allTimeTokens),
                            detail: L("Never auto-pruned"))
                    }

                    HStack(alignment: .top, spacing: 12) {
                        if !report.modelTotals.isEmpty {
                            TokenHistoryBreakdownBox(
                                title: L("Models"),
                                rows: report.modelTotals)
                        }
                        if report.providerTotals.count > 1 {
                            TokenHistoryBreakdownBox(
                                title: L("Providers"),
                                rows: report.providerTotals)
                        }
                    }

                    GroupBox(label: Text(L("Token volume · %@", L(range.title))).font(.headline)) {
                        TokenHistoryBarChart(points: report.chart)
                            .padding(12)
                    }

                    if report.components.hasData {
                        GroupBox(label: Text(L("Token components · %@", L(range.title))).font(.headline)) {
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                                spacing: 10)
                            {
                                TokenHistoryComponentCell(title: L("Input"), value: report.components.input)
                                TokenHistoryComponentCell(title: L("Output"), value: report.components.output)
                                TokenHistoryComponentCell(title: L("Cache read"), value: report.components.cacheRead)
                                TokenHistoryComponentCell(title: L("Cache creation"), value: report.components.cacheCreation)
                            }
                            .padding(12)
                        }
                    }


                }

                GroupBox(label: Text(L("Retention & export")).font(.headline)) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("Dated token buckets are merged by provider, account, time, and model in Application Support. Existing buckets are updated in place and are never automatically deleted. Quota percentages are stored separately and are not counted as tokens."))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(dashboardStore.tokenHistoryStorageURL.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)

                        HStack(spacing: 10) {
                            Button(L("Export visible CSV…"), action: exportVisibleCSV)
                            Button(L("Export full JSON…"), action: exportFullJSON)
                            Button(L("Show data file"), action: revealDataFile)
                            Spacer()
                        }

                        if let persistenceError = dashboardStore.tokenHistoryPersistenceError {
                            Label(persistenceError, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let exportStatus = exportStatus {
                            Text(exportStatus)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(12)
                }
            }
            .padding(28)
        }
    }

    private func exportVisibleCSV() {
        let csv = dashboardStore.tokenHistoryCSV(accountID: accountID, range: range)
        save(
            data: Data(csv.utf8),
            suggestedName: "aiusagebar-token-history-\(range.rawValue).csv")
    }

    private func exportFullJSON() {
        do {
            let data = try dashboardStore.tokenHistoryJSON(accountID: nil, range: nil)
            save(
                data: data,
                suggestedName: "aiusagebar-token-history-full.json")
        } catch {
            exportStatus = L("Export failed: %@", error.localizedDescription)
        }
    }

    private func save(data: Data, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try data.write(to: destination, options: .atomic)
            exportStatus = L("Exported %@", destination.lastPathComponent)
        } catch {
            exportStatus = L("Export failed: %@", error.localizedDescription)
        }
    }

    private func revealDataFile() {
        let fileURL = dashboardStore.tokenHistoryStorageURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            NSWorkspace.shared.open(fileURL.deletingLastPathComponent())
        }
    }
}

struct TokenHistoryEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text(L("No dated token history in this range"))
                .font(.system(size: 15, weight: .semibold))
            Text(L("Refresh a provider that exposes dated token usage. Codex and Claude import their current daily history; z.ai imports its rolling hourly model data and keeps it permanently from then on."))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
    }
}

struct TokenHistoryStatCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(detail)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72)))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

struct TokenHistoryComponentCell: View {
    let title: String
    let value: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(value.map(tokenHistoryCompactNumber) ?? "—")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TokenHistoryBreakdownBox: View {
    let title: String
    let rows: [TokenHistoryNamedTotal]

    var body: some View {
        GroupBox(label: Text(title).font(.headline)) {
            VStack(spacing: 8) {
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        Text(row.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer()
                        Text(tokenHistoryCompactNumber(row.tokens))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .help(L("%.0f tokens", row.tokens))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity)
    }
}

struct TokenHistoryBarChart: View {
    let points: [TokenHistoryChartPoint]

    private var maximum: Double {
        max(1, points.map(\.tokens).max() ?? 1)
    }

    var body: some View {
        VStack(spacing: 7) {
            GeometryReader { geometry in
                ZStack(alignment: .bottomLeading) {
                    VStack(spacing: 0) {
                        ForEach(0..<4) { index in
                            if index > 0 { Spacer() }
                            Divider().opacity(0.45)
                        }
                    }
                    HStack(alignment: .bottom, spacing: points.count > 60 ? 1 : 3) {
                        ForEach(points) { point in
                            TokenHistoryBar(point: point, maximum: maximum,
                                height: geometry.size.height, dense: points.count > 60)
                        }
                    }
                }
            }
            .frame(height: 176)

            HStack {
                Text(points.first?.label ?? "")
                Spacer()
                if points.count > 2 { Text(points[points.count / 2].label) }
                Spacer()
                Text(points.last?.label ?? "")
            }
            .font(.system(size: 9))
            .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("Token usage chart")))
        .accessibilityValue(Text(accessibilitySummary))
    }

    private var accessibilitySummary: String {
        guard let first = points.first, let last = points.last else { return L("No data") }
        let total = points.reduce(0) { $0 + $1.tokens }
        var parts = [L("%d bars from %@ to %@", points.count, first.label, last.label),
                     L("total %d tokens", Int(total)),
                     L("latest %@ %d tokens", last.label, Int(last.tokens))]
        if let peak = points.max(by: { $0.tokens < $1.tokens }), points.count > 1 {
            parts.append(L("peak %d tokens on %@", Int(peak.tokens), peak.label))
        }
        return parts.joined(separator: ", ")
    }
}

struct TokenHistoryBar: View {
    let point: TokenHistoryChartPoint
    let maximum: Double
    let height: CGFloat
    let dense: Bool

    private var valueText: String {
        point.hasRecords ? L("%@ tokens", tokenHistoryCompactNumber(point.tokens)) : L("No recorded data")
    }

    var body: some View {
        RoundedRectangle(cornerRadius: dense ? 1 : 2)
            .fill(Color.accentColor.opacity(0.82))
            .frame(maxWidth: .infinity)
            .frame(height: point.tokens > 0 ? max(2, CGFloat(point.tokens / maximum) * height) : 0)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .accessibilityLabel(point.label)
            .accessibilityValue(valueText)
            .help("\(point.label): \(valueText)")
    }
}

private func tokenHistoryCoverageDetail(_ report: TokenHistoryReport) -> String {
    guard let first = report.firstRecordedAt else { return L("No local coverage") }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "MMM d, yyyy"
    return L("Since %@", formatter.string(from: first))
}

private func tokenHistoryCompactNumber(_ value: Double) -> String {
    guard value.isFinite else { return "—" }
    let absolute = abs(value)
    let divisor: Double
    let suffix: String
    switch absolute {
    case 1_000_000_000...:
        divisor = 1_000_000_000
        suffix = "B"
    case 1_000_000...:
        divisor = 1_000_000
        suffix = "M"
    case 1_000...:
        divisor = 1_000
        suffix = "K"
    default:
        return String(format: "%.0f", value)
    }
    let scaled = value / divisor
    return String(format: scaled >= 100 ? "%.0f%@" : (scaled >= 10 ? "%.1f%@" : "%.2f%@"), scaled, suffix)
}
