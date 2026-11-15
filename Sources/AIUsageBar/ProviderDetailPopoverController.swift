@preconcurrency import AppKit
import SwiftUI

@MainActor
final class ProviderDetailPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let store: DashboardStore

    init(store: DashboardStore) {
        self.store = store
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 390, height: 560)
    }

    var isShown: Bool { popover.isShown }

    func show(snapshot: ProviderSnapshot, relativeTo button: NSStatusBarButton) {
        store.select(snapshot)
        let controller = NSHostingController(
            rootView: LiveProviderDetailPopoverView(store: store, snapshotID: snapshot.id) { [weak self] height in
                self?.fit(height: height)
            })
        popover.contentViewController = controller
        // Lay out once before showing, so the popover opens at the content's height.
        popover.contentSize = NSSize(width: 390, height: 560)
        controller.view.layoutSubtreeIfNeeded()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Short panels get a short popover; long ones stop at 560 and scroll.
    private func fit(height: CGFloat) {
        let height = max(160, min(560, height))
        guard abs(popover.contentSize.height - height) > 0.5 else { return }
        popover.contentSize = NSSize(width: 390, height: height)
    }

    func close() {
        popover.performClose(nil)
    }
}
