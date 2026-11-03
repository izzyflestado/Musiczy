import SwiftUI
import AppKit

// MARK: - Look (change the numbers here)

enum ShineStyle {
    static let turnSeconds: Double = 16      // one lap of the cover colors around the border
    static let sweepSeconds: Double = 9      // one lap of the white highlight (runs the other way)
    static let fadeSeconds: Double = 1.2     // color change between songs
    static let sweepOpacity: Double = 1.0
    static let sweepWidth: CGFloat = 40      // NEW: thickness of the highlight band along the edge
    static let sweepBlur: CGFloat = 10       // NEW: lower = sharper highlight
    static let sweepLength: Double = 0.2     // how much of the border the highlight covers: 0.1 = short, 0.3 = long

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
                // The cover's colors, turning slowly, as a soft glow
                ZStack {
                    if !colors.isEmpty {
                        AngularGradient(gradient: Gradient(colors: colors + [colors[0]]), center: .center)
                            .saturation(1.3)
                            .id(version)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: ShineStyle.fadeSeconds), value: version)
                .frame(width: d, height: d)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: ShineStyle.turnSeconds).repeatForever(autoreverses: false),
                           value: spin)
                .frame(width: size.width, height: size.height)
                .mask { RingMask(size: size) }

                // White highlight running the other way, with its own tighter ring so it stays sharper
                AngularGradient(gradient: Gradient(stops: [
                    .init(color: .white.opacity(0), location: 0.00),
                    .init(color: .white.opacity(0), location: 1 - ShineStyle.sweepLength),
                    .init(color: .white.opacity(ShineStyle.sweepOpacity), location: 1 - ShineStyle.sweepLength / 2),
                    .init(color: .white.opacity(0), location: 1.00)
                ]), center: .center)
                .frame(width: d, height: d)
                .rotationEffect(.degrees(spin ? -360 : 0))
                .animation(.linear(duration: ShineStyle.sweepSeconds).repeatForever(autoreverses: false),
                           value: spin)
                .frame(width: size.width, height: size.height)
                .mask { SweepMask(size: size) }
                .opacity(colors.isEmpty ? 0 : 1)
                .animation(.easeInOut(duration: ShineStyle.fadeSeconds), value: colors.isEmpty)
            }
            .frame(width: size.width, height: size.height)
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

/// A tighter ring just for the white highlight, so it stays sharper than the soft glow.
private struct SweepMask: View {
    let size: CGSize

    var body: some View {
        Rectangle().strokeBorder(Color.white, lineWidth: ShineStyle.sweepWidth)
            .blur(radius: ShineStyle.sweepBlur)
            .frame(width: size.width, height: size.height)
            .drawingGroup()
    }
}
