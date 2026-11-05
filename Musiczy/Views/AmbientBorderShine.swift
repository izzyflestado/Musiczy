import SwiftUI
import AppKit

// MARK: - Look (change the numbers here)

enum ShineStyle {
    // Colored glow
    static let turnSeconds: Double = 16      // one lap of the cover colors around the border
    static let fadeSeconds: Double = 1.2     // color change between songs
    static let softWidth: CGFloat = 90
    static let softBlur: CGFloat = 70
    static let softOpacity: Double = 0.75
    static let midWidth: CGFloat = 24
    static let midBlur: CGFloat = 16
    static let midOpacity: Double = 1.0

    // White highlight
    static let sweepSeconds: Double = 10     // time for one lap around the whole border (bigger = slower)
    static let sweepOpacity: Double = 1.0    // strength at the middle of the highlight
    static let sweepLength: Double = 0.20    // fraction of the border it covers
    static let sweepFalloff: Double = 2      // 1 = even along the length, 2 = brighter middle, 3 = sharp peak
    static let sweepWidth: CGFloat = 40      // how far it reaches in from the screen edge
    static let sweepBlur: CGFloat = 10       // softness of its inner edge and ends
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

                // White highlight (Core Animation, so it doesn't skip)
                BorderStreak()
                    .frame(width: size.width, height: size.height)
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

