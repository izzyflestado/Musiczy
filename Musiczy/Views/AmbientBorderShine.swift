import SwiftUI
import AppKit

// MARK: - Look (change the numbers here)

enum ShineStyle {
    static let turnSeconds: Double = 16      // one lap of the cover colors around the border
    static let sweepSeconds: Double = 9      // one lap of the white highlight (runs the other way)
    static let fadeSeconds: Double = 1.2     // color change between songs
    static let sweepOpacity: Double = 1.0    // 0 = no white highlight

    // Three layers, from a wide soft glow to a thin crisp line
    static let softWidth: CGFloat = 40
    static let softBlur: CGFloat = 45
    static let softOpacity: Double = 0.8
    static let midWidth: CGFloat = 16
    static let midBlur: CGFloat = 14
    static let midOpacity: Double = 1.0
    static let lineWidth: CGFloat = 2.5      // 0 = no crisp line
    static let lineInset: CGFloat = 5        // keeps the line off the very edge of the screen
}

/// Black background mode: a glowing border that turns slowly and uses the cover's colors.
struct AmbientBorderShine: View {
    let artwork: NSImage?
    let songID: UUID

    @State private var colors: [Color] = []
    @State private var version = 0          // changes with every new palette, so the old one fades out
    @State private var spin = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let d = hypot(size.width, size.height)    // big enough to cover the screen at any angle

            ZStack {
                // The cover's colors, turning slowly. The turning layer stays; only the gradient inside swaps.
                ZStack {
                    if !colors.isEmpty {
                        AngularGradient(gradient: Gradient(colors: colors + [colors[0]]), center: .center)
                            .id(version)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: ShineStyle.fadeSeconds), value: version)
                .frame(width: d, height: d)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: ShineStyle.turnSeconds).repeatForever(autoreverses: false),
                           value: spin)

                // A white highlight running around the border the other way
                AngularGradient(gradient: Gradient(stops: [
                    .init(color: .white.opacity(0), location: 0.00),
                    .init(color: .white.opacity(0), location: 0.68),
                    .init(color: .white.opacity(ShineStyle.sweepOpacity), location: 0.84),
                    .init(color: .white.opacity(0), location: 1.00)
                ]), center: .center)
                .frame(width: d, height: d)
                .rotationEffect(.degrees(spin ? -360 : 0))
                .animation(.linear(duration: ShineStyle.sweepSeconds).repeatForever(autoreverses: false),
                           value: spin)
                .opacity(colors.isEmpty ? 0 : 1)
                .animation(.easeInOut(duration: ShineStyle.fadeSeconds), value: colors.isEmpty)
            }
            .frame(width: size.width, height: size.height)
            .mask { RingMask(size: size) }       // only the border shows
        }
        .onAppear { spin = true }
        .task(id: songID) {
            var palette: [Color] = []
            if let artwork {
                palette = await Task.detached(priority: .utility) {
                    CoverPalette.colors(from: artwork)
                }.value
            }
            guard !Task.isCancelled, palette != colors else { return }   // same colors: nothing to fade
            colors = palette
            version += 1
        }
    }
}

/// The shape of the glow: a border ring in three layers. Drawn once and kept as a picture,
/// so only the colors behind it move.
private struct RingMask: View {
    let size: CGSize

    var body: some View {
        ZStack {
            Rectangle().strokeBorder(Color.white, lineWidth: ShineStyle.softWidth)
                .blur(radius: ShineStyle.softBlur)
                .opacity(ShineStyle.softOpacity)
            Rectangle().strokeBorder(Color.white, lineWidth: ShineStyle.midWidth)
                .blur(radius: ShineStyle.midBlur)
                .opacity(ShineStyle.midOpacity)
        }
        .frame(width: size.width, height: size.height)
        .drawingGroup()
    }
}
