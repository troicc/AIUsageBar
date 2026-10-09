// Converts the upstream provider logos (SVG) into vector PDFs the app can
// load on macOS 12, whose NSImage cannot read SVG. Uses WebKit's renderer.
// Usage: convert_provider_icons <svg-dir> <out-dir>
import AppKit
import WebKit

@MainActor
final class Converter: NSObject, WKNavigationDelegate {
    private let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 256, height: 256))
    private var continuation: CheckedContinuation<Void, Never>?

    @MainActor override init() {
        super.init()
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
    }

    func convert(_ svg: URL, to pdf: URL) async -> Bool {
        let markup = (try? String(contentsOf: svg)) ?? ""
        // Fit the logo into a square page with no margins or background.
        let html = """
        <html><head><style>
        html,body{margin:0;padding:0;background:transparent;width:256px;height:256px;overflow:hidden}
        svg{width:256px;height:256px;display:block}
        </style></head><body>\(markup)</body></html>
        """
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
        let configuration = WKPDFConfiguration()
        configuration.rect = NSRect(x: 0, y: 0, width: 256, height: 256)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            webView.createPDF(configuration: configuration) { result in
                if case let .success(data) = result, (try? data.write(to: pdf)) != nil {
                    continuation.resume(returning: true)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.continuation?.resume()
            self.continuation = nil
        }
    }
}

@main
enum ConvertProviderIcons {
    @MainActor
    static func main() async {
        _ = NSApplication.shared
        let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let converter = Converter()
        let files = ((try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("ProviderIcon-") && $0.pathExtension == "svg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var converted = 0
        for svg in files {
            let id = svg.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ProviderIcon-", with: "")
            if await converter.convert(svg, to: output.appendingPathComponent("\(id).pdf")) {
                converted += 1
            } else {
                print("FAILED \(id)")
            }
        }
        print("converted \(converted) of \(files.count)")
        exit(0)
    }
}
