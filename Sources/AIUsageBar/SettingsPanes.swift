@preconcurrency import AppKit
import SwiftUI

// MARK: - Root

/// System Settings–style window: a translucent sidebar with colored icon
/// tiles, and a scrolling pane of inset grouped cards on the right.
struct SettingsRootView: View {
    @ObservedObject var store: SettingsStore
    /// Not observed here: a refresh would otherwise re-render the whole
    /// window (and stutter scrolling). Panes that show live data observe it.
    let dashboardStore: DashboardStore

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(store: store)
                .frame(width: 214)
            Divider()
                .ignoresSafeArea()
            Group {
                switch store.tab {
                case .general: GeneralSettingsView(store: store)
                case .menuBar: LiveMenuBarSettingsView(store: store, dashboardStore: dashboardStore)
                case .notifications: NotificationSettingsView(store: store)
                case .usageData: TokenHistorySettingsView(dashboardStore: dashboardStore)
                case .providers: ProviderSettingsView(store: store, dashboardStore: dashboardStore)
                case .advanced: AdvancedSettingsView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .id(store.appLanguage)
        .frame(minWidth: 900, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            if !store.isBusy { await store.reloadProviders() }
        }
    }
}

/// Observes the dashboard only while the Menu Bar pane is visible.
private struct LiveMenuBarSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var dashboardStore: DashboardStore

    var body: some View {
        MenuBarSettingsView(store: store, snapshots: dashboardStore.snapshots)
    }
}

struct SettingsSidebar: View {
    @ObservedObject var store: SettingsStore

    private var selection: Binding<SettingsStore.Tab?> {
        Binding(get: { store.tab }, set: { tab in
            if let tab = tab { store.tab = tab }
        })
    }

    private var version: String? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SettingsAppBadge(size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AIUsageBar")
                        .font(.system(size: 14, weight: .semibold))
                    Text(L("Settings"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .accessibilityElement(children: .combine)

            List(selection: selection) {
                ForEach(SettingsStore.Tab.allCases) { tab in
                    HStack(spacing: 9) {
                        SettingsIconTile(symbol: tab.symbol, color: tab.tint, size: 22)
                        Text(L(tab.rawValue))
                            .font(.system(size: 13))
                    }
                    .padding(.vertical, 2)
                    .tag(tab)
                    .accessibilityLabel(Text(L(tab.rawValue)))
                }
            }
            .listStyle(.sidebar)

            if let version = version {
                Text(L("Version %@", version))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
            }
        }
        .background(SettingsVisualEffect(material: .sidebar).ignoresSafeArea())
    }
}

/// The app icon inside the bundle; a gradient tile when run outside it.
struct SettingsAppBadge: View {
    var size: CGFloat = 36

    var body: some View {
        Group {
            if Bundle.main.bundleURL.pathExtension == "app", let icon = NSApp?.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color(nsColor: .systemTeal), Color(nsColor: .systemBlue), Color(nsColor: .systemIndigo)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing))
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: size * 0.46, weight: .bold))
                        .foregroundColor(.white)
                        .shadow(color: Color.black.opacity(0.2), radius: 0.5, y: 0.5)
                }
                .frame(width: size, height: size)
                .shadow(color: Color(nsColor: .systemBlue).opacity(0.3), radius: 3, y: 1.5)
            }
        }
        .accessibilityHidden(true)
    }
}

struct SettingsVisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

// MARK: - Shared building blocks

/// White SF Symbol on a colored continuous rounded square.
struct SettingsIconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [color.opacity(0.78), color], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Card surface used by every settings group. Lighter than the window in
/// both appearances, like System Settings' inset groups.
enum SettingsSurface {
    static let fill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.055)
            : NSColor.white.withAlphaComponent(0.72)
    })
    static let border = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.09)
            : NSColor.black.withAlphaComponent(0.075)
    })
}

struct SettingsCard<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                    .fill(SettingsSurface.fill))
            .overlay(
                RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                    .strokeBorder(SettingsSurface.border, lineWidth: 0.5))
    }
}

/// A page: large title with a one-line description, then grouped sections.
struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    var tab: SettingsStore.Tab? = nil
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsPageTitle(title: title, subtitle: subtitle, tab: tab)
                content
            }
            .frame(maxWidth: 700, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 22)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
    }
}

struct SettingsPageTitle: View {
    let title: String
    let subtitle: String
    var tab: SettingsStore.Tab? = nil

    var body: some View {
        HStack(spacing: 14) {
            if let tab = tab {
                SettingsIconTile(symbol: tab.symbol, color: tab.tint, size: 44)
                    .shadow(color: tab.tint.opacity(0.28), radius: 4, y: 2)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Header, inset card and optional footnote.
struct SettingsSection<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 2)
                    .accessibilityAddTraits(.isHeader)
            }
            SettingsCard {
                VStack(alignment: .leading, spacing: 0) { content }
            }
            if let footer = footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// Label (and optional subtitle) on the left, control on the right.
struct SettingsRow<Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var symbolColor: Color = Color(nsColor: .systemBlue)
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            if let symbol = symbol {
                SettingsIconTile(symbol: symbol, color: symbolColor, size: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 42)
    }
}

struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var symbolColor: Color = Color(nsColor: .systemBlue)
    let isOn: Binding<Bool>

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, symbol: symbol, symbolColor: symbolColor) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

struct SettingsRowDivider: View {
    var inset: CGFloat = 14

    var body: some View {
        Divider().padding(.leading, inset)
    }
}

/// Tinted inline message. Replaces the old monospaced status box.
struct SettingsBanner: View {
    let text: String
    var tone: SettingsStore.StatusTone = .info
    var busy = false

    private var color: Color {
        switch tone {
        case .quiet, .info: return Color(nsColor: .systemBlue)
        case .success: return Color(nsColor: .systemGreen)
        case .warning: return Color(nsColor: .systemOrange)
        case .error: return Color(nsColor: .systemRed)
        }
    }

    private var symbol: String {
        switch tone {
        case .quiet, .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
                    .frame(width: 14, height: 14)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(color)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.primary.opacity(0.85))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(busy ? 0.07 : 0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(color.opacity(0.22), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject var store: SettingsStore
    private let intervals: [(String, TimeInterval)] = [
        ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300), ("15 minutes", 900), ("30 minutes", 1800),
    ]

    var body: some View {
        SettingsPage(
            title: L("General"),
            subtitle: L("Refresh behavior and application lifecycle"),
            tab: .general)
        {
            SettingsSection(
                title: L("Language"),
                footer: L("Menus update immediately; reopen this window to refresh every label."))
            {
                SettingsRow(title: L("Language"), symbol: "globe", symbolColor: Color(nsColor: .systemBlue)) {
                    Picker(L("Language"), selection: Binding(
                        get: { store.appLanguage },
                        set: { store.setAppLanguage($0) }))
                    {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.pickerTitle).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }

            SettingsSection(
                title: L("Refresh"),
                footer: store.refreshMode == .adaptive
                    ? L("Adaptive refresh uses 2 minutes after menu activity, 5 minutes while warm, 15 minutes while idle, and 30 minutes in Low Power Mode.")
                    : nil)
            {
                SettingsRow(title: L("Mode"), symbol: "arrow.triangle.2.circlepath", symbolColor: Color(nsColor: .systemGreen)) {
                    Picker(L("Mode"), selection: Binding(
                        get: { store.refreshMode },
                        set: { store.setRefreshMode($0) }))
                    {
                        ForEach(RefreshMode.allCases) { mode in
                            Text(L(mode.title)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                if store.refreshMode == .fixed {
                    SettingsRowDivider(inset: 50)
                    SettingsRow(title: L("Interval"), symbol: "timer", symbolColor: Color(nsColor: .systemTeal)) {
                        Picker(L("Interval"), selection: Binding(
                            get: { store.refreshInterval },
                            set: { store.setRefreshInterval($0) }))
                        {
                            ForEach(Array(intervals.enumerated()), id: \.offset) { _, entry in
                                Text(L(entry.0)).tag(entry.1)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
                SettingsRowDivider(inset: 50)
                SettingsToggleRow(
                    title: L("Refresh when the status menu opens"),
                    symbol: "cursorarrow.click.2",
                    symbolColor: Color(nsColor: .systemIndigo),
                    isOn: Binding(get: { store.refreshOnMenuOpen }, set: { store.setRefreshOnMenuOpen($0) }))
            }

            CurrencySettingsView()

            SettingsSection(title: L("Application")) {
                SettingsToggleRow(
                    title: L("Launch at login"),
                    symbol: "power",
                    symbolColor: Color(nsColor: .systemGray),
                    isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                SettingsRowDivider(inset: 50)
                SettingsToggleRow(
                    title: L("Automatically download updates"),
                    symbol: "arrow.down.circle.fill",
                    symbolColor: Color(nsColor: .systemBlue),
                    isOn: Binding(get: { store.automaticUpdates }, set: { store.setAutomaticUpdates($0) }))
            }
        }
    }
}

// MARK: - Menu Bar

struct MenuBarSettingsView: View {
    @ObservedObject var store: SettingsStore
    var snapshots: [ProviderSnapshot] = []

    var body: some View {
        SettingsPage(
            title: L("Menu Bar"),
            subtitle: L("Choose what appears in the status item and native menu"),
            tab: .menuBar)
        {
            SettingsMenuBarPreview(
                style: store.menuBarDisplayStyle,
                merged: store.mergeIcons,
                snapshots: snapshots)

            SettingsSection(title: L("Status item")) {
                SettingsRow(title: L("Display"), symbol: "menubar.rectangle", symbolColor: Color(nsColor: .systemBlue)) {
                    Picker(L("Display"), selection: Binding(
                        get: { store.menuBarDisplayStyle },
                        set: { store.setMenuBarDisplayStyle($0) }))
                    {
                        ForEach(MenuBarDisplayStyle.allCases) { style in
                            Text(L(style.title)).tag(style)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                SettingsRowDivider(inset: 50)
                SettingsToggleRow(
                    title: L("Merge provider icons"),
                    subtitle: L("One status item for all providers instead of one per provider"),
                    symbol: "square.stack.3d.up.fill",
                    symbolColor: Color(nsColor: .systemIndigo),
                    isOn: Binding(get: { store.mergeIcons }, set: { store.setMergeIcons($0) }))
            }

            SettingsSection(title: L("Native menu content")) {
                Group {
                    SettingsToggleRow(
                        title: L("Show account names"),
                        symbol: "person.crop.circle.fill",
                        symbolColor: Color(nsColor: .systemBlue),
                        isOn: Binding(get: { store.showAccountInMenu }, set: { store.setShowAccountInMenu($0) }))
                    SettingsRowDivider(inset: 50)
                    SettingsToggleRow(
                        title: L("Show summary metrics"),
                        symbol: "chart.bar.doc.horizontal.fill",
                        symbolColor: Color(nsColor: .systemPurple),
                        isOn: Binding(get: { store.showMenuMetrics }, set: { store.setShowMenuMetrics($0) }))
                    SettingsRowDivider(inset: 50)
                    SettingsToggleRow(
                        title: L("Show reset time and pace"),
                        symbol: "clock.fill",
                        symbolColor: Color(nsColor: .systemOrange),
                        isOn: Binding(get: { store.showResetTime }, set: { store.setShowResetTime($0) }))
                    SettingsRowDivider(inset: 50)
                    SettingsToggleRow(
                        title: L("Show provider service status"),
                        symbol: "waveform.path.ecg",
                        symbolColor: Color(nsColor: .systemGreen),
                        isOn: Binding(get: { store.showServiceStatus }, set: { store.setShowServiceStatus($0) }))
                }
                Group {
                    SettingsRowDivider(inset: 50)
                    SettingsRow(title: L("Quota values"), symbol: "percent", symbolColor: Color(nsColor: .systemTeal)) {
                        Picker(L("Quota values"), selection: Binding(
                            get: { store.menuQuotaPresentation },
                            set: { store.setMenuQuotaPresentation($0) }))
                        {
                            ForEach(MenuQuotaPresentation.allCases) { presentation in
                                Text(L(presentation.title)).tag(presentation)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    SettingsRowDivider(inset: 50)
                    SettingsRow(title: L("Overview rows"), symbol: "list.bullet", symbolColor: Color(nsColor: .systemGray)) {
                        Picker(L("Overview rows"), selection: Binding(
                            get: { store.overviewProviderLimit },
                            set: { store.setOverviewProviderLimit($0) }))
                        {
                            Text(L("3 providers")).tag(3)
                            Text(L("6 providers")).tag(6)
                            Text(L("9 providers")).tag(9)
                            Text(L("12 providers")).tag(12)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
            }
        }
    }
}

/// A miniature desktop with a menu bar showing how the status item will
/// look with the current options. Uses live values when available.
struct SettingsMenuBarPreview: View {
    let style: MenuBarDisplayStyle
    let merged: Bool
    let snapshots: [ProviderSnapshot]

    private struct Item: Identifiable {
        let id: String
        let provider: String
        let used: Double
    }

    private var items: [Item] {
        var live = snapshots.compactMap { snapshot -> Item? in
            guard let used = snapshot.headlineUsedPercent else { return nil }
            return Item(id: snapshot.id, provider: snapshot.provider, used: used)
        }
        if live.isEmpty {
            live = [
                Item(id: "claude", provider: "claude", used: 42),
                Item(id: "codex", provider: "codex", used: 68),
                Item(id: "zai", provider: "zai", used: 17),
            ]
        }
        let shown = Array(live.prefix(4))
        if merged {
            let highest = shown.max(by: { $0.used < $1.used }) ?? shown[0]
            return [Item(id: "merged", provider: shown.count == 1 ? highest.provider : "", used: highest.used)]
        }
        return shown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [Color(red: 0.26, green: 0.45, blue: 0.86),
                             Color(red: 0.55, green: 0.38, blue: 0.82),
                             Color(red: 0.93, green: 0.55, blue: 0.48)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing)
                VStack(spacing: 6) {
                    SettingsMenuBarStrip {
                        HStack(spacing: 2) {
                            ForEach(items) { item in
                                statusItem(item)
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        dropdown
                            .padding(.trailing, 96)
                    }
                }
            }
            .frame(height: 132)
            .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                    .strokeBorder(SettingsSurface.border, lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.08), radius: 4, y: 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(L("Menu bar preview")))

            Text(snapshots.contains(where: { $0.headlineUsedPercent != nil })
                ? L("Preview uses your latest provider values.")
                : L("Preview uses sample values."))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.horizontal, 2)
        }
    }

    /// Rows of the menu that opens from the status item.
    private var menuRows: [Item] {
        var live = snapshots.compactMap { snapshot -> Item? in
            guard let used = snapshot.headlineUsedPercent else { return nil }
            return Item(id: snapshot.id, provider: snapshot.provider, used: used)
        }
        if live.isEmpty {
            live = [
                Item(id: "claude", provider: "claude", used: 42),
                Item(id: "codex", provider: "codex", used: 68),
                Item(id: "zai", provider: "zai", used: 17),
            ]
        }
        return Array(live.prefix(3))
    }

    private var dropdown: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(menuRows) { row in
                HStack(spacing: 7) {
                    ProviderBadge(providerID: row.provider, size: 14)
                    Text(ProviderCatalog.displayName(for: row.provider))
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .frame(width: 58, alignment: .leading)
                    UsageBar(fill: 100 - row.used, remaining: 100 - row.used, height: 4)
                        .frame(width: 64)
                    Text(String(format: "%.0f%%", 100 - row.used))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 26, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.18), radius: 6, y: 3)
    }

    @ViewBuilder
    private func statusItem(_ item: Item) -> some View {
        Group {
            switch style {
            case .meter:
                SettingsMeterGlyph(used: item.used)
            case .usedPercentage:
                HStack(spacing: 3) {
                    SettingsMeterGlyph(used: item.used)
                    Text(String(format: "%.0f%%", item.used))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                }
            case .remainingPercentage:
                HStack(spacing: 3) {
                    SettingsMeterGlyph(used: item.used)
                    Text(String(format: "%.0f%%", max(0, 100 - item.used)))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                }
            case .providerIcon:
                if item.provider.isEmpty {
                    SettingsMeterGlyph(used: item.used)
                } else {
                    Image(systemName: ProviderBrand.symbol(for: item.provider))
                        .font(.system(size: 12, weight: .medium))
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(item.id == items.first?.id ? 0.12 : 0)))
    }
}

private struct SettingsMenuBarStrip<Items: View>: View {
    @ViewBuilder let items: Items

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "applelogo")
                .font(.system(size: 12, weight: .semibold))
            Text("Finder").font(.system(size: 12, weight: .bold))
            Spacer(minLength: 8)
            items
            Image(systemName: "wifi").font(.system(size: 12, weight: .medium))
            Image(systemName: "battery.75").font(.system(size: 13))
            Text("9:41").font(.system(size: 12, weight: .medium).monospacedDigit())
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.ultraThinMaterial)
    }
}

/// The status item's ring glyph, drawn by the same code as the real icon.
private struct SettingsMeterGlyph: View {
    let used: Double

    var body: some View {
        let remaining = max(0, 100 - used)
        Image(nsImage: MenuController.ringImage(remaining: remaining, failed: false, size: 14))
            .renderingMode(remaining < 15 ? .original : .template)
    }
}

// MARK: - Notifications

struct NotificationSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsPage(
            title: L("Notifications"),
            subtitle: L("Receive transition-based alerts without repeated notification noise"),
            tab: .notifications)
        {
            SettingsSection(title: L("Provider status")) {
                SettingsToggleRow(
                    title: L("Notify when a provider becomes unavailable or degraded"),
                    symbol: "exclamationmark.triangle.fill",
                    symbolColor: Color(nsColor: .systemOrange),
                    isOn: Binding(
                        get: { store.notifyOnServiceIncidents },
                        set: { store.setNotifyOnServiceIncidents($0) }))
                SettingsRowDivider(inset: 50)
                SettingsToggleRow(
                    title: L("Notify when the provider recovers"),
                    symbol: "checkmark.seal.fill",
                    symbolColor: Color(nsColor: .systemGreen),
                    isOn: Binding(get: { store.notifyOnRecovery }, set: { store.setNotifyOnRecovery($0) }))
                    .disabled(!store.notifyOnServiceIncidents)
                    .opacity(store.notifyOnServiceIncidents ? 1 : 0.55)
            }

            SettingsSection(
                title: L("Quota warnings"),
                footer: L("Alerts are sent only when a refreshed value crosses the threshold. The first refresh after launch establishes a baseline."))
            {
                SettingsToggleRow(
                    title: L("Notify when usage crosses the warning threshold"),
                    symbol: "speedometer",
                    symbolColor: Color(nsColor: .systemRed),
                    isOn: Binding(
                        get: { store.notifyOnQuotaThreshold },
                        set: { store.setNotifyOnQuotaThreshold($0) }))
                SettingsRowDivider(inset: 50)
                SettingsThresholdRow(store: store)
                    .disabled(!store.notifyOnQuotaThreshold)
                    .opacity(store.notifyOnQuotaThreshold ? 1 : 0.55)
            }
        }
    }
}

private struct SettingsThresholdRow: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SettingsIconTile(symbol: "slider.horizontal.3", color: Color(nsColor: .systemGray), size: 24)
                Text(L("Warning threshold"))
                    .font(.system(size: 13))
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(String(format: "%.0f", store.quotaWarningThreshold))
                        .font(DS.numeral(20, weight: .bold))
                    Text("%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.secondary)
                }
                .foregroundColor(DS.tone(remaining: 100 - store.quotaWarningThreshold))
                .accessibilityHidden(true)
            }
            HStack(spacing: 10) {
                Text("50%").font(.system(size: 10)).foregroundColor(.secondary)
                Slider(
                    value: Binding(
                        get: { store.quotaWarningThreshold },
                        set: { store.setQuotaWarningThreshold($0) }),
                    in: 50 ... 100,
                    step: 5)
                    .accessibilityLabel(Text(L("Warning threshold")))
                    .accessibilityValue(Text(String(format: "%.0f%%", store.quotaWarningThreshold)))
                Text("100%").font(.system(size: 10)).foregroundColor(.secondary)
            }
            .padding(.leading, 36)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

// MARK: - Advanced

struct AdvancedSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsPage(
            title: L("Advanced"),
            subtitle: L("Updates, configuration checks and diagnostics"),
            tab: .advanced)
        {
            SettingsSection(title: L("Updates")) {
                SettingsRow(
                    title: L("Software update"),
                    subtitle: L("Look for a newer AIUsageBar release now"),
                    symbol: "arrow.down.app.fill",
                    symbolColor: Color(nsColor: .systemBlue))
                {
                    Button(L("Check for updates"), action: { store.checkUpdates() })
                        .buttonStyle(.bordered)
                }
            }

            SettingsSection(title: L("Provider configuration")) {
                SettingsRow(
                    title: L("Validate provider configuration"),
                    subtitle: L("Ask the engine to check the config file for errors"),
                    symbol: "checkmark.shield.fill",
                    symbolColor: Color(nsColor: .systemGreen))
                {
                    Button(action: { store.validateConfig() }) {
                        Text(L("Validate"))
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.isBusy)
                    .accessibilityLabel(Text(L("Validate provider configuration")))
                }
                SettingsRowDivider(inset: 50)
                SettingsRow(
                    title: L("Configuration file"),
                    subtitle: L("Edit provider settings directly in JSON"),
                    symbol: "doc.text.fill",
                    symbolColor: Color(nsColor: .systemOrange))
                {
                    Button(L("Open config file"), action: { store.openConfig() })
                        .buttonStyle(.bordered)
                }
            }

            SettingsSection(title: L("Diagnostics")) {
                SettingsRow(
                    title: L("Console logs"),
                    subtitle: L("Search for AIUsageBar in Console to see diagnostics"),
                    symbol: "terminal.fill",
                    symbolColor: Color(red: 0.36, green: 0.40, blue: 0.48))
                {
                    Button(L("Open Console logs"), action: { store.openLogs() })
                        .buttonStyle(.bordered)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Last result"))
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 2)
                if store.isBusy {
                    SettingsBanner(text: store.status, tone: .info, busy: true)
                } else if store.statusTone == .quiet {
                    Text(L("Results from the actions above appear here."))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                                .strokeBorder(SettingsSurface.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                } else {
                    SettingsBanner(text: store.status, tone: store.statusTone)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(L("Command output")))
        }
    }
}
