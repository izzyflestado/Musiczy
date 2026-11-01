import SwiftUI
import AppKit
import Combine

/// Makes the lock-screen glow as a finished, already-blurred picture.
/// A live blur can fail to redraw after the display sleeps and wakes on the lock screen,
/// which leaves an unblurred box around the cover. A ready-made picture can't do that.
final class GlowStore: ObservableObject {
    static let shared = GlowStore()

    @Published private(set) var image: NSImage?
    @Published private(set) var revision = 0

    /// Room around the cover so the blur can fade out completely (grows with the blur radius).
    static var padding: CGFloat { ceil(LockStyle.compactGlowBlur * 3) }
    /// Side of the whole picture, including that room.
    static var side: CGFloat { LockStyle.coverSize + padding * 2 }

    private var cancellable: AnyCancellable?
    private var lastID: UUID?

    /// Call once at launch. Re-makes the glow whenever the song (or its cover) changes.
    func start() {
        guard cancellable == nil else { return }
        cancellable = LockSongGate.shared.$song
            .receive(on: DispatchQueue.main)
            .sink { [weak self] song in self?.update(song) }
    }

    private func update(_ song: Song) {
        guard let art = song.artwork else {
            image = nil
            lastID = nil
            return
        }
        guard song.id != lastID else { return }
        lastID = song.id
        image = render(art)
        revision += 1 
    }

    private func render(_ art: NSImage) -> NSImage? {
        MainActor.assumeIsolated { () -> NSImage? in
            let side = GlowStore.side
            let renderer = ImageRenderer(content: GlowCanvas(image: art, side: side))
            renderer.scale = 2
            guard let cg = renderer.cgImage else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
        }
    }
}

/// The same glow as before (rounded cover, enlarged, blurred, saturated), drawn once.
private struct GlowCanvas: View {
    let image: NSImage
    let side: CGFloat

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: LockStyle.coverSize, height: LockStyle.coverSize)
            .clipShape(RoundedRectangle(cornerRadius: LockStyle.coverSize * LockStyle.coverRounding,
                                        style: .continuous))
            .scaleEffect(LockStyle.compactGlowScale)
            .blur(radius: LockStyle.compactGlowBlur)
            .saturation(LockStyle.glowSaturation)
            .frame(width: side, height: side)
    }
}
