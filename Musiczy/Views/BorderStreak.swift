import SwiftUI
import AppKit
import QuartzCore
import CoreImage

/// The white highlight, drawn with Core Animation instead of SwiftUI animation.
/// Core Animation keeps running while the main thread is busy, and the highlight
/// moves at an even speed along the border, so it is the same length on every edge.
struct BorderStreak: NSViewRepresentable {
    var length: Double      // fraction of the border it covers
    var seconds: Double     // time for one lap
    var scale: Double = 1   // 1 = full size (ShineStyle values), lower = smaller

    func makeNSView(context: Context) -> StreakView {
        let view = StreakView()
        view.configure(length: length, seconds: seconds, scale: scale)
        return view
    }

    func updateNSView(_ nsView: StreakView, context: Context) {
        nsView.configure(length: length, seconds: seconds, scale: scale)
    }
}

final class StreakView: NSView {
    private let container = CALayer()
    private var builtSize = CGSize.zero
    private var length = ShineStyle.sweepLength
    private var seconds = ShineStyle.sweepSeconds
    private var sizeScale = 1.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.masksToBounds = true       // nothing draws outside the screen
        layer?.addSublayer(container)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Never catch clicks: the player's buttons are underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Called when the sliders change. Rebuilds the highlight only if a value really changed.
    func configure(length: Double, seconds: Double, scale: Double) {
        guard length != self.length || seconds != self.seconds || scale != self.sizeScale else { return }
        self.length = length
        self.seconds = seconds
        self.sizeScale = scale
        if builtSize != .zero { rebuild() }
    }

    override func layout() {
        super.layout()
        guard bounds.size != builtSize, bounds.width > 50, bounds.height > 50 else { return }
        builtSize = bounds.size
        rebuild()
    }

    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        container.sublayers?.forEach { $0.removeFromSuperlayer() }

        // The container is bigger than the screen, so the blur also has something to blur
        // outside the screen edge. That keeps the highlight at full strength AT the edge.
        // The sweep follows the ambient Size slider, but is never bigger than the ShineStyle values.
        let k = CGFloat(min(max(sizeScale, 0.05), 1))
        let sweepWidth = ShineStyle.sweepWidth * k
        let sweepBlur = ShineStyle.sweepBlur * k

        let pad = sweepWidth + sweepBlur * 3
        container.frame = bounds.insetBy(dx: -pad, dy: -pad)

        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setDefaults()
            blur.setValue(Double(sweepBlur), forKey: kCIInputRadiusKey)
            container.filters = [blur]
        }

        // The screen's edge, twice in a row, so the highlight can run one full lap and start over with no seam.
        // On a Mac with a notch, the line dips down around it.
        let r = CGRect(x: pad, y: pad, width: bounds.width, height: bounds.height)
        var loop = [CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY)]
        if let n = Notch.size(for: bounds.size) {
            loop += [CGPoint(x: r.midX + n.width / 2, y: r.maxY),
                     CGPoint(x: r.midX + n.width / 2, y: r.maxY - n.height),
                     CGPoint(x: r.midX - n.width / 2, y: r.maxY - n.height),
                     CGPoint(x: r.midX - n.width / 2, y: r.maxY)]
        }
        loop += [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY)]

        let path = CGMutablePath()
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        for _ in 0..<2 { loop.forEach { path.addLine(to: $0) } }

        // The streak is cut into thin slices, each with its own strength:
        // brightest in the middle, fading out toward both ends.
        let steps = 40
        let whole = length / 2        // its length as a fraction of the doubled path
        let lapSeconds = seconds

        for i in 0..<steps {
            let u0 = Double(i) / Double(steps)
            let u1 = Double(i + 1) / Double(steps)
            let strength = pow(sin(.pi * (u0 + u1) / 2), ShineStyle.sweepFalloff)
            let alpha = ShineStyle.sweepOpacity * strength
            guard alpha > 0.01 else { continue }

            let start = whole * u0
            let end = whole * u1

            let shape = CAShapeLayer()
            shape.frame = container.bounds
            shape.path = path
            shape.fillColor = nil
            shape.strokeColor = NSColor.white.cgColor
            shape.lineWidth = sweepWidth * 2               // centered on the screen edge, so half is off-screen
            shape.lineCap = .butt                          // flat ends, no round blobs
            shape.lineJoin = .round
            shape.opacity = Float(min(alpha, 1))
            shape.strokeStart = CGFloat(start)
            shape.strokeEnd = CGFloat(end)

            let moveStart = CABasicAnimation(keyPath: "strokeStart")
            moveStart.fromValue = start
            moveStart.toValue = start + 0.5            // half of the doubled path = one lap
            let moveEnd = CABasicAnimation(keyPath: "strokeEnd")
            moveEnd.fromValue = end
            moveEnd.toValue = end + 0.5
            for anim in [moveStart, moveEnd] {
                anim.duration = lapSeconds
                anim.timingFunction = CAMediaTimingFunction(name: .linear)
            }

            let group = CAAnimationGroup()
            group.animations = [moveStart, moveEnd]
            group.duration = lapSeconds
            group.repeatCount = .infinity
            shape.add(group, forKey: "lap")

            container.addSublayer(shape)
        }
    }
}
