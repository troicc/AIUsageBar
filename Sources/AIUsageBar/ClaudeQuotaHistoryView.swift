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
    @State private var selected: String
    /// How far the visible range is scrolled back from the current one, in seconds.
    @State private var pan: TimeInterval = 0
    @State private var dragStartPan: TimeInterval?
    let now: Date

    /// `expanded` is kept for callers; the trend is always shown now.
    init(dashboard: ProviderDashboard, expanded: Bool = true, now: Date = Date(), window: String = "five-hour",
         scrolledBack: TimeInterval = 0) {
        self.dashboard = dashboard
        self.now = now
        _selected = State(initialValue: window)
        _pan = State(initialValue: scrolledBack)
    }

    private var official: ClaudeProductBreakdown? { dashboard.claudeProductBreakdown }

    private var lane: ClaudeQuotaSeries? {
        dashboard.claudeQuotaHistory.first { $0.id == selected } ?? dashboard.claudeQuotaHistory.first
    }

    private var isWeekly: Bool { lane?.id == "weekly" }

    /// Renewal or expiry date, from the account or entered in the subscription card.
    private var subscriptionDate: Date? {
        let manual = dashboard.subscriptionDatePreferenceKey.flatMap { UserDefaults.standard.string(forKey: $0) } ?? ""
        return SubscriptionTiming.resolve(expires: dashboard.subscriptionExpiresAt,
                                          renews: dashboard.subscriptionRenewsAt, manual: manual)?.date
    }

    /// The weekly lane spans the current subscription month; the 5-hour lane the last day.
    private var currentRange: DateInterval {
        isWeekly ? ClaudeQuotaSeries.billingCycle(now: now, anchor: subscriptionDate)
            : DateInterval(start: now.addingTimeInterval(-86_400), end: now)
    }

    /// The visible range: the current one, scrolled back by `pan`.
    private var range: DateInterval {
        let current = currentRange
        return DateInterval(start: current.start.addingTimeInterval(-pan), duration: current.duration)
    }

    /// Far enough back for the oldest reading to reach the left edge.
    private var maxPan: TimeInterval {
        guard let first = lane?.samples.first else { return 0 }
        return max(0, currentRange.start.timeIntervalSince(first.timestamp))
    }

    private func scroll(by seconds: TimeInterval) {
        pan = min(maxPan, max(0, pan + seconds))
    }

    private var title: String {
        guard isWeekly else { return L("Quota trend · 24h") }
        return subscriptionDate != nil ? L("Quota trend · this billing cycle") : L("Quota trend · 30 days")
    }

    private var series: ClaudeQuotaSeries? { lane?.within(range) }

    var body: some View {
        DSCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    Label(title, systemImage: "chart.xyaxis.line")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if dashboard.claudeQuotaHistory.count > 1 {
                        QuotaWindowSwitch(series: dashboard.claudeQuotaHistory, selected: $selected)
                    }
                }
                if let lane = lane, let series = series, let last = lane.samples.last {
                    summary(lane, last: last)
                    navigation
                    chart(series)
                    if official == nil { legend(lane) }
                } else {
                    Text(dashboard.claudeQuotaHistoryNotice ?? L("History begins with successful refreshes. No samples in the last 24 hours."))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                if let official = official {
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
                    ClaudeProductBreakdownView(breakdown: official)
                }
                if let credit = dashboard.claudeIncludedCredit {
                    ClaudeIncludedCreditView(credit: credit)
                }
                Text(official != nil
                     ? L("Shared by Claude Code, Cowork, chats and other apps. The weekly breakdown comes from your Claude account.")
                     : L("Shared by web, desktop and Claude Code. Sources are estimated from Claude Code activity on this Mac; web chat tokens and costs are not available."))
                    .font(.system(size: 10)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if series != nil, let notice = dashboard.claudeQuotaHistoryNotice {
                    Text(notice).font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
        }
        .onChange(of: selected) { _ in pan = 0 }
    }

    /// Visible range, and buttons to step back and forth by one range.
    private var navigation: some View {
        HStack(spacing: 6) {
            Text(rangeText)
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(.secondary)
                .help(L("Swipe sideways or drag the chart to scroll through history."))
            Spacer()
            if pan > 0 {
                Button(L("Back to now")) { pan = 0 }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.accentColor)
            }
            navigationButton("chevron.left", help: L("Earlier"), enabled: pan < maxPan) { scroll(by: range.duration) }
            navigationButton("chevron.right", help: L("Later"), enabled: pan > 0) { scroll(by: -range.duration) }
        }
    }

    private func navigationButton(_ symbol: String, help: String, enabled: Bool,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 22, height: 18)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundColor(enabled ? .primary : .secondary.opacity(0.4))
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(Text(help))
    }

    /// Dragging right reveals earlier readings, like moving the paper.
    private func drag(plotWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let start = dragStartPan ?? pan
                dragStartPan = start
                pan = min(maxPan, max(0, start + Double(value.translation.width / plotWidth) * range.duration))
            }
            .onEnded { _ in dragStartPan = nil }
    }

    private var rangeText: String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(isWeekly ? "yMd" : "MdHHmm")
        return "\(formatter.string(from: range.start)) – \(formatter.string(from: range.end))"
    }

    /// Curve, the strip of recorded stretches under it, and the time axis.
    private func chart(_ series: ClaudeQuotaSeries) -> some View {
        let scale = QuotaTrendScale(range: range)
        let longGap = ClaudeQuotaSeries.longGap(over: range)
        let spans = series.recordedSpans(maxGap: longGap)
        return VStack(alignment: .leading, spacing: 4) {
            // Per-segment source coloring is an estimate; when the
            // account reports the official breakdown, show that instead.
            GeometryReader { geometry in
                ClaudeQuotaPlot(series: series.thinned(bucket: range.duration / 400), scale: scale, now: now,
                                longGap: longGap,
                                showsLatest: series.samples.last == lane?.samples.last
                                    && range.contains(series.samples.last?.timestamp ?? .distantPast),
                                showsSources: official == nil)
                    .background(HorizontalScrollReader { deltaX in
                        scroll(by: deltaX / max(1, geometry.size.width - 32) * range.duration)
                    })
                    .gesture(drag(plotWidth: max(1, geometry.size.width - 32)))
            }
            .frame(height: 128)
            QuotaRecordedStrip(spans: spans, scale: scale)
            QuotaTimeAxis(scale: scale, now: now, daily: isWeekly)
            if spans.count > 1 { QuotaTrendKey().padding(.top, 2) }
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

/// Reports horizontal trackpad swipes and shift-scrolling over its frame,
/// and lets vertical scrolling through to the enclosing scroll view.
private struct HorizontalScrollReader: NSViewRepresentable {
    let onScroll: (Double) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onScroll = onScroll
    }

    final class ReaderView: NSView {
        var onScroll: ((Double) -> Void)?
        private var monitor: Any?

        // Transparent to clicks and hovering; scrolling is read by the monitor.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self = self, let window = self.window, event.window === window,
                      abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                else { return event }
                self.onScroll?(Double(event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 8)))
                return nil
            }
        }

        deinit {
            if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

/// Maps dates in a trend's range to x positions. The right 28 pt hold the
/// percent labels.
struct QuotaTrendScale {
    let range: DateInterval

    /// Position kept inside the range, for the strip and the axis.
    func x(_ date: Date, width: CGFloat) -> CGFloat {
        4 + CGFloat(max(0, min(1, fraction(date)))) * max(0, width - 32)
    }

    /// Position that may fall outside the range, for drawing a line that runs past the edges.
    func position(_ date: Date, width: CGFloat) -> CGFloat {
        4 + CGFloat(fraction(date)) * max(0, width - 32)
    }

    private func fraction(_ date: Date) -> Double {
        range.duration > 0 ? date.timeIntervalSince(range.start) / range.duration : 1
    }
}

enum QuotaTrendStyle {
    /// Joins readings across a long stretch with none: the Mac asleep or the app not running.
    static let unrecorded = Color.secondary.opacity(0.55)
}

/// Quota curve over the trend's range, drawn as one continuous line.
/// Observed stretches are smooth Catmull-Rom curves colored by the estimated
/// source of each rise. Between them a straight connector joins the readings:
/// in the brand color after a short gap, gray after a long one (`longGap`). When a
/// window reset in between, the connector holds the last reading until the
/// reset, drops to zero, then rises to the next reading.
private struct ClaudeQuotaPlot: View {
    let series: ClaudeQuotaSeries
    let scale: QuotaTrendScale
    let now: Date
    let longGap: TimeInterval
    /// Whether the last reading is the latest one, marked as the current value.
    var showsLatest = true
    var showsSources = true

    private func x(_ date: Date, size: CGSize) -> CGFloat { scale.position(date, width: size.width) }

    private func y(_ percent: Double, _ size: CGSize) -> CGFloat {
        6 + CGFloat(1 - percent / 100) * (size.height - 12)
    }

    private func point(_ sample: ClaudeQuotaSample, size: CGSize) -> CGPoint {
        CGPoint(x: x(sample.timestamp, size: size), y: y(sample.usedPercent, size))
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

    /// Indices of samples that start a run, joined to the previous run by a connector.
    private var connectors: [Int] {
        series.samples.indices.dropFirst().filter {
            !ClaudeQuotaSeries.connects(series.samples[$0 - 1], series.samples[$0])
        }
    }

    /// Catmull-Rom control points for the segment from `i` to `i + 1` of a run,
    /// clamped vertically so the curve never overshoots the plot.
    private func controls(_ run: [CGPoint], _ i: Int) -> (CGPoint, CGPoint) {
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
                nowMarker(geometry.size)
                ZStack(alignment: .topLeading) {
                    resetMarkers(geometry.size)
                    area(geometry.size).fill(fill)
                    ForEach(connectors, id: \.self) { index in
                        connectorView(index, size: geometry.size)
                    }
                    ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                        runView(run, size: geometry.size)
                    }
                }
                .clipShape(PlotClip())
                if showsLatest { currentValue(geometry.size) }
                hoverTargets(geometry.size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("%@ shared quota trend, 0 to 100 percent", series.title)))
        .accessibilityValue(Text(L("%d observations", series.samples.count)))
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

    /// Where "now" falls when the range runs on to the end of the billing cycle.
    @ViewBuilder
    private func nowMarker(_ size: CGSize) -> some View {
        let nowX = x(now, size: size)
        if x(scale.range.end, size: size) - nowX >= 3 {
            Path { path in
                path.move(to: CGPoint(x: nowX, y: 0))
                path.addLine(to: CGPoint(x: nowX, y: size.height - 6))
            }
            .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 0.6, dash: [2, 2]))
        }
    }

    private var resetIndices: [Int] {
        series.samples.indices.dropFirst().filter { index in
            let previous = series.samples[index - 1], sample = series.samples[index]
            return !ClaudeQuotaSeries.sameWindow(previous.resetsAt, sample.resetsAt) && sample.usedPercent < previous.usedPercent
        }
    }

    @ViewBuilder
    private func resetMarkers(_ size: CGSize) -> some View {
        ForEach(resetIndices, id: \.self) { index in
            // The old window's reset time when known (where the line drops),
            // otherwise the new window's start.
            let reset = ClaudeQuotaSeries.reset(between: series.samples[index - 1], series.samples[index])
            let markerX = x(reset ?? series.windowStart(at: index), size: size)
            if (0...(size.width - 28)).contains(markerX) { resetMarker(at: markerX, size: size) }
        }
    }

    @ViewBuilder
    private func resetMarker(at markerX: CGFloat, size: CGSize) -> some View {
        Path { path in
            path.move(to: CGPoint(x: markerX, y: 0))
            path.addLine(to: CGPoint(x: markerX, y: size.height))
        }
        .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 0.6, dash: [2, 2]))
        Text(L("Reset"))
            .font(.system(size: 8, weight: .medium))
            .foregroundColor(.secondary)
            .fixedSize()
            .position(x: min(markerX, size.width - 46), y: 4)
    }

    /// Area under the whole line (runs and connectors) as one path, so the
    /// fill has no seams where pieces meet.
    private func area(_ size: CGSize) -> Path {
        Path { path in
            let baseline = size.height - 6
            var lastX: CGFloat?
            for (offset, run) in runs.enumerated() {
                let points = run.map { point(series.samples[$0], size: size) }
                if offset == 0 {
                    path.move(to: CGPoint(x: points[0].x, y: baseline))
                    path.addLine(to: points[0])
                } else {
                    connectorPoints(run[0], size: size).dropFirst().forEach { path.addLine(to: $0) }
                }
                if points.count > 1 { addLine(points, smooth: true, to: &path) }
                lastX = points.last?.x
            }
            if let lastX = lastX {
                path.addLine(to: CGPoint(x: lastX, y: baseline))
                path.closeSubpath()
            }
        }
    }

    private func line(_ points: [CGPoint], smooth: Bool) -> Path {
        Path { path in
            path.move(to: points[0])
            addLine(points, smooth: smooth, to: &path)
        }
    }

    private func addLine(_ points: [CGPoint], smooth: Bool, to path: inout Path) {
        for i in 0..<(points.count - 1) {
            if smooth {
                let (c1, c2) = controls(points, i)
                path.addCurve(to: points[i + 1], control1: c1, control2: c2)
            } else {
                path.addLine(to: points[i + 1])
            }
        }
    }

    private var fill: LinearGradient {
        LinearGradient(colors: [QuotaSourceStyle.claudeCode.opacity(0.22), QuotaSourceStyle.claudeCode.opacity(0.0)],
                       startPoint: .top, endPoint: .bottom)
    }

    private func connectorPoints(_ index: Int, size: CGSize) -> [CGPoint] {
        let previous = series.samples[index - 1], next = series.samples[index]
        let a = point(previous, size: size), b = point(next, size: size)
        guard let reset = ClaudeQuotaSeries.reset(between: previous, next) else { return [a, b] }
        let resetX = x(reset, size: size)
        return [a, CGPoint(x: resetX, y: a.y), CGPoint(x: resetX, y: y(0, size)), b]
    }

    @ViewBuilder
    private func connectorView(_ index: Int, size: CGSize) -> some View {
        let points = connectorPoints(index, size: size)
        let gap = series.samples[index].timestamp.timeIntervalSince(series.samples[index - 1].timestamp)
        line(points, smooth: false)
            .stroke(gap > longGap ? QuotaTrendStyle.unrecorded : QuotaSourceStyle.claudeCode,
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
    }

    private func otherDeviceSegments(_ run: [Int]) -> [Int] {
        guard showsSources else { return [] }
        return (0..<max(0, run.count - 1)).filter { series.sources[series.samples[run[$0 + 1]].timestamp] == .otherDevices }
    }

    private func segmentPath(_ points: [CGPoint], _ i: Int) -> Path {
        let (c1, c2) = controls(points, i)
        return Path { path in
            path.move(to: points[i])
            path.addCurve(to: points[i + 1], control1: c1, control2: c2)
        }
    }

    @ViewBuilder
    private func runView(_ run: [Int], size: CGSize) -> some View {
        let points = run.map { point(series.samples[$0], size: size) }
        if points.count > 1 {
            // One continuous stroke per run, then the other-device segments
            // on top, so joints never show as dashes.
            line(points, smooth: true)
                .stroke(QuotaSourceStyle.claudeCode,
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            ForEach(otherDeviceSegments(run), id: \.self) { i in
                segmentPath(points, i)
                    .stroke(QuotaSourceStyle.otherDevices,
                            style: StrokeStyle(lineWidth: 2.4, lineCap: .butt, lineJoin: .round))
            }
        } else if series.samples.count == 1, let only = points.first {
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
        ForEach(series.samples.filter { scale.range.contains($0.timestamp) }) { sample in
            Color.clear.frame(width: 10, height: 10).contentShape(Rectangle())
                .position(point(sample, size: size))
                .help("\(sample.timestamp.formatted(date: .abbreviated, time: .shortened)): \(L("%.1f%% used", sample.usedPercent))")
        }
    }
}

/// The plot area left of the percent labels; lines that run past a scrolled
/// view's edges are cut here.
private struct PlotClip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - 4, width: max(0, rect.width - 25), height: rect.height + 8))
    }
}

/// Stretches with readings, as brand-colored marks on a faint track under the plot.
private struct QuotaRecordedStrip: View {
    let spans: [DateInterval]
    let scale: QuotaTrendScale

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.primary.opacity(0.07))
                    .frame(width: max(0, width - 32), height: 3)
                    .position(x: 4 + max(0, width - 32) / 2, y: 4)
                ForEach(spans, id: \.self) { span in
                    let left = scale.x(span.start, width: width), right = scale.x(span.end, width: width)
                    Color.clear
                        .frame(width: max(3, right - left), height: 8)
                        .overlay(Capsule().fill(QuotaSourceStyle.claudeCode).frame(height: 3))
                        .contentShape(Rectangle())
                        .position(x: (left + right) / 2, y: 4)
                        .help(Self.describe(span))
                }
            }
        }
        .frame(height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("Recorded")))
        .accessibilityValue(Text(spans.map(Self.describe).joined(separator: "; ")))
    }

    private static func describe(_ span: DateInterval) -> String {
        let start = span.start.formatted(date: .abbreviated, time: .shortened)
        guard span.duration > 0 else { return L("Recorded %@", start) }
        let sameDay = Calendar.current.isDate(span.start, inSameDayAs: span.end)
        return L("Recorded %@ – %@", start, span.end.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened))
    }
}

/// Hour ticks for the last day, or day ticks for a billing cycle. Labels are
/// placed by priority (edges and "Now" first) and dropped when they would overlap.
private struct QuotaTimeAxis: View {
    let scale: QuotaTrendScale
    let now: Date
    let daily: Bool

    private struct Tick: Hashable {
        let text: String
        let x: CGFloat
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(ticks(width: geometry.size.width), id: \.self) { tick in
                    Text(tick.text).fixedSize().position(x: tick.x, y: 6)
                }
            }
        }
        .frame(height: 12)
        .font(.system(size: 9).monospacedDigit())
        .foregroundColor(.secondary)
    }

    private func ticks(width: CGFloat) -> [Tick] {
        var placed: [Tick] = []
        func place(_ text: String, at x: CGFloat, clearance: CGFloat) {
            guard placed.allSatisfy({ abs($0.x - x) >= clearance }) else { return }
            placed.append(Tick(text: text, x: x))
        }
        let calendar = Calendar.current
        let range = scale.range
        let plotWidth = max(1, width - 32)
        let nowX = scale.x(now, width: width)
        let showsNow = now >= range.start && now <= range.end.addingTimeInterval(60)
        if daily {
            place(Self.dayFormatter.string(from: range.start), at: 14, clearance: 0)
            if showsNow { place(L("Now"), at: nowX, clearance: 34) }
            place(Self.dayFormatter.string(from: range.end), at: 4 + plotWidth, clearance: 34)
            let days = max(1, range.duration / 86_400)
            let perDay = plotWidth / CGFloat(days)
            let step = [1, 2, 3, 5, 7, 10, 14].first { CGFloat($0) * perDay >= 34 } ?? 14
            var day = calendar.startOfDay(for: range.start)
            for index in 0..<64 {
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next < range.end else { break }
                day = next
                if (index + 1) % step == 0 {
                    place(Self.dayFormatter.string(from: day), at: scale.x(day, width: width), clearance: 32)
                }
            }
        } else {
            if showsNow { place(L("Now"), at: nowX, clearance: 0) }
            let firstHour = calendar.nextDate(after: range.start, matching: DateComponents(minute: 0),
                                              matchingPolicy: .nextTime) ?? range.start
            for offset in 0..<24 {
                let date = firstHour.addingTimeInterval(Double(offset) * 3600)
                let x = scale.x(date, width: width)
                let hour = calendar.component(.hour, from: date)
                guard hour % 6 == 0, x >= 14, x <= width - 30 else { continue }
                // Midnight shows the date, so a scrolled-back day can be told apart.
                place((hour == 0 ? Self.dayFormatter : Self.hourFormatter).string(from: date), at: x, clearance: 30)
            }
        }
        return placed
    }

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:00"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter
    }()
}

/// Explains the two line colors and the recorded strip.
private struct QuotaTrendKey: View {
    var body: some View {
        HStack(spacing: 14) {
            item(QuotaSourceStyle.claudeCode, L("Recorded"))
            item(QuotaTrendStyle.unrecorded, L("No readings, joined"))
            Spacer()
        }
        .font(.system(size: 9))
        .foregroundColor(.secondary)
    }

    private func item(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 12, height: 3)
            Text(title)
        }
    }
}
