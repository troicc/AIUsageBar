@preconcurrency import AppKit
import Foundation

extension RateWindow {
    var displayLabel: String {
        guard let minutes = windowMinutes else { return L("Quota") }
        if abs(minutes - 300) < 1 { return L("5 hours") }
        if abs(minutes - 1440) < 1 { return L("Daily") }
        if abs(minutes - 10080) < 1 { return L("Weekly") }
        if abs(minutes - 43200) < 60 { return L("Monthly") }
        if minutes >= 1440 { return L("%d days", Int(minutes / 1440)) }
        if minutes >= 60 { return L("%d hours", Int(minutes / 60)) }
        return L("%d minutes", Int(minutes))
    }

    var resetText: String? {
        guard let resetsAt = resetsAt else { return nil }
        let interval = resetsAt.timeIntervalSinceNow
        if interval <= 0 { return L("Reset pending") }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = interval >= 86400 ? [.day, .hour] : [.hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter.string(from: interval).map { L("Resets in %@", $0) }
    }
}

extension NSColor {
    static func providerColor(id: String) -> NSColor {
        let hash = abs(id.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) })
        return NSColor(calibratedHue: CGFloat(hash % 360) / 360.0, saturation: 0.62, brightness: 0.88, alpha: 1)
    }
}
