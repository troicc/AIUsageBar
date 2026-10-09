import SwiftUI

enum ClaudeProductStyle {
    static func color(_ key: String) -> Color {
        switch key {
        case "claude_code": return ProviderBrand.color(for: "claude")
        case "cowork": return Color(nsColor: .systemTeal)
        case "chat": return Color(nsColor: .systemBlue)
        default: return Color(nsColor: .systemGray)
        }
    }

    static func title(_ row: ClaudeProductBreakdown.Row) -> String {
        switch row.key {
        case "claude_code": return "Claude Code"
        case "chat": return L("Chats")
        case "cowork": return "Cowork"
        case "other": return L("Other")
        default: return row.title
        }
    }
}

/// "This week's usage by product" from the Claude account, as a single
/// proportional bar with a legend. Official numbers, not estimates.
struct ClaudeProductBreakdownView: View {
    let breakdown: ClaudeProductBreakdown
    var compact = false

    private var rows: [ClaudeProductBreakdown.Row] {
        breakdown.rows.sorted { $0.percent > $1.percent }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("This week by product"))
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                Spacer()
                if let start = breakdown.windowStartedAt {
                    Text(L("Since %@", FlexibleDate.label(start, style: .day)))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            bar
            if compact {
                HStack(spacing: 10) {
                    ForEach(rows.filter { $0.percent > 0 }.prefix(3)) { row in
                        legendItem(row)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(rows) { row in
                        HStack(spacing: 7) {
                            Circle().fill(ClaudeProductStyle.color(row.key)).frame(width: 7, height: 7)
                            Text(ClaudeProductStyle.title(row))
                                .font(.system(size: 12))
                            Spacer()
                            Text(String(format: "%.0f%%", row.percent))
                                .font(.system(size: 14, weight: .light, design: .rounded).monospacedDigit())
                                .foregroundColor(row.percent > 0 ? .primary : .secondary)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var bar: some View {
        GeometryReader { geometry in
            let visible = rows.filter { $0.percent > 0 }
            let total = max(1, visible.reduce(0) { $0 + $1.percent })
            let gaps = CGFloat(max(0, visible.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(visible) { row in
                    Rectangle()
                        .fill(ClaudeProductStyle.color(row.key))
                        .frame(width: max(2, (geometry.size.width - gaps) * CGFloat(row.percent / total)))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: compact ? 6 : 8)
    }

    private func legendItem(_ row: ClaudeProductBreakdown.Row) -> some View {
        HStack(spacing: 4) {
            Circle().fill(ClaudeProductStyle.color(row.key)).frame(width: 6, height: 6)
            Text(ClaudeProductStyle.title(row))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(String(format: "%.0f%%", row.percent))
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
        }
    }
}

/// Promotional included credit on the Claude account.
struct ClaudeIncludedCreditView: View {
    let credit: ClaudeIncludedCredit
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "gift")
                .font(.system(size: compact ? 10 : 11))
                .foregroundColor(.secondary)
            Text(L("Included credit"))
                .font(.system(size: compact ? 10 : 11))
                .foregroundColor(.secondary)
            Spacer(minLength: 4)
            Text(L("%@ of %@ left", Self.dollars(credit.remainingDollars), Self.dollars(credit.limitDollars)))
                .font(.system(size: compact ? 11 : 12, weight: .medium, design: .rounded).monospacedDigit())
            if let expires = credit.expiresAt {
                Text(L("expires %@", FlexibleDate.label(expires, style: .day)))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static func dollars(_ value: Double) -> String {
        value == value.rounded() ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }
}
