@preconcurrency import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let store: SettingsStore
    private let dashboardStore: DashboardStore

    init(client: CLIClient, updater: UpdaterController, dashboardStore: DashboardStore) {
        self.store = SettingsStore(client: client, updater: updater)
        self.dashboardStore = dashboardStore
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = L("AIUsageBar Settings")
        // System Settings look: the sidebar runs under the traffic lights.
        // The title stays set for the Window menu and accessibility.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        let frameName = "AIUsageBar.SettingsWindow"
        if !window.setFrameUsingName(frameName) { window.center() }
        window.setFrameAutosaveName(frameName)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(
            rootView: SettingsRootView(store: store, dashboardStore: dashboardStore))
    }

    required init?(coder: NSCoder) { nil }

    func show(
        selectedProviderID: String? = nil,
        selectedTab: SettingsStore.Tab? = nil
    ) {
        if let selectedProviderID = selectedProviderID { store.requestSelection(selectedProviderID) }
        if let selectedTab = selectedTab { store.tab = selectedTab }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !store.isBusy { Task { @MainActor in await store.reloadProviders() } }
    }

    func prepareTokenHistoryVisualQA() {
        let appearance = ProcessInfo.processInfo.environment["AIUSAGEBAR_VISUAL_QA_APPEARANCE"] == "dark"
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua)
        // SwiftUI resolves several semantic colors from the application-level
        // appearance. Set both scopes so the source-level snapshot exercises
        // the same light/dark environment as the live window.
        NSApp.appearance = appearance
        window?.appearance = appearance
        window?.setContentSize(NSSize(width: 980, height: 680))
        show(selectedTab: .usageData)
    }

    func tokenHistoryVisualQAReport() -> String {
        guard let window = window, let content = window.contentView else {
            return "FAIL: settings window or content view missing"
        }
        window.layoutIfNeeded()
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()

        var failures: [String] = []
        if content.bounds.width < 900 || content.bounds.height < 620 {
            failures.append("content viewport is smaller than 900x620")
        }
        let descendants = Self.descendants(of: content)
        let scrollViews = descendants.compactMap { $0 as? NSScrollView }
        let primaryScroll = scrollViews.max {
            ($0.bounds.width * $0.bounds.height) < ($1.bounds.width * $1.bounds.height)
        }
        if let primaryScroll = primaryScroll {
            let frame = content.convert(primaryScroll.bounds, from: primaryScroll)
            if frame.width < 600 || frame.height < 500 {
                failures.append("primary history scroll viewport is smaller than 600x500")
            }
        } else {
            failures.append("token history scroll view missing")
        }
        return failures.isEmpty
            ? "PASS | viewport=\(Int(content.bounds.width))x\(Int(content.bounds.height)) scrollViews=\(scrollViews.count)"
            : "FAIL: \(failures.joined(separator: "; "))"
    }

    func writeTokenHistoryVisualQASnapshot(to output: URL) throws {
        guard let window = window, let content = window.contentView else {
            throw NSError(
                domain: "AIUsageBar.VisualQA",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Settings window or content view is missing."])
        }
        window.layoutIfNeeded()
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw NSError(
                domain: "AIUsageBar.VisualQA",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate a settings bitmap."])
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(
                domain: "AIUsageBar.VisualQA",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Could not encode the settings bitmap as PNG."])
        }
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try png.write(to: output, options: .atomic)
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}

extension Notification.Name {
    static let preferencesChanged = Notification.Name("AIUsageBar.preferencesChanged")
    static let providerConfigurationChanged = Notification.Name("AIUsageBar.providerConfigurationChanged")
}
