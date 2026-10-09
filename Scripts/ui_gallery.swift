@preconcurrency import AppKit
import SwiftUI

/// Renders the app's real views with live provider data from the installed
/// engine, for design review. Read-only: it never records into the local
/// history stores. Usage: ui_gallery <output-dir> [en|zh-Hans]
@main
enum UIGallery {
    @MainActor
    static func main() async {
        let arguments = CommandLine.arguments
        let output = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "ui-gallery", isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if arguments.count > 2, let language = AppLanguage(rawValue: arguments[2]) {
            L10n.language = language
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        if ProcessInfo.processInfo.environment["AIUSAGEBAR_PROVIDER_ICONS"] == nil {
            print("note: set AIUSAGEBAR_PROVIDER_ICONS=<repo>/Resources/ProviderIcons to render official logos")
        }

        let appURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AIUSAGEBAR_GALLERY_APP"]
            ?? "/Applications/AIUsageBar.app")
        let client = CLIClient(bundle: Bundle(url: appURL) ?? .main)
        let snapshots: [ProviderSnapshot]
        do {
            snapshots = try await client.fetchEnabled(status: true)
        } catch {
            print("FAIL: could not fetch snapshots: \(error.localizedDescription)")
            exit(1)
        }
        // Claude quota history from a copy of the app's file, so the gallery
        // never writes to the running app's data.
        let historyCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("ui-gallery-quota-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: historyCopy, withIntermediateDirectories: true)
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.copyItem(
                at: support.appendingPathComponent("AIUsageBar/claude-quota-history-v1.json"),
                to: historyCopy.appendingPathComponent("claude-quota-history-v1.json"))
        }
        let quotaHistory = ClaudeQuotaHistoryStore(storageDirectory: historyCopy)
        let activeMinutes = await ClaudeCodeActivityLog().activeMinutes()
        var dashboards: [String: ProviderDashboard] = [:]
        for snapshot in snapshots {
            let supplement = await client.dashboardSupplementJSON(provider: snapshot.provider)
            var dashboard = DashboardParser.dashboard(snapshot: snapshot, supplementalJSON: supplement)
            if snapshot.provider == "claude" {
                // Official account usage from a saved API response (the
                // gallery never reads the keychain itself).
                if let path = ProcessInfo.processInfo.environment["AIUSAGEBAR_GALLERY_CLAUDE_USAGE"],
                   let data = FileManager.default.contents(atPath: path),
                   let usage = ClaudeAccountUsage.parse(data)
                {
                    dashboard.claudeProductBreakdown = usage.breakdown
                    dashboard.claudeIncludedCredit = usage.includedCredit
                }
                dashboard.claudeQuotaHistory = quotaHistory.record(snapshot: snapshot)
                    .map { $0.attributed(activeMinutes: activeMinutes) }
                for series in dashboard.claudeQuotaHistory {
                    print(String(format: "%@: %d samples, Claude Code %.1f pts, other %.1f pts",
                                 series.id, series.samples.count, series.claudeCodePoints, series.otherDevicePoints))
                }
            }
            dashboards[snapshot.id] = dashboard
        }
        print("snapshots: \(snapshots.map(\.provider).joined(separator: ", "))")

        for (mode, appearance) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
            render(MenuMock(snapshots: snapshots, dashboards: dashboards),
                   appearance: appearance, output: output.appendingPathComponent("menu-overview-\(mode).png"))
            for snapshot in snapshots {
                let dashboard = dashboards[snapshot.id] ?? DashboardParser.dashboard(snapshot: snapshot)
                render(ProviderMenuMock(snapshot: snapshot, dashboard: dashboard), appearance: appearance,
                       output: output.appendingPathComponent("menu-\(snapshot.provider)-\(mode).png"))
                render(ProviderDetailPopoverView(dashboard: dashboard, isRefreshing: false,
                                                 refresh: {}, openDashboard: {}, openStatus: {}, openSettings: {})
                        .frame(width: 390, height: 560),
                       appearance: appearance, output: output.appendingPathComponent("detail-\(snapshot.provider)-\(mode).png"))
            }
            if let claude = snapshots.first(where: { $0.provider == "claude" }), let dashboard = dashboards[claude.id] {
                render(ClaudeQuotaHistoryView(dashboard: dashboard).padding(16).frame(width: 390)
                        .background(Color(nsColor: .windowBackgroundColor)),
                       appearance: appearance, output: output.appendingPathComponent("quota-trend-\(mode).png"))
            }
            let entries = snapshots.map { AllProviderEntry(id: $0.id, dashboard: dashboards[$0.id] ?? DashboardParser.dashboard(snapshot: $0)) }
            render(AllProvidersContentView(entries: entries, isRefreshing: false, error: nil, refresh: {}, openSettings: {})
                    .frame(width: 620, height: 680),
                   appearance: appearance, output: output.appendingPathComponent("all-providers-\(mode).png"))

            let settingsStore = SettingsStore(client: client, updater: UpdaterController())
            await settingsStore.reloadProviders()
            for tab in SettingsStore.Tab.allCases {
                settingsStore.tab = tab
                render(SettingsRootView(store: settingsStore, dashboardStore: DashboardStore(client: client))
                        .frame(width: 980, height: 680),
                       appearance: appearance,
                       output: output.appendingPathComponent("settings-\(tab.rawValue.replacingOccurrences(of: " ", with: "-"))-\(mode).png"))
            }
        }
        // Status-item rings at real size on a menu-bar-like strip, scaled 4x.
        for (mode, appearance) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
            render(HStack(spacing: 14) {
                ForEach([100.0, 72, 41, 18, 9], id: \.self) { remaining in
                    HStack(spacing: 3) {
                        Image(nsImage: MenuController.ringImage(remaining: remaining, failed: false))
                            .renderingMode(remaining < 15 ? .original : .template)
                        Text(String(format: "%.0f%%", remaining)).font(.system(size: 13))
                    }
                }
            }
            .padding(.horizontal, 12).frame(height: 24)
            .background(Color(nsColor: appearance.name == .darkAqua ? .black : .white).opacity(0.85))
            .scaleEffect(4).frame(width: 1400, height: 110),
            appearance: appearance, output: output.appendingPathComponent("status-items-\(mode).png"))
        }
        print("PASS | gallery written to \(output.path)")
        exit(0)
    }

    @MainActor
    static func render<V: View>(_ view: V, appearance: NSAppearance, output: URL) {
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, appearance.name == .darkAqua ? .dark : .light))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: NSSize(width: max(1, size.width), height: max(1, size.height)))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.backgroundColor = appearance.name == .darkAqua
            ? NSColor(calibratedWhite: 0.16, alpha: 1) : NSColor(calibratedWhite: 0.93, alpha: 1)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        appearance.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        try? bitmap.representation(using: .png, properties: [:])?.write(to: output)
        window.orderOut(nil)
    }
}

/// Approximates the native NSMenu around the hosted rows: menu material,
/// rounded corners and the standard text items below them.
private struct MenuChrome<Content: View>: View {
    let items: [(String, String?)]
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                if item.0 == "-" {
                    Divider().padding(.vertical, 5).padding(.horizontal, 10)
                } else {
                    HStack {
                        Text(item.0).font(.system(size: 13))
                        Spacer()
                        if let shortcut = item.1 {
                            Text(shortcut).font(.system(size: 13)).foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 22)
                }
            }
        }
        .padding(.vertical, 5)
        .frame(width: NativeMenuLayout.width)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .padding(24)
    }
}

private struct MenuMock: View {
    let snapshots: [ProviderSnapshot]
    let dashboards: [String: ProviderDashboard]

    var body: some View {
        MenuChrome(items: [
            ("-", nil), (L("Providers") + "  ▸", nil), (L("Open All Provider Details…"), nil), ("-", nil),
            (L("Refresh Now"), "⌘R"), (L("Settings…"), "⌘,"), (L("Check for Updates…"), nil), ("-", nil),
            (L("Quit AIUsageBar"), "⌘Q"),
        ]) {
            NativeMenuHeaderView(title: "AIUsageBar", subtitle: L("Updated %@ · %d enabled", "18:05", snapshots.count),
                                 providerID: nil, health: snapshots.map(\.serviceHealth).max(), refreshing: false)
            NativeMenuOverviewView(
                rows: snapshots.map { snapshot -> NativeMenuOverviewRow in
                    let dashboard = dashboards[snapshot.id] ?? DashboardParser.dashboard(snapshot: snapshot)
                    let headline = dashboard.quotas.first { $0.title == snapshot.headlineQuotaLabel } ?? dashboard.quotas.first
                    return NativeMenuOverviewRow(id: snapshot.id, providerID: snapshot.provider, title: snapshot.displayName,
                                          account: snapshot.accountDisplayName, usedPercent: snapshot.headlineUsedPercent,
                                          quotaLabel: headline?.title ?? snapshot.headlineQuotaLabel, health: snapshot.serviceHealth,
                                          hasError: snapshot.error != nil, resetsAt: headline?.resetsAt,
                                          balanceText: dashboard.metrics.first { $0.id == "balance" && !DS.isPlaceholder($0) }?.value)
                }.sorted { ($0.remainingPercent ?? 999) < ($1.remainingPercent ?? 999) },
                totalCount: snapshots.count, quotaPresentation: .remaining, showAccount: true, showStatus: true)
        }
    }
}

private struct ProviderMenuMock: View {
    let snapshot: ProviderSnapshot
    let dashboard: ProviderDashboard

    var body: some View {
        MenuChrome(items: [
            ("-", nil), (L("Open Detailed Dashboard…"), nil), (L("Usage Dashboard"), nil), (L("Status Page"), nil),
            (L("Authentication & Accounts…"), nil), ("-", nil), (L("Refresh Now"), "⌘R"), (L("Settings…"), "⌘,"),
        ]) {
            NativeMenuHeaderView(title: snapshot.displayName,
                                 subtitle: [snapshot.accountDisplayName, dashboard.updatedText].compactMap { $0 }.joined(separator: " · "),
                                 providerID: snapshot.provider,
                                 health: snapshot.serviceHealth.isIncident ? nil : snapshot.serviceHealth, refreshing: false,
                                 planLabel: dashboard.planLabel ?? snapshot.planDisplayName)
            NativeMenuProviderCardView(snapshot: snapshot, dashboard: dashboard, showAccount: true, showMetrics: true,
                                       showResetTime: true, showStatus: true, quotaPresentation: .remaining)
        }
    }
}
