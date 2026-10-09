@preconcurrency import AppKit
import SwiftUI


struct SettingsRootView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var dashboardStore: DashboardStore

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AIUsageBar")
                    .font(.system(size: 16, weight: .bold))
                    .padding(.horizontal, 14)
                    .padding(.top, 18)
                    .padding(.bottom, 10)
                ForEach(SettingsStore.Tab.allCases) { tab in
                    Button(action: { store.tab = tab }) {
                        HStack(spacing: 10) {
                            Image(systemName: tab.symbol)
                                .frame(width: 18)
                            Text(L(tab.rawValue))
                            Spacer()
                        }
                        .font(.system(size: 13, weight: store.tab == tab ? .semibold : .regular))
                        .padding(.horizontal, 11)
                        .frame(height: 34)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(store.tab == tab ? Color.accentColor.opacity(0.18) : Color.clear))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                Spacer()
            }
            .padding(8)
            .frame(width: 190)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))

            Divider()

            Group {
                switch store.tab {
                case .general: GeneralSettingsView(store: store)
                case .menuBar: MenuBarSettingsView(store: store)
                case .notifications: NotificationSettingsView(store: store)
                case .usageData: TokenHistorySettingsView(dashboardStore: dashboardStore)
                case .providers: ProviderSettingsView(store: store, dashboardStore: dashboardStore)
                case .advanced: AdvancedSettingsView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(store.appLanguage)
        .frame(minWidth: 900, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            if !store.isBusy { await store.reloadProviders() }
        }
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var store: SettingsStore
    private let intervals: [(String, TimeInterval)] = [
        ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300), ("15 minutes", 900), ("30 minutes", 1800),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsPageTitle(
                    title: L("General"),
                    subtitle: L("Refresh behavior and application lifecycle"))
                GroupBox(label: Text(L("Language")).font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(L("Language"), selection: Binding(
                            get: { store.appLanguage },
                            set: { store.setAppLanguage($0) }))
                        {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.pickerTitle).tag(language)
                            }
                        }
                        Text(L("Menus update immediately; reopen this window to refresh every label."))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                }
                GroupBox(label: Text(L("Refresh")).font(.headline)) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker(L("Mode"), selection: Binding(
                            get: { store.refreshMode },
                            set: { store.setRefreshMode($0) }))
                        {
                            ForEach(RefreshMode.allCases) { mode in
                                Text(L(mode.title)).tag(mode)
                            }
                        }
                        if store.refreshMode == .fixed {
                            Picker(L("Interval"), selection: Binding(
                                get: { store.refreshInterval },
                                set: { store.setRefreshInterval($0) }))
                            {
                                ForEach(Array(intervals.enumerated()), id: \.offset) { _, entry in
                                    Text(L(entry.0)).tag(entry.1)
                                }
                            }
                        }
                        Toggle(
                            L("Refresh when the status menu opens"),
                            isOn: Binding(get: { store.refreshOnMenuOpen }, set: { store.setRefreshOnMenuOpen($0) }))
                        if store.refreshMode == .adaptive {
                            Text(L("Adaptive refresh uses 2 minutes after menu activity, 5 minutes while warm, 15 minutes while idle, and 30 minutes in Low Power Mode."))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(12)
                }
                CurrencySettingsView()
                GroupBox(label: Text(L("Application")).font(.headline)) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(L("Launch at login"), isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                        Toggle(L("Automatically download updates"), isOn: Binding(get: { store.automaticUpdates }, set: { store.setAutomaticUpdates($0) }))
                    }
                    .padding(12)
                }
            }
            .padding(28)
        }
    }
}

struct MenuBarSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsPageTitle(
                    title: L("Menu Bar"),
                    subtitle: L("Choose what appears in the status item and native menu"))
                GroupBox(label: Text(L("Status item")).font(.headline)) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker(L("Display"), selection: Binding(
                            get: { store.menuBarDisplayStyle },
                            set: { store.setMenuBarDisplayStyle($0) }))
                        {
                            ForEach(MenuBarDisplayStyle.allCases) { style in
                                Text(L(style.title)).tag(style)
                            }
                        }
                        Toggle(L("Merge provider icons"), isOn: Binding(get: { store.mergeIcons }, set: { store.setMergeIcons($0) }))
                    }
                    .padding(12)
                }
                GroupBox(label: Text(L("Native menu content")).font(.headline)) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(L("Show account names"), isOn: Binding(get: { store.showAccountInMenu }, set: { store.setShowAccountInMenu($0) }))
                        Toggle(L("Show summary metrics"), isOn: Binding(get: { store.showMenuMetrics }, set: { store.setShowMenuMetrics($0) }))
                        Toggle(L("Show reset time and pace"), isOn: Binding(get: { store.showResetTime }, set: { store.setShowResetTime($0) }))
                        Toggle(L("Show provider service status"), isOn: Binding(get: { store.showServiceStatus }, set: { store.setShowServiceStatus($0) }))
                        Picker(L("Quota values"), selection: Binding(
                            get: { store.menuQuotaPresentation },
                            set: { store.setMenuQuotaPresentation($0) }))
                        {
                            ForEach(MenuQuotaPresentation.allCases) { presentation in
                                Text(L(presentation.title)).tag(presentation)
                            }
                        }
                        Picker(L("Overview rows"), selection: Binding(
                            get: { store.overviewProviderLimit },
                            set: { store.setOverviewProviderLimit($0) }))
                        {
                            Text(L("3 providers")).tag(3)
                            Text(L("6 providers")).tag(6)
                            Text(L("9 providers")).tag(9)
                            Text(L("12 providers")).tag(12)
                        }
                    }
                    .padding(12)
                }
            }
            .padding(28)
        }
    }
}

struct NotificationSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsPageTitle(
                    title: L("Notifications"),
                    subtitle: L("Receive transition-based alerts without repeated notification noise"))
                GroupBox(label: Text(L("Provider status")).font(.headline)) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(
                            L("Notify when a provider becomes unavailable or degraded"),
                            isOn: Binding(
                                get: { store.notifyOnServiceIncidents },
                                set: { store.setNotifyOnServiceIncidents($0) }))
                        Toggle(
                            L("Notify when the provider recovers"),
                            isOn: Binding(get: { store.notifyOnRecovery }, set: { store.setNotifyOnRecovery($0) }))
                            .disabled(!store.notifyOnServiceIncidents)
                    }
                    .padding(12)
                }
                GroupBox(label: Text(L("Quota warnings")).font(.headline)) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(
                            L("Notify when usage crosses the warning threshold"),
                            isOn: Binding(
                                get: { store.notifyOnQuotaThreshold },
                                set: { store.setNotifyOnQuotaThreshold($0) }))
                        HStack {
                            Text(L("Warning threshold"))
                            Slider(
                                value: Binding(
                                    get: { store.quotaWarningThreshold },
                                    set: { store.setQuotaWarningThreshold($0) }),
                                in: 50 ... 100,
                                step: 5)
                            Text(String(format: "%.0f%%", store.quotaWarningThreshold))
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 42, alignment: .trailing)
                        }
                        .disabled(!store.notifyOnQuotaThreshold)
                        Text(L("Alerts are sent only when a refreshed value crosses the threshold. The first refresh after launch establishes a baseline."))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                }
            }
            .padding(28)
        }
    }
}

struct SettingsPageTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 24, weight: .bold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }
}

struct AdvancedSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(L("Check for updates"), action: { store.checkUpdates() })
            Button(L("Validate provider configuration"), action: { store.validateConfig() })
            Button(L("Open config file"), action: { store.openConfig() })
            Button(L("Open Console logs"), action: { store.openLogs() })
            GroupBox(label: Text(L("Command output"))) {
                ScrollView {
                    Text(store.status)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(minHeight: 200)
            }
            Spacer()
        }
        .padding(28)
    }
}
