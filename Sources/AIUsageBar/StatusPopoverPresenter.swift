@preconcurrency import AppKit
import os

let menuClickLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.github.troicc.aiusagebar", category: "MenuClick")

/// Shows a transient popover under a status item from an accessory app that
/// is usually not active when the menu is clicked.
///
/// `NSApp.activate` completes asynchronously. While the activation is still
/// in flight, a transient popover can see the switch of the frontmost app as
/// an interaction outside of it and close right after opening, so the first
/// click after launch (or after using another app) seemed to do nothing.
/// The popover is held open until the activation has landed, and made key
/// again once it does, so its own first click is not spent on activation.
@MainActor
final class StatusPopoverPresenter: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
    private let name: String
    private var holdOpenUntil: Date?
    private var observingActivation = false

    init(name: String) {
        self.name = name
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }

    func show(relativeTo button: NSStatusBarButton) {
        let wasActive = NSApp.isActive
        menuClickLog.notice("\(self.name, privacy: .public) show; app active=\(wasActive, privacy: .public)")
        if !wasActive {
            holdOpenUntil = Date().addingTimeInterval(0.8)
            observeActivation()
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        holdOpenUntil = nil
        popover.performClose(nil)
    }

    private func observeActivation() {
        guard !observingActivation else { return }
        observingActivation = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(activationDidLand),
            name: NSApplication.didBecomeActiveNotification,
            object: nil)
    }

    @objc private func activationDidLand() {
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        observingActivation = false
        menuClickLog.notice("\(self.name, privacy: .public) app became active; shown=\(self.popover.isShown, privacy: .public)")
        // Keep a short grace period for the window-server churn that follows activation.
        holdOpenUntil = Date().addingTimeInterval(0.2)
        if popover.isShown { popover.contentViewController?.view.window?.makeKey() }
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        if let until = holdOpenUntil, Date() < until {
            menuClickLog.notice("\(self.name, privacy: .public) kept open during activation")
            return false
        }
        holdOpenUntil = nil
        return true
    }

    func popoverDidClose(_ notification: Notification) {
        menuClickLog.notice("\(self.name, privacy: .public) closed")
    }
}
