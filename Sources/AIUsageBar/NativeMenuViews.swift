@preconcurrency import AppKit
import SwiftUI

enum NativeMenuLayout {
    /// Width of every hosted row; NSMenu sizes itself to its widest item.
    static let width: CGFloat = 340
    static let inset: CGFloat = 16
}

struct NativeMenuOverviewRow: Identifiable, Hashable {
    let id: String
    let providerID: String
    let title: String
    let account: String?
    let usedPercent: Double?
    let quotaLabel: String?
    let health: ProviderServiceHealth
    let hasError: Bool
    var resetsAt: Date? = nil
    /// Shown instead of a gauge for prepaid providers without a quota window.
    var balanceText: String? = nil

    var remainingPercent: Double? { usedPercent.map { max(0, min(100, 100 - $0)) } }
}

/// Hairline divider inset like native menu separators.
private struct MenuHairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
            .padding(.horizontal, NativeMenuLayout.inset)
    }
}

struct NativeMenuHeaderView: View {
    let title: String
    let subtitle: String
    let providerID: String?
    let health: ProviderServiceHealth?
    let refreshing: Bool
    var planLabel: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let providerID = providerID {
                ProviderBadge(providerID: providerID, size: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.system(size: providerID == nil ? 13 : 14, weight: .semibold))
                        .lineLimit(1)
                    if let plan = planLabel, !plan.isEmpty {
                        Text(plan.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.6)
                            .foregroundColor(providerID.map(ProviderBrand.color(for:)) ?? .accentColor)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if refreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .accessibilityLabel(Text(L("Refreshing providers")))
            } else if let health = health, health.isIncident {
                HStack(spacing: 4) {
                    Circle().fill(DS.healthColor(health)).frame(width: 6, height: 6)
                    Text(health.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.healthColor(health))
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, NativeMenuLayout.inset)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(width: NativeMenuLayout.width)
    }
}

/// Shown in place of the provider rows until a provider is set up.
struct NativeMenuEmptyStateView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundColor(.secondary)
            Text(L("No providers enabled yet"))
                .font(.system(size: 13, weight: .medium))
            Text(L("Choose Set Up Providers… below to connect Claude, Codex, DeepSeek or another service."))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, NativeMenuLayout.inset)
        .padding(.vertical, 16)
        .frame(width: NativeMenuLayout.width)
    }
}

struct NativeMenuProviderCardView: View {
    let snapshot: ProviderSnapshot
    let dashboard: ProviderDashboard
    let showAccount: Bool
    let showMetrics: Bool
    let showResetTime: Bool
    let showStatus: Bool
    let quotaPresentation: MenuQuotaPresentation

    private var tint: Color { ProviderBrand.color(for: snapshot.provider) }
    private var visibleMetrics: [DashboardMetric] {
        Array(dashboard.metrics.filter { !DS.isPlaceholder($0) }.prefix(4))
    }
    private var quotas: [DashboardQuotaLane] { Array(dashboard.quotas.prefix(4)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showStatus, let status = dashboard.serviceStatus, status.health.isIncident {
                notice(symbol: status.health.symbolName, tint: DS.healthColor(status.health),
                       text: "\(status.health.title) · \(status.displayText)")
            }
            if let error = dashboard.errorMessage {
                notice(symbol: "exclamationmark.triangle.fill", tint: Color(nsColor: .systemRed), text: error)
            }

            if let primary = quotas.first {
                heroQuota(primary)
                    .padding(.horizontal, NativeMenuLayout.inset)
                    .padding(.vertical, 12)
            }
            if quotas.count > 1 {
                VStack(spacing: 10) {
                    ForEach(quotas.dropFirst()) { lane in
                        compactQuota(lane)
                    }
                }
                .padding(.horizontal, NativeMenuLayout.inset)
                .padding(.bottom, 12)
            }

            if showMetrics, !visibleMetrics.isEmpty {
                MenuHairline()
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                          alignment: .leading, spacing: 12) {
                    ForEach(visibleMetrics) { metric in
                        metricCell(metric)
                    }
                }
                .padding(.horizontal, NativeMenuLayout.inset)
                .padding(.vertical, 12)
            }

            footer
        }
        .frame(width: NativeMenuLayout.width)
    }

    private func heroQuota(_ lane: DashboardQuotaLane) -> some View {
        HStack(spacing: 16) {
            UsageRing(remaining: lane.remainingPercent, size: 78, lineWidth: 7,
                      showsUsed: quotaPresentation == .used, tint: tint, numeralWeight: .light)
            VStack(alignment: .leading, spacing: 4) {
                Text(lane.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(quotaPresentation == .used
                     ? L("%@%% used", String(format: "%.0f", lane.usedPercent))
                     : L("%@%% remaining", String(format: "%.0f", lane.remainingPercent)))
                    .font(.system(size: 11))
                    .foregroundColor(lane.remainingPercent < 15 ? Color(nsColor: .systemRed) : .secondary)
                if showResetTime {
                    if let resetsAt = lane.resetsAt, let countdown = DS.countdown(to: resetsAt) {
                        Label(L("Resets in %@", countdown), systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else if let reset = lane.resetText {
                        Label(reset, systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    if let pace = lane.paceDescription() {
                        Label(pace, systemImage: "speedometer")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.tone(remaining: lane.remainingPercent))
                            .lineLimit(2)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func compactQuota(_ lane: DashboardQuotaLane) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(lane.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if showResetTime, let resetsAt = lane.resetsAt, let countdown = DS.countdown(to: resetsAt) {
                    Text(countdown)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 4)
                Text(String(format: "%.0f%%", quotaPresentation == .used ? lane.usedPercent : lane.remainingPercent))
                    .font(.system(size: 13, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundColor(lane.remainingPercent < 15 ? Color(nsColor: .systemRed) : .primary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.14))
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(3, geometry.size.width * CGFloat(
                            (quotaPresentation == .used ? lane.usedPercent : lane.remainingPercent) / 100)))
                }
            }
            .frame(height: 3)
        }
        .accessibilityElement(children: .combine)
    }

    private func metricCell(_ metric: DashboardMetric) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metric.title)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(metric.value)
                .font(.system(size: 18, weight: .light, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var footer: some View {
        let hasMore = dashboard.metrics.count > 4 || dashboard.quotas.count > 4
        MenuHairline()
        if let breakdown = dashboard.claudeProductBreakdown {
            ClaudeProductBreakdownView(breakdown: breakdown, compact: true)
                .padding(.horizontal, NativeMenuLayout.inset)
                .padding(.vertical, 10)
            MenuHairline()
        }
        VStack(alignment: .leading, spacing: 5) {
            if let credit = dashboard.claudeIncludedCredit {
                ClaudeIncludedCreditView(credit: credit, compact: true)
            }
            SubscriptionTimingView(dashboard: dashboard, compact: true)
            if snapshot.provider == "claude" {
                Label(dashboard.hasClaudeSharedQuota
                      ? L("Quota · all devices including web chat")
                      : L("Shared quota unavailable"),
                      systemImage: "laptopcomputer.and.iphone")
                if showMetrics {
                    Label(L("Tokens & cost · local logs only"), systemImage: "internaldrive")
                }
            }
            if hasMore {
                Text(L("More information is available in Detailed Dashboard"))
            }
        }
        .font(.system(size: 10))
        .foregroundColor(.secondary)
        .padding(.horizontal, NativeMenuLayout.inset)
        .padding(.vertical, 10)
    }

    private func notice(symbol: String, tint: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
        }
        .foregroundColor(tint)
        .padding(.horizontal, NativeMenuLayout.inset)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }
}

/// One provider written out in the main menu. Clicking it opens that
/// provider's detail popover, so there is no submenu in between.
struct NativeMenuProviderRowView: View {
    let row: NativeMenuOverviewRow
    let quotaPresentation: MenuQuotaPresentation
    let showAccount: Bool
    let showStatus: Bool
    /// The quota just reset: the ring plays the fill-and-glow.
    var celebrating = false
    /// Drawn on the menu's accent highlight: everything turns white.
    var highlighted: Bool = false

    private var secondary: Color { highlighted ? Color.white.opacity(0.85) : .secondary }

    var body: some View {
        HStack(spacing: 10) {
            ProviderBadge(providerID: row.providerID, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(row.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if showStatus, row.health.isIncident {
                        Circle()
                            .fill(highlighted ? Color.white : DS.healthColor(row.health))
                            .frame(width: 6, height: 6)
                    }
                    if showAccount, let account = row.account {
                        Text(account)
                            .font(.system(size: 11))
                            .foregroundColor(secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundColor(row.hasError && !highlighted ? Color(nsColor: .systemRed) : secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .foregroundColor(highlighted ? .white : .primary)
        .padding(.horizontal, NativeMenuLayout.inset)
        .padding(.vertical, 5)
        .frame(width: NativeMenuLayout.width, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        var parts: [String] = []
        if row.hasError {
            parts.append(L("Connection error"))
        } else if row.remainingPercent != nil {
            if let label = row.quotaLabel, !label.isEmpty { parts.append(label) }
            if let resetsAt = row.resetsAt, let countdown = DS.countdown(to: resetsAt) {
                parts.append(L("Resets in %@", countdown))
            }
        } else if row.balanceText != nil {
            parts.append(L("Balance"))
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var trailing: some View {
        if row.hasError {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(highlighted ? .white : Color(nsColor: .systemRed))
        } else if let remaining = row.remainingPercent {
            let shown = quotaPresentation == .used ? 100 - remaining : remaining
            HStack(spacing: 8) {
                Text(String(format: "%.0f%%", shown))
                    .font(.system(size: 14, weight: .regular, design: .rounded).monospacedDigit())
                    .foregroundColor(remaining < 15 && !highlighted ? Color(nsColor: .systemRed) : nil)
                // Core Animation ring: it keeps animating while the menu tracks.
                AnimatedQuotaRing(percent: shown,
                                  color: highlighted ? .white : DS.toneNSColor(remaining: remaining),
                                  lineWidth: 2.5, diameter: 18,
                                  celebrate: celebrating)
                    .frame(width: 18 + QuotaRingLayerView.glowMargin * 2,
                           height: 18 + QuotaRingLayerView.glowMargin * 2)
                    .padding(-QuotaRingLayerView.glowMargin)
                    // A new identity replays the reset when it arrives with the menu open.
                    .id("\(row.id)-\(celebrating)")
            }
        } else if let balance = row.balanceText {
            Text(balance)
                .font(.system(size: 13, weight: .regular, design: .rounded).monospacedDigit())
                .lineLimit(1)
        } else {
            Text("—").foregroundColor(secondary)
        }
    }
}

/// Hosts a clickable SwiftUI row in an NSMenu. A menu item with a view gets
/// no highlight of its own, so this draws the system selection behind the
/// row, and a click sends the item's action like a standard item does.
final class MenuActionRowView: NSView {
    private let selection = NSVisualEffectView()
    private let hosting: NSHostingView<AnyView>
    private let content: (Bool) -> AnyView
    private(set) var isHighlighted = false

    init(content: @escaping (Bool) -> AnyView) {
        self.content = content
        hosting = NSHostingView(rootView: content(false))
        super.init(frame: .zero)
        selection.material = .selection
        selection.state = .active
        selection.isEmphasized = true
        selection.blendingMode = .behindWindow
        selection.maskImage = Self.roundedMask(radius: 4)
        selection.isHidden = true
        addSubview(selection)
        addSubview(hosting)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Rebuilds the row from current data and resizes it to fit.
    func reload() {
        hosting.rootView = content(isHighlighted)
        let height = max(1, hosting.fittingSize.height)
        frame = NSRect(x: 0, y: 0, width: NativeMenuLayout.width, height: height)
        hosting.frame = bounds
        // Same inset and corner as the native highlight since Big Sur.
        selection.frame = bounds.insetBy(dx: 5, dy: 0)
    }

    func setHighlighted(_ highlighted: Bool) {
        guard highlighted != isHighlighted else { return }
        isHighlighted = highlighted
        selection.isHidden = !highlighted
        hosting.rootView = content(highlighted)
    }

    /// The row has no controls of its own: every click lands here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    /// The menu belongs to an accessory app that is usually not active when it is
    /// clicked. Without this, the first click after launch (or after using another
    /// app) only activated the menu's window and never reached the row, so a
    /// provider took two clicks to open; native items do not have that problem.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Taken here so the press is not passed up to the menu's own views, which
    /// would leave the release without a target.
    override func mouseDown(with event: NSEvent) {
        menuClickLog.notice("provider row mouseDown; app active=\(NSApp.isActive, privacy: .public)")
    }

    override func mouseUp(with event: NSEvent) {
        menuClickLog.notice("provider row mouseUp; app active=\(NSApp.isActive, privacy: .public)")
        guard let item = enclosingMenuItem, let menu = item.menu else { return }
        let index = menu.index(of: item)
        menu.cancelTracking()
        guard index >= 0 else { return }
        // Native items fire their action only after the menu has closed. Running it here,
        // while the menu is still tracking, let a popover opened by the action be dismissed
        // by the menu's own teardown, so a tap sometimes did nothing. The default run-loop
        // mode resumes only once tracking has ended.
        RunLoop.main.perform(inModes: [.default]) {
            menu.performActionForItem(at: index)
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
