@preconcurrency import AppKit
import SwiftUI


@MainActor
final class SettingsStore: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case menuBar = "Menu Bar"
        case notifications = "Notifications"
        case usageData = "Usage Data"
        case providers = "Providers"
        case advanced = "Advanced"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .menuBar: return "menubar.rectangle"
            case .notifications: return "bell"
            case .usageData: return "chart.bar"
            case .providers: return "square.grid.2x2"
            case .advanced: return "wrench.and.screwdriver"
            }
        }
    }

    @Published var tab: Tab = .providers
    @Published private(set) var providers: [ProviderDescriptor] = []
    @Published var selectedProviderID: String?
    @Published var apiKey = ""
    @Published var credentialLabel = "Default"
    @Published var enterpriseHost = ""
    @Published var workspaceID = ""
    @Published var region = ""
    @Published var revealAPIKey = false
    @Published var providerSearch = ""
    @Published private(set) var status = L("Select a provider to configure authentication.")
    @Published private(set) var isBusy = false
    @Published private(set) var configuredAccounts: [ConfiguredProviderAccount] = []

    @Published private(set) var refreshMode = Preferences.shared.refreshMode
    @Published private(set) var refreshInterval = Preferences.shared.refreshInterval
    @Published private(set) var refreshOnMenuOpen = Preferences.shared.refreshOnMenuOpen
    @Published private(set) var mergeIcons = Preferences.shared.mergeIcons
    @Published private(set) var menuBarDisplayStyle = Preferences.shared.menuBarDisplayStyle
    @Published private(set) var showAccountInMenu = Preferences.shared.showAccountInMenu
    @Published private(set) var showMenuMetrics = Preferences.shared.showMenuMetrics
    @Published private(set) var showResetTime = Preferences.shared.showResetTime
    @Published private(set) var showServiceStatus = Preferences.shared.showServiceStatus
    @Published private(set) var menuQuotaPresentation = Preferences.shared.menuQuotaPresentation
    @Published private(set) var overviewProviderLimit = Preferences.shared.overviewProviderLimit
    @Published private(set) var notifyOnServiceIncidents = Preferences.shared.notifyOnServiceIncidents
    @Published private(set) var notifyOnRecovery = Preferences.shared.notifyOnRecovery
    @Published private(set) var notifyOnQuotaThreshold = Preferences.shared.notifyOnQuotaThreshold
    @Published private(set) var quotaWarningThreshold = Preferences.shared.quotaWarningThreshold
    @Published private(set) var launchAtLogin = Preferences.shared.launchAtLogin
    @Published private(set) var automaticUpdates = Preferences.shared.automaticUpdates
    @Published private(set) var appLanguage = L10n.language

    private let client: CLIClient
    private let updater: UpdaterController
    private var requestedProviderID: String?
    private var isReloadingProviders = false

    init(client: CLIClient, updater: UpdaterController) {
        self.client = client
        self.updater = updater
    }

    var selectedProvider: ProviderDescriptor? {
        guard let selectedProviderID = selectedProviderID else { return nil }
        return providers.first(where: { $0.id == selectedProviderID })
    }

    var selectedAuthenticationProfile: ProviderAuthenticationProfile? {
        guard let provider = selectedProvider else { return nil }
        return ProviderAuthenticationCatalog.profile(for: provider.id)
    }

    var filteredProviders: [ProviderDescriptor] {
        let query = providerSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return providers }
        return providers.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
                $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    var canSaveSelectedConfiguration: Bool {
        guard let profile = selectedAuthenticationProfile, profile.canSaveConfiguration else {
            return false
        }
        if profile.requiresSecret &&
            apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return false
        }
        if profile.enterpriseHostRequired &&
            enterpriseHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return false
        }
        if profile.workspaceRequired &&
            workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return false
        }
        if profile.storage == .providerFields {
            return !enterpriseHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    func requestSelection(_ providerID: String) {
        requestedProviderID = providerID
        selectedProviderID = providerID
        tab = .providers
    }

    func reloadProviders() async {
        guard !isReloadingProviders else { return }
        isReloadingProviders = true
        isBusy = true
        defer {
            isBusy = false
            isReloadingProviders = false
        }
        do {
            providers = try await client.listProviders()
            let target = requestedProviderID ?? selectedProviderID
            if let target = target, providers.contains(where: { $0.id == target }) {
                selectedProviderID = target
            } else if selectedProviderID == nil {
                selectedProviderID = providers.first?.id
            }
            requestedProviderID = nil
            if let selectedProvider = selectedProvider {
                status = L("Selected %@ (provider ID: %@).", selectedProvider.name, selectedProvider.id)
            } else {
                status = L("%d providers detected.", providers.count)
            }
            await reloadConfiguredAccounts()
        } catch {
            status = error.localizedDescription
        }
    }

    func select(_ provider: ProviderDescriptor) {
        selectedProviderID = provider.id
        clearCredentialFields()
        let profile = ProviderAuthenticationCatalog.profile(for: provider.id)
        status = "\(profile.title): \(profile.guidance)"
        Task { @MainActor in await reloadConfiguredAccounts() }
    }

    func setEnabled(_ enabled: Bool, provider: ProviderDescriptor) {
        guard !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            do {
                try await client.setProvider(provider.id, enabled: enabled)
                NotificationCenter.default.post(name: .providerConfigurationChanged, object: provider.id)
                await reloadProviders()
            } catch {
                status = error.localizedDescription
            }
            isBusy = false
        }
    }

    func pasteAPIKey() {
        guard let value = NSPasteboard.general.string(forType: .string), !value.isEmpty else {
            status = L("Clipboard does not contain text.")
            return
        }
        apiKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
        status = L("API key pasted. Choose Save & Verify.")
    }

    func clearAPIKeyField() {
        clearCredentialFields()
        status = L("Credential fields cleared.")
    }

    private func clearCredentialFields() {
        apiKey = ""
        credentialLabel = "Default"
        enterpriseHost = ""
        workspaceID = ""
        region = ""
        revealAPIKey = false
    }

    func saveAndVerifyAPIKey() {
        guard !isBusy else { return }
        guard let provider = selectedProvider,
              let profile = selectedAuthenticationProfile
        else {
            status = L("Select a provider first.")
            return
        }
        guard profile.canSaveConfiguration else {
            status = profile.guidance
            return
        }

        let input = ProviderCredentialInput(
            secret: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            accountLabel: credentialLabel.trimmingCharacters(in: .whitespacesAndNewlines),
            enterpriseHost: enterpriseHost.trimmingCharacters(in: .whitespacesAndNewlines),
            workspaceID: workspaceID.trimmingCharacters(in: .whitespacesAndNewlines),
            region: region.trimmingCharacters(in: .whitespacesAndNewlines))

        isBusy = true
        Task { @MainActor in
            let receipt: CredentialSaveReceipt
            do {
                status = L("Saving and verifying %@…", provider.name)
                receipt = try await client.saveCredential(
                    input,
                    provider: provider.id,
                    profile: profile)
            } catch {
                status = L("Save failed: %@", error.localizedDescription)
                isBusy = false
                return
            }

            NotificationCenter.default.post(
                name: .providerConfigurationChanged,
                object: provider.id)
            clearCredentialFields()
            await reloadProviders()
            status = L("%@ configuration saved and verified in %@.", provider.name, receipt.configURL.path)
            isBusy = false
        }
    }

    func refreshBrowserSession() {
        guard !isBusy else { return }
        guard let provider = selectedProvider else { return }
        isBusy = true
        Task { @MainActor in
            do {
                let result = try await client.refreshBrowserSession(provider: provider.id)
                status = result.isEmpty ? L("Browser session refreshed for %@.", provider.name) : result
                NotificationCenter.default.post(name: .providerConfigurationChanged, object: provider.id)
            } catch {
                status = error.localizedDescription
            }
            isBusy = false
        }
    }

    func clearBrowserSession() {
        guard !isBusy else { return }
        guard let provider = selectedProvider else { return }
        isBusy = true
        Task { @MainActor in
            do {
                let result = try await client.clearBrowserSession(provider: provider.id)
                status = result.isEmpty ? L("Browser cache cleared for %@.", provider.name) : result
                NotificationCenter.default.post(name: .providerConfigurationChanged, object: provider.id)
            } catch {
                status = error.localizedDescription
            }
            isBusy = false
        }
    }

    func openProviderDocs() {
        guard let provider = selectedProvider else { return }
        NSWorkspace.shared.open(ProviderCatalog.documentationURL(for: provider.id))
    }

    func openConfig() {
        Task { @MainActor in
            do {
                let target = try await client.configFileURL()
                NSWorkspace.shared.open(target)
            } catch {
                status = L("Could not open config file: %@", error.localizedDescription)
            }
        }
    }

    func validateConfig() {
        guard !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            do { status = try await client.validateConfig() }
            catch { status = error.localizedDescription }
            isBusy = false
        }
    }

    func openLogs() {
        let candidates = [
            URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
            URL(fileURLWithPath: "/Applications/Utilities/Console.app"),
        ]
        guard let console = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            status = L("Console.app could not be found.")
            return
        }
        NSWorkspace.shared.open(console)
        status = L("Opened Console. Search for AIUsageBar to view diagnostics.")
    }

    func checkUpdates() { updater.checkForUpdates() }

    func reloadConfiguredAccounts() async {
        guard let provider = selectedProvider else {
            configuredAccounts = []
            return
        }
        do {
            configuredAccounts = try await client.configuredAccounts(provider: provider.id)
        } catch {
            configuredAccounts = []
            status = L("Could not read configured accounts: %@", error.localizedDescription)
        }
    }

    func activateConfiguredAccount(_ account: ConfiguredProviderAccount) {
        guard !isBusy,
              let provider = selectedProvider,
              let profile = selectedAuthenticationProfile
        else { return }
        isBusy = true
        Task { @MainActor in
            do {
                status = L("Switching %@ to %@…", provider.name, account.label)
                try await client.activateConfiguredAccount(
                    provider: provider.id,
                    accountID: account.id,
                    profile: profile)
                await reloadConfiguredAccounts()
                NotificationCenter.default.post(name: .providerConfigurationChanged, object: provider.id)
                status = L("%@ is now the active %@ account.", account.label, provider.name)
            } catch {
                status = L("Account switch failed: %@", error.localizedDescription)
            }
            isBusy = false
        }
    }

    func removeConfiguredAccount(_ account: ConfiguredProviderAccount) {
        guard !isBusy, let provider = selectedProvider else { return }
        let alert = NSAlert()
        alert.messageText = L("Remove %@?", account.label)
        alert.informativeText = L("This removes the saved token from the provider configuration. Other accounts are preserved.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Remove"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isBusy = true
        Task { @MainActor in
            do {
                try await client.removeConfiguredAccount(provider: provider.id, accountID: account.id)
                await reloadConfiguredAccounts()
                NotificationCenter.default.post(name: .providerConfigurationChanged, object: provider.id)
                status = L("Removed %@ from %@.", account.label, provider.name)
            } catch {
                status = L("Account removal failed: %@", error.localizedDescription)
            }
            isBusy = false
        }
    }

    func setRefreshMode(_ value: RefreshMode) {
        refreshMode = value
        Preferences.shared.refreshMode = value
        postPreferencesChanged()
    }

    func setRefreshInterval(_ value: TimeInterval) {
        refreshInterval = value
        Preferences.shared.refreshInterval = value
        postPreferencesChanged()
    }

    func setRefreshOnMenuOpen(_ value: Bool) {
        refreshOnMenuOpen = value
        Preferences.shared.refreshOnMenuOpen = value
        postPreferencesChanged()
    }

    func setMergeIcons(_ value: Bool) {
        mergeIcons = value
        Preferences.shared.mergeIcons = value
        postPreferencesChanged()
    }

    func setMenuBarDisplayStyle(_ value: MenuBarDisplayStyle) {
        menuBarDisplayStyle = value
        Preferences.shared.menuBarDisplayStyle = value
        postPreferencesChanged()
    }

    func setShowAccountInMenu(_ value: Bool) {
        showAccountInMenu = value
        Preferences.shared.showAccountInMenu = value
        postPreferencesChanged()
    }

    func setShowMenuMetrics(_ value: Bool) {
        showMenuMetrics = value
        Preferences.shared.showMenuMetrics = value
        postPreferencesChanged()
    }

    func setShowResetTime(_ value: Bool) {
        showResetTime = value
        Preferences.shared.showResetTime = value
        postPreferencesChanged()
    }

    func setShowServiceStatus(_ value: Bool) {
        showServiceStatus = value
        Preferences.shared.showServiceStatus = value
        postPreferencesChanged()
    }

    func setMenuQuotaPresentation(_ value: MenuQuotaPresentation) {
        menuQuotaPresentation = value
        Preferences.shared.menuQuotaPresentation = value
        postPreferencesChanged()
    }

    func setOverviewProviderLimit(_ value: Int) {
        overviewProviderLimit = value
        Preferences.shared.overviewProviderLimit = value
        postPreferencesChanged()
    }

    func setNotifyOnServiceIncidents(_ value: Bool) {
        notifyOnServiceIncidents = value
        Preferences.shared.notifyOnServiceIncidents = value
        if value { ProviderAlertController.requestAuthorization() }
        postPreferencesChanged()
    }

    func setNotifyOnRecovery(_ value: Bool) {
        notifyOnRecovery = value
        Preferences.shared.notifyOnRecovery = value
        postPreferencesChanged()
    }

    func setNotifyOnQuotaThreshold(_ value: Bool) {
        notifyOnQuotaThreshold = value
        Preferences.shared.notifyOnQuotaThreshold = value
        if value { ProviderAlertController.requestAuthorization() }
        postPreferencesChanged()
    }

    func setQuotaWarningThreshold(_ value: Double) {
        quotaWarningThreshold = value
        Preferences.shared.quotaWarningThreshold = value
        postPreferencesChanged()
    }

    func setLaunchAtLogin(_ value: Bool) {
        launchAtLogin = value
        Preferences.shared.launchAtLogin = value
    }

    func setAutomaticUpdates(_ value: Bool) {
        automaticUpdates = value
        Preferences.shared.automaticUpdates = value
        updater.setAutomatic(value)
    }

    func setAppLanguage(_ value: AppLanguage) {
        L10n.language = value
        appLanguage = value
        postPreferencesChanged()
    }

    private func postPreferencesChanged() {
        NotificationCenter.default.post(name: .preferencesChanged, object: nil)
    }
}
