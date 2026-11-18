import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let launch = Date(timeIntervalSince1970: 1_700_000_000)

// Cold launch starts warm (15m) and drops to idle (30m) after 60 minutes even without menu opens.
expect(
    RefreshSchedulePolicy.adaptiveInterval(
        lastMenuOpenedAt: nil,
        launchedAt: launch,
        now: launch.addingTimeInterval(30 * 60),
        isLowPowerModeEnabled: false) == 900,
    "cold launch within 60m should use 15m warm interval"
)
expect(
    RefreshSchedulePolicy.adaptiveInterval(
        lastMenuOpenedAt: nil,
        launchedAt: launch,
        now: launch.addingTimeInterval(60 * 60),
        isLowPowerModeEnabled: false) == 1800,
    "cold launch after 60m without menu activity should drop to 30m idle interval"
)

// Menu activity uses 5m for 10m, 15m up to 60m, and 30m when idle; Low Power Mode forces 30m.
let menuOpen = launch.addingTimeInterval(2 * 3600)
expect(
    RefreshSchedulePolicy.adaptiveInterval(
        lastMenuOpenedAt: menuOpen,
        launchedAt: launch,
        now: menuOpen.addingTimeInterval(9 * 60 + 59),
        isLowPowerModeEnabled: false) == 300,
    "recent menu activity (<10m) should use 5m interval"
)
expect(
    RefreshSchedulePolicy.adaptiveInterval(
        lastMenuOpenedAt: menuOpen,
        launchedAt: launch,
        now: menuOpen.addingTimeInterval(10 * 60),
        isLowPowerModeEnabled: false) == 900,
    "warm window (10m..60m) should use 15m interval"
)
expect(
    RefreshSchedulePolicy.adaptiveInterval(
        lastMenuOpenedAt: menuOpen,
        launchedAt: launch,
        now: menuOpen.addingTimeInterval(60 * 60),
        isLowPowerModeEnabled: false) == 1800,
    "idle window (>=60m) should use 30m interval"
)
expect(
    RefreshSchedulePolicy.adaptiveInterval(
        lastMenuOpenedAt: menuOpen,
        launchedAt: launch,
        now: menuOpen.addingTimeInterval(30),
        isLowPowerModeEnabled: true) == 1800,
    "Low Power Mode should always use 30m interval"
)

// No timer should be scheduled while a refresh is already running (prevents double-refresh race).
expect(
    RefreshSchedulePolicy.timerDelay(
        interval: 300,
        isRefreshing: true,
        lastRefreshStartedAt: menuOpen.addingTimeInterval(-400),
        now: menuOpen) == nil,
    "timerDelay must return nil while a refresh is in flight"
)
expect(
    RefreshSchedulePolicy.timerDelay(
        interval: 300,
        isRefreshing: false,
        lastRefreshStartedAt: menuOpen.addingTimeInterval(-120),
        now: menuOpen) == 180,
    "timerDelay should compute remaining wait from lastRefreshStartedAt"
)
expect(
    RefreshSchedulePolicy.timerDelay(
        interval: 300,
        isRefreshing: false,
        lastRefreshStartedAt: menuOpen.addingTimeInterval(-400),
        now: menuOpen) == 1,
    "overdue timerDelay should clamp to 1s"
)

// Menu-open immediate refresh respects freshness window and in-flight state.
expect(
    !RefreshSchedulePolicy.shouldRefreshOnMenuOpen(
        refreshOnMenuOpen: true,
        isRefreshing: true,
        lastSuccessfulRefresh: nil,
        now: menuOpen),
    "shouldRefreshOnMenuOpen must be false while refreshing"
)
expect(
    !RefreshSchedulePolicy.shouldRefreshOnMenuOpen(
        refreshOnMenuOpen: true,
        isRefreshing: false,
        lastSuccessfulRefresh: menuOpen.addingTimeInterval(-60),
        now: menuOpen),
    "shouldRefreshOnMenuOpen must skip refreshes within 60s"
)
expect(
    RefreshSchedulePolicy.shouldRefreshOnMenuOpen(
        refreshOnMenuOpen: true,
        isRefreshing: false,
        lastSuccessfulRefresh: menuOpen.addingTimeInterval(-61),
        now: menuOpen),
    "shouldRefreshOnMenuOpen should trigger when data is older than 60s"
)

print("Refresh schedule regression tests passed.")
