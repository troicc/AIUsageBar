@preconcurrency import AppKit
import SwiftUI


enum ProviderHistoryChartStyle {
    case bars
    case line
}

enum ProviderHistoryValueKind {
    case tokens
    case spend
    case requests
    case percentage
}

struct ProviderHistorySeries: Identifiable {
    let id: String
    let title: String
    let values: [Double?]
    let firstLabel: String
    let lastLabel: String
    let labels: [String]
    let style: ProviderHistoryChartStyle
    let kind: ProviderHistoryValueKind
    let currencyCode: String?
    let color: Color
    let fixedMaximum: Double?

    var latestText: String {
        valueText(at: values.count - 1)
    }

    var costEstimates: [CostEstimateSummary?] = []

    var hasPartialEstimates: Bool {
        costEstimates.contains { $0?.knownCost != nil && $0?.isPartial == true }
    }

    func valueText(at index: Int) -> String {
        guard values.indices.contains(index), let value = values[index] else { return "—" }
        switch kind {
        case .tokens, .requests:
            return compactNumber(value)
        case .spend:
            let partial = costEstimates.indices.contains(index) && costEstimates[index]?.isPartial == true
            return (partial ? "≥" : "") + currencyNumber(value, code: currencyCode)
        case .percentage:
            return String(format: "%.0f%%", value)
        }
    }

    /// Spoken summary of the whole chart, not just its last bar: range,
    /// latest value and peak, so VoiceOver users get what a glance gives.
    var accessibilitySummary: String {
        let known = values.enumerated().compactMap { index, value in value.map { (index, $0) } }
        guard let latest = known.last else { return L("No data") }
        var parts = [L("%@ points from %@ to %@", String(values.count), firstLabel, lastLabel),
                     L("latest %@%@", labels.indices.contains(latest.0) ? labels[latest.0] + " " : "", valueText(at: latest.0))]
        if let peak = known.max(by: { $0.1 < $1.1 }), known.count > 1 {
            let label = labels.indices.contains(peak.0) ? labels[peak.0] : ""
            parts.append(L("peak %@ on %@", valueText(at: peak.0), label))
        }
        if hasPartialEstimates { parts.append(L("some costs are partial estimates")) }
        return parts.joined(separator: L(", "))
    }

    func tooltip(at index: Int) -> String {
        var text = "\(labels[index]): \(valueText(at: index))"
        if costEstimates.indices.contains(index), let estimate = costEstimates[index], estimate.isPartial {
            text += " · " + L(estimate.knownCost == nil ? "No known prices" : "Partial estimate; known costs only")
            if !estimate.unpricedModels.isEmpty { text += " · " + L("Unpriced: %@", estimate.unpricedModels.joined(separator: ", ")) }
            if estimate.hasUnattributedCost { text += " · " + L("Some costs unavailable") }
        }
        return text
    }
}

struct ProviderHistorySeriesView: View {
    let series: ProviderHistorySeries

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(series.title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(series.latestText)
                        .font(DS.numeral(15, weight: .bold))
                        .foregroundColor(series.color)
                    Text(L("Latest"))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            ZStack {
                ChartGridLines()
                Group {
                    switch series.style {
                    case .bars:
                        ProviderHistoryBarChart(
                            values: series.values,
                            color: series.color,
                            fixedMaximum: series.fixedMaximum)
                    case .line:
                        LineHistoryChart(
                            values: series.values,
                            color: series.color,
                            fixedMaximum: series.fixedMaximum)
                    }
                }
            }
            .frame(height: 86)
            .overlay {
                HStack(spacing: 0) {
                    ForEach(Array(series.values.enumerated()), id: \.offset) { index, _ in
                        Color.clear.contentShape(Rectangle())
                            .help(series.tooltip(at: index))
                    }
                }
            }
            HStack {
                Text(series.firstLabel)
                Spacer()
                Text(series.lastLabel)
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            if series.hasPartialEstimates {
                Label(L("Partial estimates · known costs only"), systemImage: "info.circle")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                .fill(Color.primary.opacity(0.045)))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(series.title))
        .accessibilityValue(Text(series.accessibilitySummary))
    }
}

/// Three faint dashed guides behind a chart.
struct ChartGridLines: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<3) { index in
                if index > 0 { Spacer(minLength: 0) }
                Rectangle()
                    .fill(Color.primary.opacity(index == 2 ? 0.12 : 0.06))
                    .frame(height: 0.5)
            }
        }
        .accessibilityHidden(true)
    }
}

struct ProviderHistoryBarChart: View {
    let values: [Double?]
    let color: Color
    let fixedMaximum: Double?

    var body: some View {
        GeometryReader { geometry in
            let maximum = max(fixedMaximum ?? values.compactMap { $0 }.max() ?? 1, 1)
            let lastIndex = values.lastIndex { $0 != nil }
            HStack(alignment: .bottom, spacing: max(2, geometry.size.width / CGFloat(max(values.count, 1)) * 0.24)) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(LinearGradient(
                            colors: [color.opacity(index == lastIndex ? 0.75 : 0.45),
                                     color.opacity(index == lastIndex ? 1 : 0.7)],
                            startPoint: .bottom, endPoint: .top))
                        .opacity(value == nil ? 0 : 1)
                        .frame(maxWidth: .infinity)
                        .frame(height: (value ?? 0) > 0 ? max(3, geometry.size.height * CGFloat(value! / maximum)) : 0)
                }
            }
        }
    }
}

func dashboardHistorySeries(for dashboard: ProviderDashboard) -> [ProviderHistorySeries] {
    let tokens = dashboard.history.map { $0.tokens.map { max(0, $0) } }
    let spend = dashboard.history.map { $0.spend.map { max(0, $0) } }
    let requests = dashboard.history.map { $0.requests.map { max(0, $0) } }
    let firstLabel = dashboard.history.first?.label ?? ""
    let lastLabel = dashboard.history.last?.label ?? ""
    let providerColor = ProviderBrand.color(for: dashboard.id)
    let currency = dashboard.historySummary?.currencyCode
    var result: [ProviderHistorySeries] = []

    func hasValues(_ values: [Double?]) -> Bool {
        values.contains(where: { $0 != nil })
    }

    func append(
        id: String,
        title: String,
        values: [Double?],
        style: ProviderHistoryChartStyle,
        kind: ProviderHistoryValueKind,
        color: Color,
        fixedMaximum: Double? = nil
    ) {
        guard hasValues(values) else { return }
        result.append(ProviderHistorySeries(
            id: id,
            title: title,
            values: values,
            firstLabel: firstLabel,
            lastLabel: lastLabel,
            labels: dashboard.history.map { $0.dayKey ?? $0.label },
            style: style,
            kind: kind,
            currencyCode: currency,
            color: color,
            fixedMaximum: fixedMaximum,
            costEstimates: kind == .spend ? dashboard.history.map(\.spendEstimate) : []))
    }

    switch dashboard.historyContext {
    case .dailyUsage:
        append(
            id: "daily-tokens",
            title: L("Daily tokens"),
            values: tokens,
            style: .bars,
            kind: .tokens,
            color: providerColor)
        append(
            id: "daily-cost",
            title: L((dashboard.id == "claude" || dashboard.id == "codex") ? "Daily estimated cost" : "Daily cost"),
            values: spend,
            style: .line,
            kind: .spend,
            color: .green)
        if result.count < 2 {
            append(
                id: "daily-requests",
                title: L("Daily requests"),
                values: requests,
                style: .line,
                kind: .requests,
                color: .orange)
        }
    case .hourlyUsage:
        append(
            id: "hourly-tokens",
            title: L("Hourly tokens"),
            values: tokens,
            style: .bars,
            kind: .tokens,
            color: providerColor)
    case .dailySpend:
        append(
            id: "daily-estimated-spend",
            title: L("Daily estimated spend"),
            values: spend,
            style: .bars,
            kind: .spend,
            color: .green)
    case .fiveHourQuotaSamples:
        append(
            id: "five-hour-quota",
            title: L("5h quota used"),
            values: tokens,
            style: .line,
            kind: .percentage,
            color: providerColor,
            fixedMaximum: 100)
    case .generic:
        append(
            id: "tokens",
            title: L("Tokens"),
            values: tokens,
            style: .bars,
            kind: .tokens,
            color: providerColor)
        append(
            id: "cost",
            title: L("Cost"),
            values: spend,
            style: .line,
            kind: .spend,
            color: .green)
        if result.count < 2 {
            append(
                id: "requests",
                title: L("Requests"),
                values: requests,
                style: .line,
                kind: .requests,
                color: .orange)
        }
    }
    return Array(result.prefix(2))
}

struct LineHistoryChart: View {
    let values: [Double?]
    let color: Color
    let fixedMaximum: Double?

    var body: some View {
        GeometryReader { geometry in
            let maximum = max(fixedMaximum ?? values.compactMap { $0 }.max() ?? 1, 1)
            let point: (Int, Double) -> CGPoint = { index, value in
                CGPoint(
                    x: values.count == 1 ? geometry.size.width / 2 : geometry.size.width * CGFloat(index) / CGFloat(values.count - 1),
                    y: geometry.size.height * (1 - CGFloat(max(0, value) / maximum)))
            }
            // Contiguous runs of known values; gaps stay gaps.
            let runs: [[CGPoint]] = values.enumerated().reduce(into: [[CGPoint]]()) { runs, entry in
                guard let value = entry.element else { runs.append([]); return }
                if runs.isEmpty { runs.append([]) }
                runs[runs.count - 1].append(point(entry.offset, value))
            }.filter { !$0.isEmpty }
            let lastIndex = values.lastIndex { $0 != nil }
            ZStack {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    if run.count > 1 {
                        Path { path in
                            path.move(to: CGPoint(x: run[0].x, y: geometry.size.height))
                            run.forEach { path.addLine(to: $0) }
                            path.addLine(to: CGPoint(x: run[run.count - 1].x, y: geometry.size.height))
                            path.closeSubpath()
                        }
                        .fill(LinearGradient(colors: [color.opacity(0.30), color.opacity(0.0)],
                                             startPoint: .top, endPoint: .bottom))
                    }
                }
                Path { path in
                    for run in runs {
                        path.move(to: run[0])
                        run.dropFirst().forEach { path.addLine(to: $0) }
                    }
                }.stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    if let value = value {
                        let isLast = index == lastIndex
                        Circle()
                            .fill(color)
                            .frame(width: isLast ? 7 : 4, height: isLast ? 7 : 4)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: isLast ? 2 : 0))
                            .shadow(color: isLast ? color.opacity(0.5) : .clear, radius: 3)
                            .position(point(index, value))
                    }
                }
            }
        }
    }
}
