// Drag and hover performance check for the Claude quota trend, on a copy of the
// real quota history. Build like Scripts/ui_gallery.swift (all Sources except
// AIUsageBarApp.swift, -O -parse-as-library) and run:
//   quota_trend_bench [history.json]
// Each step scrolls the chart or moves the pointer over it in a window holding
// the trend and the insights card, as the detail popover does, and times
// state update + layout + draw. Baseline 2026-11-14 (5.5k readings, M1):
// insights weekly hover ~200 ms a step.
@preconcurrency import AppKit
import SwiftUI
import QuartzCore

@main
enum QuotaTrendBench {
    @MainActor
    static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        L10n.language = .simplifiedChinese
        let arguments = CommandLine.arguments
        let path = arguments.count > 1 ? arguments[1]
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AIUsageBar/claude-quota-history-v1.json").path
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = FileManager.default.contents(atPath: path),
              let accounts = try? decoder.decode([String: [String: [ClaudeQuotaSample]]].self, from: data),
              let lanes = accounts.values.max(by: { ($0["weekly"]?.count ?? 0) < ($1["weekly"]?.count ?? 0) })
        else {
            print("FAIL: no quota history at \(path)")
            exit(1)
        }
        let activeMinutes = await ClaudeCodeActivityLog().activeMinutes()
        var dashboard = ProviderDashboard.loading(providerID: "claude", title: "Claude")
        dashboard.hasClaudeSharedQuota = true
        dashboard.claudeQuotaHistory = [("five-hour", L("5 hours")), ("weekly", L("Weekly"))].compactMap { id, title in
            guard let samples = lanes[id], !samples.isEmpty else { return nil }
            return ClaudeQuotaSeries(id: id, title: title, samples: samples.sorted { $0.timestamp < $1.timestamp })
                .attributed(activeMinutes: activeMinutes, since: Date().addingTimeInterval(-86_400))
        }
        print("samples: " + dashboard.claudeQuotaHistory.map { "\($0.id) \($0.samples.count)" }.joined(separator: ", "))
        computations(dashboard.claudeQuotaHistory)

        for mode in QuotaChartMode.allCases {
            UserDefaults.standard.set(mode.rawValue, forKey: QuotaChartMode.preferenceKey)
            for window in ["five-hour", "weekly"] {
                let root = ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 16) {
                        ClaudeQuotaHistoryView(dashboard: dashboard, window: window)
                        ClaudeUsageInsightsSection(dashboard: dashboard)
                    }
                    .padding(14)
                }
                .frame(width: 390, height: 560)
                .background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: root)
                let frame = NSRect(x: 200, y: 200, width: 390, height: 560)
                let nsWindow = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
                nsWindow.contentView = host
                NSApp.activate(ignoringOtherApps: true)
                nsWindow.makeKeyAndOrderFront(nil)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
                guard let reader = all(host).first(where: { String(describing: type(of: $0)).contains("ReaderView") }) else {
                    print("FAIL: no chart in \(window)")
                    exit(1)
                }
                let plot = reader.convert(reader.bounds, to: nil)
                let name = "\(mode.rawValue) \(window)"
                report("\(name) swipe", swipe(reader))
                report("\(name) hover", hover(reader, plot: plot))
                nsWindow.orderOut(nil)
            }
        }
        exit(0)
    }

    /// The model work behind the trend and the insights card, once each.
    static func computations(_ history: [ClaudeQuotaSeries]) {
        let now = Date()
        func time(_ name: String, _ work: () -> Void) {
            let start = CACurrentMediaTime()
            for _ in 0..<5 { work() }
            print(String(format: "  %-28@ %6.2f ms", name as NSString, (CACurrentMediaTime() - start) * 1000 / 5))
        }
        guard let fiveHour = history.first(where: { $0.id == "five-hour" }),
              let weekly = history.first(where: { $0.id == "weekly" }) else { return }
        time("five-hour cycles()") { _ = fiveHour.cycles() }
        time("weekly cycles()") { _ = weekly.cycles() }
        time("rhythm") { _ = QuotaUsageRhythm.make(from: fiveHour, now: now) }
        time("weeklyPace") { _ = ClaudeQuotaInsights.weeklyPace(history: history, now: now) }
        time("five-hour pace") { _ = fiveHour.pace(now: now, lookback: 3600) }
        time("scaleTrend") { _ = ClaudeQuotaInsights.scaleTrend(fiveHour: fiveHour, weekly: weekly) }
        time("habits") { _ = ClaudeQuotaInsights.habits(fiveHour: fiveHour, now: now) }
        time("insights make") { _ = ClaudeQuotaInsights.make(history: history, now: now) }
        time("windowsPerWeek") { _ = ClaudeQuotaSeries.fiveHourWindowsPerWeek(fiveHour: fiveHour, weekly: weekly, now: now) }
    }

    static func all(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + all($0) }
    }

    @MainActor
    static func settle(_ window: NSWindow) {
        window.displayIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
    }

    static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                           pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// Two-finger swipes left then right over the plot, through the same
    /// callback the app's scroll-wheel monitor calls.
    @MainActor
    static func swipe(_ reader: NSView) -> [Double] {
        guard let window = reader.window, let chart = reader as? ChartPointerReader.ReaderView else { return [] }
        var times: [Double] = []
        for step in 0..<160 {
            let start = CACurrentMediaTime()
            chart.onScroll?(step < 80 ? 6 : -6)
            chart.onHover?(nil)
            settle(window)
            times.append((CACurrentMediaTime() - start) * 1000)
        }
        return times
    }

    /// Moves the pointer across the plot through its tracking area.
    @MainActor
    static func hover(_ reader: NSView, plot: NSRect) -> [Double] {
        guard let window = reader.window else { return [] }
        var times: [Double] = []
        for step in 0..<160 {
            let phase = Double(step % 80) / 79
            let x = plot.minX + 6 + CGFloat(step < 80 ? phase : 1 - phase) * (plot.width - 40)
            let start = CACurrentMediaTime()
            reader.mouseMoved(with: mouse(.mouseMoved, at: NSPoint(x: x, y: plot.midY), in: window))
            settle(window)
            times.append((CACurrentMediaTime() - start) * 1000)
        }
        reader.mouseExited(with: mouse(.mouseMoved, at: .zero, in: window))
        settle(window)
        return times
    }

    static func report(_ name: String, _ times: [Double]) {
        guard !times.isEmpty else { return print("\(name): no samples") }
        let sorted = times.sorted()
        print(String(format: "%-22@ avg %5.1f ms  p95 %5.1f ms  max %5.1f ms", name as NSString,
                     times.reduce(0, +) / Double(times.count), sorted[Int(Double(sorted.count) * 0.95)], sorted.last!))
    }
}
