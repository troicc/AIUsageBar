import Foundation

/// Carries an install from before the AIUsageBar rename over to the new
/// names: preferences under the old bundle identifier, the old data folders,
/// the provider config file and the launch-at-login agent. Every step only
/// acts when the old item exists and the new one does not, so running it on
/// every launch is cheap and safe.
enum LegacyMigration {
    /// Engines bundled before the rename read this name instead of
    /// `AIUSAGEBAR_INCLUDE_LIVE_USAGE`.
    static let liveUsageEnvironmentKey = "CODEXBAR_MONTEREY_INCLUDE_LIVE_USAGE"

    private static let legacyBundleIdentifiers = [
        "com.example.codexbar.monterey",
        "com.codexbar.monterey",
    ]
    private static let legacyFolderName = "CodexBarMonterey"
    private static let currentFolderName = "AIUsageBar"
    private static let legacyEngineCacheName = "CodexBarCLI"
    /// Preference keys that embed the old name (window frames, status item
    /// positions) are rewritten so restored layout survives the rename.
    private static let keyRenames = [
        ("CodexBarMonterey", "AIUsageBar"),
        ("codexbar-monterey", "aiusagebar"),
        ("__codexbar_overview__", "__aiusagebar_overview__"),
    ]

    @MainActor
    static func run(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        configStore: ProviderConfigStore = ProviderConfigStore()
    ) {
        migrateDefaults(defaults)
        migrateFolders(fileManager)
        do {
            if let legacy = try configStore.migrateLegacyConfigIfNeeded() {
                NSLog("Moved provider config from %@", legacy.path)
            }
        } catch {
            NSLog("Provider config migration failed: %@", error.localizedDescription)
        }
        migrateLaunchAgent(fileManager)
        removeLegacyCaches(fileManager)
    }

    private static var currentBundleIdentifier: String? {
        Bundle.main.bundleIdentifier
    }

    private static var otherLegacyIdentifiers: [String] {
        legacyBundleIdentifiers.filter { $0 != currentBundleIdentifier }
    }

    private static func migrateDefaults(_ defaults: UserDefaults) {
        guard let current = currentBundleIdentifier else { return }
        for legacyID in otherLegacyIdentifiers {
            guard let legacy = defaults.persistentDomain(forName: legacyID), !legacy.isEmpty else { continue }
            // Compare against the persistent domain only: registered defaults
            // would otherwise hide keys the user has never set here.
            let existing = defaults.persistentDomain(forName: current) ?? [:]
            for (key, value) in legacy {
                let renamed = keyRenames.reduce(key) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
                if existing[renamed] == nil {
                    defaults.set(value, forKey: renamed)
                }
            }
            defaults.removePersistentDomain(forName: legacyID)
        }
    }

    private static func migrateFolders(_ fileManager: FileManager) {
        let bases = [
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
        ].compactMap { $0 }
        for base in bases {
            let legacy = base.appendingPathComponent(legacyFolderName, isDirectory: true)
            let current = base.appendingPathComponent(currentFolderName, isDirectory: true)
            guard fileManager.fileExists(atPath: legacy.path) else { continue }
            do {
                if !fileManager.fileExists(atPath: current.path) {
                    try fileManager.moveItem(at: legacy, to: current)
                    continue
                }
                // Both exist (e.g. config already moved in): keep anything the
                // new folder has and bring over the rest.
                for name in try fileManager.contentsOfDirectory(atPath: legacy.path) {
                    let target = current.appendingPathComponent(name)
                    if !fileManager.fileExists(atPath: target.path) {
                        try fileManager.moveItem(at: legacy.appendingPathComponent(name), to: target)
                    }
                }
                if try fileManager.contentsOfDirectory(atPath: legacy.path).isEmpty {
                    try fileManager.removeItem(at: legacy)
                }
            } catch {
                NSLog("Data folder migration failed for %@: %@", legacy.path, error.localizedDescription)
            }
        }
    }

    @MainActor
    private static func migrateLaunchAgent(_ fileManager: FileManager) {
        let agents = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        var hadLegacyAgent = false
        for legacyID in otherLegacyIdentifiers {
            let plist = agents.appendingPathComponent("\(legacyID).plist")
            guard fileManager.fileExists(atPath: plist.path) else { continue }
            hadLegacyAgent = true
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["unload", "-w", plist.path]
            try? process.run()
            process.waitUntilExit()
            try? fileManager.removeItem(at: plist)
        }
        if hadLegacyAgent {
            Preferences.shared.launchAtLogin = true
        }
    }

    private static func removeLegacyCaches(_ fileManager: FileManager) {
        let library = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        var stale = otherLegacyIdentifiers.flatMap { id in
            [
                library.appendingPathComponent("Caches/\(id)", isDirectory: true),
                library.appendingPathComponent("HTTPStorages/\(id)", isDirectory: true),
                library.appendingPathComponent("HTTPStorages/\(id).binarycookies"),
            ]
        }
        // URL cache of the engine helper, named after its old executable.
        stale.append(library.appendingPathComponent("Caches/\(legacyEngineCacheName)", isDirectory: true))
        for url in stale where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }
}
