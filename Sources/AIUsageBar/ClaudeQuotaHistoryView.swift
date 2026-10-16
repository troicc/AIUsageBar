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
    /// Pointer position over the plot, for the hover readout.
    @State private var pointer: CGPoint?
    @AppStorage(QuotaChartMode.preferenceKey) private var storedMode = QuotaChartMode.insights.rawValue
    let now: Date
    /// Overrides the display style chosen in Settings, for previews.
    private let forcedMode: QuotaChartMode?

    /// `expanded` is kept for callers; the trend is always shown now.
    init(dashboard: ProviderDashboard, expanded: Bool = true, now: Date = Date(), window: String = "five-hour",
         scrolledBack: TimeInterval = 0, pointer: CGPoint? = nil, mode: QuotaChartMode? = nil) {
        self.dashboard = dashboard
        self.now = now
        forcedMode = mode
        _selected = State(initialValue: window)
        _pan = State(initialValue: scrolledBack)
        _pointer = State(initialValue: pointer)
    }

    private var official: ClaudeProductBreakdown? { dashboard.claudeProductBreakdown }

    private var lane: ClaudeQuotaSeries? {
        dashboard.claudeQuotaHistory.first { $0.id == selected } ?? dashboard.claudeQuotaHistory.first
    }

    private var isWeekly: Bool { lane?.id == "weekly" }

    private var showsInsights: Bool { (forcedMode ?? QuotaChartMode(rawValue: storedMode) ?? .insights) == .insights }

    /// The weekly window that contains now; a week back when none is known.
    private var currentWeek: DateInterval {
        if let cycle = weeklyLane?.cycles().last?.interval, cycle.start <= now, cycle.end > now { return cycle }
        return DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now)
    }

    /// The pace of the shown window, for the insights style.
    private var pace: QuotaPace? {
        guard showsInsights else { return nil }
        return lane?.pace(now: now, lookback: isWeekly ? 86_400 : 3600)
    }

    /// Renewal or expiry date, from the account, the subscription card or the subscription start.
    private var subscriptionDate: Date? {
        let manual = dashboard.subscriptionDatePreferenceKey.flatMap { UserDefaults.standard.string(forKey: $0) } ?? ""
        return dashboard.subscriptionTiming(manual: manual, now: now)?.date
    }

    /// The weekly lane spans the current subscription month (the current
    /// weekly window with insights); the 5-hour lane the last day.
    private var currentRange: DateInterval {
        guard isWeekly else {
            // With insights the day runs on to the current window's reset, leaving room for the forecast.
            let windowEnd = showsInsights ? lane?.cycles().last.flatMap { $0.interval.end > now ? $0.interval.end : nil } : nil
            let end = min(windowEnd ?? now, now.addingTimeInterval(5 * 3600))
            return DateInterval(start: end.addingTimeInterval(-86_400), end: end)
        }
        return showsInsights ? currentWeek : ClaudeQuotaSeries.billingCycle(now: now, anchor: subscriptionDate)
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
        if showsInsights { return L("Quota trend · this week") }
        return subscriptionDate != nil ? L("Quota trend · this billing cycle") : L("Quota trend · 30 days")
    }

    private var series: ClaudeQuotaSeries? { lane?.within(range) }

    var body: some View {
        DSCard(padding: showsInsights ? 16 : 14) {
            if showsInsights { insightsLayout } else { classicLayout }
        }
        .onChange(of: selected) { _ in pan = 0 }
    }

    private var sharedNote: String {
        official != nil
            ? L("Shared by Claude Code, Cowork, chats and other apps. The weekly breakdown comes from your Claude account.")
            : L("Shared by web, desktop and Claude Code. Sources are estimated from Claude Code activity on this Mac; web chat tokens and costs are not available.")
    }

    private var header: some View {
        HStack(alignment: .center) {
            Label(title, systemImage: "chart.xyaxis.line")
                .font(.system(size: 12, weight: .semibold))
            if showsInsights { InfoGlyph(text: sharedNote) }
            Spacer()
            if dashboard.claudeQuotaHistory.count > 1 {
                QuotaWindowSwitch(series: dashboard.claudeQuotaHistory, selected: $selected)
            }
        }
    }

    /// The earlier layout, unchanged.
    private var classicLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
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

    /// One headline with two supporting figures, the chart on its own
    /// panel, then the breakdown. Explanations sit behind info glyphs.
    private var insightsLayout: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let lane = lane, let series = series, let last = lane.samples.last {
                QuotaTrendHero(title: lane.title, last: last, pace: pace, isWeekly: isWeekly, now: now)
                insightChart(series)
                footer(lane)
            } else {
                Text(dashboard.claudeQuotaHistoryNotice ?? L("History begins with successful refreshes. No samples in the last 24 hours."))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
    }

    /// The 5-hour allowance, where the quota went, and any notice.
    private func footer(_ lane: ClaudeQuotaSeries) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isWeekly, let weekly = weeklyLane, let fiveHour = fiveHourLane {
                QuotaAllowanceFigures(fiveHour: fiveHour, weekly: weekly, now: now)
            }
            if let official = official {
                ClaudeProductBreakdownView(breakdown: official)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    DSSectionLabel(title: L("Where it went"), symbol: "chart.pie")
                    legend(lane)
                }
            }
            if let credit = dashboard.claudeIncludedCredit { ClaudeIncludedCreditView(credit: credit) }
            if let notice = dashboard.claudeQuotaHistoryNotice {
                Text(notice).font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
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
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate(isWeekly ? "yMd" : "MdHHmm")
        return "\(formatter.string(from: range.start)) – \(formatter.string(from: range.end))"
    }

    /// Curve, the strip of recorded stretches under it, and the time axis.
    private func chart(_ series: ClaudeQuotaSeries) -> some View {
        let scale = QuotaTrendScale(range: range)
        let longGap = ClaudeQuotaSeries.longGap(over: range)
        let spans = series.recordedSpans(maxGap: longGap)
        // The 5-hour view also shows the weekly window it draws from.
        let weekly = isWeekly ? nil : weeklyLane
        let cycles = weekly?.cycles().filter { $0.overlaps(range) } ?? []
        // With insights the weekly view adds pace guides and each 5-hour window.
        let paced = showsInsights && isWeekly
        let weeks = paced ? (lane?.cycles().filter { $0.overlaps(range) } ?? []) : []
        let windows = paced ? (fiveHourLane?.cycles().filter { $0.overlaps(range) } ?? []) : []
        return VStack(alignment: .leading, spacing: 4) {
            plotArea(series, scale: scale, longGap: longGap, weekly: weekly, weeks: weeks)
            .frame(height: 128)
            QuotaRecordedStrip(spans: spans, scale: scale)
            if !cycles.isEmpty { QuotaCycleStrip(cycles: cycles, scale: scale, now: now) }
            QuotaTimeAxis(scale: scale, now: now, daily: isWeekly)
            if paced {
                QuotaWindowBars(windows: windows, scale: scale).equatable().padding(.top, 6)
                QuotaPaceKey().padding(.top, 4)
            } else if spans.count > 1 || weekly != nil {
                QuotaTrendKey(showsGaps: spans.count > 1, showsWeekly: weekly != nil).padding(.top, 2)
            }
            if let weekly = weekly { fiveHourAllowance(weekly) }
        }
    }

    /// The curve with its overlays, hover readout, scrolling and dragging.
    private func plotArea(_ series: ClaudeQuotaSeries, scale: QuotaTrendScale, longGap: TimeInterval,
                          weekly: ClaudeQuotaSeries?, weeks: [ClaudeQuotaSeries.Cycle]) -> some View {
        // Per-segment source coloring is an estimate; when the
        // account reports the official breakdown, show that instead.
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ClaudeQuotaPlot(series: series.thinned(bucket: range.duration / 400), scale: scale, now: now,
                                longGap: longGap,
                                showsLatest: series.samples.last == lane?.samples.last
                                    && range.contains(series.samples.last?.timestamp ?? .distantPast),
                                showsSources: official == nil,
                                companion: weekly?.within(range).thinned(bucket: range.duration / 400))
                    .equatable()
                if showsInsights {
                    QuotaPaceOverlay(cycles: weeks, pace: range.end >= now.addingTimeInterval(-60) ? pace : nil,
                                     scale: scale, now: now)
                        .equatable()
                }
                if dragStartPan == nil, let pointer = pointer {
                    QuotaHoverReadout(series: series, scale: scale, pointer: pointer)
                }
            }
            .background(ChartPointerReader(
                onScroll: { deltaX in scroll(by: deltaX / max(1, geometry.size.width - 32) * range.duration) },
                onHover: { pointer = $0 }))
            .gesture(drag(plotWidth: max(1, geometry.size.width - 32)))
        }
    }

    /// The chart on an inset panel: range and navigation, the plot, labeled
    /// lanes under it, the axis, the 5-hour windows of a week, and a key.
    private func insightChart(_ series: ClaudeQuotaSeries) -> some View {
        let scale = QuotaTrendScale(range: range)
        let longGap = ClaudeQuotaSeries.longGap(over: range)
        let spans = series.recordedSpans(maxGap: longGap)
        let weekly = isWeekly ? nil : weeklyLane
        let cycles = weekly?.cycles().filter { $0.overlaps(range) } ?? []
        let weeks = isWeekly ? (lane?.cycles().filter { $0.overlaps(range) } ?? []) : []
        let windows = isWeekly ? (fiveHourLane?.cycles().filter { $0.overlaps(range) } ?? []) : []
        return VStack(alignment: .leading, spacing: 6) {
            navigation
            plotArea(series, scale: scale, longGap: longGap, weekly: weekly, weeks: weeks)
                .frame(height: 140)
            VStack(spacing: 5) {
                QuotaRecordedStrip(spans: spans, scale: scale).laneLabel(L("Logged"))
                if !cycles.isEmpty {
                    QuotaCycleStrip(cycles: cycles, scale: scale, now: now).laneLabel(L("Week"))
                }
            }
            QuotaTimeAxis(scale: scale, now: now, daily: isWeekly)
            if isWeekly {
                QuotaWindowBars(windows: windows, scale: scale).equatable().padding(.top, 8)
                QuotaPaceKey().padding(.top, 6)
            } else {
                QuotaTrendKey(showsGaps: spans.count > 1, showsWeekly: weekly != nil).padding(.top, 6)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 12, trailing: 8))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
    }

    private var weeklyLane: ClaudeQuotaSeries? { dashboard.claudeQuotaHistory.first { $0.id == "weekly" } }
    private var fiveHourLane: ClaudeQuotaSeries? { dashboard.claudeQuotaHistory.first { $0.id == "five-hour" } }

    /// How many full 5-hour windows a week holds, and how many are left in this one.
    @ViewBuilder
    private func fiveHourAllowance(_ weekly: ClaudeQuotaSeries) -> some View {
        if let fiveHour = dashboard.claudeQuotaHistory.first(where: { $0.id == "five-hour" }),
           let estimate = ClaudeQuotaSeries.fiveHourWindowsPerWeek(fiveHour: fiveHour, weekly: weekly, now: now)
        {
            VStack(alignment: .leading, spacing: 1) {
                Text(L("One week ≈ %@ full 5-hour windows · about %@ left this week",
                       String(format: "%.1f", estimate.perWeek), String(format: "%.1f", estimate.remaining)))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                Text(L(estimate.fromCurrent ? "Estimated from this week's readings" : "Estimated from an earlier week's readings"))
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
            .padding(.top, 4)
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
                HStack(spacing: 8) {
                    GeometryReader { geometry in
                        HStack(spacing: 2) {
                            Capsule().fill(QuotaSourceStyle.claudeCode)
                                .frame(width: max(0, geometry.size.width * CGFloat(code / 100) - 1))
                            Capsule().fill(QuotaSourceStyle.otherDevices)
                        }
                    }
                    .frame(height: 5)
                    Text(L("Estimated"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                        .fixedSize()
                }
                HStack(spacing: 14) {
                    legendItem(color: QuotaSourceStyle.claudeCode, title: L("Claude Code"),
                               value: String(format: "%.0f%%", code))
                    legendItem(color: QuotaSourceStyle.otherDevices, title: L("Web & other devices"),
                               value: String(format: "%.0f%%", 100 - code))
                    Spacer(minLength: 0)
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

/// Follows the pointer over the chart, and reports horizontal trackpad
/// swipes and shift-scrolling while letting vertical scrolling through to the
/// enclosing scroll view.
private struct ChartPointerReader: NSViewRepresentable {
    let onScroll: (Double) -> Void
    let onHover: (CGPoint?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onScroll = onScroll
        view.onHover = onHover
    }

    final class ReaderView: NSView {
        var onScroll: ((Double) -> Void)?
        var onHover: ((CGPoint?) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        // Transparent to clicks; the pointer is read through a tracking area
        // and scrolling through the monitor.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) { report(event) }
        override func mouseMoved(with event: NSEvent) { report(event) }
        override func mouseExited(with event: NSEvent) { onHover?(nil) }

        private func report(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            onHover?(bounds.contains(point) ? point : nil)
        }

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
                self.onHover?(nil)
                return nil
            }
        }

        deinit {
            if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

/// Snaps to the reading nearest the pointer's time and shows it: a blue dot
/// on the line, a guide, and a callout with the usage and when it was read.
private struct QuotaHoverReadout: View {
    let series: ClaudeQuotaSeries
    let scale: QuotaTrendScale
    let pointer: CGPoint

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            if let sample = nearest(width: size.width) {
                let point = CGPoint(x: scale.position(sample.timestamp, width: size.width),
                                    y: 6 + CGFloat(1 - sample.usedPercent / 100) * (size.height - 12))
                Path { path in
                    path.move(to: CGPoint(x: point.x, y: 0))
                    path.addLine(to: CGPoint(x: point.x, y: size.height - 6))
                }
                .stroke(QuotaTrendStyle.hover.opacity(0.35), lineWidth: 0.8)
                Circle().fill(QuotaTrendStyle.hover.opacity(0.2)).frame(width: 14, height: 14).position(point)
                Circle().fill(QuotaTrendStyle.hover).frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .position(point)
                callout(sample)
                    .fixedSize()
                    .position(x: min(max(point.x, 46), size.width - 74),
                              y: point.y > 44 ? point.y - 24 : point.y + 24)
            }
        }
        .allowsHitTesting(false)
    }

    /// Reading in the visible range closest in time to the pointer.
    private func nearest(width: CGFloat) -> ClaudeQuotaSample? {
        guard pointer.x <= width - 28 else { return nil }
        let date = scale.date(at: pointer.x, width: width)
        return series.samples
            .filter { scale.range.contains($0.timestamp) }
            .min { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }
    }

    private func callout(_ sample: ClaudeQuotaSample) -> some View {
        let used = sample.usedPercent
        let value = used.rounded() == used ? String(format: "%.0f", used) : String(format: "%.1f", used)
        return VStack(alignment: .leading, spacing: 1) {
            Text(L("%@%% used", value))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
            Text(sample.timestamp.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))
                .font(.system(size: 9).monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}

/// Maps dates in a trend's range to x positions. The right 28 pt hold the
/// percent labels.
struct QuotaTrendScale: Equatable {
    let range: DateInterval

    /// Time at an x position in the plot.
    func date(at x: CGFloat, width: CGFloat) -> Date {
        let fraction = Double((x - 4) / max(1, width - 32))
        return range.start.addingTimeInterval(fraction * range.duration)
    }

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

    /// Vertical position of a used share in a plot of `height`, as the curve draws it.
    static func plotY(_ percent: Double, height: CGFloat) -> CGFloat {
        6 + CGFloat(1 - percent / 100) * (height - 12)
    }
}

enum QuotaTrendStyle {
    /// The hover readout's dot and guide.
    static let hover = Color(nsColor: .systemBlue)
    /// Joins readings across a long stretch with none: the Mac asleep or the app not running.
    static let unrecorded = Color.secondary.opacity(0.55)
    /// The weekly window shown with the 5-hour one.
    static let weekly = Color(nsColor: .systemTeal)
}

/// Quota curve over the trend's range, drawn as one continuous line.
/// Observed stretches are smooth Catmull-Rom curves colored by the estimated
/// source of each rise. Between them a straight connector joins the readings:
/// in the brand color after a short gap, gray after a long one (`longGap`). When a
/// window reset in between, the connector holds the last reading until the
/// reset, drops to zero, and rises from zero once the new window starts.
private struct ClaudeQuotaPlot: View, Equatable {
    let series: ClaudeQuotaSeries
    let scale: QuotaTrendScale
    let now: Date
    let longGap: TimeInterval
    /// Whether the last reading is the latest one, marked as the current value.
    var showsLatest = true
    var showsSources = true
    /// The weekly window, drawn on the same scale under the 5-hour line.
    var companion: ClaudeQuotaSeries? = nil

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
                    if let companion = companion, !companion.samples.isEmpty {
                        companionLine(companion, size: geometry.size)
                            .stroke(QuotaTrendStyle.weekly,
                                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    }
                    ForEach(connectors, id: \.self) { index in
                        connectorView(index, size: geometry.size)
                    }
                    ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                        runView(run, size: geometry.size)
                    }
                }
                .clipShape(PlotClip())
                if showsLatest { currentValue(geometry.size) }
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
        series.samples.indices.dropFirst().filter { series.hasReset(before: $0) }
    }

    private func resetMarkers(_ size: CGSize) -> some View {
        // Where the line drops: the old window's reset time. Every reset gets
        // a guide; a label that would collide with the previous one is left out.
        var markers: [(x: CGFloat, labeled: Bool)] = []
        for index in resetIndices {
            let markerX = x(series.reset(before: index)?.end ?? series.windowStart(at: index), size: size)
            guard (0...(size.width - 28)).contains(markerX) else { continue }
            let lastLabel = markers.last { $0.labeled }?.x
            markers.append((markerX, lastLabel.map { markerX - $0 >= 30 } ?? true))
        }
        return ForEach(markers.indices, id: \.self) { offset in
            resetMarker(at: markers[offset].x, labeled: markers[offset].labeled, size: size)
        }
    }

    @ViewBuilder
    private func resetMarker(at markerX: CGFloat, labeled: Bool, size: CGSize) -> some View {
        Path { path in
            path.move(to: CGPoint(x: markerX, y: 0))
            path.addLine(to: CGPoint(x: markerX, y: size.height))
        }
        .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 0.6, dash: [2, 2]))
        if labeled {
            Text(L("Reset"))
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.secondary)
                .fixedSize()
                .position(x: min(max(markerX, 12), size.width - 46), y: 4)
        }
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

    /// The companion window as straight segments; across its resets it drops
    /// to zero and rises again from the new window's start.
    private func companionLine(_ companion: ClaudeQuotaSeries, size: CGSize) -> Path {
        Path { path in
            let zero = y(0, size)
            for (index, sample) in companion.samples.enumerated() {
                let next = point(sample, size: size)
                guard index > 0 else { path.move(to: next); continue }
                if let reset = companion.reset(before: index) {
                    let endX = x(reset.end, size: size), startX = x(reset.start, size: size)
                    path.addLine(to: CGPoint(x: endX, y: path.currentPoint?.y ?? next.y))
                    path.addLine(to: CGPoint(x: endX, y: zero))
                    path.addLine(to: CGPoint(x: startX, y: zero))
                }
                path.addLine(to: next)
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
        guard let reset = series.reset(before: index) else { return [a, b] }
        let endX = x(reset.end, size: size), startX = x(reset.start, size: size), zero = y(0, size)
        return [a, CGPoint(x: endX, y: a.y), CGPoint(x: endX, y: zero), CGPoint(x: startX, y: zero), b]
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
}

/// The plot area left of the percent labels; lines that run past a scrolled
/// view's edges are cut here.
struct PlotClip: Shape {
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
        let start = span.start.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))
        guard span.duration > 0 else { return L("Recorded %@", start) }
        let sameDay = Calendar.current.isDate(span.start, inSameDayAs: span.end)
        let end = span.end.formatted(Date.FormatStyle(date: sameDay ? .omitted : .abbreviated, time: .shortened)
            .locale(L10n.locale))
        return L("Recorded %@ – %@", start, end)
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

/// Weekly windows under the 5-hour chart: each runs from its start to its
/// reset (teal, stronger up to now), red where it was used up. Neighbors
/// alternate in strength so the boundary between two weeks stays visible.
private struct QuotaCycleStrip: View {
    let cycles: [ClaudeQuotaSeries.Cycle]
    let scale: QuotaTrendScale
    let now: Date

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(Array(cycles.enumerated()), id: \.element) { offset, cycle in
                    band(cycle, offset: offset, width: geometry.size.width)
                }
            }
        }
        .frame(height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("Weekly window")))
        .accessibilityValue(Text(cycles.map(Self.describe).joined(separator: "; ")))
    }

    private func band(_ cycle: ClaudeQuotaSeries.Cycle, offset: Int, width: CGFloat) -> some View {
        let start: CGFloat = scale.x(cycle.interval.start, width: width) + (offset == 0 ? 0 : 1)
        let end: CGFloat = max(start, scale.x(cycle.interval.end, width: width) - 1)
        let elapsed: CGFloat = min(end, max(start, scale.x(now, width: width)))
        let strength = offset % 2 == 0 ? 0.9 : 0.55
        return ZStack(alignment: .leading) {
            Capsule().fill(QuotaTrendStyle.weekly.opacity(0.18)).frame(width: end - start, height: 4)
            Capsule().fill(QuotaTrendStyle.weekly.opacity(strength)).frame(width: elapsed - start, height: 4)
            ForEach(cycle.exhausted, id: \.self) { span in
                usedUp(span, start: start, end: elapsed, width: width)
            }
        }
        .clipShape(Capsule())
        .frame(width: max(3, end - start), height: 8, alignment: .leading)
        .contentShape(Rectangle())
        .position(x: (start + max(start + 3, end)) / 2, y: 4)
        .help(Self.describe(cycle))
    }

    /// The part of a used-up stretch inside the band, up to now.
    private func usedUp(_ span: DateInterval, start: CGFloat, end: CGFloat, width: CGFloat) -> some View {
        let left: CGFloat = min(end, max(start, scale.x(span.start, width: width)))
        let right: CGFloat = min(end, max(left, scale.x(span.end, width: width)))
        return Rectangle().fill(Color(nsColor: .systemRed).opacity(0.7))
            .frame(width: max(2, right - left), height: 4)
            .offset(x: left - start)
    }

    private static func describe(_ cycle: ClaudeQuotaSeries.Cycle) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)
        let span = L("Weekly window %@ – %@", cycle.interval.start.formatted(style), cycle.interval.end.formatted(style))
        let spent = cycle.exhausted.map { L("Used up %@", $0.start.formatted(style)) }
        return ([span, L("%@%% used", String(format: "%.0f", cycle.usedPercent))] + spent).joined(separator: " · ")
    }
}

/// Explains the line colors and the strips.
private struct QuotaTrendKey: View {
    var showsGaps = true
    var showsWeekly = false

    var body: some View {
        HStack(spacing: 14) {
            item(QuotaSourceStyle.claudeCode, showsWeekly ? L("5 hours") : L("Recorded"))
            if showsGaps { item(QuotaTrendStyle.unrecorded, L("No readings, joined")) }
            if showsWeekly { item(QuotaTrendStyle.weekly, L("Weekly window")) }
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
