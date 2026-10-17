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
            if let pace = pace { drawQuiet(pace, in: &context, size: size) }
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

    /// The stretches of three hours or more ahead that are usually quiet, up
    /// to the projected run-out, faintly shaded with a moon where there is
    /// room: the forecast stays flat across them.
    private func drawQuiet(_ pace: QuotaPace, in context: inout GraphicsContext, size: CGSize) {
        guard let rhythm = pace.rhythm, pace.followsRhythm, !pace.isExhausted else { return }
        let end = max(now, pace.runsOutAt ?? pace.cycle.end)
        var runs: [DateInterval] = []
        var start: Date?
        for piece in QuotaUsageRhythm.hours(in: DateInterval(start: now, end: end), calendar: rhythm.calendar) {
            if rhythm.isQuiet(at: piece.start) {
                if start == nil { start = piece.start }
            } else if let first = start {
                runs.append(DateInterval(start: first, end: piece.start))
                start = nil
            }
        }
        if let first = start { runs.append(DateInterval(start: first, end: max(first, end))) }
        for run in runs where run.duration >= 3 * 3600 || run.start == now || run.end == end {
            let left = scale.position(run.start, width: size.width), right = scale.position(run.end, width: size.width)
            guard right > left + 0.5 else { continue }
            let rect = CGRect(x: left, y: 0, width: right - left, height: size.height - 6)
            context.fill(Path(rect), with: .color(Color.primary.opacity(0.035)))
            if rect.width >= 12 {
                context.draw(Text(Image(systemName: "moon.fill")).font(.system(size: 6.5)).foregroundColor(.secondary.opacity(0.7)),
                             at: CGPoint(x: rect.midX, y: 7))
            }
        }
    }

    private func drawProjection(_ pace: QuotaPace, in context: inout GraphicsContext, size: CGSize) {
        guard pace.isMeasured, !pace.isExhausted, pace.ratePerHour > 0.01 else { return }
        let start = point(now, pace.usedPercent, size)
        var path = Path()
        path.move(to: start)
        if pace.followsRhythm {
            for step in pace.forecast { path.addLine(to: point(step.date, step.percent, size)) }
        } else {
            path.addLine(to: pace.runsOutAt.map { point($0, 100, size) }
                ?? point(pace.cycle.end, pace.projectedAtReset(now: now), size))
        }
        let end = path.currentPoint ?? start
        context.stroke(path, with: .color(QuotaInsightStyle.brand.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round, dash: [4, 3]))
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
    /// Whether the forecast follows the usual rhythm, with its quiet hours shaded.
    var showsQuiet = false

    /// The lines on one row; the shaded marks join them, or take a second
    /// row when the quiet hours are shown too.
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                lines
                if !showsQuiet { usedUp }
                Spacer(minLength: 0)
            }
            if showsQuiet {
                HStack(spacing: 12) {
                    usedUp
                    HStack(spacing: 5) {
                        Image(systemName: "moon.fill").font(.system(size: 6.5))
                            .frame(width: 12, height: 9)
                            .background(RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.08)))
                        Text(L("Usually idle"))
                    }
                    .help(L("The forecast follows how you used the quota hour by hour over the last 4 weeks, so the hours you are usually asleep or away add nothing."))
                    Spacer(minLength: 0)
                }
            }
        }
        .font(.system(size: 9))
        .foregroundColor(.secondary)
    }

    @ViewBuilder
    private var lines: some View {
        swatch(L("Weekly usage")) { path in
            path.move(to: CGPoint(x: 0, y: 3)); path.addLine(to: CGPoint(x: 12, y: 3))
        }
        .foregroundColor(QuotaInsightStyle.brand)
        dashed(L("Even pace"), color: QuotaInsightStyle.even)
        dashed(L("Projected"), color: QuotaInsightStyle.brand)
    }

    private var usedUp: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5).fill(QuotaInsightStyle.usedUp.opacity(0.25)).frame(width: 12, height: 6)
            Text(L("Used up"))
        }
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

// MARK: - Days of a weekly range

enum QuotaDays {
    /// The calendar days that overlap `range`, whole.
    static func days(in range: DateInterval, calendar: Calendar = .current) -> [DateInterval] {
        var result: [DateInterval] = []
        var day = calendar.dateInterval(of: .day, for: range.start)
        while let current = day, current.start < range.end, result.count < 64 {
            result.append(current)
            day = calendar.dateInterval(of: .day, for: current.end)
        }
        return result
    }
}

/// Midnight guides through the plot of a weekly range, with the chosen day shaded.
struct QuotaDayColumns: View, Equatable {
    let scale: QuotaTrendScale
    let selected: Date?

    var body: some View {
        Canvas { context, size in
            let bottom = size.height - 6
            let days = QuotaDays.days(in: scale.range)
            if let selected = selected, let day = days.first(where: { $0.contains(selected) }) {
                let left = scale.x(day.start, width: size.width), right = scale.x(day.end, width: size.width)
                if right > left {
                    context.fill(Path(roundedRect: CGRect(x: left, y: 0, width: right - left, height: bottom), cornerRadius: 3),
                                 with: .color(QuotaInsightStyle.brand.opacity(0.09)))
                }
            }
            for day in days.dropFirst() {
                let x = scale.x(day.start, width: size.width)
                var line = Path()
                line.move(to: CGPoint(x: x, y: 6))
                line.addLine(to: CGPoint(x: x, y: bottom))
                context.stroke(line, with: .color(Color.primary.opacity(0.07)), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
    }
}

/// One column per day under a weekly range: the weekday over the date, cut
/// by a tick at each midnight. Clicking a day selects it, and again clears it.
struct QuotaDayAxis: View {
    let scale: QuotaTrendScale
    let now: Date
    @Binding var selected: Date?

    private static let weekday: DateFormatter = formatter("EEE")
    private static let date: DateFormatter = formatter("d")
    private static let full: DateFormatter = formatter("MMMMdEEEE")

    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                ForEach(QuotaDays.days(in: scale.range), id: \.self) { day in
                    column(day, width: width)
                }
            }
        }
        .frame(height: 26)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L("Days")))
    }

    private func column(_ day: DateInterval, width: CGFloat) -> some View {
        let left = scale.x(day.start, width: width), right = scale.x(day.end, width: width)
        let isSelected = selected.map(day.contains) ?? false
        let isToday = day.contains(now)
        let isFuture = day.start > now
        let tint: Color = isToday ? QuotaInsightStyle.brand : isFuture ? .secondary.opacity(0.6) : .secondary
        return VStack(spacing: 1) {
            if right - left >= 18 {
                Text(Self.weekday.string(from: day.start)).font(.system(size: 8.5))
                Text(Self.date.string(from: day.start))
                    .font(.system(size: 10, weight: isToday || isSelected ? .semibold : .regular).monospacedDigit())
            }
        }
        .foregroundColor(isSelected ? .primary : tint)
        .lineLimit(1)
        .frame(width: max(1, right - left - 2), height: 26)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isSelected ? QuotaInsightStyle.brand.opacity(0.16) : Color.clear))
        .overlay(alignment: .topLeading) {
            Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 0.5, height: 4).offset(x: -1)
        }
        .contentShape(Rectangle())
        .onTapGesture { selected = isSelected ? nil : day.start }
        .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        .help(L("%@ · click for details", Self.full.string(from: day.start)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(Text(Self.full.string(from: day.start)))
        .position(x: (left + right) / 2, y: 13)
    }
}

/// What happened on the chosen day of the weekly range, or, ahead of now,
/// what the forecast expects of it.
struct QuotaDayDetail: View {
    let day: DateInterval
    let weekly: ClaudeQuotaSeries
    let fiveHour: ClaudeQuotaSeries?
    let pace: QuotaPace?
    let now: Date
    let showDay: (() -> Void)?
    let close: () -> Void

    private var isToday: Bool { day.contains(now) }
    private var isFuture: Bool { day.start > now }

    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static let title = formatter("MMMMdEEEE")
    private static let time = formatter("HHmm")

    /// Weekly points used that day, timed at the reading that shows each rise.
    private var used: Double {
        weekly.within(day).consumptionSteps().filter { day.contains($0.timestamp) }.reduce(0) { $0 + $1.points }
    }

    /// First and last rise of the day, from the finer 5-hour readings when there are any.
    private var active: (start: Date, end: Date)? {
        let steps = (fiveHour ?? weekly).within(day).consumptionSteps().filter { day.contains($0.timestamp) }
        guard let first = steps.first, let last = steps.last else { return nil }
        return (first.timestamp, last.timestamp)
    }

    private var windows: [ClaudeQuotaSeries.Cycle] {
        (fiveHour?.cycles() ?? []).filter { day.contains($0.interval.start) && $0.interval.start < day.end && $0.peakPercent > 0 }
    }

    /// Points the forecast expects for the rest of the day.
    private var expected: Double? {
        guard let pace = pace, pace.isMeasured, !pace.isExhausted, pace.cycle.end > now, day.end > now else { return nil }
        let from = max(day.start, now), to = min(day.end, pace.cycle.end)
        guard to > from else { return nil }
        return max(0, pace.projectedPercent(at: to, now: now) - pace.projectedPercent(at: from, now: now))
    }

    /// The longest usually quiet stretch of that weekday.
    private var quiet: (start: Int, end: Int)? {
        guard let rhythm = pace?.rhythm, pace?.followsRhythm == true else { return nil }
        var best: (start: Int, end: Int)?
        var start: Int?
        for hour in 0...24 {
            let date = day.start.addingTimeInterval(Double(hour) * 3600)
            if hour < 24, rhythm.isQuiet(at: date) {
                if start == nil { start = hour }
            } else if let first = start {
                if hour - first > (best.map { $0.end - $0.start } ?? 1) { best = (first, hour) }
                start = nil
            }
        }
        return best
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(Self.title.string(from: day.start)).font(.system(size: 11, weight: .semibold))
                if isToday || isFuture { tag(isToday ? L("Today") : L("Forecast")) }
                Spacer(minLength: 4)
                if let showDay = showDay, !isFuture {
                    Button(action: showDay) {
                        HStack(spacing: 2) {
                            Text(L("24-hour view"))
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.accentColor)
                    .help(L("Show this day in the 5-hour view"))
                }
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help(L("Close"))
                .accessibilityLabel(Text(L("Close")))
            }
            figures
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    @ViewBuilder
    private var figures: some View {
        let used = isFuture ? 0 : self.used
        let expected = self.expected
        HStack(alignment: .top, spacing: 14) {
            if !isFuture {
                figure("+" + InsightFormat.percent(used) + "%", caption: L("Weekly quota used"))
            }
            if let expected = expected, isToday || isFuture {
                figure("≈ +" + InsightFormat.percent(expected) + "%",
                       caption: isToday ? L("Expected later today") : L("Expected"), tint: QuotaInsightStyle.brand)
            }
            if !isFuture, !windows.isEmpty {
                let usedUp = windows.filter { !$0.exhausted.isEmpty }.count
                figure("\(windows.count)", caption: usedUp > 0 ? L("5-hour windows · %d used up", usedUp) : L("5-hour windows"))
            }
            if !isFuture, let active = active {
                figure(Self.time.string(from: active.start) + "–" + Self.time.string(from: active.end), caption: L("Active hours"))
            } else if isFuture, let quiet = quiet {
                figure(InsightFormat.hour(quiet.start) + "–" + InsightFormat.hour(quiet.end), caption: L("Usually idle"),
                       tint: .secondary)
            }
            Spacer(minLength: 0)
        }
        if !isFuture, used == 0, active == nil, expected == nil {
            Text(L("No use recorded on this day.")).font(.system(size: 10)).foregroundColor(.secondary)
        } else if isFuture, expected == nil {
            Text(L("A forecast follows once there are more readings.")).font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(QuotaInsightStyle.brand)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(QuotaInsightStyle.brand.opacity(0.12)))
    }

    private func figure(_ value: String, caption: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundColor(tint)
                .lineLimit(1)
            Text(caption).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
        }
        .fixedSize()
    }
}

/// A secondary explanation, shown on hover instead of taking a line.
struct InfoGlyph: View {
    let text: String

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 10))
            .foregroundColor(.secondary.opacity(0.8))
            .help(text)
            .accessibilityLabel(Text(text))
    }
}

/// A quiet inset surface that groups one chart or figure inside a card.
struct InsightPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
    }
}

extension View {
    /// Names a strip under the plot in the gutter beside it, where the percent labels sit.
    func laneLabel(_ text: String) -> some View {
        overlay(alignment: .trailing) {
            Text(text)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 24, alignment: .leading)
        }
    }
}

/// The trend's headline: what is left, set large, with the reset and the
/// forecast beside it, and a gauge of use against an even pace.
struct QuotaTrendHero: View {
    let title: String
    let last: ClaudeQuotaSample
    let pace: QuotaPace?
    let isWeekly: Bool
    let now: Date

    private var remaining: Double { max(0, 100 - last.usedPercent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(InsightFormat.percent(remaining))
                            .font(.system(size: 38, weight: .light, design: .rounded).monospacedDigit())
                            .foregroundColor(remaining < 15 ? QuotaInsightStyle.usedUp : .primary)
                        Text("%").font(.system(size: 16, weight: .light, design: .rounded)).foregroundColor(.secondary)
                    }
                    Text(L("%@ · remaining", title)).font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer(minLength: 12)
                figures
            }
            if let pace = pace, pace.isMeasured, !pace.isExhausted { gauge(pace) }
        }
    }

    private var figures: some View {
        HStack(alignment: .bottom, spacing: 14) {
            if let resetsAt = last.resetsAt, let countdown = DS.countdown(to: resetsAt, now: now) {
                figure(countdown, caption: L("Until reset"), tint: .primary)
            }
            if let forecast = forecast {
                Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 0.5, height: 30)
                figure(forecast.value, caption: forecast.caption, tint: forecast.tint)
            }
        }
        .padding(.bottom, 1)
    }

    private func figure(_ value: String, caption: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 16, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundColor(tint)
                .lineLimit(1)
            Text(caption).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
        }
        .fixedSize()
    }

    private var forecast: (value: String, caption: String, tint: Color)? {
        guard let pace = pace else { return nil }
        if pace.isExhausted { return (L("Used up"), L("This window"), QuotaInsightStyle.usedUp) }
        guard pace.isMeasured else { return ("—", L("Forecast soon"), .secondary) }
        if let runsOut = pace.runsOutAt {
            let formatter = DateFormatter()
            formatter.locale = L10n.locale
            formatter.setLocalizedDateFormatFromTemplate(isWeekly ? "EEEHHmm" : "HHmm")
            return (formatter.string(from: runsOut), L("Runs out"), QuotaInsightStyle.fast)
        }
        return (InsightFormat.percent(100 - pace.projectedAtReset(now: now)) + "%", L("Left at reset"), .primary)
    }

    /// Used so far as a fill, with a tick where an even pace would be now.
    private func gauge(_ pace: QuotaPace) -> some View {
        let difference = pace.ahead
        let text = abs(difference) < 1
            ? L("Right on an even pace")
            : difference > 0 ? L("%@%% more than an even pace", InsightFormat.percent(difference))
                : L("%@%% less than an even pace", InsightFormat.percent(-difference))
        let tint = difference > 3 ? QuotaInsightStyle.fast : QuotaInsightStyle.brand
        return HStack(spacing: 8) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(tint.opacity(0.85)).frame(width: max(3, width * CGFloat(min(100, pace.usedPercent) / 100)))
                    Rectangle().fill(Color.primary.opacity(0.55)).frame(width: 1.5, height: 10)
                        .offset(x: width * CGFloat(pace.evenPercent / 100) - 0.75)
                }
            }
            .frame(width: 96, height: 4)
            Text(text).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundColor(.secondary)
            InfoGlyph(text: L("Spread evenly over this window, %@%% would be used by now; %@%% is.",
                              InsightFormat.percent(pace.evenPercent), InsightFormat.percent(pace.usedPercent)))
            Spacer(minLength: 0)
        }
    }
}

/// How many full 5-hour windows a week holds and how many are left in this
/// one, from the same level the quota-size chart shows.
struct QuotaAllowanceFigures: View {
    let fiveHour: ClaudeQuotaSeries
    let weekly: ClaudeQuotaSeries
    let now: Date

    var body: some View {
        if let perWeek = ClaudeQuotaInsights.scaleTrend(fiveHour: fiveHour, weekly: weekly).current {
            let used = weekly.pace(now: now, lookback: 86_400)?.usedPercent ?? weekly.samples.last?.usedPercent ?? 0
            InsightPanel {
                HStack(alignment: .center, spacing: 14) {
                    figure(InsightFormat.count(perWeek), caption: L("Per week, used in full"))
                    Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 0.5, height: 28)
                    figure(InsightFormat.count(max(0, 100 - used) / 100 * perWeek), caption: L("Left this week"))
                    Spacer(minLength: 0)
                    InfoGlyph(text: L("From the 5-hour and weekly quota used on the same days; see Quota size in Usage insights."))
                }
            }
        }
    }

    private func figure(_ value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 18, weight: .medium, design: .rounded).monospacedDigit())
                Text(L("windows")).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Text(caption).font(.system(size: 10)).foregroundColor(.secondary)
        }
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

    private struct Tile: Identifiable {
        let id: String
        let symbol: String
        let tint: Color
        let label: String
        let value: String
        let detail: String?
    }

    var body: some View {
        if let insights = ClaudeQuotaInsights.make(history: dashboard.claudeQuotaHistory, now: now),
           insights.habits.grid.contains(where: { $0.contains { $0 > 0 } })
        {
            DSCard(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    tileGrid(tiles(insights))
                    InsightPanel { QuotaScaleSection(trend: insights.scale, costLine: costLine) }
                    InsightPanel { QuotaHabitHeatmap(habits: insights.habits) }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            Label(L("Usage insights"), systemImage: "sparkles")
                .font(.system(size: 12, weight: .semibold))
            InfoGlyph(text: L("From the quota readings recorded on this Mac while AIUsageBar runs."))
            Spacer()
            Text(L("Last 4 weeks")).font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    /// Two tiles a row, each row as tall as its taller tile.
    private func tileGrid(_ tiles: [Tile]) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(stride(from: 0, to: tiles.count, by: 2)), id: \.self) { start in
                HStack(alignment: .top, spacing: 8) {
                    tileView(tiles[start])
                    if start + 1 < tiles.count { tileView(tiles[start + 1]) } else { Color.clear.frame(maxWidth: .infinity) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tileView(_ tile: Tile) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: tile.symbol).font(.system(size: 9, weight: .semibold)).foregroundColor(tile.tint)
                Text(tile.label).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
            }
            Text(tile.value)
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail = tile.detail {
                Text(detail).font(.system(size: 10)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
    }

    private func tiles(_ insights: ClaudeQuotaInsights) -> [Tile] {
        [paceTile(insights.weeklyPace), changeTile(insights.paceChange),
         hoursTile(insights.habits), drainTile(insights.habits)].compactMap { $0 }
    }

    private func paceTile(_ pace: QuotaPace?) -> Tile? {
        guard let pace = pace else { return nil }
        let label = L("This week's outlook")
        if pace.isExhausted {
            return Tile(id: "pace", symbol: "exclamationmark.circle.fill", tint: QuotaInsightStyle.usedUp, label: label,
                        value: L("Used up"),
                        detail: L("Resets in %@", InsightFormat.duration(pace.cycle.end.timeIntervalSince(now), now: now)))
        }
        guard pace.isMeasured else {
            return Tile(id: "pace", symbol: "speedometer", tint: QuotaInsightStyle.calm, label: label,
                        value: L("%@%% used", InsightFormat.percent(pace.usedPercent)),
                        detail: L("A forecast follows once there are more readings."))
        }
        if let runsOut = pace.runsOutAt {
            let early = InsightFormat.duration(pace.cycle.end.timeIntervalSince(runsOut), now: now)
            return Tile(id: "pace", symbol: "speedometer", tint: QuotaInsightStyle.fast, label: label,
                        value: L("Runs out %@", InsightFormat.moment(runsOut)),
                        detail: pace.followsRhythm
                            ? L("%@ before the reset, at the last day's rate and your usual hours.", early)
                            : L("%@ before the reset, at the last day's rate.", early))
        }
        let left = InsightFormat.percent(100 - pace.projectedAtReset(now: now))
        return Tile(id: "pace", symbol: "speedometer", tint: QuotaInsightStyle.slow, label: label,
                    value: L("Lasts the week"),
                    detail: pace.followsRhythm
                        ? L("About %@%% left at the reset, at the last day's rate and your usual hours.", left)
                        : L("About %@%% left at the reset, at the last day's rate.", left))
    }

    private func changeTile(_ change: Double?) -> Tile {
        let label = L("Against last week")
        guard let change = change else {
            return Tile(id: "change", symbol: "arrow.left.arrow.right", tint: .secondary, label: label,
                        value: "—", detail: L("Compared once this week has 12 hours of readings."))
        }
        let detail = L("Weekly quota used per hour.")
        if abs(change) < 0.1 {
            return Tile(id: "change", symbol: "equal", tint: QuotaInsightStyle.calm, label: label,
                        value: L("About the same"), detail: detail)
        }
        let percent = InsightFormat.percent(abs(change) * 100)
        return change > 0
            ? Tile(id: "change", symbol: "arrow.up.right", tint: QuotaInsightStyle.fast, label: label,
                   value: L("%@%% faster", percent), detail: detail)
            : Tile(id: "change", symbol: "arrow.down.right", tint: QuotaInsightStyle.slow, label: label,
                   value: L("%@%% slower", percent), detail: detail)
    }

    private func hoursTile(_ habits: QuotaHabits) -> Tile? {
        guard let first = habits.peakHours.first else { return nil }
        let value = habits.peakHours.count > 1
            ? InsightFormat.hour(first) + " · " + InsightFormat.hour(habits.peakHours[1])
            : InsightFormat.hour(first)
        let detail = habits.quietStart.map {
            L("Hardly used from %@ to %@.", InsightFormat.hour($0), InsightFormat.hour($0 + habits.quietLength))
        }
        return Tile(id: "hours", symbol: "clock.fill", tint: QuotaInsightStyle.brand, label: L("Busiest hours"),
                    value: value, detail: detail)
    }

    private func drainTile(_ habits: QuotaHabits) -> Tile? {
        guard habits.windowsUsed > 0 else { return nil }
        let detail = L("%d of %d 5-hour windows in the last two weeks were used up.",
                       habits.windowsUsedUp, habits.windowsUsed)
        guard let drain = habits.drainTime else {
            return Tile(id: "drain", symbol: "hourglass", tint: QuotaInsightStyle.slow, label: L("Full 5-hour window"),
                        value: L("None used up"), detail: detail)
        }
        return Tile(id: "drain", symbol: "hourglass", tint: QuotaInsightStyle.fast, label: L("Full 5-hour window"),
                    value: L("Lasts %@", InsightFormat.duration(drain, now: now)), detail: detail)
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
            HStack(alignment: .center) {
                DSSectionLabel(title: L("Quota size"), symbol: "ruler")
                if let shift = trend.shift { shiftChip(shift) }
            }
            if let current = trend.current, trend.points.count >= 2 {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(InsightFormat.count(current)).font(.system(size: 28, weight: .light, design: .rounded).monospacedDigit())
                    Text(L("full 5-hour windows per week")).font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer(minLength: 0)
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
                     at: CGPoint(x: split - 4, y: y(shift.before) - 7), anchor: .trailing)
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
