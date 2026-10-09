@preconcurrency import AppKit
import SwiftUI


struct TokenHistorySettingsView: View {
    @ObservedObject var dashboardStore: DashboardStore
    @State private var selectedAccountID = ""
    @State private var range: TokenHistoryRange = .thirtyDays
    @State private var exportStatus: String?
    @State private var exportFailed = false

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
        SettingsPage(
            title: L("Usage Data"),
            subtitle: L("Long-term token history, every available token component, and portable exports"),
            tab: .usageData)
        {
            HStack(spacing: 12) {
                Picker(L("Account"), selection: $selectedAccountID) {
                    Text(L("All providers & accounts")).tag("")
                    ForEach(dashboardStore.tokenHistoryAccounts) { account in
                        Text(account.displayName).tag(account.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 300)

                Spacer(minLength: 8)

                Picker(L("Range"), selection: $range) {
                    ForEach(TokenHistoryRange.allCases) { range in
                        Text(L(range.title)).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityLabel(Text(L("Range")))
            }

            if report.recordCount == 0 {
                TokenHistoryEmptyState()
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
                    spacing: 12)
                {
                    TokenHistoryStatCard(
                        title: L("%@ tokens", L(range.title)),
                        value: tokenHistoryCompactNumber(report.totalTokens),
                        detail: L("%d dated buckets", report.recordCount),
                        symbol: "sum",
                        tint: Color(nsColor: .systemPurple))
                    TokenHistoryStatCard(
                        title: L("Today"),
                        value: tokenHistoryCompactNumber(report.todayTokens),
                        detail: L("Local calendar day"),
                        symbol: "sun.max.fill",
                        tint: Color(nsColor: .systemOrange))
                    TokenHistoryStatCard(
                        title: L("30 days"),
                        value: tokenHistoryCompactNumber(report.last30DaysTokens),
                        detail: tokenHistoryCoverageDetail(report),
                        symbol: "calendar",
                        tint: Color(nsColor: .systemBlue))
                    TokenHistoryStatCard(
                        title: L("All time"),
                        value: tokenHistoryCompactNumber(report.allTimeTokens),
                        detail: L("Never auto-pruned"),
                        symbol: "infinity",
                        tint: Color(nsColor: .systemTeal))
                }

                SettingsCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(L("Token volume · %@", L(range.title)))
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            if let peak = report.chart.max(by: { $0.tokens < $1.tokens }), peak.tokens > 0 {
                                Text(L("Peak %@ · %@", tokenHistoryCompactNumber(peak.tokens), peak.label))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        TokenHistoryBarChart(points: report.chart)
                    }
                }

                if report.components.hasData {
                    SettingsSection(title: L("Token components · %@", L(range.title))) {
                        TokenHistoryComponentsView(components: report.components)
                    }
                }

                if !report.modelTotals.isEmpty || report.providerTotals.count > 1 {
                    HStack(alignment: .top, spacing: 12) {
                        if !report.modelTotals.isEmpty {
                            TokenHistoryBreakdownBox(
                                title: L("Models"),
                                rows: report.modelTotals,
                                tint: Color(nsColor: .systemPurple))
                        }
                        if report.providerTotals.count > 1 {
                            TokenHistoryBreakdownBox(
                                title: L("Providers"),
                                rows: report.providerTotals,
                                tint: Color(nsColor: .systemOrange))
                        }
                    }
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Text(L("Claude and Codex show local model usage, not official quota consumption or invoices. Claude web chat tokens and costs are not included; web activity is reflected in the shared subscription quota. Other Claude Code models are kept separately and excluded from the combined total to avoid overlap with provider API data. Mixed days without model token counts remain unattributed. Token components appear only when complete."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 2)

            SettingsSection(
                title: L("Retention & export"),
                footer: L("Dated token buckets are merged by provider, account, time, and model in Application Support. Existing buckets are updated in place and are never automatically deleted. Quota percentages are stored separately and are not counted as tokens."))
            {
                SettingsRow(
                    title: L("Data file"),
                    subtitle: dashboardStore.tokenHistoryStorageURL.path,
                    symbol: "internaldrive.fill",
                    symbolColor: Color(nsColor: .systemGray))
                {
                    Button(action: revealDataFile) {
                        Label(L("Show data file"), systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }
                SettingsRowDivider(inset: 50)
                SettingsRow(
                    title: L("Export"),
                    subtitle: L("CSV follows the account and range shown above; JSON contains everything."),
                    symbol: "square.and.arrow.up.fill",
                    symbolColor: Color(nsColor: .systemBlue))
                {
                    HStack(spacing: 8) {
                        Button(action: exportVisibleCSV) {
                            Text(L("Export visible CSV…"))
                        }
                        Button(action: exportFullJSON) {
                            Text(L("Export full JSON…"))
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let persistenceError = dashboardStore.tokenHistoryPersistenceError {
                SettingsBanner(text: persistenceError, tone: .error)
            }
            if let exportStatus = exportStatus {
                SettingsBanner(text: exportStatus, tone: exportFailed ? .error : .success)
            }
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
            exportFailed = true
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
            exportFailed = false
            exportStatus = L("Exported %@", destination.lastPathComponent)
        } catch {
            exportFailed = true
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
        SettingsCard {
            VStack(spacing: 10) {
                SettingsIconTile(symbol: "chart.bar.xaxis", color: Color(nsColor: .systemPurple), size: 48)
                    .shadow(color: Color(nsColor: .systemPurple).opacity(0.25), radius: 4, y: 2)
                    .padding(.bottom, 4)
                Text(L("No dated token history in this range"))
                    .font(.system(size: 15, weight: .semibold))
                Text(L("Refresh a provider that exposes dated token usage. Codex and Claude import their current daily history; z.ai imports its rolling hourly model data and keeps it permanently from then on."))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
            .padding(.horizontal, 20)
        }
    }
}

struct TokenHistoryStatCard: View {
    let title: String
    let value: String
    let detail: String
    var symbol: String = "number"
    var tint: Color = .accentColor

    var body: some View {
        SettingsCard(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(tint)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(tint.opacity(0.14)))
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Text(value)
                    .font(DS.numeral(28, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Input / output / cache split as a proportional stacked bar with a legend.
struct TokenHistoryComponentsView: View {
    let components: TokenHistoryComponentTotals

    private var entries: [(String, Double?, Color)] {
        [
            (L("Input"), components.input, Color(nsColor: .systemBlue)),
            (L("Output"), components.output, Color(nsColor: .systemPurple)),
            (L("Cache read"), components.cacheRead, Color(nsColor: .systemTeal)),
            (L("Cache creation"), components.cacheCreation, Color(nsColor: .systemOrange)),
        ]
    }

    var body: some View {
        let total = entries.compactMap(\.1).reduce(0, +)
        VStack(alignment: .leading, spacing: 14) {
            if total > 0 {
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                            if let value = entry.1, value > 0 {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(LinearGradient(colors: [entry.2.opacity(0.8), entry.2],
                                                         startPoint: .top, endPoint: .bottom))
                                    .frame(width: max(3, (geometry.size.width - 6) * CGFloat(value / total)))
                            }
                        }
                    }
                }
                .frame(height: 10)
                .accessibilityHidden(true)
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    TokenHistoryComponentCell(title: entry.0, value: entry.1, tint: entry.2,
                                              share: total > 0 ? entry.1.map { $0 / total } : nil)
                }
            }
        }
        .padding(16)
    }
}

struct TokenHistoryComponentCell: View {
    let title: String
    let value: Double?
    var tint: Color = .accentColor
    var share: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Text(value.map(tokenHistoryCompactNumber) ?? "—")
                .font(DS.numeral(18))
            if let share = share {
                Text(String(format: "%.0f%%", share * 100))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct TokenHistoryBreakdownBox: View {
    let title: String
    let rows: [TokenHistoryNamedTotal]
    var tint: Color = .accentColor

    var body: some View {
        let top = max(1, rows.map(\.tokens).max() ?? 1)
        SettingsSection(title: title) {
            VStack(spacing: 10) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            Text(row.name)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(tokenHistoryCompactNumber(row.tokens))
                                .font(DS.numeral(12))
                                .help(L("%.0f tokens", row.tokens))
                                .textSelection(.enabled)
                        }
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.07))
                                Capsule()
                                    .fill(LinearGradient(colors: [tint.opacity(0.65), tint],
                                                         startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(4, geometry.size.width * CGFloat(row.tokens / top)))
                            }
                        }
                        .frame(height: 4)
                        .accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity)
    }
}

struct TokenHistoryBarChart: View {
    let points: [TokenHistoryChartPoint]
    private let chartHeight: CGFloat = 180

    private var maximum: Double {
        max(1, points.map(\.tokens).max() ?? 1)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                GeometryReader { geometry in
                    ZStack(alignment: .bottomLeading) {
                        VStack(spacing: 0) {
                            ForEach(0..<4) { index in
                                if index > 0 { Spacer(minLength: 0) }
                                gridLine(solid: index == 3)
                            }
                        }
                        HStack(alignment: .bottom, spacing: points.count > 60 ? 1 : (points.count > 20 ? 3 : 6)) {
                            ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                                TokenHistoryBar(point: point, maximum: maximum,
                                                height: geometry.size.height, dense: points.count > 60,
                                                isLatest: index == points.count - 1)
                            }
                        }
                    }
                }
                .frame(height: chartHeight)

                VStack(alignment: .leading, spacing: 0) {
                    Text(tokenHistoryCompactNumber(maximum))
                    Spacer(minLength: 0)
                    Text(tokenHistoryCompactNumber(maximum * 2 / 3))
                    Spacer(minLength: 0)
                    Text(tokenHistoryCompactNumber(maximum / 3))
                    Spacer(minLength: 0)
                    Text("0")
                }
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 36, height: chartHeight + 10, alignment: .leading)
                .offset(y: -5)
                .accessibilityHidden(true)
            }

            HStack {
                Text(points.first?.label ?? "")
                Spacer()
                if points.count > 2 { Text(points[points.count / 2].label) }
                Spacer()
                Text(points.last?.label ?? "")
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .padding(.trailing, 46)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("Token usage chart")))
        .accessibilityValue(Text(accessibilitySummary))
    }

    private func gridLine(solid: Bool) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(solid ? 0.14 : 0.06))
            .frame(height: solid ? 1 : 0.5)
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
    var isLatest = false

    private var valueText: String {
        point.hasRecords ? L("%@ tokens", tokenHistoryCompactNumber(point.tokens)) : L("No recorded data")
    }

    var body: some View {
        let tint = Color(nsColor: .systemPurple)
        RoundedRectangle(cornerRadius: dense ? 1.5 : 4, style: .continuous)
            .fill(LinearGradient(
                colors: isLatest
                    ? [Color(nsColor: .systemPink), tint]
                    : [tint.opacity(0.85), Color(nsColor: .systemIndigo).opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom))
            .frame(maxWidth: 28)
            .frame(maxWidth: .infinity)
            .frame(height: point.tokens > 0 ? max(3, CGFloat(point.tokens / maximum) * height) : 0)
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
    formatter.locale = Locale(identifier: L10n.usesChinese ? "zh_Hans" : "en_US_POSIX")
    formatter.dateFormat = L10n.usesChinese ? "yyyy年M月d日" : "MMM d, yyyy"
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
