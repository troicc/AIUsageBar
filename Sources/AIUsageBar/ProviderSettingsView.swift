@preconcurrency import AppKit
import SwiftUI

/// Connection state shown as a chip in the provider list and hero header.
enum SettingsProviderState: Equatable {
    case connected
    case needsAuthentication
    case failed
    case enabled
    case disabled

    init(provider: ProviderDescriptor, snapshots: [ProviderSnapshot]) {
        guard provider.enabled else {
            self = .disabled
            return
        }
        let own = snapshots.filter { $0.provider == provider.id }
        if own.isEmpty {
            self = .enabled
        } else if own.contains(where: { $0.error == nil }) {
            self = .connected
        } else {
            let message = own.compactMap { $0.error?.message?.lowercased() }.joined(separator: " ")
            let authHints = ["auth", "login", "log in", "sign in", "token", "api key", "apikey", "credential",
                             "cookie", "session", "401", "403", "unauthor", "forbidden", "认证", "登录"]
            self = authHints.contains(where: message.contains) ? .needsAuthentication : .failed
        }
    }

    var title: String {
        switch self {
        case .connected: return L("Connected")
        case .needsAuthentication: return L("Needs authentication")
        case .failed: return L("Error")
        case .enabled: return L("Enabled")
        case .disabled: return L("Disabled")
        }
    }

    var symbol: String? {
        switch self {
        case .connected: return "checkmark"
        case .needsAuthentication: return "key.fill"
        case .failed: return "exclamationmark"
        case .enabled, .disabled: return nil
        }
    }

    var tint: Color {
        switch self {
        case .connected: return Color(nsColor: .systemGreen)
        case .needsAuthentication: return Color(nsColor: .systemOrange)
        case .failed: return Color(nsColor: .systemRed)
        case .enabled: return Color(nsColor: .systemBlue)
        case .disabled: return .secondary
        }
    }

    var chip: DSChip { DSChip(text: title, symbol: symbol, tint: tint) }
}

struct ProviderSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var dashboardStore: DashboardStore

    var body: some View {
        HStack(spacing: 0) {
            SettingsProviderList(store: store, snapshots: dashboardStore.snapshots)
                .frame(width: 292)
                .disabled(store.isBusy)
            Divider()
                .ignoresSafeArea()
            configurationPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var configurationPane: some View {
        if let provider = store.selectedProvider {
            let profile = ProviderAuthenticationCatalog.profile(for: provider.id)
            let connectedSnapshots = dashboardStore.snapshots.filter { $0.provider == provider.id }
            let state = SettingsProviderState(provider: provider, snapshots: dashboardStore.snapshots)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SettingsProviderHero(
                        provider: provider,
                        profile: profile,
                        state: state,
                        plan: connectedSnapshots.compactMap(\.planDisplayName).first,
                        isBusy: store.isBusy,
                        toggle: { store.setEnabled($0, provider: provider) })

                    if store.isBusy {
                        SettingsBanner(text: store.status, tone: .info, busy: true)
                    } else if store.statusTone != .quiet {
                        SettingsBanner(text: store.status, tone: store.statusTone)
                    }

                    SettingsSection(title: L("Connection & service")) {
                        if connectedSnapshots.isEmpty {
                            HStack(spacing: 12) {
                                SettingsIconTile(
                                    symbol: provider.enabled ? "arrow.clockwise" : "power",
                                    color: provider.enabled ? Color(nsColor: .systemBlue) : Color(nsColor: .systemGray),
                                    size: 24)
                                Text(provider.enabled
                                    ? L("No account snapshot is available yet. Refresh after configuring authentication.")
                                    : L("Enable this provider to fetch account and quota information."))
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                        } else {
                            ForEach(Array(connectedSnapshots.enumerated()), id: \.element.id) { index, snapshot in
                                if index > 0 { SettingsRowDivider(inset: 50) }
                                ProviderConnectionRow(snapshot: snapshot)
                            }
                        }
                    }

                    SettingsProviderAuthentication(store: store, provider: provider, profile: profile)
                        .disabled(store.isBusy)

                    if profile.storage == .tokenAccount {
                        SettingsSection(title: L("Saved token accounts")) {
                            if store.configuredAccounts.isEmpty {
                                Text(L("No token accounts are saved. Enter a label and API key above to add one."))
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                            } else {
                                ForEach(Array(store.configuredAccounts.enumerated()), id: \.element.id) { index, account in
                                    if index > 0 { SettingsRowDivider(inset: 44) }
                                    SettingsTokenAccountRow(
                                        account: account,
                                        use: { store.activateConfiguredAccount(account) },
                                        remove: { store.removeConfiguredAccount(account) })
                                }
                            }
                        }
                        .disabled(store.isBusy)
                    }

                    SettingsSection(title: L("Provider tools")) {
                        VStack(alignment: .leading, spacing: 12) {
                            if profile.supportsBrowserTools {
                                HStack(spacing: 8) {
                                    Button(action: { store.refreshBrowserSession() }) {
                                        Label(L("Refresh browser session"), systemImage: "arrow.clockwise")
                                    }
                                    Button(action: { store.clearBrowserSession() }) {
                                        Label(L("Clear browser cache"), systemImage: "trash")
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                            HStack(spacing: 6) {
                                Button(action: { store.openProviderDocs() }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "book.fill")
                                        Text(L("Provider docs"))
                                        Image(systemName: "arrow.up.right")
                                            .font(.system(size: 9, weight: .bold))
                                    }
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.accentColor)
                                }
                                .buttonStyle(.plain)
                                .onHover { inside in
                                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                                }
                                Spacer()
                                Text(L("Provider ID: %@", provider.id))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .disabled(store.isBusy)
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 12) {
                SettingsIconTile(symbol: SettingsStore.Tab.providers.symbol, color: SettingsStore.Tab.providers.tint, size: 52)
                Text(L("Select a provider"))
                    .font(.system(size: 15, weight: .semibold))
                Text(L("Choose a provider on the left to connect it and see its status."))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - List column

private struct SettingsProviderList: View {
    @ObservedObject var store: SettingsStore
    let snapshots: [ProviderSnapshot]

    var body: some View {
        let filtered = store.filteredProviders
        let enabled = filtered.filter(\.enabled)
        let available = filtered.filter { !$0.enabled }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Providers"))
                        .font(.system(size: 22, weight: .bold))
                    Text(L("%d enabled · %d available",
                           store.providers.filter(\.enabled).count,
                           store.providers.filter { !$0.enabled }.count))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { Task { @MainActor in await store.reloadProviders() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help(L("Reload providers"))
                .accessibilityLabel(Text(L("Reload providers")))
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 12)

            SettingsSearchField(text: $store.providerSearch, prompt: L("Search providers"))
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            ScrollView {
                // A plain VStack builds the ~65 rows once. LazyVStack created
                // rows (and their AppKit switches) while scrolling, which
                // pushed frames past the 16 ms budget.
                VStack(alignment: .leading, spacing: 2) {
                    if !enabled.isEmpty {
                        listHeader(L("Enabled"), count: enabled.count)
                        ForEach(enabled) { provider in row(provider) }
                    }
                    if !available.isEmpty {
                        listHeader(L("Available"), count: available.count)
                            .padding(.top, enabled.isEmpty ? 0 : 10)
                        ForEach(available) { provider in row(provider) }
                    }
                    if filtered.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 22, weight: .light))
                                .foregroundColor(.secondary)
                            Text(L("No providers match “%@”", store.providerSearch))
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
    }

    private func listHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundColor(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ provider: ProviderDescriptor) -> some View {
        ProviderSettingsRow(
            provider: provider,
            state: SettingsProviderState(provider: provider, snapshots: snapshots),
            selected: store.selectedProviderID == provider.id,
            select: { store.select(provider) },
            toggle: { store.setEnabled($0, provider: provider) })
    }
}

private struct SettingsSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L("Clear")))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

struct ProviderSettingsRow: View {
    let provider: ProviderDescriptor
    let state: SettingsProviderState
    let selected: Bool
    let select: () -> Void
    let toggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: select) {
                HStack(spacing: 10) {
                    ProviderBadge(providerID: provider.id, size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.name)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if provider.enabled {
                            state.chip
                        } else {
                            Text(ProviderAuthenticationCatalog.profile(for: provider.id).methodTitle)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(provider.name))
            .accessibilityValue(Text(state.title))
            .accessibilityAddTraits(selected ? .isSelected : [])

            Toggle(L("Enable %@", provider.name), isOn: Binding(get: { provider.enabled }, set: toggle))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.28) : Color.clear, lineWidth: 0.5))
    }
}

// MARK: - Detail column

private struct SettingsProviderHero: View {
    let provider: ProviderDescriptor
    let profile: ProviderAuthenticationProfile
    let state: SettingsProviderState
    let plan: String?
    let isBusy: Bool
    let toggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ProviderBadge(providerID: provider.id, size: 56)
            VStack(alignment: .leading, spacing: 7) {
                Text(provider.name)
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                HStack(spacing: 6) {
                    state.chip
                    if let plan = plan {
                        DSChip(text: plan, symbol: "creditcard.fill", tint: Color(nsColor: .systemPurple))
                    }
                    DSChip(text: profile.methodTitle, symbol: profile.methodSymbol)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Toggle(L("Enable %@", provider.name), isOn: Binding(get: { provider.enabled }, set: toggle))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(isBusy)
                Text(provider.enabled ? L("On") : L("Off"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct SettingsProviderAuthentication: View {
    @ObservedObject var store: SettingsStore
    let provider: ProviderDescriptor
    let profile: ProviderAuthenticationProfile

    private var methodDescription: String {
        switch profile.storage {
        case .apiKey: return L("Saved to the provider configuration and verified before it is kept.")
        case .tokenAccount: return L("Save several labeled keys and switch the active one at any time.")
        case .manualCookie: return L("Uses a signed-in browser session, or a cookie you paste.")
        case .providerFields: return L("Point the engine at your account with a few provider fields.")
        case .external: return L("Signs in with the provider's own app, CLI or local data.")
        }
    }

    private var steps: [String] {
        var result = Self.sentences(profile.guidance)
        if profile.canSaveConfiguration {
            result.append(L("Fill in the fields below, then choose Save & Verify."))
        } else if provider.enabled {
            result.append(L("Refresh from the menu bar to confirm the connection."))
        } else {
            result.append(L("Turn the provider on to start fetching usage."))
        }
        return result
    }

    var body: some View {
        SettingsSection(
            title: profile.title,
            footer: profile.canSaveConfiguration ? L("Stored locally with owner-only permissions.") : nil)
        {
            HStack(spacing: 12) {
                SettingsIconTile(symbol: profile.methodSymbol, color: ProviderBrand.color(for: provider.id), size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.methodTitle)
                        .font(.system(size: 13, weight: .semibold))
                    Text(methodDescription)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08)))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1))
            .padding(10)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isSelected)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.accentColor)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.accentColor.opacity(0.14)))
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        Text(step)
                            .font(.system(size: 12))
                            .foregroundColor(.primary.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 14)

            if profile.canSaveConfiguration {
                SettingsRowDivider(inset: 0)
                credentialForm
            } else {
                SettingsBanner(
                    text: L("This provider does not accept a generic config API key. Use the provider login, CLI, OAuth, browser, or local source described above."),
                    tone: .info)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
    }

    private var credentialForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            if profile.requiresSecret {
                field(profile.secretLabel) {
                    HStack(spacing: 6) {
                        Group {
                            if store.revealAPIKey {
                                TextField(profile.secretPlaceholder, text: $store.apiKey)
                            } else {
                                SecureField(profile.secretPlaceholder, text: $store.apiKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(Text(profile.secretLabel))
                        Button(action: { store.revealAPIKey.toggle() }) {
                            Image(systemName: store.revealAPIKey ? "eye.slash" : "eye")
                                .frame(width: 16)
                        }
                        .buttonStyle(.borderless)
                        .help(store.revealAPIKey ? L("Hide") : L("Show"))
                        .accessibilityLabel(Text(store.revealAPIKey ? L("Hide") : L("Show")))
                        Button(action: { store.pasteAPIKey() }) {
                            Label(L("Paste"), systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            if profile.accountLabelVisible {
                field(L("Account label")) {
                    TextField(L("Account label"), text: $store.credentialLabel)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let label = profile.enterpriseHostLabel {
                field(label) {
                    TextField(label, text: $store.enterpriseHost)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let label = profile.workspaceLabel {
                field(label) {
                    TextField(label, text: $store.workspaceID)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let label = profile.regionLabel {
                field(label) {
                    TextField(profile.regionPlaceholder ?? label, text: $store.region)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(Text(label))
                }
            }

            HStack(spacing: 8) {
                Spacer()
                Button(L("Clear fields"), action: { store.clearAPIKeyField() })
                    .buttonStyle(.bordered)
                    .disabled(store.isBusy)
                Button(L("Save & Verify"), action: { store.saveAndVerifyAPIKey() })
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.canSaveSelectedConfiguration || store.isBusy)
            }
            .padding(.top, 2)
        }
        .padding(14)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            content()
        }
    }

    /// Splits guidance prose into steps: English sentences end with
    /// ".", "!" or "?" followed by a space; Chinese ones with "。！？".
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            let ends = "。！？".contains(character)
                || (".!?".contains(character) && (next == nil || next == " " || next == "\n"))
            if ends {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }
}

private struct SettingsTokenAccountRow: View {
    let account: ConfiguredProviderAccount
    let use: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: account.isActive ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundColor(account.isActive ? Color(nsColor: .systemGreen) : .secondary)
                .frame(width: 20)
            Text(account.label)
                .font(.system(size: 13, weight: account.isActive ? .semibold : .regular))
                .lineLimit(1)
            if account.isActive {
                DSChip(text: L("Active"), tint: Color(nsColor: .systemGreen))
            }
            Spacer()
            if !account.isActive {
                Button(L("Use"), action: use)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button(action: remove) {
                Text(L("Remove")).foregroundColor(Color(nsColor: .systemRed))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

struct ProviderConnectionRow: View {
    let snapshot: ProviderSnapshot

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                ProviderBadge(providerID: snapshot.provider, size: 26)
                Circle()
                    .fill(connectionColor)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.accountDisplayName ?? snapshot.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(detailText)
                    .font(.system(size: 11))
                    .foregroundColor(snapshot.error == nil ? .secondary : Color(nsColor: .systemRed))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let percent = snapshot.maximumUsedPercent {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(L("%.0f%% used", percent))
                        .font(DS.numeral(12))
                        .foregroundColor(.secondary)
                    UsageBar(fill: percent, remaining: 100 - percent, height: 5)
                        .frame(width: 84)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        if snapshot.error != nil { return Color(nsColor: .systemRed) }
        return DS.healthColor(snapshot.serviceHealth)
    }
}
