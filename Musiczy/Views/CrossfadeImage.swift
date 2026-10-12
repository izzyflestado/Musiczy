import SwiftUI
import AppKit

/// Shows an image. When the image changes, the new one fades in
/// over the old one, so nothing dips to black.
struct CrossfadeImage: View {
    let image: NSImage
    var duration: Double = 1.0

    @State private var old: NSImage? = nil
    @State private var fade: Double = 1

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let old {
                    Image(nsImage: old)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .opacity(fade)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onChange(of: image) { oldValue, _ in
            old = oldValue
            fade = 0
            withAnimation(.easeInOut(duration: duration)) {
                fade = 1
            }
        }
    }
}
