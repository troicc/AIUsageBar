@preconcurrency import AppKit
import SwiftUI

@MainActor
final class DetailsWindowController: NSObject {
    private let store: DashboardStore
    private let presenter: StatusPopoverPresenter
    private var popover: NSPopover { presenter.popover }

    init(store: DashboardStore) {
        self.store = store
        presenter = StatusPopoverPresenter(name: "all-providers")
        super.init()
    }

    var isShown: Bool { presenter.isShown }

    func show(relativeTo button: NSStatusBarButton) {
        let available = button.window?.screen?.visibleFrame.size ?? NSSize(width: 1024, height: 768)
        popover.contentSize = NSSize(width: min(620, available.width - 40), height: min(680, available.height - 70))
        popover.contentViewController = NSHostingController(rootView: AllProvidersDashboardView(store: store))
        presenter.show(relativeTo: button)
    }

    func close() { presenter.close() }
}
