@preconcurrency import UserNotifications
import Foundation

@MainActor
final class ProviderAlertController: NSObject, UNUserNotificationCenterDelegate {
    private struct AlertState: Equatable {
        let health: ProviderServiceHealth
        let hasError: Bool
        /// Used percent per quota window, keyed by the window's title. Each
        /// window is tracked separately so a full weekly quota cannot hide a
        /// five-hour window crossing the threshold.
        let quotaUsage: [String: Double]
    }

    private let center: UNUserNotificationCenter
    private var previousStates: [String: AlertState]?

    override init() {
        self.center = .current()
        super.init()
        center.delegate = self
    }

    func prepareAuthorizationIfNeeded() {
        if Preferences.shared.notifyOnServiceIncidents || Preferences.shared.notifyOnQuotaThreshold {
            Self.requestAuthorization()
        }
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                NSLog("Notification authorization failed: %@", error.localizedDescription)
            } else if !granted {
                NSLog("AIUsageBar notifications were not authorized")
            }
        }
    }

    func evaluate(
        snapshots: [ProviderSnapshot],
        dashboards: [String: ProviderDashboard] = [:]
    ) {
        // Snapshot IDs fall back to `provider::default` without an account,
        // so two accounts can share one; the later one wins instead of trapping.
        var current: [String: AlertState] = [:]
        var uniqueSnapshots: [ProviderSnapshot] = []
        for snapshot in snapshots {
            if current[snapshot.id] == nil { uniqueSnapshots.append(snapshot) }
            current[snapshot.id] = AlertState(
                health: snapshot.serviceHealth,
                hasError: snapshot.error != nil,
                quotaUsage: Self.quotaUsage(snapshot: snapshot, dashboard: dashboards[snapshot.id]))
        }

        // The first successful refresh establishes a baseline. It must not flood
        // Notification Center simply because the application has just launched.
        guard let previousStates = previousStates else {
            self.previousStates = current
            return
        }

        for snapshot in uniqueSnapshots {
            guard let prior = previousStates[snapshot.id],
                  let next = current[snapshot.id]
            else { continue }

            if Preferences.shared.notifyOnServiceIncidents {
                if (!prior.health.isIncident && next.health.isIncident) || (!prior.hasError && next.hasError) {
                    let detail = snapshot.error?.message ?? snapshot.status?.displayText ?? next.health.title
                    notify(
                        title: L("%@ needs attention", snapshot.displayName),
                        body: detail,
                        identifier: "incident-\(StableIdentifier.hash(snapshot.id))-\(next.health.rawValue)")
                } else if Preferences.shared.notifyOnRecovery,
                          (prior.health.isIncident || prior.hasError),
                          !next.health.isIncident,
                          !next.hasError
                {
                    notify(
                        title: L("%@ recovered", snapshot.displayName),
                        body: snapshot.status?.displayText ?? L("Provider access is available again."),
                        identifier: "recovery-\(StableIdentifier.hash(snapshot.id))")
                }
            }

            if Preferences.shared.notifyOnQuotaThreshold {
                let threshold = Preferences.shared.quotaWarningThreshold
                for (window, used) in next.quotaUsage.sorted(by: { $0.key < $1.key }) {
                    // A window seen for the first time only sets its baseline.
                    guard let priorUsed = prior.quotaUsage[window],
                          priorUsed < threshold, used >= threshold
                    else { continue }
                    let title = used >= 100
                        ? L("%@ quota depleted", snapshot.displayName)
                        : L("%@ quota warning", snapshot.displayName)
                    let body = L("%@ usage reached %.0f%%.", window, used)
                    notify(
                        title: title,
                        body: body,
                        identifier: "quota-\(StableIdentifier.hash(snapshot.id))-\(StableIdentifier.hash(window))-\(Int(threshold))")
                }
            }
        }

        self.previousStates = current
    }

    private static func quotaUsage(snapshot: ProviderSnapshot, dashboard: ProviderDashboard?) -> [String: Double] {
        var usage: [String: Double] = [:]
        if let quotas = dashboard?.quotas, !quotas.isEmpty {
            for quota in quotas {
                usage[quota.title] = max(usage[quota.title] ?? 0, quota.usedPercent)
            }
            return usage
        }
        // DeepSeek API-key mode exposes a balance sentinel, not a quota window.
        guard snapshot.provider != "deepseek" else { return [:] }
        for window in [snapshot.usage?.primary, snapshot.usage?.secondary, snapshot.usage?.tertiary] {
            guard let window = window, let used = window.usedPercent, used.isFinite else { continue }
            usage[window.displayLabel] = max(usage[window.displayLabel] ?? 0, used)
        }
        return usage
    }

    private func notify(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: "\(identifier)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil))
        { error in
            if let error = error {
                NSLog("Could not deliver provider notification: %@", error.localizedDescription)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
