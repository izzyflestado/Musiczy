import SwiftUI
import AppKit
import Combine

// MARK: - The picker (goes inside Settings)

struct DisplayStylePicker: View {
    @ObservedObject private var style = DisplayStyleStore.shared
    @State private var artwork: NSImage? = NowPlayingViewModel.shared.song.artwork

    private let thumbWidth: CGFloat = 128   // thumbnail size: change this number

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Art", [.artNormal, .artFull, .artFullBar])
            row("Lyrics", [.lyricsNormal, .lyricsFull, .lyricsFullBar])
        }
        .frame(maxWidth: .infinity)
        .onReceive(NowPlayingViewModel.shared.$song) { artwork = $0.artwork }
    }

    private func row(_ title: String, _ states: [DisplayState]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(width: 46, alignment: .leading)
                .padding(.top, 4)
            ForEach(states) { state in
                tile(state)
            }
        }
    }

    private func tile(_ state: DisplayState) -> some View {
        let selected = style.current == state
        return Button {
            style.select(state)
        } label: {
            VStack(spacing: 6) {
                StylePreview(state: state, artwork: artwork, width: thumbWidth)
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15),
                                          lineWidth: selected ? 3 : 1)
                    }
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.white, Color.accentColor)
                                .padding(5)
                        }
                    }
                Text(state.title)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(state.group): \(state.title)")
    }
}

// MARK: - One thumbnail, drawn in code (no image files)

struct StylePreview: View {
    let state: DisplayState
    let artwork: NSImage?
    var width: CGFloat = 128

    private var isFull: Bool { state.artStyle >= 1 }
    private var hasBar: Bool { state.artStyle == 2 }

    var body: some View {
        let h = width / 1.6
        let s = width / 160      // everything below is drawn for a 160 x 100 picture and scaled

        ZStack {
            background(w: width, h: h, s: s)
            content(w: width, h: h, s: s)
        }
        .frame(width: width, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: Background (blurred cover, or the sharp full-screen cover)

    @ViewBuilder
    private func background(w: CGFloat, h: CGFloat, s: CGFloat) -> some View {
        ZStack {
            Color.black
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: w, height: h)
                    .clipped()
                    .blur(radius: isFull ? 0 : 9 * s)
                    .saturation(isFull ? 1.0 : 1.6)
                    .scaleEffect(isFull ? 1.1 : 1.3)
            } else {
                LinearGradient(colors: [.purple.opacity(0.6), .blue.opacity(0.5)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            Color.black.opacity(isFull ? 0.40 : 0.30)
            if hasBar {
                LinearGradient(colors: [.clear, .black.opacity(0.65)],
                               startPoint: .center, endPoint: .bottom)
            }
        }
        .frame(width: w, height: h)
        .clipped()
    }

    // MARK: Layout of each of the six styles

    @ViewBuilder
    private func content(w: CGFloat, h: CGFloat, s: CGFloat) -> some View {
        switch state {
        case .artNormal:
            centeredColumn(s: s, showArt: true)

        case .artFull:
            // The cover fades out in this style but keeps its space, so the text sits lower.
            centeredColumn(s: s, showArt: false)

        case .artFullBar:
            bottomBar(w: w, h: h, s: s)

        case .lyricsNormal:
            HStack(spacing: 0) {
                centeredColumn(s: s * 0.85, showArt: true)
                    .frame(width: w / 2, height: h)
                lyricList(s: s, rows: 5, centered: false)
                    .padding(.leading, 6 * s)
                    .frame(width: w / 2, height: h, alignment: .leading)
            }

        case .lyricsFull:
            VStack(spacing: 5 * s) {
                lyricList(s: s, rows: 3, centered: true)
                textBlock(s: s)
                progress(width: 62 * s, s: s)
                controls(s: s)
            }

        case .lyricsFullBar:
            ZStack {
                lyricList(s: s * 1.25, rows: 3, centered: true)
                    .offset(y: -12 * s)
                bottomBar(w: w, h: h, s: s)
            }
        }
    }

    // MARK: Building blocks

    private func centeredColumn(s: CGFloat, showArt: Bool) -> some View {
        VStack(spacing: 3.5 * s) {
            if showArt {
                artSquare(s: s)
            } else {
                Color.clear.frame(width: 38 * s, height: 38 * s)
            }
            textBlock(s: s)
            progress(width: 62 * s, s: s)
            controls(s: s)
        }
    }

    private func artSquare(s: CGFloat) -> some View {
        Group {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.25)
            }
        }
        .frame(width: 38 * s, height: 38 * s)
        .clipShape(RoundedRectangle(cornerRadius: 6 * s, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 4 * s, y: 2 * s)
    }

    private func bottomBar(w: CGFloat, h: CGFloat, s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3 * s) {
            textBlock(s: s, alignment: .leading)
            progress(width: w - 24 * s, s: s)
                .padding(.top, 1 * s)
            controls(s: s)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12 * s)
        .padding(.bottom, 7 * s)
        .frame(width: w, height: h, alignment: .bottom)
    }

    /// Title, artist and album drawn as three bars.
    private func textBlock(s: CGFloat, alignment: HorizontalAlignment = .center) -> some View {
        VStack(alignment: alignment, spacing: 2.5 * s) {
            bar(58 * s, 4.5 * s, 0.95)
            bar(38 * s, 3 * s, 0.7)
            bar(28 * s, 2.5 * s, 0.5)
        }
    }

    /// Lyric lines drawn as bars. The middle one is the current line.
    private func lyricList(s: CGFloat, rows: Int, centered: Bool) -> some View {
        let widths: [CGFloat] = rows == 5 ? [30, 38, 50, 38, 30] : [38, 56, 38]
        let heights: [CGFloat] = rows == 5 ? [3, 4, 6, 4, 3] : [4, 6, 4]
        let opacities: [Double] = rows == 5 ? [0.28, 0.55, 1, 0.55, 0.28] : [0.55, 1, 0.55]
        return VStack(alignment: centered ? .center : .leading, spacing: 6 * s) {
            ForEach(0..<rows, id: \.self) { i in
                bar(widths[i] * s, heights[i] * s, opacities[i])
            }
        }
    }

    private func bar(_ width: CGFloat, _ height: CGFloat, _ opacity: Double) -> some View {
        Capsule()
            .fill(Color.white.opacity(opacity))
            .frame(width: width, height: height)
    }

    private func progress(width: CGFloat, s: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.25))
            Capsule().fill(Color.white.opacity(0.9)).frame(width: width * 0.4)
        }
        .frame(width: width, height: 2.2 * s)
    }

    private func controls(s: CGFloat) -> some View {
        HStack(spacing: 6 * s) {
            Image(systemName: "backward.fill").font(.system(size: 5 * s))
            Image(systemName: "play.fill").font(.system(size: 8 * s))
            Image(systemName: "forward.fill").font(.system(size: 5 * s))
        }
        .foregroundStyle(Color.white.opacity(0.9))
    }
}
