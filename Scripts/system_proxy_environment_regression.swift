import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("System proxy environment regression failed: \(message)\n").utf8))
    exit(1)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
}

let surge: [String: Any] = [
    "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 6152,
    "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 6152,
    "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 6153,
    "ExceptionsList": ["151.241.88.168", "*.local", "localhost"],
]

// A launchd environment without proxy variables gets the system proxy.
var env = ["PATH": "/usr/bin:/bin", "HOME": "/Users/someone"]
SystemProxyEnvironment.apply(settings: surge, to: &env)
require(env["HTTPS_PROXY"] == "http://127.0.0.1:6152", "HTTPS_PROXY \(env["HTTPS_PROXY"] ?? "nil")")
require(env["https_proxy"] == "http://127.0.0.1:6152", "https_proxy")
require(env["HTTP_PROXY"] == "http://127.0.0.1:6152", "HTTP_PROXY")
require(env["http_proxy"] == "http://127.0.0.1:6152", "http_proxy")
require(env["ALL_PROXY"] == nil, "SOCKS must not become ALL_PROXY")
require(env["NO_PROXY"] == "localhost,127.0.0.1,::1,151.241.88.168,*.local", "NO_PROXY \(env["NO_PROXY"] ?? "nil")")
require(env["no_proxy"] == env["NO_PROXY"], "no_proxy")
require(env["PATH"] == "/usr/bin:/bin", "unrelated variables are kept")

// An explicit proxy (for example from a shell) is never overridden.
var explicit = ["https_proxy": "http://10.0.0.1:8080"]
SystemProxyEnvironment.apply(settings: surge, to: &explicit)
require(explicit == ["https_proxy": "http://10.0.0.1:8080"], "explicit proxy kept untouched")

// An existing NO_PROXY is kept.
var withNoProxy = ["NO_PROXY": "example.com"]
SystemProxyEnvironment.apply(settings: surge, to: &withNoProxy)
require(withNoProxy["NO_PROXY"] == "example.com" && withNoProxy["no_proxy"] == nil, "existing NO_PROXY kept")

// Proxy switched off, or incomplete settings: nothing is added.
var off = [String: String]()
SystemProxyEnvironment.apply(settings: ["HTTPSEnable": 0, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 6152], to: &off)
require(off.isEmpty, "disabled proxy adds nothing")
SystemProxyEnvironment.apply(settings: ["HTTPSEnable": 1, "HTTPSProxy": "", "HTTPSPort": 6152], to: &off)
SystemProxyEnvironment.apply(settings: ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1"], to: &off)
require(off.isEmpty, "incomplete proxy adds nothing")

// Only an HTTP proxy configured: it is used for HTTPS too.
var httpOnly = [String: String]()
SystemProxyEnvironment.apply(settings: ["HTTPEnable": 1, "HTTPProxy": "proxy.lan", "HTTPPort": 3128], to: &httpOnly)
require(httpOnly["HTTPS_PROXY"] == "http://proxy.lan:3128", "HTTP-only proxy covers HTTPS")

// IPv6 hosts are bracketed.
var v6 = [String: String]()
SystemProxyEnvironment.apply(settings: ["HTTPSEnable": 1, "HTTPSProxy": "::1", "HTTPSPort": 6152], to: &v6)
require(v6["HTTPS_PROXY"] == "http://[::1]:6152", "IPv6 \(v6["HTTPS_PROXY"] ?? "nil")")

print("System proxy environment regression passed.")
