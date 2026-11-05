import SwiftUI
import AppKit

/// Finds the camera notch (MacBooks with a notch only).
enum Notch {
    /// The notch's width and height, but only when the view covers a whole notched screen.
    /// nil = no notch, or the player is in a small window.
    static func size(for viewSize: CGSize) -> CGSize? {
        guard let screen = NSScreen.screens.first(where: {
            $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil
                && abs(viewSize.width - $0.frame.width) < 10
                && abs(viewSize.height - $0.frame.height) < 10
        }),
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }

        let width = right.minX - left.maxX
        // The player window is a couple of points taller than the screen, so count that too.
        let overhang = max(0, (viewSize.height - screen.frame.height) / 2)
        let height = screen.safeAreaInsets.top + overhang
        guard width > 0, height > 0 else { return nil }

        return CGSize(width: width + 2 * ShineStyle.notchMargin,
                      height: height + ShineStyle.notchMargin)
    }
}

/// The screen's outline with the notch cut out of the top edge (a plain rectangle if there is no notch).
struct ScreenOutline: Shape {
    var notch: CGSize?

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        if let n = notch {
            p.addLine(to: CGPoint(x: r.midX - n.width / 2, y: r.minY))
            p.addLine(to: CGPoint(x: r.midX - n.width / 2, y: r.minY + n.height))
            p.addLine(to: CGPoint(x: r.midX + n.width / 2, y: r.minY + n.height))
            p.addLine(to: CGPoint(x: r.midX + n.width / 2, y: r.minY))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
