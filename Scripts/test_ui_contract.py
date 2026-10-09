#!/usr/bin/env python3
"""Fast source-level regressions for the original-style Monterey UI."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources" / "AIUsageBar"

menu = (SOURCES / "MenuController.swift").read_text()
native_menu = (SOURCES / "NativeMenuViews.swift").read_text()
alerts = (SOURCES / "ProviderAlertController.swift").read_text()
preferences = (SOURCES / "Preferences.swift").read_text()
# Views and settings are split across several files; contracts read them as one.
views = "\n".join((SOURCES / name).read_text() for name in [
    "DashboardViews.swift", "ProviderHistoryCharts.swift", "AllProvidersView.swift",
])
settings = "\n".join((SOURCES / name).read_text() for name in [
    "SettingsWindowController.swift", "SettingsStore.swift", "SettingsPanes.swift",
    "ProviderSettingsView.swift", "TokenHistorySettingsView.swift",
])
details = (SOURCES / "DetailsWindowController.swift").read_text()
detail_popover = (SOURCES / "ProviderDetailPopoverController.swift").read_text()
client = (SOURCES / "CLIClient.swift").read_text()
parser = (SOURCES / "DashboardParser.swift").read_text()
store = (SOURCES / "DashboardStore.swift").read_text()
cost_payload = (SOURCES / "CostHistoryPayload.swift").read_text()
quota_trend = (SOURCES / "LocalQuotaTrendStore.swift").read_text()
local_spend = (SOURCES / "LocalSpendHistoryStore.swift").read_text()
token_history = (SOURCES / "LocalTokenHistoryStore.swift").read_text()
models = (SOURCES / "Models.swift").read_text()
provider_auth = (SOURCES / "ProviderAuthentication.swift").read_text()
config_store = (SOURCES / "ProviderConfigStore.swift").read_text()

# The primary interaction is a real macOS status menu. The redundant fixed-dark
# multi-provider popover is gone; only the native provider-detail popover remains.
assert not (SOURCES / "DashboardPopoverController.swift").exists()
assert "NSMenuDelegate" in menu
assert "item.menu = menu" in menu
assert "menuWillOpen" in menu
assert "populateOverviewMenu" in menu
assert "populateProviderMenu" in menu
assert "NativeMenuOverviewView" in native_menu
assert "NativeMenuProviderCardView" in native_menu
assert "Open Dashboard Popover" not in menu
assert "openDashboardPopoverMenuItem" not in menu
assert "statusButtonClicked" not in menu
assert "NSApp.mainMenu = mainMenu" in menu
assert "setAccessibilityLabel" in menu

# Refresh and menu-bar behavior must be configurable in the same categories as
# upstream's useful native-menu subset.
for token in [
    "case manual",
    "case fixed",
    "case adaptive",
    "refreshOnMenuOpen",
    "MenuBarDisplayStyle",
    "MenuQuotaPresentation",
    "overviewProviderLimit",
]:
    assert token in preferences, token
assert "adaptiveRefreshInterval" in menu
assert "ProcessInfo.processInfo.isLowPowerModeEnabled" in menu
assert "runtimeSmokeReport" in menu
assert 'failures.append("provider detail popover did not open")' in menu
assert "AIUSAGEBAR_UI_SMOKE_OUTPUT" in (SOURCES / "AppDelegate.swift").read_text()

# Dashboard UI contract: history charts, actions, and the native provider
# detail remain available. The unused fixed-dark popover has been deleted.
for token in [
    "LiveProviderDetailPopoverView",
    "ProviderDetailPopoverView",
    "ProviderHistorySeriesView",
    "Web dashboard",
    "Status Page",
    'keyboardShortcut("r", modifiers: .command)',
]:
    assert token in views, token
assert "struct DashboardPopoverView" not in views
assert "NSAppearance(named: .darkAqua)" not in views
assert "Usage Dashboard" in menu and "Status Page" in menu

# Provider detail is anchored to the status item as a transient popover. The
# all-provider overview uses the same system-native popover interaction.
assert "AllProvidersDashboardView" in details
assert "NSTextView.scrollableTextView" not in details
assert "setFrameAutosaveName" in settings
assert "NSPopover" in details
assert "NSWindowController" not in details
assert "relativeTo button: NSStatusBarButton" in details
all_provider_view = views[views.index("struct AllProvidersDashboardView:"):]
assert "preferredColorScheme(.dark)" not in all_provider_view
assert "AllProvidersContentView" in all_provider_view
assert "windowBackgroundColor" in all_provider_view
assert "NSPopover" in detail_popover
assert "NSWindowController" not in detail_popover
assert "LiveProviderDetailPopoverView" in detail_popover
assert "relativeTo button: NSStatusBarButton" in detail_popover
assert "detailPopover.show(snapshot: snapshot, relativeTo: button)" in menu

# API key UX must support direct paste and a persistent secure field.
assert "SecureField" in settings
assert "pasteAPIKey" in settings
assert "NSPasteboard.general.string" in settings
assert "Save & Verify" in settings
assert "probeProvider" in client
assert "saveCredential" in client
assert "ProviderAuthenticationCatalog" in settings
assert 'status = L("Save failed: %@"' in settings
assert "Saved, but verification failed" not in settings
assert 'tokenAccount("deepseek"' in provider_auth
assert 'tokenAccount("venice"' in provider_auth
assert 'case .tokenAccount:' in config_store
assert 'provider["tokenAccounts"]' in config_store
assert 'provider["apiKey"] = secret' in config_store
assert 'provider["cookieSource"] = "manual"' in config_store
assert 'provider["enterpriseHost"] = host' in config_store
assert 'provider["workspaceID"] = workspace' in config_store
assert 'provider["region"] = region' in config_store
assert ".posixPermissions: 0o600" in config_store
assert "makeBackup" in config_store
assert "restore(_ backup:" in config_store
assert "configStore.restore(backup)" in client
assert "rollbackFailed" in client
assert "try await probeProvider(provider, profile: profile)" in client
assert "previous configuration was restored" in client
assert "let receipt = try configStore.save" in client
assert "configuredTokenAccounts" in config_store
assert "activateTokenAccount" in config_store
assert "removeTokenAccount" in config_store
assert "activateConfiguredAccount" in client
assert "removeConfiguredAccount" in client
assert "Saved token accounts" in settings
assert "Connection & service" in settings

# Provider dashboard JSON must be enriched from the upstream CLI and parsed
# tolerantly so provider-specific histories can render without lockstep schemas.
assert "dashboardSupplementJSON" in client
assert "extractHistory" in parser
assert "today-spend" in parser
assert "30d-tokens" in parser
assert "metrics: metrics" in parser
assert "metrics: Array(metrics.prefix(4))" not in parser
assert "return Array(lanes.prefix(8))" not in parser

# Status polling is visible and transition-based notifications are opt-in.
assert "serviceStatus: snapshot.status" in parser
assert "ProviderServiceHealth" in models
assert "UNUserNotificationCenter" in alerts
assert "previousStates" in alerts
assert "notifyOnServiceIncidents" in alerts
assert "notifyOnQuotaThreshold" in alerts
assert "Notifications" in settings

# Codex cost history must use the documented aggregate fields, not a fuzzy
# recursive match that can select `daily[].totalTokens` at random.
assert "last30DaysTokens" in cost_payload
assert "last30DaysCostUSD" in cost_payload
assert "resolvedTodayTokens" in cost_payload
assert 'title: L("Today tokens")' in parser
assert "LocalQuotaTrendStore" in store
assert "LocalTokenHistoryStore" in store
assert 'snapshot.provider == "zai"' in quota_trend
assert 'zai-five-hour-trend-v3.json' in quota_trend
assert 'snapshot.headlineUsedPercent' in quota_trend
assert 'return values.max()' not in quota_trend
assert "StableIdentifier.hash(snapshot.id)" in quota_trend
assert "headlineQuotaWindow" in models
assert "headlineUsedPercent" in models
assert 'return abs(minutes - 300) <= 1' in models
assert 'return "5h"' in models
assert "usedPercent: snapshot.headlineUsedPercent" in menu
assert "quotaLabel: snapshot.headlineQuotaLabel" in menu
assert "quota_trend_store_regression.swift" in (ROOT / "Scripts" / "test_cost_history_parser.sh").read_text()
assert "local_spend_history_regression.swift" in (ROOT / "Scripts" / "test_cost_history_parser.sh").read_text()
assert "token_history_store_regression.swift" in (ROOT / "Scripts" / "test_cost_history_parser.sh").read_text()
assert "maximumAttributableInterval" in local_spend
assert "unattributedIntervals" in local_spend
assert "calendar.isDate(previous.timestamp, inSameDayAs: next.timestamp)" in local_spend
assert "StableIdentifier.hash(accountKey)" in local_spend
assert "usage?.identity?.accountEmail" in models
assert "usage?.accountEmail" in models
# z.ai must use real hourly token usage rather than presenting locally sampled
# quota percentages as token history.
assert "private static func zaiPayload" in parser
assert 'dictionary(named: "zaiUsage"' in parser
assert 'title: L("30d tokens")' in parser
assert 'dictionary(named: "localTokenHistory"' in parser
assert 'zai.modelUsage' in token_history
assert 'token-history-v1.json' in token_history
assert 'applicationSupportDirectory' in token_history
assert 'hasFull30DayCoverage' in token_history
assert 'Quota percentages are stored separately' in settings
assert 'case usageData = "Usage Data"' in settings
assert 'Export visible CSV' in settings
assert 'Export full JSON' in settings
assert 'case all' in token_history
assert 'case year' in token_history
assert 'recordsByID[candidate.id]' in token_history
assert 'suffix(' not in token_history
assert 'value: L("Not exposed")' in parser
assert 'title: "5-hour trend"' not in parser
assert "Local 5-hour samples" not in views
assert 'title: L("Hourly tokens")' in views
assert 'title: L("5h quota used")' in views
assert 'fixedMaximum: 100' in views
assert 'title: L("Daily tokens")' in views
assert '"Daily estimated cost" : "Daily cost"' in views
assert "Each chart is labeled and scaled independently." in views
assert "resolvedHistoryValues" not in views
assert "historyContext: historyContext" in parser
assert '"30dtokens", "thirtydaytokens", "totaltokens"' not in parser
assert "supplementalJSONBySnapshot" in store
assert "providerAccountCount(snapshot.provider) <= 1" in store
assert "accountCount > 1" in store
assert "refreshPending = true" in store
# Enrichment re-resolves the account's current snapshot after the scan,
# shares in-flight scans, and reuses recent results for menu opens.
assert "let snapshot = snapshots.first(where: { $0.id == key })" in store
assert "guard let current = snapshots.first(where: { $0.id == key })" in store
assert "scansInFlight" in store
assert "interactiveSupplementMaxAge" in store
assert "recordLocalHistory(for:" in store
assert "await enrichDashboard(for: snapshot)" not in store
assert "store.onRefreshStateChanged" in menu
assert "self?.rebuildStatusItems()" in menu
assert '["cost", "--provider", provider' in client
assert '["--provider", provider, "--format", "json"' not in client

# Swift 6.3 requires StrokeStyle labels in declaration order. Catch the exact
# ordering bug before the macOS build step.
assert "StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)" in views
assert "StrokeStyle(lineWidth: 3, lineJoin: .round, lineCap: .round)" not in views

# The all-provider details popover follows the system appearance.
assert "DashboardTheme" not in views
assert "ScrollView(.vertical, showsIndicators: true)" in views
assert ".accessibilityValue" in views

# A newly created config must have the upstream versioned root shape, never `{}`.
assert '"version": 1' in config_store
assert 'Data("{}\\n".utf8)' not in settings
assert "revealAPIKey = false" in settings
assert "Open Console logs" in settings
assert "Library/Logs/AIUsageBar" not in settings




# Translation tables trap at launch on duplicate keys, and every L("...")
# literal must have a Simplified Chinese entry.
import re as _re
_entry = _re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)"\s*,?\s*$', _re.M)
_merged = {}
for _table in sorted(SOURCES.glob("L10n+*.swift")):
    _keys = [k for k, _ in _entry.findall(_table.read_text())]
    assert len(_keys) == len(set(_keys)), f"duplicate translation keys in {_table.name}"
    _merged.update(dict(_entry.findall(_table.read_text())))
for _source in SOURCES.glob("*.swift"):
    if _source.name.startswith("L10n"):
        continue
    for _key in _re.findall(r'\bL\(\s*"((?:[^"\\]|\\.)*)"', _source.read_text()):
        assert _key in _merged, f"missing translation in {_source.name}: {_key}"

print("All-provider authentication UI contract tests passed.")
