@preconcurrency import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuController: MenuController?
    private var updaterController: UpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Must run before any store reads its folder or preferences.
        LegacyMigration.run()
        let updater = UpdaterController()
        updaterController = updater
        menuController = MenuController(client: CLIClient(), updater: updater)
        CurrencySettingsStore.shared.start()

        if let outputPath = ProcessInfo.processInfo.environment["AIUSAGEBAR_UI_SMOKE_OUTPUT"],
           !outputPath.isEmpty
        {
            Task { @MainActor [weak self] in
                let report = await self?.menuController?.runtimeSmokeReport()
                    ?? "FAIL: menu controller unavailable"
                do {
                    try (report + "\n").write(
                        toFile: outputPath,
                        atomically: true,
                        encoding: .utf8)
                } catch {
                    NSLog("Could not write UI smoke report: %@", error.localizedDescription)
                }
                NSApp.terminate(nil)
            }
        } else if ProcessInfo.processInfo.environment["AIUSAGEBAR_VISUAL_QA_USAGE_DATA"] == "1" {
            Task { @MainActor [weak self] in
                await self?.menuController?.showTokenHistoryForVisualQA()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
