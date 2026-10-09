@preconcurrency import AppKit
import SwiftUI

/// Official provider logos, shipped as vector PDFs in
/// `Contents/Resources/ProviderIcons/<id>.pdf` (converted from the upstream
/// CodexBar SVGs by `Scripts/convert_provider_icons.swift`; macOS 12 cannot
/// load SVG). Most logos are single-color marks and are used as template
/// masks; a few multi-color marks keep their own colors.
enum ProviderLogo {
    /// Marks whose official artwork is multi-colored.
    private static let fullColor: Set<String> = ["codebuff", "doubao", "sub2api", "zoommate"]

    /// Provider IDs that share another provider's mark.
    private static let aliases: [String: String] = [
        "openai": "codex",
        "azureopenai": "codex",
        "moonshot": "kimi",
        "alibabatokenplan": "alibaba",
    ]

    private static let cache = NSCache<NSString, NSImage>()
    private static let missing = NSCache<NSString, NSNumber>()

    static func isFullColor(_ id: String) -> Bool {
        fullColor.contains(aliases[id] ?? id)
    }

    /// The logo, or nil when no official artwork ships for this provider.
    static func image(for id: String) -> NSImage? {
        let name = aliases[id] ?? id
        if let cached = cache.object(forKey: name as NSString) { return cached }
        if missing.object(forKey: name as NSString) != nil { return nil }
        guard let url = url(for: name), let image = NSImage(contentsOf: url) else {
            missing.setObject(true, forKey: name as NSString)
            return nil
        }
        image.isTemplate = !fullColor.contains(name)
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    /// A monochrome copy for the menu bar and menu items, at point size.
    static func templateImage(for id: String, size: CGFloat) -> NSImage? {
        guard let logo = image(for: id) else { return nil }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            logo.draw(in: rect)
            if !logo.isTemplate {
                // Collapse multi-color marks to a single-color mask.
                NSColor.black.set()
                rect.fill(using: .sourceAtop)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func url(for name: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: name, withExtension: "pdf", subdirectory: "ProviderIcons") {
            return bundled
        }
        // Source checkouts (visual QA, galleries) point here instead.
        if let directory = ProcessInfo.processInfo.environment["AIUSAGEBAR_PROVIDER_ICONS"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).pdf")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}

extension ProviderBrand {
    /// Tile color behind a white logo, matching each brand's own app icon.
    /// Black-and-white brands get a near-black tile.
    static func tileColor(for id: String) -> Color {
        switch id {
        case "claude": return Color(red: 0.851, green: 0.467, blue: 0.341)
        case "deepseek": return Color(red: 0.302, green: 0.420, blue: 0.996)
        case "gemini", "vertexai": return Color(red: 0.259, green: 0.522, blue: 0.957)
        case "mistral": return Color(red: 0.980, green: 0.322, blue: 0.059)
        case "perplexity": return Color(red: 0.125, green: 0.502, blue: 0.553)
        case "openrouter": return Color(red: 0.392, green: 0.404, blue: 0.949)
        case "minimax": return Color(red: 0.906, green: 0.247, blue: 0.353)
        case "mimo": return Color(red: 0.980, green: 0.420, blue: 0.180)
        case "bedrock": return Color(red: 1.0, green: 0.600, blue: 0.0)
        case "copilot", "factory", "doubao", "sub2api", "zoommate", "codebuff":
            return Color(nsColor: ProviderBrand.nsColor(for: id))
        default: return Color(red: 0.11, green: 0.11, blue: 0.12)
        }
    }
}

extension ProviderBrand {
    /// Color for a bare logo on the menu background: the brand color, or the
    /// label color for black-and-white brands.
    static func logoTint(for id: String) -> Color {
        switch id {
        case "claude", "deepseek", "gemini", "vertexai", "mistral", "perplexity",
             "openrouter", "minimax", "mimo", "bedrock":
            return tileColor(for: id)
        default:
            return .primary
        }
    }
}

/// The provider's official logo. Single-color marks take `tint`
/// (default: the label color); multi-color marks keep their colors.
/// Falls back to the SF Symbol when no artwork ships.
struct ProviderLogoView: View {
    let providerID: String
    var size: CGFloat = 18
    var tint: Color? = nil

    var body: some View {
        Group {
            if let logo = ProviderLogo.image(for: providerID) {
                if logo.isTemplate {
                    Image(nsImage: logo)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .foregroundColor(tint ?? .primary)
                } else {
                    Image(nsImage: logo)
                        .renderingMode(.original)
                        .resizable()
                        .interpolation(.high)
                }
            } else {
                Image(systemName: ProviderBrand.symbol(for: providerID))
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(tint ?? ProviderBrand.color(for: providerID))
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
