import SwiftUI

enum QuotaInsightStyle {
    static let brand = QuotaSourceStyle.claudeCode
    /// The even-pace guide through a window.
    static let even = Color.secondary.opacity(0.5)
    static let usedUp = Color(nsColor: .systemRed)
    static let fast = Color(nsColor: .systemOrange)
    static let slow = Color(nsColor: .systemGreen)
    static let calm = Color(nsColor: .systemBlue)
}

enum InsightFormat {
    /// "Wed 21:00" / "周三 21:00".
    static func moment(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate("EEEHHmm")
        return formatter.string(from: date)
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return formatter.string(from: date)
    }

    static func duration(_ seconds: TimeInterval, now: Date = Date()) -> String {
        DS.countdown(to: now.addingTimeInterval(max(60, seconds)), now: now) ?? "—"
    }

    static func hour(_ hour: Int) -> String { String(format: "%d:00", hour % 24) }

    static func count(_ value: Double) -> String { String(format: value >= 10 ? "%.0f" : "%.1f", value) }

    static func percent(_ value: Double) -> String { String(format: "%.0f", value) }
}

// MARK: - Trend overlays

/// Even-pace guides through each weekly window, its used-up stretches and the
/// projected run-out, drawn in the trend plot's coordinates.
struct QuotaPaceOverlay: View, Equatable {
    let cycles: [ClaudeQuotaSeries.Cycle]
    let pace: QuotaPace?
    let scale: QuotaTrendScale
    let now: Date

    var body: some View {
        Canvas { context, size in
            for cycle in cycles {
                drawUsedUp(cycle, in: &context, size: size)
                drawGuide(cycle, in: &context, size: size)
            }
            if let pace = pace { drawProjection(pace, in: &context, size: size) }
        }
        .clipShape(PlotClip())
        .allowsHitTesting(false)
    }

    private func point(_ date: Date, _ percent: Double, _ size: CGSize) -> CGPoint {
        CGPoint(x: scale.position(date, width: size.width), y: QuotaTrendScale.plotY(percent, height: size.height))
    }

    private func drawGuide(_ cycle: ClaudeQuotaSeries.Cycle, in context: inout GraphicsContext, size: CGSize) {
        var guide = Path()
        guide.move(to: point(cycle.interval.start, 0, size))
        guide.addLine(to: point(cycle.interval.end, 100, size))
        context.stroke(guide, with: .color(QuotaInsightStyle.even), style: StrokeStyle(lineWidth: 0.9, dash: [3, 3]))
    }

    private func drawUsedUp(_ cycle: ClaudeQuotaSeries.Cycle, in context: inout GraphicsContext, size: CGSize) {
        for span in cycle.exhausted {
            let left = scale.position(span.start, width: size.width)
            let right = scale.position(min(span.end, now), width: size.width)
            guard right > left + 1 else { continue }
            let rect = CGRect(x: left, y: 2, width: right - left, height: size.height - 8)
            var stripes = Path()
            var x = left - rect.height
            while x < right {
                stripes.move(to: CGPoint(x: x, y: rect.maxY))
                stripes.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                x += 5
            }
            var clipped = context
            clipped.clip(to: Path(rect))
            clipped.fill(Path(rect), with: .color(QuotaInsightStyle.usedUp.opacity(0.05)))
            clipped.stroke(stripes, with: .color(QuotaInsightStyle.usedUp.opacity(0.2)), lineWidth: 0.7)
        }
    }

    private func drawProjection(_ pace: QuotaPace, in context: inout GraphicsContext, size: CGSize) {
        guard pace.isMeasured, !pace.isExhausted, pace.ratePerHour > 0.01 else { return }
        let start = point(now, pace.usedPercent, size)
        let end = pace.runsOutAt.map { point($0, 100, size) }
            ?? point(pace.cycle.end, pace.projectedAtReset(now: now), size)
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(path, with: .color(QuotaInsightStyle.brand.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 1.3, lineCap: .round, dash: [4, 3]))
        let dot = Path(ellipseIn: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6))
        context.fill(dot, with: .color(Color(nsColor: .windowBackgroundColor)))
        context.stroke(dot, with: .color(QuotaInsightStyle.brand), lineWidth: 1.3)
    }
}

/// Each 5-hour window as a bar as wide as the window and as tall as its peak;
/// used-up windows are solid, so a week's allowance can be counted at a glance.
struct QuotaWindowBars: View, Equatable {
    let windows: [ClaudeQuotaSeries.Cycle]
    let scale: QuotaTrendScale

    private var used: [ClaudeQuotaSeries.Cycle] { windows.filter { $0.peakPercent > 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(L("5-hour windows"))
                Spacer(minLength: 4)
                Text(L("%d used · %d used up", used.count, used.filter { !$0.exhausted.isEmpty }.count))
                    .monospacedDigit()
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.trailing, 28)
            Canvas { context, size in draw(in: &context, size: size) }
                .frame(height: 26)
        }
        .accessibilityElement(children: .combine)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let plot = CGRect(x: 0, y: 0, width: max(0, size.width - 25), height: size.height)
        context.clip(to: Path(plot))
        var baseline = Path()
        baseline.move(to: CGPoint(x: 4, y: size.height - 0.5))
        baseline.addLine(to: CGPoint(x: size.width - 28, y: size.height - 0.5))
        context.stroke(baseline, with: .color(Color.primary.opacity(0.12)), lineWidth: 0.5)
        for window in used {
            let left = scale.position(window.interval.start, width: size.width) + 0.5
            let right = scale.position(window.interval.end, width: size.width) - 0.5
            guard right > left else { continue }
            let height = max(1.5, CGFloat(min(100, window.peakPercent) / 100) * (size.height - 2))
            let rect = CGRect(x: left, y: size.height - 1 - height, width: right - left, height: height)
            let spent = !window.exhausted.isEmpty
            let opacity = spent ? 0.9 : 0.22 + 0.38 * min(1, window.peakPercent / 100)
            context.fill(Path(roundedRect: rect, cornerRadius: min(1.5, rect.width / 2)),
                         with: .color(QuotaInsightStyle.brand.opacity(opacity)))
        }
    }
}

/// Explains the pace chart's marks.
struct QuotaPaceKey: View {
    var body: some View {
        HStack(spacing: 12) {
            swatch(L("Weekly usage")) { path in
                path.move(to: CGPoint(x: 0, y: 3)); path.addLine(to: CGPoint(x: 12, y: 3))
            }
            .foregroundColor(QuotaInsightStyle.brand)
            dashed(L("Even pace"), color: QuotaInsightStyle.even)
            dashed(L("Projected"), color: QuotaInsightStyle.brand)
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5).fill(QuotaInsightStyle.usedUp.opacity(0.25)).frame(width: 12, height: 6)
                Text(L("Used up"))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 9))
        .foregroundColor(.secondary)
    }

    private func swatch(_ title: String, _ shape: @escaping (inout Path) -> Void) -> some View {
        HStack(spacing: 5) {
            Path(shape).stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round)).frame(width: 12, height: 6)
            Text(title).foregroundColor(.secondary)
        }
    }

    private func dashed(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 3)); path.addLine(to: CGPoint(x: 12, y: 3))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
            .frame(width: 12, height: 6)
            Text(title)
        }
    }
}

/// One line under the trend's big numbers: ahead of or behind an even pace,
/// and when the window runs out at the current rate.
struct QuotaPaceSummary: View {
    let pace: QuotaPace
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            chip
            Text(detail)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var tint: Color {
        if pace.isExhausted { return QuotaInsightStyle.usedUp }
        if pace.ahead > 3 { return QuotaInsightStyle.fast }
        if pace.ahead < -3 { return QuotaInsightStyle.slow }
        return QuotaInsightStyle.calm
    }

    private var chipText: String {
        if pace.isExhausted { return L("Used up") }
        if pace.ahead > 3 { return L("%@ pts ahead of pace", InsightFormat.percent(pace.ahead)) }
        if pace.ahead < -3 { return L("%@ pts under pace", InsightFormat.percent(-pace.ahead)) }
        return L("On an even pace")
    }

    private var chip: some View {
        Text(chipText)
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundColor(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.13)))
            .fixedSize()
    }

    private var detail: String {
        if pace.isExhausted {
            return L("Resets in %@", InsightFormat.duration(pace.cycle.end.timeIntervalSince(now), now: now))
        }
        guard pace.isMeasured else { return L("A forecast follows once there are more readings.") }
        if let runsOut = pace.runsOutAt {
            return L("At this rate it runs out %@, %@ before the reset", InsightFormat.moment(runsOut),
                     InsightFormat.duration(pace.cycle.end.timeIntervalSince(runsOut), now: now))
        }
        return L("At this rate it lasts until the reset, about %@%% used", InsightFormat.percent(pace.projectedAtReset(now: now)))
    }
}

// MARK: - Insights card

/// Shown after the quota trend when the insights style is chosen.
struct ClaudeUsageInsightsSection: View {
    let dashboard: ProviderDashboard
    var now = Date()
    @AppStorage(QuotaChartMode.preferenceKey) private var mode = QuotaChartMode.insights.rawValue

    var body: some View {
        if QuotaChartMode(rawValue: mode) ?? .insights == .insights {
            ClaudeUsageInsightsCard(dashboard: dashboard, now: now)
        }
    }
}

/// A personal summary of pace and habits, how large the official weekly
/// allowance is in 5-hour windows and whether that changed, and when the
/// quota gets used through the week.
struct ClaudeUsageInsightsCard: View {
    let dashboard: ProviderDashboard
    let now: Date

    private struct Bullet: Identifiable {
        let id: String
        let symbol: String
        let tint: Color
        let title: String
        let detail: String?
    }

    var body: some View {
        if let insights = ClaudeQuotaInsights.make(history: dashboard.claudeQuotaHistory, now: now),
           insights.habits.grid.contains(where: { $0.contains { $0 > 0 } })
        {
            DSCard(padding: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    VStack(alignment: .leading, spacing: 11) {
                        ForEach(bullets(insights)) { bulletRow($0) }
                    }
                    hairline
                    QuotaScaleSection(trend: insights.scale, costLine: costLine)
                    hairline
                    QuotaHabitHeatmap(habits: insights.habits)
                    Text(L("From the quota readings recorded on this Mac while AIUsageBar runs."))
                        .font(.system(size: 9)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Label(L("Usage insights"), systemImage: "sparkles")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(L("Last 4 weeks")).font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private var hairline: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
    }

    private func bulletRow(_ bullet: Bullet) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(bullet.tint.opacity(0.13))
                Image(systemName: bullet.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(bullet.tint)
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(bullet.title).font(.system(size: 12, weight: .medium))
                if let detail = bullet.detail {
                    Text(detail).font(.system(size: 10)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func bullets(_ insights: ClaudeQuotaInsights) -> [Bullet] {
        [paceBullet(insights.weeklyPace), changeBullet(insights.paceChange),
         hoursBullet(insights.habits), drainBullet(insights.habits)].compactMap { $0 }
    }

    private func paceBullet(_ pace: QuotaPace?) -> Bullet? {
        guard let pace = pace else { return nil }
        if pace.isExhausted {
            return Bullet(id: "pace", symbol: "exclamationmark.circle", tint: QuotaInsightStyle.usedUp,
                          title: L("This week's quota is used up"),
                          detail: L("Resets in %@", InsightFormat.duration(pace.cycle.end.timeIntervalSince(now), now: now)))
        }
        guard pace.isMeasured else {
            return Bullet(id: "pace", symbol: "speedometer", tint: QuotaInsightStyle.calm,
                          title: L("The week has just started"),
                          detail: L("%@%% used so far. A forecast follows once there are more readings.",
                                    InsightFormat.percent(pace.usedPercent)))
        }
        if let runsOut = pace.runsOutAt {
            return Bullet(id: "pace", symbol: "speedometer", tint: QuotaInsightStyle.fast,
                          title: L("On course to run out early"),
                          detail: L("At the last day's rate it runs out %@, %@ before the reset.",
                                    InsightFormat.moment(runsOut),
                                    InsightFormat.duration(pace.cycle.end.timeIntervalSince(runsOut), now: now)))
        }
        return Bullet(id: "pace", symbol: "speedometer", tint: QuotaInsightStyle.slow,
                      title: L("On course to last the week"),
                      detail: L("At the last day's rate about %@%% is used by the reset.",
                                InsightFormat.percent(pace.projectedAtReset(now: now))))
    }

    private func changeBullet(_ change: Double?) -> Bullet? {
        guard let change = change else { return nil }
        let detail = L("Weekly quota used per hour, this week against the previous one.")
        if abs(change) < 0.1 {
            return Bullet(id: "change", symbol: "equal.circle", tint: QuotaInsightStyle.calm,
                          title: L("About as fast as last week"), detail: detail)
        }
        let percent = InsightFormat.percent(abs(change) * 100)
        return change > 0
            ? Bullet(id: "change", symbol: "arrow.up.right", tint: QuotaInsightStyle.fast,
                     title: L("%@%% faster than last week", percent), detail: detail)
            : Bullet(id: "change", symbol: "arrow.down.right", tint: QuotaInsightStyle.slow,
                     title: L("%@%% slower than last week", percent), detail: detail)
    }

    private func hoursBullet(_ habits: QuotaHabits) -> Bullet? {
        guard let first = habits.peakHours.first else { return nil }
        let title = habits.peakHours.count > 1
            ? L("Busiest around %@ and %@", InsightFormat.hour(first), InsightFormat.hour(habits.peakHours[1]))
            : L("Busiest around %@", InsightFormat.hour(first))
        let detail = habits.quietStart.map {
            L("Hardly used from %@ to %@.", InsightFormat.hour($0), InsightFormat.hour($0 + habits.quietLength))
        }
        return Bullet(id: "hours", symbol: "clock", tint: QuotaInsightStyle.brand, title: title, detail: detail)
    }

    private func drainBullet(_ habits: QuotaHabits) -> Bullet? {
        guard habits.windowsUsed > 0 else { return nil }
        let detail = L("%d of %d 5-hour windows in the last two weeks were used up.",
                       habits.windowsUsedUp, habits.windowsUsed)
        guard let drain = habits.drainTime else {
            return Bullet(id: "drain", symbol: "hourglass", tint: QuotaInsightStyle.slow,
                          title: L("No 5-hour window used up lately"), detail: detail)
        }
        return Bullet(id: "drain", symbol: "hourglass", tint: QuotaInsightStyle.fast,
                      title: L("A full 5-hour window lasts about %@", InsightFormat.duration(drain, now: now)),
                      detail: detail)
    }

    /// Cost of 1% of the weekly quota in local API-equivalent use, only when
    /// Claude Code is most of the account's use; otherwise why it is left out.
    @MainActor private var costLine: String? {
        guard let history = dashboard.usageCostHistory,
              let weekly = dashboard.claudeQuotaHistory.first(where: { $0.id == "weekly" }),
              let share = dashboard.claudeProductBreakdown?.rows.first(where: { $0.key == "claude_code" })?.percent
        else { return nil }
        guard share >= 70 else {
            return L("Claude Code is %@%% of this week's use, so a cost per point would mislead.", InsightFormat.percent(share))
        }
        let since = Calendar.current.startOfDay(for: now.addingTimeInterval(-6 * 86_400))
        let points = weekly.consumedPoints(in: DateInterval(start: since, end: now))
        guard points >= 10, let cost = history.costEstimate(since: since, now: now).knownCost, cost > 0 else { return nil }
        return L("1%% of the weekly quota ≈ %@ of API-equivalent use on this Mac (last 7 days).",
                 CurrencySettingsStore.shared.display.format(cost / points))
    }
}

/// How many full 5-hour windows the weekly quota holds, day by day, with the
/// typical value before and after a change.
struct QuotaScaleSection: View {
    let trend: QuotaScaleTrend
    let costLine: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DSSectionLabel(title: L("Quota size"), symbol: "ruler")
            if let current = trend.current, trend.points.count >= 2 {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(InsightFormat.count(current)).font(.system(size: 26, weight: .light, design: .rounded).monospacedDigit())
                    Text(L("full 5-hour windows per week")).font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer(minLength: 4)
                    if let shift = trend.shift { shiftChip(shift) }
                }
                QuotaScaleChart(trend: trend).frame(height: 78)
                Text(caption).font(.system(size: 10)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("Needs a few days with weekly use to compare."))
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            if let costLine = costLine {
                Text(costLine).font(.system(size: 10)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var caption: String {
        guard let shift = trend.shift else { return L("Steady: no clear change in the weekly allowance.") }
        let day = InsightFormat.day(shift.day)
        let after = InsightFormat.count(shift.after), before = InsightFormat.count(shift.before)
        return shift.change < 0
            ? L("Since %@ a week holds about %@ windows, down from %@. A smaller weekly limit, a larger 5-hour limit, or a change of plan or models can cause this.", day, after, before)
            : L("Since %@ a week holds about %@ windows, up from %@. A larger weekly limit, a smaller 5-hour limit, or a change of plan or models can cause this.", day, after, before)
    }

    private func shiftChip(_ shift: QuotaScaleTrend.Shift) -> some View {
        let shrank = shift.change < 0
        let tint = shrank ? QuotaInsightStyle.usedUp : QuotaInsightStyle.slow
        return HStack(spacing: 3) {
            Image(systemName: shrank ? "arrow.down.right" : "arrow.up.right").font(.system(size: 9, weight: .bold))
            Text(L("%@ since %@", InsightFormat.percent(abs(shift.change) * 100) + "%", InsightFormat.day(shift.day)))
        }
        .font(.system(size: 10, weight: .semibold).monospacedDigit())
        .foregroundColor(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.12)))
        .fixedSize()
    }
}

/// Daily values as dots on a faint line, with the typical level before and
/// after a change drawn across each side.
struct QuotaScaleChart: View {
    let trend: QuotaScaleTrend

    var body: some View {
        Canvas { context, size in draw(in: &context, size: size) }
            .accessibilityElement()
            .accessibilityLabel(Text(L("Quota size")))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard let first = trend.points.first?.day, let last = trend.points.last?.day else { return }
        let plot = CGRect(x: 4, y: 6, width: max(1, size.width - 34), height: max(1, size.height - 22))
        let top = (trend.points.map(\.windowsPerWeek).max() ?? 1) * 1.15
        let span = max(1, last.timeIntervalSince(first))
        func x(_ day: Date) -> CGFloat { plot.minX + CGFloat(day.timeIntervalSince(first) / span) * plot.width }
        func y(_ value: Double) -> CGFloat { plot.maxY - CGFloat(value / top) * plot.height }
        var baseline = Path()
        baseline.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        baseline.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        context.stroke(baseline, with: .color(Color.primary.opacity(0.12)), lineWidth: 0.5)
        if let shift = trend.shift { drawLevels(shift, first: first, last: last, x: x, y: y, plot: plot, in: &context) }
        var line = Path()
        for (index, point) in trend.points.enumerated() {
            let position = CGPoint(x: x(point.day), y: y(point.windowsPerWeek))
            if index == 0 { line.move(to: position) } else { line.addLine(to: position) }
        }
        context.stroke(line, with: .color(QuotaInsightStyle.brand.opacity(0.3)), lineWidth: 1)
        for point in trend.points {
            let center = CGPoint(x: x(point.day), y: y(point.windowsPerWeek))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 2.2, y: center.y - 2.2, width: 4.4, height: 4.4)),
                         with: .color(QuotaInsightStyle.brand))
        }
        var labels: [(String, CGFloat)] = [(InsightFormat.day(first), plot.minX), (InsightFormat.day(last), plot.maxX)]
        if let shift = trend.shift, x(shift.day) - plot.minX > 30, plot.maxX - x(shift.day) > 30 {
            labels.append((InsightFormat.day(shift.day), x(shift.day)))
        }
        for (text, position) in labels {
            context.draw(Text(text).font(.system(size: 8).monospacedDigit()).foregroundColor(.secondary),
                         at: CGPoint(x: min(max(position, plot.minX + 10), plot.maxX - 10), y: size.height - 5))
        }
    }

    private func drawLevels(_ shift: QuotaScaleTrend.Shift, first: Date, last: Date,
                            x: (Date) -> CGFloat, y: (Double) -> CGFloat, plot: CGRect,
                            in context: inout GraphicsContext)
    {
        let split = x(shift.day)
        var divider = Path()
        divider.move(to: CGPoint(x: split, y: plot.minY))
        divider.addLine(to: CGPoint(x: split, y: plot.maxY))
        context.stroke(divider, with: .color(Color.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 0.6, dash: [2, 2]))
        var before = Path()
        before.move(to: CGPoint(x: x(first), y: y(shift.before)))
        before.addLine(to: CGPoint(x: split, y: y(shift.before)))
        context.stroke(before, with: .color(Color.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
        var after = Path()
        after.move(to: CGPoint(x: split, y: y(shift.after)))
        after.addLine(to: CGPoint(x: x(last), y: y(shift.after)))
        context.stroke(after, with: .color(QuotaInsightStyle.brand), lineWidth: 1.6)
        let font = Font.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit()
        context.draw(Text(InsightFormat.count(shift.before)).font(font).foregroundColor(.secondary),
                     at: CGPoint(x: x(first) + 9, y: y(shift.before) - 7), anchor: .leading)
        context.draw(Text(InsightFormat.count(shift.after)).font(font).foregroundColor(QuotaInsightStyle.brand),
                     at: CGPoint(x: plot.maxX + 5, y: y(shift.after)), anchor: .leading)
    }
}

/// When the 5-hour quota gets used, by weekday and hour, as a weekly average.
struct QuotaHabitHeatmap: View {
    let habits: QuotaHabits

    private static let rowHeight: CGFloat = 9
    private static let gap: CGFloat = 2
    private static let labelWidth: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSectionLabel(title: L("When you use it"), symbol: "calendar", trailing: L("Average week"))
            Canvas { context, size in draw(in: &context, size: size) }
                .frame(height: 7 * (Self.rowHeight + Self.gap) + 12)
                .accessibilityElement()
                .accessibilityLabel(Text(L("When you use it")))
            HStack(spacing: 4) {
                Spacer()
                Text(L("Less"))
                ForEach(0..<5) { step in
                    RoundedRectangle(cornerRadius: 2).fill(color(Double(step) / 4)).frame(width: 9, height: 9)
                }
                Text(L("More"))
            }
            .font(.system(size: 9))
            .foregroundColor(.secondary)
        }
    }

    private func color(_ level: Double) -> Color {
        level <= 0 ? Color.primary.opacity(0.05) : QuotaInsightStyle.brand.opacity(0.12 + 0.83 * level)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let top = habits.grid.flatMap { $0 }.max() ?? 0
        let cellWidth = (size.width - Self.labelWidth - 23 * Self.gap) / 24
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = L10n.locale
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        for row in 0..<7 {
            let y = CGFloat(row) * (Self.rowHeight + Self.gap)
            // Monday first: the calendar's symbols start on Sunday.
            context.draw(Text(symbols[(row + 1) % 7]).font(.system(size: 8)).foregroundColor(.secondary),
                         at: CGPoint(x: 0, y: y + Self.rowHeight / 2), anchor: .leading)
            for hour in 0..<24 {
                let value = habits.grid[row][hour]
                let level = top > 0 ? (value / top).squareRoot() : 0
                let rect = CGRect(x: Self.labelWidth + CGFloat(hour) * (cellWidth + Self.gap), y: y,
                                  width: cellWidth, height: Self.rowHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color(level)))
            }
        }
        let axisY = 7 * (Self.rowHeight + Self.gap) + 5
        for hour in [0, 6, 12, 18] {
            let x = Self.labelWidth + CGFloat(hour) * (cellWidth + Self.gap)
            context.draw(Text(InsightFormat.hour(hour)).font(.system(size: 8).monospacedDigit()).foregroundColor(.secondary),
                         at: CGPoint(x: x, y: axisY), anchor: .leading)
        }
    }
}
