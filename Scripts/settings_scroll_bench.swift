// Scroll performance check for the Settings panes. Build like Scripts/ui_gallery.swift
// (all Sources except AIUsageBarApp.swift, -O -parse-as-library) and run; each frame
// should stay well under 16 ms. Baseline 2026-10-09: Providers avg 3.0 ms, p95 5.8 ms.
@preconcurrency import AppKit
import SwiftUI
import QuartzCore

/// Scrolls each settings pane in a real window and reports per-frame cost.
@main
enum ScrollBench {
    @MainActor
    static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        L10n.language = .simplifiedChinese
        let client = CLIClient(bundle: Bundle(url: URL(fileURLWithPath: "/Applications/AIUsageBar.app")) ?? .main)
        let store = SettingsStore(client: client, updater: UpdaterController())
        await store.reloadProviders()
        let dashboardStore = DashboardStore(client: client)
        let host = NSHostingView(rootView: SettingsRootView(store: store, dashboardStore: dashboardStore))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        for tab in [SettingsStore.Tab.providers, .usageData, .menuBar, .general] {
            store.tab = tab
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))
            func all(_ v: NSView) -> [NSView] { var r: [NSView] = []; for s in v.subviews { r.append(s); r += all(s) }; return r }
            let scrolls = all(host).compactMap { $0 as? NSScrollView }
                .filter { ($0.documentView?.frame.height ?? 0) > $0.contentSize.height + 50 }
            guard !scrolls.isEmpty else { print("\(tab.rawValue): no scrollable content"); continue }
            for scroll in scrolls {
                let clip = scroll.contentView
                let maxY = (scroll.documentView?.frame.height ?? 0) - clip.bounds.height
                var times: [Double] = []
                var y: CGFloat = 0
                for step in 0..<160 {
                    y = CGFloat(step % 80) / 79 * maxY
                    if step >= 80 { y = maxY - y }
                    let start = CACurrentMediaTime()
                    clip.scroll(to: NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(clip)
                    window.displayIfNeeded()
                    CATransaction.flush()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
                    times.append((CACurrentMediaTime() - start) * 1000)
                }
                let sorted = times.sorted()
                print(String(format: "%@ [%.0fpt]: avg %.1f ms, p95 %.1f ms, max %.1f ms",
                             tab.rawValue, maxY, times.reduce(0, +) / Double(times.count),
                             sorted[Int(Double(sorted.count) * 0.95)], sorted.last!))
            }
        }
        exit(0)
    }
}
