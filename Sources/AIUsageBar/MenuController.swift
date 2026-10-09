@preconcurrency import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private static let mergedMenuContext = "__aiusagebar_overview__"

    private let client: CLIClient
    private let updater: UpdaterController
    private let store: DashboardStore
    private let detailPopover: ProviderDetailPopoverController
    private let alertController = ProviderAlertController()

    private var mergedItem: NSStatusItem?
    private var providerItems: [String: NSStatusItem] = [:]
    private var menuContexts: [ObjectIdentifier: String] = [:]
    private var refreshTimer: Timer?
    private var lastMenuOpenedAt: Date?
    /// Start of the most recent refresh. The next automatic refresh is always
    /// scheduled relative to it, so opening menus can never postpone it.
    private var lastRefreshStartedAt: Date?
    /// Menus currently on screen, including open submenus.
    private var openMenus: Set<ObjectIdentifier> = []
    /// Re-render closures for the hosted rows and dynamic items of each menu,
    /// so an open menu follows refreshes instead of showing stale content.
    private var liveUpdaters: [ObjectIdentifier: [() -> Void]] = [:]
    private var liveUpdateScheduled = false
    /// Provider submenus under "Providers" are filled only when opened.
    private var lazyProviderMenus: [ObjectIdentifier: String] = [:]
    private var storeObservation: AnyCancellable?
    /// Providers whose gauges play the reset animation in the open menu.
    private var activeCelebrations: Set<String> = []
    private var statusAnimationTimers: [ObjectIdentifier: Timer] = [:]
    private weak var lastStatusButton: NSStatusBarButton?
    private var lastMenuProviderID: String?

    private lazy var settings = SettingsWindowController(
        client: client,
        updater: updater,
        dashboardStore: store)
    private lazy var details = DetailsWindowController(store: store)

    init(client: CLIClient, updater: UpdaterController) {
        self.client = client
        self.updater = updater
        let dashboardStore = DashboardStore(client: client)
        self.store = dashboardStore
        self.detailPopover = ProviderDetailPopoverController(store: dashboardStore)
        super.init()
        alertController.prepareAuthorizationIfNeeded()

        store.onOpenSettings = { [weak self] in
            self?.detailPopover.close()
            self?.details.close()
            self?.settings.show(selectedProviderID: self?.store.selectedSnapshot?.provider)
        }
        store.onOpenAllDetails = { [weak self] in
            self?.openAllDetailsMenuItem()
        }
        store.onOpenProviderDetails = { [weak self] snapshotID in
            guard let self = self,
                  let snapshot = self.store.snapshots.first(where: { $0.id == snapshotID }),
                  let button = self.lastStatusButton
            else { return }
            DispatchQueue.main.async { [weak self, weak button] in
                guard let self = self, let button = button else { return }
                self.details.close()
                self.detailPopover.show(snapshot: snapshot, relativeTo: button)
            }
        }
        store.onQuit = { NSApp.terminate(nil) }
        store.onRefreshStateChanged = { [weak self] in
            self?.rebuildStatusItems()
            self?.renderStatusItems()
        }
        store.onQuotaReset = { [weak self] ids in
            self?.quotaDidReset(ids)
        }
        store.onRefreshCompleted = { [weak self] snapshots in
            guard let self = self else { return }
            self.alertController.evaluate(snapshots: snapshots, dashboards: self.store.dashboards)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged),
            name: .preferencesChanged,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(previewResetAnimation),
            name: .previewResetAnimation,
            object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(currencyDisplayChanged),
            name: .currencyDisplayChanged, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(providerConfigurationChanged(_:)),
            name: .providerConfigurationChanged,
            object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil)
        storeObservation = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleLiveUpdate() }
        }

        rebuildStatusItems()
        renderStatusItems()
        installApplicationMenu()
        if ProcessInfo.processInfo.environment["AIUSAGEBAR_VISUAL_QA_USAGE_DATA"] != "1" {
            Task { await refresh() }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        refreshTimer?.invalidate()
    }

    @objc private func systemDidWake() {
        guard Preferences.shared.refreshMode != .manual else { return }
        Task { @MainActor [weak self] in
            // Give Wi-Fi a moment to reconnect before probing providers.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self = self else { return }
            let stale = self.store.lastSuccessfulRefresh.map { Date().timeIntervalSince($0) > 60 } ?? true
            if stale, !self.store.isRefreshing { await self.refresh() }
        }
    }

    @objc private func preferencesChanged() {
        rebuildStatusItems()
        renderStatusItems()
        scheduleNextRefresh()
    }

    @objc private func currencyDisplayChanged() {
        store.rebuildCurrencyPresentation()
    }

    @objc private func providerConfigurationChanged(_: Notification) {
        Task { await refresh() }
    }

    private func refresh() async {
        lastRefreshStartedAt = Date()
        await store.refresh()
        scheduleNextRefresh()
        offerProviderSetupIfNeeded()
    }

    /// On the very first launch with nothing configured, open the Providers
    /// settings instead of leaving an empty menu as the only hint.
    private func offerProviderSetupIfNeeded() {
        guard !Preferences.shared.hasShownProviderSetup,
              ProcessInfo.processInfo.environment["AIUSAGEBAR_UI_SMOKE_OUTPUT"] == nil,
              ProcessInfo.processInfo.environment["AIUSAGEBAR_VISUAL_QA_USAGE_DATA"] != "1"
        else { return }
        Preferences.shared.hasShownProviderSetup = true
        if store.snapshots.isEmpty {
            settings.show(selectedTab: .providers)
        }
    }

    /// Schedules the next automatic refresh relative to when the last one
    /// started. Calling this again (menu opens, preference changes) only ever
    /// keeps or shortens the wait, it never pushes the refresh further out.
    private func scheduleNextRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        let interval: TimeInterval
        switch Preferences.shared.refreshMode {
        case .manual:
            return
        case .fixed:
            interval = Preferences.shared.refreshInterval
        case .adaptive:
            interval = adaptiveRefreshInterval()
        }

        let now = Date()
        let due = (lastRefreshStartedAt ?? now).addingTimeInterval(interval)
        let delay = max(1, due.timeIntervalSince(now))
        refreshTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func adaptiveRefreshInterval(now: Date = Date()) -> TimeInterval {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return 1800 }
        guard let lastMenuOpenedAt = lastMenuOpenedAt else { return 300 }
        let idle = now.timeIntervalSince(lastMenuOpenedAt)
        if idle < 10 * 60 { return 120 }
        if idle < 60 * 60 { return 300 }
        return 900
    }

    private func rebuildStatusItems() {
        menuContexts.removeAll()
        if Preferences.shared.mergeIcons || store.snapshots.isEmpty {
            providerItems.values.forEach { NSStatusBar.system.removeStatusItem($0) }
            providerItems.removeAll()
            if mergedItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.autosaveName = "aiusagebar-merged"
                mergedItem = item
            }
            if let mergedItem = mergedItem {
                installNativeMenu(on: mergedItem, providerID: nil)
            }
        } else {
            if let mergedItem = mergedItem {
                NSStatusBar.system.removeStatusItem(mergedItem)
                self.mergedItem = nil
            }
            let desired = Set(store.snapshots.map(\.id))
            let staleKeys = providerItems.keys.filter { !desired.contains($0) }
            for key in staleKeys {
                guard let stale = providerItems.removeValue(forKey: key) else { continue }
                NSStatusBar.system.removeStatusItem(stale)
            }
            for snapshot in store.snapshots where providerItems[snapshot.id] == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.autosaveName = "aiusagebar-\(snapshot.provider)-\(StableIdentifier.hash(snapshot.id))"
                providerItems[snapshot.id] = item
            }
            for snapshot in store.snapshots {
                if let item = providerItems[snapshot.id] {
                    installNativeMenu(on: item, providerID: snapshot.id)
                }
            }
        }
    }

    private func installNativeMenu(on item: NSStatusItem, providerID: String?) {
        let menu: NSMenu
        if let existing = item.menu {
            menu = existing
        } else {
            menu = NSMenu(title: "AIUsageBar")
            menu.autoenablesItems = false
            menu.delegate = self
            item.menu = menu
        }
        menuContexts[ObjectIdentifier(menu)] = providerID ?? Self.mergedMenuContext
    }

    private func renderStatusItems() {
        if let mergedItem = mergedItem {
            configureButton(mergedItem.button, snapshots: store.snapshots)
        }
        for snapshot in store.snapshots {
            if let item = providerItems[snapshot.id] {
                configureButton(item.button, snapshots: [snapshot])
            }
        }
    }

    private func configureButton(_ button: NSStatusBarButton?, snapshots: [ProviderSnapshot]) {
        guard let button = button else { return }
        let highest = snapshots.compactMap(\.headlineUsedPercent).max()
        let hasAlert = Preferences.shared.showServiceStatus && snapshots.contains(where: \.hasVisibleAlert)
        let alertPrefix = hasAlert ? "! " : ""

        let failed = !snapshots.isEmpty && snapshots.allSatisfy(\.isFailed)
        let remaining = highest.map { max(0, 100 - $0) }
        button.imagePosition = .imageLeading
        switch Preferences.shared.menuBarDisplayStyle {
        case .meter:
            button.title = hasAlert ? "!" : ""
            button.image = Self.ringImage(remaining: remaining, failed: failed)
        case .usedPercentage:
            button.title = highest.map { alertPrefix + String(format: "%.0f%%", $0) } ?? "—"
            button.image = Self.ringImage(remaining: remaining, failed: failed, size: 13)
        case .remainingPercentage:
            button.title = remaining.map { alertPrefix + String(format: "%.0f%%", $0) } ?? "—"
            button.image = Self.ringImage(remaining: remaining, failed: failed, size: 13)
        case .providerIcon:
            button.title = hasAlert ? "!" : ""
            if snapshots.count == 1, let snapshot = snapshots.first {
                button.image = ProviderLogo.templateImage(for: snapshot.provider, size: 16)
                    ?? NSImage(systemSymbolName: ProviderBrand.symbol(for: snapshot.provider),
                               accessibilityDescription: snapshot.displayName)
                button.image?.isTemplate = true
            } else {
                button.image = Self.ringImage(remaining: remaining, failed: failed)
            }
        }

        button.toolTip = statusItemTooltip(snapshots: snapshots)
        let providerDescription = snapshots.isEmpty ? "AIUsageBar" : snapshots.map { snapshot in
            snapshot.accountDisplayName.map { "\(snapshot.displayName), \($0)" } ?? snapshot.displayName
        }.joined(separator: ", ")
        button.setAccessibilityLabel(providerDescription)
        if store.isRefreshing {
            button.setAccessibilityValue(L("Refreshing"))
        } else if store.lastError != nil {
            button.setAccessibilityValue(snapshots.isEmpty ? L("Refresh failed") : L("Refresh failed; showing saved data"))
        } else if hasAlert {
            button.setAccessibilityValue(L("Provider needs attention"))
        } else if let highest = highest {
            button.setAccessibilityValue(L("%.0f percent used", highest))
        } else {
            button.setAccessibilityValue(L("Usage unavailable"))
        }
    }

    private func statusItemTooltip(snapshots: [ProviderSnapshot]) -> String {
        if store.isRefreshing { return L("AIUsageBar — Refreshing…") }
        if let error = store.lastError {
            return snapshots.isEmpty ? L("Refresh failed: %@", error) : L("Refresh failed — showing saved data: %@", error)
        }
        guard !snapshots.isEmpty else { return L("AIUsageBar — no providers enabled") }
        return snapshots.map { snapshot in
            var parts = [snapshot.displayName]
            if let account = snapshot.accountDisplayName { parts.append(account) }
            if let error = snapshot.error?.message { parts.append(error) }
            else if snapshot.serviceHealth.isIncident, let status = snapshot.status { parts.append(status.displayText) }
            else if let percent = snapshot.headlineUsedPercent {
                let label = snapshot.headlineQuotaLabel.map { "\($0) " } ?? ""
                parts.append(label + L("%.0f%% used", percent))
            }
            return parts.joined(separator: " — ")
        }.joined(separator: "\n")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let snapshotID = lazyProviderMenus[ObjectIdentifier(menu)],
              let snapshot = store.snapshots.first(where: { $0.id == snapshotID })
        else { return }
        resetMenu(menu)
        populateProviderMenu(menu, snapshot: snapshot, includeQuit: false)
        if snapshot.provider == "claude" { store.loadClaudeAccountUsageIfNeeded() }
    }

    func menuDidClose(_ menu: NSMenu) {
        openMenus.remove(ObjectIdentifier(menu))
        if openMenus.isEmpty { activeCelebrations.removeAll() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if openMenus.isEmpty { activeCelebrations = store.takeResetCelebrations() }
        openMenus.insert(ObjectIdentifier(menu))
        // Provider submenus are filled in menuNeedsUpdate; they are not roots.
        if lazyProviderMenus[ObjectIdentifier(menu)] != nil { return }
        let context = menuContexts[ObjectIdentifier(menu)] ?? Self.mergedMenuContext
        let providerID = context == Self.mergedMenuContext ? nil : context
        lastMenuProviderID = providerID
        lastStatusButton = statusItem(for: menu)?.button
        lastMenuOpenedAt = Date()
        populate(menu: menu, providerID: providerID)
        scheduleNextRefresh()

        if let providerID = providerID {
            store.selectProviderID(providerID)
        } else {
            for snapshot in store.snapshots.prefix(Preferences.shared.overviewProviderLimit) {
                Task { await store.enrich(snapshot) }
            }
        }

        if Preferences.shared.refreshOnMenuOpen,
           !store.isRefreshing,
           store.lastSuccessfulRefresh.map({ Date().timeIntervalSince($0) > 60 }) ?? true
        {
            Task { await refresh() }
        }
    }

    private func statusItem(for menu: NSMenu) -> NSStatusItem? {
        if mergedItem?.menu === menu { return mergedItem }
        return providerItems.values.first(where: { $0.menu === menu })
    }

    private func resetMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        liveUpdaters[ObjectIdentifier(menu)] = []
    }

    private func scheduleLiveUpdate() {
        guard !openMenus.isEmpty, !liveUpdateScheduled else { return }
        liveUpdateScheduled = true
        // objectWillChange fires before the new values are stored; apply on
        // the next turn of the run loop, coalescing bursts of changes.
        DispatchQueue.main.async { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.liveUpdateScheduled = false
                for id in self.openMenus {
                    self.liveUpdaters[id]?.forEach { $0() }
                }
            }
        }
    }

    private func registerLiveUpdate(in menu: NSMenu, _ update: @escaping () -> Void) {
        liveUpdaters[ObjectIdentifier(menu), default: []].append(update)
    }

    // MARK: Quota reset animation

    private func quotaDidReset(_ ids: Set<String>) {
        playStatusResetAnimations(for: ids)
        if !openMenus.isEmpty {
            // Already looking at the menu: replay in place.
            activeCelebrations.formUnion(store.takeResetCelebrations())
            scheduleLiveUpdate()
        }
    }

    @objc private func previewResetAnimation() {
        let ids = store.previewResetCelebration()
        quotaDidReset(ids)
    }

    /// Fills the status-item ring from empty, then glows it, for the items
    /// showing the providers that reset.
    private func playStatusResetAnimations(for ids: Set<String>) {
        guard Preferences.shared.menuBarDisplayStyle != .providerIcon else { return }
        let size: CGFloat = Preferences.shared.menuBarDisplayStyle == .meter ? 16 : 13
        if let merged = mergedItem?.button {
            let remaining = store.snapshots.compactMap(\.headlineUsedPercent).max().map { max(0, 100 - $0) }
            if let remaining = remaining { animateStatusRing(merged, remaining: remaining, size: size) }
        }
        for id in ids {
            guard let button = providerItems[id]?.button,
                  let used = store.snapshots.first(where: { $0.id == id })?.headlineUsedPercent
            else { continue }
            animateStatusRing(button, remaining: max(0, 100 - used), size: size)
        }
    }

    private func animateStatusRing(_ button: NSStatusBarButton, remaining: Double, size: CGFloat) {
        let key = ObjectIdentifier(button)
        statusAnimationTimers[key]?.invalidate()
        let start = CACurrentMediaTime()
        let fill: Double = 1.1, glow: Double = 1.3
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self, weak button] timer in
            Task { @MainActor in
                guard let self = self, let button = button else { timer.invalidate(); return }
                let elapsed = CACurrentMediaTime() - start
                if elapsed < fill {
                    let t = elapsed / fill
                    let eased = 1 - pow(1 - t, 3)
                    button.image = Self.ringImage(remaining: remaining * eased, failed: false, size: size,
                                                  celebration: 0, toneRemaining: remaining)
                } else if elapsed < fill + glow {
                    let t = (elapsed - fill) / glow
                    let intensity = t < 0.3 ? t / 0.3 : max(0, 1 - (t - 0.3) / 0.7)
                    button.image = Self.ringImage(remaining: remaining, failed: false, size: size,
                                                  celebration: intensity, toneRemaining: remaining)
                } else {
                    timer.invalidate()
                    self.statusAnimationTimers[key] = nil
                    self.renderStatusItems()
                }
            }
        }
        // Common modes keep it running while a menu is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        statusAnimationTimers[key] = timer
    }

    private func populate(menu: NSMenu, providerID: String?) {
        resetMenu(menu)
        lazyProviderMenus.removeAll()
        if let providerID = providerID,
           let snapshot = store.snapshots.first(where: { $0.id == providerID })
        {
            populateProviderMenu(menu, snapshot: snapshot, includeQuit: true)
        } else {
            populateOverviewMenu(menu)
        }
    }

    private func populateOverviewMenu(_ menu: NSMenu) {
        menu.addItem(hostedMenuItem(in: menu) { [unowned self] () -> NativeMenuHeaderView in
            let worstHealth = self.store.snapshots.map {
                $0.error == nil ? $0.serviceHealth : ProviderServiceHealth.outage
            }.max()
            return NativeMenuHeaderView(
                title: "AIUsageBar",
                subtitle: self.menuSubtitle(),
                providerID: nil,
                health: Preferences.shared.showServiceStatus ? worstHealth : nil,
                refreshing: self.store.isRefreshing)
        })

        menu.addItem(hostedMenuItem(in: menu) { [unowned self] () -> NativeMenuOverviewView in
            let rows = self.overviewRows().prefix(Preferences.shared.overviewProviderLimit)
            return NativeMenuOverviewView(
                rows: Array(rows),
                totalCount: self.store.snapshots.count,
                quotaPresentation: Preferences.shared.menuQuotaPresentation,
                showAccount: Preferences.shared.showAccountInMenu,
                showStatus: Preferences.shared.showServiceStatus,
                celebrating: self.activeCelebrations)
        })
        menu.addItem(.separator())

        if store.snapshots.isEmpty {
            menu.addItem(menuItem(
                title: L("Set Up Providers…"),
                action: #selector(setUpProvidersMenuItem),
                symbol: "plus.circle"))
            menu.addItem(.separator())
        }

        if !store.snapshots.isEmpty {
            let providersItem = NSMenuItem(title: L("Providers"), action: nil, keyEquivalent: "")
            let providersMenu = NSMenu(title: L("Providers"))
            for snapshot in store.snapshots {
                let item = NSMenuItem(
                    title: providerMenuTitle(snapshot),
                    action: nil,
                    keyEquivalent: "")
                item.image = ProviderLogo.templateImage(for: snapshot.provider, size: 16)
                    ?? NSImage(systemSymbolName: ProviderBrand.symbol(for: snapshot.provider),
                               accessibilityDescription: snapshot.displayName)
                item.image?.isTemplate = true
                // Filled on demand in menuNeedsUpdate: building every provider
                // card up front made each menu open slow with many accounts.
                let submenu = NSMenu(title: snapshot.displayName)
                submenu.autoenablesItems = false
                submenu.delegate = self
                lazyProviderMenus[ObjectIdentifier(submenu)] = snapshot.id
                item.submenu = submenu
                providersMenu.addItem(item)
            }
            providersItem.submenu = providersMenu
            menu.addItem(providersItem)
        }

        if !store.snapshots.isEmpty {
            menu.addItem(menuItem(
                title: L("Open All Provider Details…"),
                action: #selector(openAllDetailsMenuItem),
                symbol: "square.grid.2x2"))
            menu.addItem(.separator())
        }
        appendCommonActions(to: menu, includeQuit: true)
    }

    private func populateProviderMenu(
        _ menu: NSMenu,
        snapshot: ProviderSnapshot,
        includeQuit: Bool
    ) {
        let dashboard = store.dashboard(for: snapshot)
        let snapshotID = snapshot.id
        // Live rows re-resolve the account so they show refreshed values.
        let current: () -> (ProviderSnapshot, ProviderDashboard) = { [unowned self] in
            let latest = self.store.snapshots.first(where: { $0.id == snapshotID }) ?? snapshot
            return (latest, self.store.dashboard(for: latest))
        }
        menu.addItem(hostedMenuItem(in: menu) { [unowned self] () -> NativeMenuHeaderView in
            let (snapshot, dashboard) = current()
            return NativeMenuHeaderView(
                title: snapshot.displayName,
                subtitle: self.providerSubtitle(snapshot, dashboard: dashboard),
                providerID: snapshot.provider,
                // Incidents get a full banner in the card below; no duplicate chip.
                health: Preferences.shared.showServiceStatus && !snapshot.serviceHealth.isIncident
                    ? snapshot.serviceHealth : nil,
                refreshing: self.store.isRefreshing,
                planLabel: dashboard.planLabel ?? snapshot.planDisplayName)
        })
        menu.addItem(hostedMenuItem(in: menu) { () -> NativeMenuProviderCardView in
            let (snapshot, dashboard) = current()
            return NativeMenuProviderCardView(
                snapshot: snapshot,
                dashboard: dashboard,
                showAccount: Preferences.shared.showAccountInMenu,
                showMetrics: Preferences.shared.showMenuMetrics,
                showResetTime: Preferences.shared.showResetTime,
                showStatus: Preferences.shared.showServiceStatus,
                quotaPresentation: Preferences.shared.menuQuotaPresentation)
        })
        menu.addItem(.separator())

        menu.addItem(menuItem(
            title: L("Open Detailed Dashboard…"),
            action: #selector(openProviderDetailsMenuItem(_:)),
            representedObject: snapshot.id,
            symbol: "chart.bar.xaxis"))
        if let url = dashboard.dashboardURL {
            menu.addItem(menuItem(
                title: L("Usage Dashboard"),
                action: #selector(openURLMenuItem(_:)),
                representedObject: url.absoluteString,
                symbol: "arrow.up.right.square"))
        }
        if let url = dashboard.statusURL {
            menu.addItem(menuItem(
                title: L("Status Page"),
                action: #selector(openURLMenuItem(_:)),
                representedObject: url.absoluteString,
                symbol: "waveform.path.ecg"))
        }
        menu.addItem(menuItem(
            title: dashboard.errorMessage == nil ? L("Authentication & Accounts…") : L("Fix Authentication…"),
            action: #selector(openProviderSettingsMenuItem(_:)),
            representedObject: snapshot.provider,
            symbol: "person.badge.key"))
        menu.addItem(.separator())
        appendCommonActions(to: menu, includeQuit: includeQuit)
    }

    private func appendCommonActions(to menu: NSMenu, includeQuit: Bool) {
        let refreshItem = menuItem(
            title: store.isRefreshing ? L("Refreshing…") : L("Refresh Now"),
            action: #selector(refreshMenuItem),
            keyEquivalent: "r",
            symbol: "arrow.clockwise",
            enabled: !store.isRefreshing)
        menu.addItem(refreshItem)
        registerLiveUpdate(in: menu) { [weak self, weak refreshItem] in
            guard let self = self, let refreshItem = refreshItem else { return }
            refreshItem.title = self.store.isRefreshing ? L("Refreshing…") : L("Refresh Now")
            refreshItem.isEnabled = !self.store.isRefreshing
        }
        menu.addItem(menuItem(
            title: L("Settings…"),
            action: #selector(openSettingsMenuItem),
            keyEquivalent: ",",
            symbol: "gearshape"))
        menu.addItem(menuItem(
            title: L("Check for Updates…"),
            action: #selector(checkForUpdatesMenuItem),
            symbol: "arrow.down.circle"))
        if includeQuit {
            menu.addItem(.separator())
            menu.addItem(menuItem(
                title: L("Quit AIUsageBar"),
                action: #selector(quitMenuItem),
                keyEquivalent: "q",
                symbol: "power"))
        }
    }

    private func providerMenuTitle(_ snapshot: ProviderSnapshot) -> String {
        var title = snapshot.displayName
        if Preferences.shared.showAccountInMenu, let account = snapshot.accountDisplayName {
            title += " — \(account)"
        }
        if let used = snapshot.headlineUsedPercent {
            let value = Preferences.shared.menuQuotaPresentation == .used ? used : 100 - used
            let label = snapshot.headlineQuotaLabel.map { "  \($0)" } ?? ""
            title += label + String(format: "  %.0f%%", max(0, min(100, value)))
        }
        if Preferences.shared.showServiceStatus, snapshot.hasVisibleAlert { title += "  ⚠" }
        return title
    }

    /// Overview rows with the tightest quota first, so the provider that is
    /// closest to running out is always at the top of the menu.
    private func overviewRows() -> [NativeMenuOverviewRow] {
        let rows = store.snapshots.map { snapshot -> NativeMenuOverviewRow in
            let dashboard = store.dashboard(for: snapshot)
            let headline = dashboard.quotas.first { $0.title == snapshot.headlineQuotaLabel } ?? dashboard.quotas.first
            let balance = dashboard.metrics.first { $0.id == "balance" && !DS.isPlaceholder($0) }?.value
            return NativeMenuOverviewRow(
                id: snapshot.id,
                providerID: snapshot.provider,
                title: snapshot.displayName,
                account: snapshot.accountDisplayName,
                usedPercent: snapshot.headlineUsedPercent,
                quotaLabel: headline?.title ?? snapshot.headlineQuotaLabel,
                health: snapshot.serviceHealth,
                hasError: snapshot.error != nil,
                resetsAt: headline?.resetsAt,
                balanceText: balance)
        }
        return rows.enumerated().sorted { left, right in
            switch (left.element.remainingPercent, right.element.remainingPercent) {
            case let (l?, r?) where l != r: return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left.offset < right.offset
            }
        }.map(\.element)
    }

    /// Plan is shown as a chip in the header, so the subtitle carries the
    /// account and freshness.
    private func providerSubtitle(_ snapshot: ProviderSnapshot, dashboard: ProviderDashboard) -> String {
        var parts: [String] = []
        if Preferences.shared.showAccountInMenu, let account = snapshot.accountDisplayName { parts.append(account) }
        parts.append(dashboard.updatedText)
        return parts.joined(separator: " · ")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private func menuSubtitle() -> String {
        if store.isRefreshing { return L("Refreshing provider usage…") }
        if let error = store.lastError {
            // Only claim saved data when there is some to show.
            return store.snapshots.isEmpty ? L("Refresh failed: %@", error) : L("Refresh failed — showing saved data")
        }
        if let date = store.lastSuccessfulRefresh {
            return L("Updated %@ · %d enabled", Self.timeFormatter.string(from: date), store.snapshots.count)
        }
        return L("%d enabled providers", store.snapshots.count)
    }

    /// Hosts a SwiftUI row in the menu and keeps it current while the menu
    /// is open: `build` runs again whenever the dashboard store changes.
    private func hostedMenuItem<V: View>(in menu: NSMenu, _ build: @escaping () -> V) -> NSMenuItem {
        let item = NSMenuItem()
        let hosting = NSHostingView(rootView: AnyView(build().fixedSize(horizontal: false, vertical: true)))
        Self.fit(hosting)
        item.view = hosting
        item.isEnabled = false
        registerLiveUpdate(in: menu) { [weak hosting, weak item, weak menu] in
            guard let hosting = hosting, let item = item else { return }
            hosting.rootView = AnyView(build().fixedSize(horizontal: false, vertical: true))
            Self.fit(hosting)
            menu?.itemChanged(item)
        }
        return item
    }

    private static func fit(_ hosting: NSView) {
        let fitting = hosting.fittingSize
        hosting.frame = NSRect(x: 0, y: 0, width: NativeMenuLayout.width, height: max(1, fitting.height))
    }

    private func menuItem(
        title: String,
        action: Selector,
        keyEquivalent: String = "",
        representedObject: Any? = nil,
        symbol: String? = nil,
        enabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.representedObject = representedObject
        item.keyEquivalentModifierMask = keyEquivalent.isEmpty ? [] : [.command]
        item.isEnabled = enabled
        if let symbol = symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            item.image?.isTemplate = true
        }
        return item
    }

    private func installApplicationMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        mainMenu.addItem(applicationItem)

        let applicationMenu = NSMenu(title: "AIUsageBar")
        applicationItem.submenu = applicationMenu
        let about = NSMenuItem(
            title: L("About AIUsageBar"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        about.target = NSApp
        applicationMenu.addItem(about)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(menuItem(
            title: L("Settings…"),
            action: #selector(openSettingsMenuItem),
            keyEquivalent: ","))
        applicationMenu.addItem(menuItem(
            title: L("Refresh Now"),
            action: #selector(refreshMenuItem),
            keyEquivalent: "r"))
        applicationMenu.addItem(menuItem(
            title: L("Check for Updates…"),
            action: #selector(checkForUpdatesMenuItem)))
        applicationMenu.addItem(.separator())
        let quit = NSMenuItem(
            title: L("Quit AIUsageBar"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        quit.target = NSApp
        applicationMenu.addItem(quit)
        NSApp.mainMenu = mainMenu
    }

    @objc private func setUpProvidersMenuItem() {
        detailPopover.close()
        details.close()
        settings.show(selectedTab: .providers)
    }

    @objc private func refreshMenuItem() {
        Task { await refresh() }
    }

    @objc private func openSettingsMenuItem() {
        detailPopover.close()
        details.close()
        settings.show(selectedProviderID: store.selectedSnapshot?.provider ?? lastMenuProviderID)
    }

    @objc private func openProviderSettingsMenuItem(_ sender: NSMenuItem) {
        guard let providerID = sender.representedObject as? String else { return }
        settings.show(selectedProviderID: providerID)
    }

    @objc private func openProviderDetailsMenuItem(_ sender: NSMenuItem) {
        guard let snapshotID = sender.representedObject as? String,
              let snapshot = store.snapshots.first(where: { $0.id == snapshotID }),
              let button = lastStatusButton
        else { return }
        DispatchQueue.main.async { [weak self, weak button] in
            guard let self = self, let button = button else { return }
            self.details.close()
            self.detailPopover.show(snapshot: snapshot, relativeTo: button)
        }
    }

    @objc private func openAllDetailsMenuItem() {
        guard let button = lastStatusButton ?? mergedItem?.button ?? providerItems.values.first?.button else { return }
        detailPopover.close()
        store.loadClaudeAccountUsageIfNeeded()
        DispatchQueue.main.async { [weak self, weak button] in
            guard let self = self, let button = button else { return }
            self.details.show(relativeTo: button)
        }
    }

    @objc private func openURLMenuItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func checkForUpdatesMenuItem() {
        updater.checkForUpdates()
    }

    @objc private func quitMenuItem() {
        NSApp.terminate(nil)
    }

    /// End-to-end runtime probe used by local/CI bundle smoke tests. It builds
    /// the same native menus users open, forces the settings hierarchy to load,
    /// and reports structural failures without exposing provider credentials.
    func runtimeSmokeReport() async -> String {
        while store.isRefreshing {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if store.snapshots.isEmpty { await store.refresh() }

        var failures: [String] = []
        let overview = NSMenu(title: "Runtime Smoke Overview")
        populateOverviewMenu(overview)
        let overviewHostedViews = overview.items.compactMap(\.view)
        if overviewHostedViews.count < 2 {
            failures.append("overview hosted rows missing")
        }
        if overviewHostedViews.contains(where: { $0.frame.width < 300 || $0.frame.height < 20 }) {
            failures.append("overview hosted row has invalid size")
        }
        if !store.snapshots.isEmpty,
           !overview.items.contains(where: { $0.title == L("Providers") && $0.submenu != nil })
        {
            failures.append("providers submenu missing")
        }

        if let snapshot = store.snapshots.first {
            let providerMenu = NSMenu(title: "Runtime Smoke Provider")
            populateProviderMenu(providerMenu, snapshot: snapshot, includeQuit: true)
            let providerHostedViews = providerMenu.items.compactMap(\.view)
            if providerHostedViews.count < 2 {
                failures.append("provider hosted card missing")
            }
            if providerHostedViews.contains(where: { $0.frame.width < 300 || $0.frame.height < 20 }) {
                failures.append("provider hosted card has invalid size")
            }
            if !providerMenu.items.contains(where: { $0.title == L("Authentication & Accounts…") || $0.title == L("Fix Authentication…") }) {
                failures.append("authentication action missing")
            }

            let anchor = mergedItem?.button ?? providerItems[snapshot.id]?.button
            if let anchor = anchor {
                detailPopover.show(snapshot: snapshot, relativeTo: anchor)
                if !detailPopover.isShown {
                    failures.append("provider detail popover did not open")
                }
                detailPopover.close()
            } else {
                failures.append("provider detail popover anchor missing")
            }
        }

        if mergedItem?.menu == nil && providerItems.values.allSatisfy({ $0.menu == nil }) {
            failures.append("status item has no native menu")
        }
        if settings.window == nil { failures.append("settings window failed to initialize") }
        if let anchor = mergedItem?.button ?? providerItems.values.first?.button {
            details.show(relativeTo: anchor)
            if !details.isShown { failures.append("all-provider popover did not open") }
            details.close()
        } else { failures.append("all-provider popover anchor missing") }


        let result = failures.isEmpty ? "PASS" : "FAIL: \(failures.joined(separator: "; "))"
        return "\(result) | snapshots=\(store.snapshots.count) overviewItems=\(overview.items.count)"
    }

    func showTokenHistoryForVisualQA() async {
        // Environment-gated source builds use this to expose the real settings
        // window to the deterministic native-window capture harness.
        try? await Task.sleep(nanoseconds: 250_000_000)
        settings.prepareTokenHistoryVisualQA()
        try? await Task.sleep(nanoseconds: 800_000_000)
        var report = settings.tokenHistoryVisualQAReport()
        if let imagePath = ProcessInfo.processInfo.environment["AIUSAGEBAR_VISUAL_QA_IMAGE"],
           !imagePath.isEmpty
        {
            do {
                try settings.writeTokenHistoryVisualQASnapshot(to: URL(fileURLWithPath: imagePath))
            } catch {
                report = "FAIL: visual QA PNG failed: \(error.localizedDescription)"
            }
        }
        if let output = ProcessInfo.processInfo.environment["AIUSAGEBAR_VISUAL_QA_RESULT"],
           !output.isEmpty
        {
            do {
                try (report + "\n").write(toFile: output, atomically: true, encoding: .utf8)
            } catch {
                NSLog("Could not write visual QA report: %@", error.localizedDescription)
            }
        }
    }

    /// Status-item gauge: a ring whose arc is the quota left. It is a
    /// template image like other menu extras, except when almost nothing is
    /// left, where it turns red the way the battery icon does.
    /// `celebration` > 0 draws the reset animation frame: the arc in its
    /// status color with a glow of that strength; `toneRemaining` picks the
    /// color (the final value while the arc is still filling).
    static func ringImage(remaining: Double?, failed: Bool, size: CGFloat = 16,
                          celebration: CGFloat? = nil, toneRemaining: Double? = nil) -> NSImage {
        let fraction = CGFloat(max(0, min(100, remaining ?? 0)) / 100)
        let critical = !failed && remaining.map { $0 < 15 } == true
        if let celebration = celebration {
            return celebrationRingImage(fraction: fraction, size: size, glow: celebration,
                                        color: DS.toneNSColor(remaining: toneRemaining ?? remaining))
        }
        let image = NSImage(size: NSSize(width: size + 2, height: size), flipped: false) { rect in
            let lineWidth: CGFloat = size >= 16 ? 2.4 : 2.1
            let inset = lineWidth / 2 + 0.5
            let circleRect = NSRect(x: 1 + inset, y: inset, width: size - inset * 2, height: size - inset * 2)
            let center = NSPoint(x: circleRect.midX, y: circleRect.midY)
            let radius = circleRect.width / 2

            let track = NSBezierPath(ovalIn: circleRect)
            track.lineWidth = lineWidth
            (critical ? NSColor.labelColor.withAlphaComponent(0.3) : NSColor.black.withAlphaComponent(0.28)).setStroke()
            track.stroke()

            guard remaining != nil, !failed, fraction > 0 else {
                if failed {
                    let slash = NSBezierPath()
                    slash.move(to: NSPoint(x: circleRect.minX + 2, y: circleRect.minY + 2))
                    slash.line(to: NSPoint(x: circleRect.maxX - 2, y: circleRect.maxY - 2))
                    slash.lineWidth = lineWidth
                    slash.lineCapStyle = .round
                    NSColor.black.setStroke()
                    slash.stroke()
                }
                return true
            }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                          endAngle: 90 - 360 * fraction, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            (critical ? NSColor.systemRed : NSColor.black).setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = !critical
        image.accessibilityDescription = remaining.map { L("%@%% remaining", String(format: "%.0f", $0)) }
        return image
    }

    private static func celebrationRingImage(fraction: CGFloat, size: CGFloat, glow: CGFloat, color: NSColor) -> NSImage {
        let margin: CGFloat = 3
        let image = NSImage(size: NSSize(width: size + margin * 2, height: size + 2), flipped: false) { rect in
            let lineWidth: CGFloat = (size >= 16 ? 2.4 : 2.1) * (1 + 0.35 * glow)
            let inset = lineWidth / 2 + 0.5
            let circleRect = NSRect(x: margin + inset, y: 1 + inset,
                                    width: size - inset * 2, height: size - inset * 2)
            let center = NSPoint(x: circleRect.midX, y: circleRect.midY)

            let track = NSBezierPath(ovalIn: circleRect)
            track.lineWidth = lineWidth
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()
            track.stroke()
            if glow > 0 {
                // The whole ring lights up in the status color.
                let aura = NSBezierPath(ovalIn: circleRect)
                aura.lineWidth = lineWidth * 1.8
                color.withAlphaComponent(0.35 * glow).setStroke()
                aura.stroke()
            }
            guard fraction > 0 else { return true }
            NSGraphicsContext.saveGraphicsState()
            if glow > 0 {
                let shadow = NSShadow()
                shadow.shadowColor = color.withAlphaComponent(glow)
                shadow.shadowBlurRadius = 3.5 * glow
                shadow.shadowOffset = .zero
                shadow.set()
            }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: circleRect.width / 2, startAngle: 90,
                          endAngle: 90 - 360 * fraction, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            color.setStroke()
            arc.stroke()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = false
        return image
    }
}
