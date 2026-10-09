@preconcurrency import AppKit
import SwiftUI


struct ProviderSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var dashboardStore: DashboardStore

    var body: some View {
        HStack(spacing: 0) {
            providerList
                .frame(width: 340)
                .disabled(store.isBusy)
            Divider()
            configurationPane
        }
    }

    private var providerList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Providers")).font(.system(size: 17, weight: .bold))
                Spacer()
                Button(action: { Task { @MainActor in await store.reloadProviders() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(BorderlessButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)
            TextField(L("Search providers"), text: $store.providerSearch)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(store.filteredProviders) { provider in
                        ProviderSettingsRow(
                            provider: provider,
                            selected: store.selectedProviderID == provider.id,
                            select: { store.select(provider) },
                            toggle: { store.setEnabled($0, provider: provider) })
                    }
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private var configurationPane: some View {
        if let provider = store.selectedProvider {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(ProviderBrand.color(for: provider.id).opacity(0.18))
                            Image(systemName: ProviderBrand.symbol(for: provider.id))
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundColor(ProviderBrand.color(for: provider.id))
                        }
                        .frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(provider.name).font(.system(size: 22, weight: .bold))
                            Text(L("Provider ID: %@", provider.id)).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }

                    let profile = ProviderAuthenticationCatalog.profile(for: provider.id)
                    let connectedSnapshots = dashboardStore.snapshots.filter { $0.provider == provider.id }

                    GroupBox(label: Text(L("Connection & service")).font(.headline)) {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Label(profile.methodTitle, systemImage: profile.methodSymbol)
                                    .font(.system(size: 11, weight: .medium))
                                Spacer()
                                Text(provider.enabled ? L("Enabled") : L("Disabled"))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(provider.enabled ? .green : .secondary)
                            }
                            if connectedSnapshots.isEmpty {
                                Text(provider.enabled
                                    ? L("No account snapshot is available yet. Refresh after configuring authentication.")
                                    : L("Enable this provider to fetch account and quota information."))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            } else {
                                ForEach(connectedSnapshots) { snapshot in
                                    ProviderConnectionRow(snapshot: snapshot)
                                }
                            }
                        }
                        .padding(10)
                    }

                    GroupBox(label: Text(profile.title).font(.headline)) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(profile.guidance)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)

                            if profile.canSaveConfiguration {
                                if profile.requiresSecret {
                                    Text(profile.secretLabel)
                                        .font(.system(size: 11, weight: .semibold))
                                    HStack(spacing: 8) {
                                        Group {
                                            if store.revealAPIKey {
                                                TextField(profile.secretPlaceholder, text: $store.apiKey)
                                            } else {
                                                SecureField(profile.secretPlaceholder, text: $store.apiKey)
                                            }
                                        }
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                        Button(action: { store.pasteAPIKey() }) {
                                            Label(L("Paste"), systemImage: "doc.on.clipboard")
                                        }
                                        Button(action: { store.revealAPIKey.toggle() }) {
                                            Image(systemName: store.revealAPIKey ? "eye.slash" : "eye")
                                        }
                                        .buttonStyle(BorderlessButtonStyle())
                                    }
                                }

                                if profile.accountLabelVisible {
                                    TextField(L("Account label"), text: $store.credentialLabel)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                }

                                if let label = profile.enterpriseHostLabel {
                                    TextField(label, text: $store.enterpriseHost)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                }

                                if let label = profile.workspaceLabel {
                                    TextField(label, text: $store.workspaceID)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                }

                                if let label = profile.regionLabel {
                                    TextField(
                                        profile.regionPlaceholder.map { "\(label): \($0)" } ?? label,
                                        text: $store.region)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                }

                                HStack {
                                    Button(L("Save & Verify"), action: { store.saveAndVerifyAPIKey() })
                                        .keyboardShortcut(.defaultAction)
                                        .disabled(!store.canSaveSelectedConfiguration || store.isBusy)
                                    Button(L("Clear fields"), action: { store.clearAPIKeyField() })
                                        .disabled(store.isBusy)
                                    Spacer()
                                }
                            } else {
                                Text(L("This provider does not accept a generic config API key. Use the provider login, CLI, OAuth, browser, or local source described above."))
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .padding(10)
                    }
                    .disabled(store.isBusy)

                    if profile.storage == .tokenAccount {
                        GroupBox(label: Text(L("Saved token accounts")).font(.headline)) {
                            VStack(alignment: .leading, spacing: 9) {
                                if store.configuredAccounts.isEmpty {
                                    Text(L("No token accounts are saved. Enter a label and API key above to add one."))
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                } else {
                                    ForEach(store.configuredAccounts) { account in
                                        HStack(spacing: 9) {
                                            Image(systemName: account.isActive ? "checkmark.circle.fill" : "circle")
                                                .foregroundColor(account.isActive ? .green : .secondary)
                                            Text(account.label)
                                                .font(.system(size: 12, weight: account.isActive ? .semibold : .regular))
                                            if account.isActive {
                                                Text(L("Active"))
                                                    .font(.system(size: 9, weight: .semibold))
                                                    .foregroundColor(.secondary)
                                            }
                                            Spacer()
                                            if !account.isActive {
                                                Button(L("Use"), action: { store.activateConfiguredAccount(account) })
                                            }
                                            Button(L("Remove"), action: { store.removeConfiguredAccount(account) })
                                                .foregroundColor(.red)
                                        }
                                        .padding(.vertical, 2)
                                    }
                                }
                            }
                            .padding(10)
                            .disabled(store.isBusy)
                        }
                    }

                    GroupBox(label: Text(L("Provider tools")).font(.headline)) {
                        HStack(spacing: 10) {
                            if profile.supportsBrowserTools {
                                Button(L("Refresh browser session"), action: { store.refreshBrowserSession() })
                                Button(L("Clear browser cache"), action: { store.clearBrowserSession() })
                            }
                            Button(L("Provider docs"), action: { store.openProviderDocs() })
                            Spacer()
                        }
                        .padding(10)
                        .disabled(store.isBusy)
                    }

                    GroupBox(label: Text(L("Status")).font(.headline)) {
                        HStack(alignment: .top, spacing: 8) {
                            if store.isBusy { ProgressView().scaleEffect(0.7) }
                            Text(store.status)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                    }
                }
                .padding(24)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "sidebar.left").font(.system(size: 32)).foregroundColor(.secondary)
                Text(L("Select a provider")).font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ProviderConnectionRow: View {
    let snapshot: ProviderSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(connectionColor)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.accountDisplayName ?? snapshot.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(detailText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if let percent = snapshot.maximumUsedPercent {
                Text(L("%.0f%% used", percent))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detailText: String {
        if let error = snapshot.error?.message { return error }
        if snapshot.serviceHealth.isIncident, let status = snapshot.status { return status.displayText }
        let parts = [snapshot.source, snapshot.planDisplayName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? L("Connected") : parts.joined(separator: " · ")
    }

    private var connectionColor: Color {
        if snapshot.error != nil { return .red }
        switch snapshot.serviceHealth {
        case .unknown: return .secondary
        case .operational: return .green
        case .degraded: return .orange
        case .outage: return .red
        }
    }
}

struct ProviderSettingsRow: View {
    let provider: ProviderDescriptor
    let selected: Bool
    let select: () -> Void
    let toggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { provider.enabled }, set: toggle))
                .labelsHidden()
            Button(action: select) {
                HStack(spacing: 9) {
                    Image(systemName: ProviderBrand.symbol(for: provider.id))
                        .foregroundColor(ProviderBrand.color(for: provider.id))
                        .frame(width: 22)
                    Text(provider.name)
                        .lineLimit(1)
                    Spacer()
                    if selected { Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)) }
                }
                .padding(.horizontal, 8)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
    }
}
