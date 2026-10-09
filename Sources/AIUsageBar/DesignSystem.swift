@preconcurrency import AppKit
import SwiftUI

/// Shared visual language for menus, popovers and settings: native materials
/// and system colors, hairline-bordered cards, gradient gauges whose color
/// follows how much quota is left, and SF Rounded numerals. macOS 12 APIs only.
enum DS {
    static let cardRadius: CGFloat = 12
    static let tileRadius: CGFloat = 10

    /// Green while plenty remains, amber when it gets tight, red near empty.
    static func tone(remaining: Double?) -> Color {
        guard let remaining = remaining else { return Color.secondary }
        switch remaining {
        case ..<15: return Color(nsColor: .systemRed)
        case ..<35: return Color(nsColor: .systemOrange)
        case ..<60: return Color(nsColor: .systemYellow)
        default: return Color(nsColor: .systemGreen)
        }
    }

    static func gradient(remaining: Double?) -> [Color] {
        let base = tone(remaining: remaining)
        return [base.opacity(0.75), base]
    }

    static func numeral(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    /// Placeholder values the parser uses when a metric has no data. Tiles
    /// with these values are hidden instead of shouting "Unavailable".
    static func isPlaceholder(_ metric: DashboardMetric) -> Bool {
        let value = metric.value.trimmingCharacters(in: .whitespaces)
        return value.isEmpty || value == "—" || value == "-"
            || [L("Unavailable"), L("Not exposed"), "Unavailable", "Not exposed"].contains(value)
    }

    /// "3h 14m" in English, "3小时14分" in Chinese.
    static func countdown(to date: Date, now: Date = Date()) -> String? {
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: L10n.usesChinese ? "zh_Hans" : "en_US")
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = interval >= 86_400 ? [.day, .hour] : [.hour, .minute]
        return formatter.string(from: interval)?.replacingOccurrences(of: " ", with: L10n.usesChinese ? "" : " ")
    }
}

// MARK: - Surfaces

/// A quiet, native-feeling card: translucent fill plus a hairline border.
struct DSCard<Content: View>: View {
    var padding: CGFloat = 12
    var tint: Color? = nil
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                    .fill((tint ?? Color.primary).opacity(tint == nil ? 0.045 : 0.10)))
            .overlay(
                RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                    .strokeBorder((tint ?? Color.primary).opacity(tint == nil ? 0.08 : 0.22), lineWidth: 0.5))
    }
}

/// Small uppercase-style section label used above groups of content.
struct DSSectionLabel: View {
    let title: String
    var symbol: String? = nil
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let symbol = symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            }
            Text(title).font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 4)
            if let trailing = trailing {
                Text(trailing).font(.system(size: 11))
            }
        }
        .foregroundColor(.secondary)
    }
}

/// Capsule label for reset countdowns, plans and states.
struct DSChip: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let symbol = symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            }
            Text(text).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .foregroundColor(tint == .secondary ? .secondary : tint)
        .background(Capsule().fill(tint.opacity(tint == .secondary ? 0.12 : 0.15)))
    }
}

// MARK: - Identity

/// App-icon style provider badge: a continuous rounded square filled with
/// the brand color gradient and a white symbol, like System Settings icons.
struct ProviderBadge: View {
    let providerID: String?
    var size: CGFloat = 28

    private var color: Color {
        providerID.map(ProviderBrand.color(for:)) ?? Color(nsColor: .systemBlue)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient(
                    colors: [color.opacity(0.85), color],
                    startPoint: .top,
                    endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            Image(systemName: providerID.map(ProviderBrand.symbol(for:)) ?? "chart.bar.xaxis")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundColor(.white)
                .shadow(color: Color.black.opacity(0.18), radius: 0.5, y: 0.5)
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(0.25), radius: 2, y: 1)
        .accessibilityHidden(true)
    }
}

/// Colored dot for service health.
struct DSHealthDot: View {
    let health: ProviderServiceHealth
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(DS.healthColor(health))
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .accessibilityLabel(Text(health.title))
    }
}

extension DS {
    static func healthColor(_ health: ProviderServiceHealth) -> Color {
        switch health {
        case .unknown: return Color.secondary.opacity(0.6)
        case .operational: return Color(nsColor: .systemGreen)
        case .degraded: return Color(nsColor: .systemOrange)
        case .outage: return Color(nsColor: .systemRed)
        }
    }
}

// MARK: - Gauges

/// Circular quota gauge. The arc shows what is left and takes its color
/// from how much is left, so a glance answers "am I about to run out?".
struct UsageRing: View {
    /// 0–100, or nil when the provider reports no quota.
    let remaining: Double?
    var size: CGFloat = 40
    var lineWidth: CGFloat = 4.5
    var showsValue = true
    /// Show and draw the used share instead (color still follows what is left).
    var showsUsed = false

    private var displayed: Double? {
        remaining.map { showsUsed ? 100 - $0 : $0 }
    }

    var body: some View {
        let fraction = CGFloat(max(0, min(100, displayed ?? 0)) / 100)
        let colors = DS.gradient(remaining: remaining)
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.09), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: remaining == nil ? 0 : max(0.001, fraction))
                .stroke(
                    AngularGradient(colors: colors + [colors[0]], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(360 * Double(max(0.001, fraction)))),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showsValue {
                if let displayed = displayed {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(String(format: "%.0f", max(0, min(100, displayed))))
                            .font(DS.numeral(size * (displayed >= 99.5 ? 0.26 : 0.32), weight: .bold))
                        Text("%")
                            .font(.system(size: size * 0.17, weight: .semibold, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("—").font(DS.numeral(size * 0.3)).foregroundColor(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Text(remaining.map { L("%@%% remaining", String(format: "%.0f", max(0, min(100, $0)))) } ?? L("Unavailable")))
    }
}

/// Linear gauge with the same color rule as the ring.
struct UsageBar: View {
    /// Fraction to fill, 0–100.
    let fill: Double?
    /// Remaining percent used to pick the color.
    let remaining: Double?
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                if let fill = fill {
                    Capsule()
                        .fill(LinearGradient(colors: DS.gradient(remaining: remaining),
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, geometry.size.width * CGFloat(max(0, min(100, fill)) / 100)))
                        .opacity(fill <= 0 ? 0 : 1)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Minimal trend line with a soft gradient area underneath.
struct Sparkline: View {
    let values: [Double?]
    var tint: Color = .accentColor
    var maximum: Double? = nil

    var body: some View {
        GeometryReader { geometry in
            let known = values.compactMap { $0 }
            let top = max(maximum ?? (known.max() ?? 1), 0.000_1)
            let step = values.count > 1 ? geometry.size.width / CGFloat(values.count - 1) : 0
            let points: [CGPoint] = values.enumerated().compactMap { index, value in
                guard let value = value else { return nil }
                let y = geometry.size.height * (1 - CGFloat(value / top))
                return CGPoint(x: CGFloat(index) * step, y: min(geometry.size.height, max(0, y)))
            }
            if points.count > 1 {
                Path { path in
                    path.move(to: CGPoint(x: points[0].x, y: geometry.size.height))
                    points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: points[points.count - 1].x, y: geometry.size.height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.0)],
                                     startPoint: .top, endPoint: .bottom))
                Path { path in
                    path.move(to: points[0])
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}
