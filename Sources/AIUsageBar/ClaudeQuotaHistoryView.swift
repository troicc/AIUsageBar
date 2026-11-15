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

/// Where the pointer is over the plot. Only the hover readout observes it, so
/// moving the pointer redraws the readout and nothing else.
final class QuotaPointer: ObservableObject {
    @Published private(set) var location: CGPoint?

    init(_ location: CGPoint? = nil) { self.location = location }

    func move(to location: CGPoint?) {
        if location != self.location { self.location = location }
    }
}

struct ClaudeQuotaHistoryView: View {
    let dashboard: ProviderDashboard
    @State private var selected: String
    /// How far the visible range is scrolled back from the current one, in seconds.
    @State private var pan: TimeInterval = 0
    @State private var dragStartPan: TimeInterval?
    /// Pointer position over the plot, for the hover readout.
    @State private var pointer: QuotaPointer
    /// The day chosen in the weekly view, shown in detail under the chart.
    @State private var selectedDay: Date?
    /// A day to show once the view switches to the 5-hour window.
    @State private var pendingDay: Date?
    @State private var cache = QuotaTrendCache()
    @AppStorage(QuotaChartMode.preferenceKey) private var storedMode = QuotaChartMode.insights.rawValue
    let now: Date
    /// Overrides the display style chosen in Settings, for previews.
    private let forcedMode: QuotaChartMode?

    /// `expanded` is kept for callers; the trend is always shown now.
    init(dashboard: ProviderDashboard, expanded: Bool = true, now: Date = Date(), window: String = "five-hour",
         scrolledBack: TimeInterval = 0, pointer: CGPoint? = nil, mode: QuotaChartMode? = nil, day: Date? = nil) {
        self.dashboard = dashboard
        self.now = now
        forcedMode = mode
        _selected = State(initialValue: window)
        _pan = State(initialValue: scrolledBack)
        _pointer = State(initialValue: QuotaPointer(pointer))
        _selectedDay = State(initialValue: day)
    }

    private var official: ClaudeProductBreakdown? { dashboard.claudeProductBreakdown }

    private var showsInsights: Bool { (forcedMode ?? QuotaChartMode(rawValue: storedMode) ?? .insights) == .insights }

    /// Renewal or expiry date, from the account, the subscription card or the
    /// subscription start; only the classic weekly view spans the subscription month.
    private var subscriptionDate: Date? {
        let lane = dashboard.claudeQuotaHistory.first { $0.id == selected } ?? dashboard.claudeQuotaHistory.first
        guard !showsInsights, lane?.id == "weekly" else { return nil }
        let manual = dashboard.subscriptionDatePreferenceKey.flatMap { UserDefaults.standard.string(forKey: $0) } ?? ""
        return dashboard.subscriptionTiming(manual: manual, now: now)?.date
    }

    private var facts: QuotaTrendFacts {
        cache.facts(for: QuotaTrendCache.Key(history: dashboard.claudeQuotaHistory, selected: selected,
                                             insights: showsInsights, subscriptionDate: subscriptionDate),
                    now: now)
    }

    private func scroll(by seconds: TimeInterval, maxPan: TimeInterval) {
        pan = min(maxPan, max(0, pan + seconds))
    }

    private func title(_ facts: QuotaTrendFacts) -> String {
        guard facts.isWeekly else { return L("Quota trend · 24h") }
        if showsInsights { return L("Quota trend · this week") }
        return facts.subscriptionDate != nil ? L("Quota trend · this billing cycle") : L("Quota trend · 30 days")
    }

    var body: some View {
        let facts = self.facts
        DSCard(padding: showsInsights ? 16 : 14) {
            if showsInsights { insightsLayout(facts) } else { classicLayout(facts) }
        }
        .onChange(of: selected) { _ in
            pan = 0
            selectedDay = nil
            // Coming from a day picked in the weekly view: end the 24 hours with that day.
            if let day = pendingDay, let end = Calendar.current.dateInterval(of: .day, for: day)?.end {
                pendingDay = nil
                let facts = self.facts
                scroll(by: facts.currentRange.end.timeIntervalSince(end), maxPan: facts.maxPan)
            }
        }
    }

    private var sharedNote: String {
        official != nil
            ? L("Shared by Claude Code, Cowork, chats and other apps. The weekly breakdown comes from your Claude account.")
            : L("Shared by web, desktop and Claude Code. Sources are estimated from Claude Code activity on this Mac; web chat tokens and costs are not available.")
    }

    private func header(_ facts: QuotaTrendFacts) -> some View {
        HStack(alignment: .center) {
            Label(title(facts), systemImage: "chart.xyaxis.line")
                .font(.system(size: 12, weight: .semibold))
            if showsInsights { InfoGlyph(text: sharedNote) }
            Spacer()
            if dashboard.claudeQuotaHistory.count > 1 {
                QuotaWindowSwitch(series: dashboard.claudeQuotaHistory, selected: $selected)
            }
        }
    }

    /// The earlier layout, unchanged.
    private func classicLayout(_ facts: QuotaTrendFacts) -> some View {
        let series = facts.lane?.within(facts.range(pan: pan))
        return VStack(alignment: .leading, spacing: 12) {
            header(facts)
            if let lane = facts.lane, let series = series, let last = lane.samples.last {
                summary(lane, last: last)
                navigation(facts)
                chart(series, facts: facts)
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
            Text(sharedNote)
                .font(.system(size: 10)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if series != nil, let notice = dashboard.claudeQuotaHistoryNotice {
                Text(notice).font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }

    /// One headline with two supporting figures, the chart on its own
    /// panel, then the breakdown. Explanations sit behind info glyphs.
    private func insightsLayout(_ facts: QuotaTrendFacts) -> some View {
        let series = facts.lane?.within(facts.range(pan: pan))
        return VStack(alignment: .leading, spacing: 14) {
            header(facts)
            if let lane = facts.lane, let series = series, let last = lane.samples.last {
                QuotaTrendHero(title: lane.title, last: last, pace: facts.pace, isWeekly: facts.isWeekly, now: facts.now)
                insightChart(series, facts: facts)
                footer(lane, facts: facts)
            } else {
                Text(dashboard.claudeQuotaHistoryNotice ?? L("History begins with successful refreshes. No samples in the last 24 hours."))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
    }

    /// The 5-hour allowance, where the quota went, and any notice.
    private func footer(_ lane: ClaudeQuotaSeries, facts: QuotaTrendFacts) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let perWeek = facts.windowsPerWeek {
                QuotaAllowanceFigures(perWeek: perWeek, weeklyUsed: facts.weeklyUsed)
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
    private func navigation(_ facts: QuotaTrendFacts) -> some View {
        let range = facts.range(pan: pan)
        return HStack(spacing: 6) {
            Text(rangeText(range, weekly: facts.isWeekly))
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
            navigationButton("chevron.left", help: L("Earlier"), enabled: pan < facts.maxPan) {
                scroll(by: range.duration, maxPan: facts.maxPan)
            }
            navigationButton("chevron.right", help: L("Later"), enabled: pan > 0) {
                scroll(by: -range.duration, maxPan: facts.maxPan)
            }
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
    private func drag(plotWidth: CGFloat, facts: QuotaTrendFacts) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let start = dragStartPan ?? pan
                if dragStartPan == nil { dragStartPan = start }
                pointer.move(to: nil)
                let next = min(facts.maxPan, max(0, start + Double(value.translation.width / plotWidth) * facts.currentRange.duration))
                if next != pan { pan = next }
            }
            .onEnded { _ in dragStartPan = nil }
    }

    private func rangeText(_ range: DateInterval, weekly: Bool) -> String {
        let formatter = DS.dateFormatter(template: weekly ? "yMd" : "MdHHmm")
        return "\(formatter.string(from: range.start)) – \(formatter.string(from: range.end))"
    }

    /// Curve, the strip of recorded stretches under it, and the time axis.
    private func chart(_ series: ClaudeQuotaSeries, facts: QuotaTrendFacts) -> some View {
        let range = facts.range(pan: pan)
        let scale = QuotaTrendScale(range: range)
        let longGap = ClaudeQuotaSeries.longGap(over: range)
        let spans = series.recordedSpans(maxGap: longGap)
        // The 5-hour view also shows the weekly window it draws from.
        let hasCompanion = !facts.isWeekly && facts.weeklyLane != nil
        let cycles = hasCompanion ? facts.weeklyCycles.filter { $0.overlaps(range) } : []
        return VStack(alignment: .leading, spacing: 4) {
            plotArea(series, facts: facts, scale: scale, longGap: longGap, weeks: [])
                .frame(height: 128)
            QuotaRecordedStrip(spans: spans, scale: scale)
            if !cycles.isEmpty { QuotaCycleStrip(cycles: cycles, scale: scale, now: facts.now) }
            QuotaTimeAxis(scale: scale, now: facts.now, daily: facts.isWeekly)
            if spans.count > 1 || hasCompanion {
                QuotaTrendKey(showsGaps: spans.count > 1, showsWeekly: hasCompanion).padding(.top, 2)
            }
            if let estimate = facts.allowance { fiveHourAllowance(estimate) }
        }
    }

    /// The curve with its overlays, hover readout, scrolling and dragging.
    private func plotArea(_ series: ClaudeQuotaSeries, facts: QuotaTrendFacts, scale: QuotaTrendScale,
                          longGap: TimeInterval, weeks: [ClaudeQuotaSeries.Cycle]) -> some View {
        let range = scale.range
        // Days can be picked in the weekly view with insights.
        let picksDays = showsInsights && facts.isWeekly
        let drawn = facts.drawnLane?.within(range) ?? series
        let companion = facts.drawnCompanion?.within(range)
        let pointer = self.pointer
        let maxPan = facts.maxPan
        // Per-segment source coloring is an estimate; when the
        // account reports the official breakdown, show that instead.
        return GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if picksDays {
                    QuotaDayColumns(scale: scale, selected: selectedDay).equatable()
                }
                ClaudeQuotaPlot(series: drawn, scale: scale, now: facts.now,
                                longGap: longGap,
                                showsLatest: series.samples.last == facts.lane?.samples.last
                                    && range.contains(series.samples.last?.timestamp ?? .distantPast),
                                showsSources: official == nil,
                                companion: companion)
                    .equatable()
                if showsInsights {
                    QuotaPaceOverlay(cycles: weeks, pace: range.end >= facts.now.addingTimeInterval(-60) ? facts.pace : nil,
                                     quiet: facts.quiet, scale: scale, now: facts.now)
                        .equatable()
                }
                QuotaHoverLayer(pointer: pointer, series: series, scale: scale, hidden: dragStartPan != nil)
            }
            .contentShape(Rectangle())
            .background(ChartPointerReader(
                onScroll: { deltaX in
                    scroll(by: deltaX / max(1, geometry.size.width - 32) * range.duration, maxPan: maxPan)
                },
                onHover: { pointer.move(to: $0) }))
            .gesture(drag(plotWidth: max(1, geometry.size.width - 32), facts: facts))
            .onTapGesture {
                // Clicking the plot picks the day under the pointer, or clears it.
                guard picksDays, let location = pointer.location, location.x <= geometry.size.width - 28,
                      let day = Calendar.current.dateInterval(of: .day, for: scale.date(at: location.x, width: geometry.size.width))
                else { return }
                selectedDay = selectedDay.map(day.contains) == true ? nil : day.start
            }
        }
    }

    /// The chart on an inset panel: range and navigation, the plot, labeled
    /// lanes under it, the axis, the 5-hour windows of a week, and a key.
    private func insightChart(_ series: ClaudeQuotaSeries, facts: QuotaTrendFacts) -> some View {
        let range = facts.range(pan: pan)
        let scale = QuotaTrendScale(range: range)
        let longGap = ClaudeQuotaSeries.longGap(over: range)
        let spans = series.recordedSpans(maxGap: longGap)
        let isWeekly = facts.isWeekly
        let hasCompanion = !isWeekly && facts.weeklyLane != nil
        let cycles = hasCompanion ? facts.weeklyCycles.filter { $0.overlaps(range) } : []
        let weeks = isWeekly ? facts.laneCycles.filter { $0.overlaps(range) } : []
        let windows = isWeekly ? facts.fiveHourCycles.filter { $0.overlaps(range) } : []
        let now = facts.now
        return VStack(alignment: .leading, spacing: 6) {
            navigation(facts)
            plotArea(series, facts: facts, scale: scale, longGap: longGap, weeks: weeks)
                .frame(height: 140)
            VStack(spacing: 5) {
                QuotaRecordedStrip(spans: spans, scale: scale).laneLabel(L("Logged"))
                if !cycles.isEmpty {
                    QuotaCycleStrip(cycles: cycles, scale: scale, now: now).laneLabel(L("Week"))
                }
            }
            if isWeekly {
                QuotaDayAxis(scale: scale, now: now, selected: $selectedDay)
                if let day = selectedDay.flatMap({ Calendar.current.dateInterval(of: .day, for: $0) }),
                   day.end > range.start, day.start < range.end, let lane = facts.lane
                {
                    QuotaDayDetail(day: day, weekly: lane, fiveHour: facts.fiveHourLane,
                                   fiveHourCycles: facts.fiveHourCycles, pace: facts.pace, now: now,
                                   showDay: facts.fiveHourLane == nil ? nil : {
                                       pendingDay = day.start
                                       selected = "five-hour"
                                   },
                                   close: { selectedDay = nil })
                        .padding(.top, 2)
                }
                QuotaWindowBars(windows: windows, scale: scale).equatable().padding(.top, 8)
                QuotaPaceKey(showsQuiet: facts.pace?.followsRhythm == true && range.end >= now).padding(.top, 6)
            } else {
                QuotaTimeAxis(scale: scale, now: now, daily: false)
                QuotaTrendKey(showsGaps: spans.count > 1, showsWeekly: hasCompanion).padding(.top, 6)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 12, trailing: 8))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
    }

    /// How many full 5-hour windows a week holds, and how many are left in this one.
    private func fiveHourAllowance(_ estimate: (perWeek: Double, remaining: Double, fromCurrent: Bool)) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(L("One week ≈ %@ full 5-hour windows · about %@ left this week",
                   String(format: "%.1f", estimate.perWeek), String(format: "%.1f", estimate.remaining)))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
            Text(L(estimate.fromCurrent ? "Estimated from this week's readings" : "Estimated from an earlier week's readings"))
                .font(.system(size: 9)).foregroundColor(.secondary)
        }
        .padding(.top, 4)
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
struct ChartPointerReader: NSViewRepresentable {
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

/// The hover readout, redrawn on its own as the pointer moves; the chart
/// under it stays as it is.
private struct QuotaHoverLayer: View {
    @ObservedObject var pointer: QuotaPointer
    let series: ClaudeQuotaSeries
    let scale: QuotaTrendScale
    /// Hidden while the chart is dragged.
    let hidden: Bool

    var body: some View {
        if !hidden, let location = pointer.location {
            QuotaHoverReadout(series: series, scale: scale, pointer: location)
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
            Text(DS.moment(sample.timestamp))
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

    /// Text drawn on the canvas, laid out once as symbols: text drawn
    /// straight onto the canvas is typeset again on every frame of a drag.
    private enum Label: Hashable {
        case percent(Int)
        case reset
    }

    /// Drawn as one canvas: a drag redraws the curve on every frame, and one
    /// view draws that far faster than a view for every run and connector.
    var body: some View {
        Canvas(renderer: { context, size in
            drawGrid(in: &context, size: size)
            drawNowMarker(in: &context, size: size)
            var plot = context
            plot.clip(to: PlotClip().path(in: CGRect(origin: .zero, size: size)))
            let runs = self.runs
            drawResetMarkers(in: &plot, size: size)
            plot.fill(area(runs, size: size), with: .linearGradient(
                Gradient(colors: [QuotaSourceStyle.claudeCode.opacity(0.22), QuotaSourceStyle.claudeCode.opacity(0.0)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            if let companion = companion, !companion.samples.isEmpty {
                plot.stroke(companionLine(companion, size: size), with: .color(QuotaTrendStyle.weekly),
                            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }
            for run in runs.dropFirst() { drawConnector(run[0], in: &plot, size: size) }
            for run in runs { drawRun(run, in: &plot, size: size) }
            if showsLatest { drawCurrentValue(in: &context, size: size) }
        }, symbols: {
            ForEach([0, 50, 100], id: \.self) { percent in
                Text("\(percent)%").font(.system(size: 8).monospacedDigit()).foregroundColor(.secondary)
                    .tag(Label.percent(percent))
            }
            Text(L("Reset")).font(.system(size: 8, weight: .medium)).foregroundColor(.secondary).tag(Label.reset)
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("%@ shared quota trend, 0 to 100 percent", series.title)))
        .accessibilityValue(Text(L("%d observations", series.samples.count)))
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        for percent in [0.0, 50.0, 100.0] {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y(percent, size)))
            path.addLine(to: CGPoint(x: size.width - 28, y: y(percent, size)))
            context.stroke(path, with: .color(Color.primary.opacity(percent == 0 ? 0.14 : 0.07)),
                           style: StrokeStyle(lineWidth: 0.5, dash: percent == 0 ? [] : [2, 3]))
            if let label = context.resolveSymbol(id: Label.percent(Int(percent))) {
                context.draw(label, at: CGPoint(x: size.width - 12, y: y(percent, size)))
            }
        }
    }

    /// Where "now" falls when the range runs on to the end of the billing cycle.
    private func drawNowMarker(in context: inout GraphicsContext, size: CGSize) {
        let nowX = x(now, size: size)
        guard x(scale.range.end, size: size) - nowX >= 3 else { return }
        var path = Path()
        path.move(to: CGPoint(x: nowX, y: 0))
        path.addLine(to: CGPoint(x: nowX, y: size.height - 6))
        context.stroke(path, with: .color(Color.secondary.opacity(0.3)), style: StrokeStyle(lineWidth: 0.6, dash: [2, 2]))
    }

    private func drawResetMarkers(in context: inout GraphicsContext, size: CGSize) {
        // Where the line drops: the old window's reset time. Every reset gets
        // a guide; a label that would collide with the previous one is left out.
        var lastLabel: CGFloat?
        for index in series.samples.indices.dropFirst() where series.hasReset(before: index) {
            let markerX = x(series.reset(before: index)?.end ?? series.windowStart(at: index), size: size)
            guard (0...(size.width - 28)).contains(markerX) else { continue }
            var path = Path()
            path.move(to: CGPoint(x: markerX, y: 0))
            path.addLine(to: CGPoint(x: markerX, y: size.height))
            context.stroke(path, with: .color(Color.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 0.6, dash: [2, 2]))
            guard lastLabel.map({ markerX - $0 >= 30 }) ?? true else { continue }
            lastLabel = markerX
            if let label = context.resolveSymbol(id: Label.reset) {
                context.draw(label, at: CGPoint(x: min(max(markerX, 12), size.width - 46), y: 4))
            }
        }
    }

    /// Area under the whole line (runs and connectors) as one path, so the
    /// fill has no seams where pieces meet.
    private func area(_ runs: [[Int]], size: CGSize) -> Path {
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

    private func connectorPoints(_ index: Int, size: CGSize) -> [CGPoint] {
        let previous = series.samples[index - 1], next = series.samples[index]
        let a = point(previous, size: size), b = point(next, size: size)
        guard let reset = series.reset(before: index) else { return [a, b] }
        let endX = x(reset.end, size: size), startX = x(reset.start, size: size), zero = y(0, size)
        return [a, CGPoint(x: endX, y: a.y), CGPoint(x: endX, y: zero), CGPoint(x: startX, y: zero), b]
    }

    /// The connector that joins the run starting at `index` to the one before it.
    private func drawConnector(_ index: Int, in context: inout GraphicsContext, size: CGSize) {
        let gap = series.samples[index].timestamp.timeIntervalSince(series.samples[index - 1].timestamp)
        context.stroke(line(connectorPoints(index, size: size), smooth: false),
                       with: .color(gap > longGap ? QuotaTrendStyle.unrecorded : QuotaSourceStyle.claudeCode),
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

    private func drawRun(_ run: [Int], in context: inout GraphicsContext, size: CGSize) {
        let points = run.map { point(series.samples[$0], size: size) }
        if points.count > 1 {
            // One continuous stroke per run, then the other-device segments
            // on top, so joints never show as dashes.
            context.stroke(line(points, smooth: true), with: .color(QuotaSourceStyle.claudeCode),
                           style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            for i in otherDeviceSegments(run) {
                context.stroke(segmentPath(points, i), with: .color(QuotaSourceStyle.otherDevices),
                               style: StrokeStyle(lineWidth: 2.4, lineCap: .butt, lineJoin: .round))
            }
        } else if series.samples.count == 1, let only = points.first {
            context.fill(Path(ellipseIn: CGRect(x: only.x - 2, y: only.y - 2, width: 4, height: 4)),
                         with: .color(QuotaSourceStyle.claudeCode))
        }
    }

    private func drawCurrentValue(in context: inout GraphicsContext, size: CGSize) {
        guard let last = series.samples.last else { return }
        let position = point(last, size: size)
        func circle(_ diameter: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: position.x - diameter / 2, y: position.y - diameter / 2, width: diameter, height: diameter))
        }
        context.fill(circle(16), with: .color(QuotaSourceStyle.claudeCode.opacity(0.18)))
        context.fill(circle(7), with: .color(QuotaSourceStyle.claudeCode))
        context.stroke(circle(7), with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 1.5)
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

    /// Tooltips and the spoken summary are rebuilt with the strip on every
    /// frame of a drag, so each span's text is worked out once.
    private static var descriptions: [DateInterval: String] = [:]
    private static var descriptionsContext = ""

    private static func describe(_ span: DateInterval) -> String {
        let context = "\(L10n.usesChinese)|\(TimeZone.current.identifier)"
        if descriptionsContext != context || descriptions.count > 2000 {
            descriptions.removeAll()
            descriptionsContext = context
        }
        if let text = descriptions[span] { return text }
        let text = describeAnew(span)
        descriptions[span] = text
        return text
    }

    private static func describeAnew(_ span: DateInterval) -> String {
        let start = DS.moment(span.start)
        guard span.duration > 0 else { return L("Recorded %@", start) }
        let sameDay = Calendar.current.isDate(span.start, inSameDayAs: span.end)
        let end = DS.moment(span.end, withDate: !sameDay)
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
        let span = L("Weekly window %@ – %@", DS.moment(cycle.interval.start), DS.moment(cycle.interval.end))
        let spent = cycle.exhausted.map { L("Used up %@", DS.moment($0.start)) }
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
