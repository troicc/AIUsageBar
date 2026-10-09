import SwiftUI

struct ClaudeQuotaCoverageView: View {
    let dashboard: ProviderDashboard

    var body: some View {
        Text(L(dashboard.hasClaudeSharedQuota
            ? "Shared by web, desktop and Claude Code on this account. Web chat has no separate token or cost breakdown here."
            : "Shared quota unavailable. Local logs do not include web chat tokens or costs."))
            .font(.system(size: 10)).foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ClaudeQuotaHistoryView: View {
    let dashboard: ProviderDashboard
    @State private var selected = "five-hour"
    let now: Date

    /// `expanded` is kept for callers; the trend is always shown now.
    init(dashboard: ProviderDashboard, expanded: Bool = true, now: Date = Date()) {
        self.dashboard = dashboard
        self.now = now
    }

    private var series: ClaudeQuotaSeries? {
        dashboard.claudeQuotaHistory.first { $0.id == selected } ?? dashboard.claudeQuotaHistory.first
    }

    var body: some View {
        DSCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    Label(L("Quota trend · 24h"), systemImage: "chart.xyaxis.line")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if dashboard.claudeQuotaHistory.count > 1 {
                        QuotaWindowSwitch(series: dashboard.claudeQuotaHistory, selected: $selected)
                    }
                }
                if let series = series, let last = series.samples.last {
                    summary(series, last: last)
                    ClaudeQuotaPlot(series: series, now: now)
                        .frame(height: 128)
                    timeAxis
                    legend(series)
                } else {
                    Text(dashboard.claudeQuotaHistoryNotice ?? L("History begins with successful refreshes. No samples in the last 24 hours."))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                Text(L("Shared by web, desktop and Claude Code. Sources are estimated from Claude Code activity on this Mac; web chat tokens and costs are not available."))
                    .font(.system(size: 10)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if series != nil, let notice = dashboard.claudeQuotaHistoryNotice {
                    Text(notice).font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
        }
    }

    private func summary(_ series: ClaudeQuotaSeries, last: ClaudeQuotaSample) -> some View {
        let remaining = max(0, 100 - last.usedPercent)
        return HStack(alignment: .firstTextBaseline, spacing: 22) {
            stat(value: String(format: "%.0f", remaining), unit: "%", caption: L("%@ · remaining", series.title),
                 color: remaining < 15 ? Color(nsColor: .systemRed) : .primary)
            if let resetsAt = last.resetsAt, let countdown = DS.countdown(to: resetsAt) {
                stat(value: countdown, unit: nil, caption: L("Until reset"), color: .primary)
            }
            Spacer()
        }
    }

    private func stat(value: String, unit: String?, caption: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 28, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundColor(color)
                if let unit = unit {
                    Text(unit).font(.system(size: 14, weight: .light, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
            Text(caption).font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    /// Labels at whole local hours (every 6 h), placed where they fall.
    private var timeAxis: some View {
        GeometryReader { geometry in
            let start = now.addingTimeInterval(-86_400)
            let calendar = Calendar.current
            let firstHour = calendar.nextDate(after: start, matching: DateComponents(minute: 0),
                                              matchingPolicy: .nextTime) ?? start
            let ticks = (0..<24).compactMap { offset -> Date? in
                let date = firstHour.addingTimeInterval(Double(offset) * 3600)
                return calendar.component(.hour, from: date) % 6 == 0 && date < now.addingTimeInterval(-3600) ? date : nil
            }
            let plotWidth = max(0, geometry.size.width - 32)
            ZStack(alignment: .topLeading) {
                ForEach(ticks, id: \.self) { tick in
                    Text(Self.hourFormatter.string(from: tick))
                        .position(x: 4 + CGFloat(tick.timeIntervalSince(start) / 86_400) * plotWidth, y: 6)
                }
                Text(L("Now")).position(x: 4 + plotWidth, y: 6)
            }
        }
        .frame(height: 12)
        .font(.system(size: 9).monospacedDigit())
        .foregroundColor(.secondary)
    }

    @ViewBuilder
    private func legend(_ series: ClaudeQuotaSeries) -> some View {
        if series.attributedPoints > 0.05 {
            let code = series.claudeCodePoints / series.attributedPoints * 100
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        Capsule().fill(QuotaSourceStyle.claudeCode)
                            .frame(width: max(0, geometry.size.width * CGFloat(code / 100) - 1))
                        Capsule().fill(QuotaSourceStyle.otherDevices)
                    }
                }
                .frame(height: 5)
                HStack(spacing: 14) {
                    legendItem(color: QuotaSourceStyle.claudeCode, title: L("Claude Code"),
                               value: String(format: "%.0f%%", code))
                    legendItem(color: QuotaSourceStyle.otherDevices, title: L("Web & other devices"),
                               value: String(format: "%.0f%%", 100 - code))
                    Spacer()
                    Text(L("Estimated"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(L("No quota change to attribute in the last 24 hours."))
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private func legendItem(color: Color, title: String, value: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.system(size: 11)).foregroundColor(.secondary)
            Text(value).font(DS.numeral(12, weight: .semibold))
        }
    }

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:00"
        return formatter
    }()
}

enum QuotaSourceStyle {
    static let claudeCode = ProviderBrand.color(for: "claude")
    static let otherDevices = Color(nsColor: .systemIndigo)
}

/// Compact capsule switch between quota windows.
private struct QuotaWindowSwitch: View {
    let series: [ClaudeQuotaSeries]
    @Binding var selected: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(series) { lane in
                Button(action: { selected = lane.id }) {
                    Text(lane.title)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(selected == lane.id ? Color.primary.opacity(0.12) : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundColor(selected == lane.id ? .primary : .secondary)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L("Quota window")))
    }
}

/// Smooth quota curve over the last 24 hours. Segments are colored by the
/// estimated source of the rise; breaks mark resets, decreases and gaps.
private struct ClaudeQuotaPlot: View {
    let series: ClaudeQuotaSeries
    let now: Date

    private func point(_ sample: ClaudeQuotaSample, size: CGSize) -> CGPoint {
        let fraction = max(0, min(1, sample.timestamp.timeIntervalSince(now.addingTimeInterval(-86400)) / 86400))
        return CGPoint(x: 4 + fraction * max(0, size.width - 32),
                       y: 6 + (1 - sample.usedPercent / 100) * max(0, size.height - 12))
    }

    /// Indices of samples grouped into connected runs.
    private var runs: [[Int]] {
        var result: [[Int]] = []
        for index in series.samples.indices {
            if index > 0, ClaudeQuotaSeries.connects(series.samples[index - 1], series.samples[index]) {
                result[result.count - 1].append(index)
            } else {
                result.append([index])
            }
        }
        return result
    }

    /// Catmull-Rom control points for the segment from `i` to `i + 1` of a run,
    /// clamped vertically so the curve never overshoots the plot.
    private func controls(_ run: [CGPoint], _ i: Int, height: CGFloat) -> (CGPoint, CGPoint) {
        let p0 = run[max(0, i - 1)], p1 = run[i], p2 = run[i + 1], p3 = run[min(run.count - 1, i + 2)]
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x, y: min(max(p.y, min(p1.y, p2.y)), max(p1.y, p2.y)))
        }
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        return (clamp(c1), clamp(c2))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                grid(geometry.size)
                resetMarkers(geometry.size)
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    runView(run, size: geometry.size)
                }
                currentValue(geometry.size)
                hoverTargets(geometry.size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("%@ shared quota trend, 0 to 100 percent, last 24 hours", series.title)))
        .accessibilityValue(Text(L("%d observations", series.samples.count)))
    }

    private func y(_ percent: Double, _ size: CGSize) -> CGFloat {
        6 + CGFloat(1 - percent / 100) * (size.height - 12)
    }

    @ViewBuilder
    private func grid(_ size: CGSize) -> some View {
        ForEach([0.0, 50.0, 100.0], id: \.self) { percent in
            Path { path in
                path.move(to: CGPoint(x: 0, y: y(percent, size)))
                path.addLine(to: CGPoint(x: size.width - 28, y: y(percent, size)))
            }
            .stroke(Color.primary.opacity(percent == 0 ? 0.14 : 0.07),
                    style: StrokeStyle(lineWidth: 0.5, dash: percent == 0 ? [] : [2, 3]))
            Text(String(format: "%.0f%%", percent))
                .font(.system(size: 8).monospacedDigit())
                .foregroundColor(.secondary)
                .position(x: size.width - 12, y: y(percent, size))
        }
    }

    private var resetIndices: [Int] {
        series.samples.indices.dropFirst().filter { index in
            let previous = series.samples[index - 1], sample = series.samples[index]
            return previous.resetsAt != sample.resetsAt && sample.usedPercent < previous.usedPercent
        }
    }

    @ViewBuilder
    private func resetMarkers(_ size: CGSize) -> some View {
        ForEach(resetIndices, id: \.self) { index in
            let x = point(series.samples[index], size: size).x
            Path { path in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 0.6, dash: [2, 2]))
            Text(L("Reset"))
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.secondary)
                .position(x: x, y: 4)
        }
    }

    private func areaPath(_ points: [CGPoint], size: CGSize) -> Path {
        Path { path in
            path.move(to: CGPoint(x: points[0].x, y: size.height - 6))
            path.addLine(to: points[0])
            for i in 0..<(points.count - 1) {
                let (c1, c2) = controls(points, i, height: size.height)
                path.addCurve(to: points[i + 1], control1: c1, control2: c2)
            }
            path.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height - 6))
            path.closeSubpath()
        }
    }

    private func linePath(_ points: [CGPoint], size: CGSize) -> Path {
        Path { path in
            path.move(to: points[0])
            for i in 0..<(points.count - 1) {
                let (c1, c2) = controls(points, i, height: size.height)
                path.addCurve(to: points[i + 1], control1: c1, control2: c2)
            }
        }
    }

    private func otherDeviceSegments(_ run: [Int]) -> [Int] {
        (0..<max(0, run.count - 1)).filter { series.sources[series.samples[run[$0 + 1]].timestamp] == .otherDevices }
    }

    private func segmentPath(_ points: [CGPoint], _ i: Int, size: CGSize) -> Path {
        let (c1, c2) = controls(points, i, height: size.height)
        return Path { path in
            path.move(to: points[i])
            path.addCurve(to: points[i + 1], control1: c1, control2: c2)
        }
    }

    @ViewBuilder
    private func runView(_ run: [Int], size: CGSize) -> some View {
        let points = run.map { point(series.samples[$0], size: size) }
        if points.count > 1 {
            areaPath(points, size: size)
                .fill(LinearGradient(colors: [QuotaSourceStyle.claudeCode.opacity(0.22),
                                              QuotaSourceStyle.claudeCode.opacity(0.0)],
                                     startPoint: .top, endPoint: .bottom))
            // One continuous stroke per run, then the other-device segments
            // on top, so joints never show as dashes.
            linePath(points, size: size)
                .stroke(QuotaSourceStyle.claudeCode,
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            ForEach(otherDeviceSegments(run), id: \.self) { i in
                segmentPath(points, i, size: size)
                    .stroke(QuotaSourceStyle.otherDevices,
                            style: StrokeStyle(lineWidth: 2.4, lineCap: .butt, lineJoin: .round))
            }
        } else if let only = points.first {
            Circle().fill(QuotaSourceStyle.claudeCode).frame(width: 4, height: 4).position(only)
        }
    }

    @ViewBuilder
    private func currentValue(_ size: CGSize) -> some View {
        if let last = series.samples.last {
            let position = point(last, size: size)
            Circle().fill(QuotaSourceStyle.claudeCode.opacity(0.18)).frame(width: 16, height: 16).position(position)
            Circle().fill(QuotaSourceStyle.claudeCode).frame(width: 7, height: 7)
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                .position(position)
        }
    }

    @ViewBuilder
    private func hoverTargets(_ size: CGSize) -> some View {
        ForEach(series.samples) { sample in
            Color.clear.frame(width: 10, height: 10).contentShape(Rectangle())
                .position(point(sample, size: size))
                .help("\(sample.timestamp.formatted(date: .abbreviated, time: .shortened)): \(L("%.1f%% used", sample.usedPercent))")
        }
    }
}
