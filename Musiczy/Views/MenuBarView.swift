import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject private var viewModel = NowPlayingViewModel.shared
    @State private var dragFraction: Double? = nil
    @State private var panelRef = PanelWindowRef()

    // ===== SIZES: change these to resize the panel =====
    private let panelWidth: CGFloat = 340
    private let coverSize: CGFloat = 96
    private let cornerRadius: CGFloat = 14
    private let padding: CGFloat = 18
    // ===================================================

    private var barWidth: CGFloat { panelWidth - padding * 2 }

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                cover
                info
            }
            progress
            controls
            footer
        }
        .padding(padding)
        .frame(width: panelWidth)
        .background(background)
        .background(PanelWindowReader(ref: panelRef))
        .preferredColorScheme(.dark)
    }
    
    /// Remembers the window that holds the menu bar panel, so we can close it.
    final class PanelWindowRef {
        weak var window: NSWindow?
    }

    private struct PanelWindowReader: NSViewRepresentable {
        let ref: PanelWindowRef

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            DispatchQueue.main.async { ref.window = view.window }
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            DispatchQueue.main.async { ref.window = nsView.window }
        }
    }

    // MARK: - Background (blurred copy of the cover, same look as the main window)

    private var background: some View {
        ZStack {
            Color.black
            if let artwork = viewModel.song.artwork {
                CrossfadeImage(image: artwork)
                    .blur(radius: 60)
                    .saturation(1.6)
                    .brightness(0.05)
                    .scaleEffect(1.3)
            }
            Color.black.opacity(0.30)
        }
        .clipped()
    }

    // MARK: - Cover with glow (left side)

    private var cover: some View {
        ZStack {
            if let artwork = viewModel.song.artwork {
                // Glow: the same cover, enlarged and blurred, so it uses the cover's colors
                CrossfadeImage(image: artwork)
                    .frame(width: coverSize, height: coverSize)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .scaleEffect(1.15)
                    .blur(radius: 22)
                    .saturation(1.6)
                    .opacity(0.85)

                // The cover itself
                CrossfadeImage(image: artwork)
                    .frame(width: coverSize, height: coverSize)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.white.opacity(0.12))
                    .frame(width: coverSize, height: coverSize)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 34))
                            .foregroundStyle(.white.opacity(0.5))
                    }
            }
        }
        .frame(width: coverSize, height: coverSize)
    }

    // MARK: - Title, artist, album (right of the cover)

    private var info: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(viewModel.isAd ? "Made by Izzy :)" : viewModel.song.title)
                .font(.system(size: 17, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)

            if !viewModel.isAd {
                Text(viewModel.song.artist)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)

                if !viewModel.song.album.isEmpty {
                    Text(viewModel.song.album)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Progress bar (click or drag to seek)

    private var progress: some View {
        let raw = dragFraction ?? viewModel.progress
        let shown = raw.isFinite ? min(max(raw, 0), 1) : 0

        return VStack(spacing: 6) {
            HStack {
                Text(formatTime(dragFraction.map { $0 * viewModel.duration } ?? viewModel.position))
                Spacer()
                Text(formatTime(viewModel.duration))
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))

            SeekBar(fraction: shown, height: 5)
                .frame(width: barWidth, height: 5)
                .animation(dragFraction == nil && viewModel.animateProgress ? .linear(duration: 1) : nil,
                           value: shown)
                .frame(height: 22)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragFraction = min(max(value.location.x / barWidth, 0), 1)
                        }
                        .onEnded { value in
                            let f = min(max(value.location.x / barWidth, 0), 1)
                            viewModel.seek(toFraction: f)
                            dragFraction = nil
                        }
                )
        }
        .frame(width: barWidth)
    }

    // MARK: - Playback controls

    private var controls: some View {
        HStack(spacing: 36) {
            Button { viewModel.previousTrack() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 20))
            }
            Button { viewModel.playPause() } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28))
                    .frame(width: 32)
            }
            Button { viewModel.nextTrack() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 20))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.92))
    }

    // MARK: - Settings and Quit

    private var footer: some View {
        HStack(spacing: 10) {
            footerButton("Settings", icon: "gearshape.fill") {
                closePanel()                               // close the panel first
                SettingsWindowController.shared.show()     // then open Settings
            }
            footerButton("Quit", icon: "power") { NSApp.terminate(nil) }
        }
    }

    /// Closes the menu bar panel. It opens again the next time you click the icon.
    private func closePanel() {
        (panelRef.window ?? NSApp.keyWindow)?.close()
    }

    private func footerButton(_ title: String, icon: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.white.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
