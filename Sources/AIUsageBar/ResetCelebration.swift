@preconcurrency import AppKit
import QuartzCore
import SwiftUI

extension DS {
    /// AppKit version of `tone(remaining:)` for Core Animation layers.
    static func toneNSColor(remaining: Double?) -> NSColor {
        guard let remaining = remaining else { return .secondaryLabelColor }
        switch remaining {
        case ..<15: return .systemRed
        case ..<35: return .systemOrange
        case ..<60: return .systemYellow
        default: return .systemGreen
        }
    }
}

extension Notification.Name {
    /// Plays the quota-reset animation without waiting for a real reset.
    static let previewResetAnimation = Notification.Name("AIUsageBar.previewResetAnimation")
}

/// Quota ring drawn with Core Animation so its reset animation keeps
/// running while a menu is open (SwiftUI animations can stall during menu
/// tracking). On a reset the arc fills from empty, then the whole ring
/// glows and fades back.
struct AnimatedQuotaRing: NSViewRepresentable {
    /// Arc to draw, 0–100.
    let percent: Double
    let color: NSColor
    var lineWidth: CGFloat = 5
    var diameter: CGFloat = 50
    var celebrate = false

    func makeNSView(context: Context) -> QuotaRingLayerView {
        let view = QuotaRingLayerView(diameter: diameter, lineWidth: lineWidth)
        view.configure(percent: percent, color: color)
        if celebrate {
            DispatchQueue.main.async { view.celebrate() }
        }
        return view
    }

    func updateNSView(_ view: QuotaRingLayerView, context: Context) {
        view.configure(percent: percent, color: color)
    }
}

final class QuotaRingLayerView: NSView {
    private let diameter: CGFloat
    private let lineWidth: CGFloat
    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private let halo = CAShapeLayer()
    private var percent: Double = 0
    private var color: NSColor = .systemGreen

    /// Extra room around the ring so the glow is not clipped.
    static let glowMargin: CGFloat = 8

    init(diameter: CGFloat, lineWidth: CGFloat) {
        self.diameter = diameter
        self.lineWidth = lineWidth
        let side = diameter + Self.glowMargin * 2
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        layer?.masksToBounds = false
        for shape in [halo, track, progress] {
            shape.fillColor = nil
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        track.lineWidth = lineWidth
        progress.lineWidth = lineWidth
        halo.lineWidth = lineWidth * 2.6
        halo.opacity = 0
        progress.shadowOffset = .zero
        progress.shadowRadius = 0
        progress.shadowOpacity = 0
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: diameter + Self.glowMargin * 2, height: diameter + Self.glowMargin * 2)
    }

    override func layout() {
        super.layout()
        let inset = (bounds.width - diameter) / 2 + lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        // Start at 12 o'clock and run clockwise.
        let path = CGMutablePath()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.addArc(center: center, radius: rect.width / 2, startAngle: .pi / 2,
                    endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [halo, track, progress] {
            shape.frame = bounds
            shape.path = path
        }
        CATransaction.commit()
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    func configure(percent: Double, color: NSColor) {
        self.percent = max(0, min(100, percent))
        self.color = color
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progress.strokeEnd = CGFloat(self.percent / 100)
        CATransaction.commit()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            track.strokeColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
            progress.strokeColor = color.cgColor
            progress.shadowColor = color.cgColor
            halo.strokeColor = color.withAlphaComponent(0.35).cgColor
            CATransaction.commit()
        }
    }

    /// Fill from empty to the current value, then glow the whole ring.
    func celebrate() {
        let target = CGFloat(percent / 100)
        let fillDuration: CFTimeInterval = 1.1
        let glowDuration: CFTimeInterval = 1.3
        let now = CACurrentMediaTime()

        let fill = CABasicAnimation(keyPath: "strokeEnd")
        fill.fromValue = 0
        fill.toValue = target
        fill.duration = fillDuration
        fill.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        progress.add(fill, forKey: "resetFill")

        let glow = CAKeyframeAnimation(keyPath: "shadowOpacity")
        glow.values = [0, 0.95, 0]
        glow.keyTimes = [0, 0.3, 1]
        glow.beginTime = now + fillDuration - 0.15
        glow.duration = glowDuration
        progress.shadowRadius = 7
        progress.add(glow, forKey: "resetGlow")

        let swell = CAKeyframeAnimation(keyPath: "lineWidth")
        swell.values = [lineWidth, lineWidth * 1.45, lineWidth]
        swell.keyTimes = [0, 0.3, 1]
        swell.beginTime = glow.beginTime
        swell.duration = glowDuration
        progress.add(swell, forKey: "resetSwell")

        let aura = CAKeyframeAnimation(keyPath: "opacity")
        aura.values = [0, 1, 0]
        aura.keyTimes = [0, 0.3, 1]
        aura.beginTime = glow.beginTime
        aura.duration = glowDuration
        halo.add(aura, forKey: "resetAura")
    }
}
