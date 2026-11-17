import CFNetwork
import Foundation

/// Command-line tools the engine launches (the Claude Code CLI in particular) ignore the macOS
/// system proxy and only honor `HTTPS_PROXY`-style variables. Shells get those from the user's
/// profile, but an app started by launchd does not, so the CLI would connect directly and could be
/// refused (Anthropic answers region-blocked direct connections with 403). This mirrors the
/// current system proxy into those variables for every engine launch.
enum SystemProxyEnvironment {
    private static let proxyKeys = ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]

    /// Adds proxy variables from the current system settings unless the environment already
    /// names a proxy. Read on every launch, so a proxy app started after this app is picked up.
    static func apply(to environment: inout [String: String]) {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return }
        apply(settings: settings, to: &environment)
    }

    static func apply(settings: [String: Any], to environment: inout [String: String]) {
        let alreadySet = proxyKeys.contains { !(environment[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        guard !alreadySet else { return }
        let https = proxyURL(settings, enable: "HTTPSEnable", host: "HTTPSProxy", port: "HTTPSPort")
        let http = proxyURL(settings, enable: "HTTPEnable", host: "HTTPProxy", port: "HTTPPort")
        guard https != nil || http != nil else { return }
        if let https = https ?? http {
            environment["HTTPS_PROXY"] = https
            environment["https_proxy"] = https
        }
        if let http = http ?? https {
            environment["HTTP_PROXY"] = http
            environment["http_proxy"] = http
        }
        if (environment["NO_PROXY"] ?? environment["no_proxy"] ?? "").isEmpty {
            var hosts = ["localhost", "127.0.0.1", "::1"]
            for entry in settings["ExceptionsList"] as? [String] ?? [] {
                let host = entry.trimmingCharacters(in: .whitespaces)
                if !host.isEmpty, !hosts.contains(host) { hosts.append(host) }
            }
            let value = hosts.joined(separator: ",")
            environment["NO_PROXY"] = value
            environment["no_proxy"] = value
        }
    }

    private static func proxyURL(_ settings: [String: Any], enable: String, host: String, port: String) -> String? {
        guard (settings[enable] as? NSNumber)?.boolValue == true,
              let rawHost = (settings[host] as? String)?.trimmingCharacters(in: .whitespaces), !rawHost.isEmpty,
              let portNumber = (settings[port] as? NSNumber)?.intValue, (1...65535).contains(portNumber)
        else { return nil }
        let formattedHost = rawHost.contains(":") && !rawHost.hasPrefix("[") ? "[\(rawHost)]" : rawHost
        return "http://\(formattedHost):\(portNumber)"
    }
}
