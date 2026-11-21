@preconcurrency import AppKit
import SwiftUI

@MainActor
final class ProviderDetailPopoverController: NSObject {
    private let presenter: StatusPopoverPresenter
    private var popover: NSPopover { presenter.popover }
    private let store: DashboardStore

    init(store: DashboardStore) {
        self.store = store
        presenter = StatusPopoverPresenter(name: "provider-detail")
        super.init()
        popover.contentSize = NSSize(width: 390, height: 560)
    }

    var isShown: Bool { presenter.isShown }

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
        presenter.show(relativeTo: button)
    }

    /// Short panels get a short popover; long ones stop at 560 and scroll.
    private func fit(height: CGFloat) {
        let height = max(160, min(560, height))
        guard abs(popover.contentSize.height - height) > 0.5 else { return }
        popover.contentSize = NSSize(width: 390, height: height)
    }

    func close() {
        presenter.close()
    }
}
