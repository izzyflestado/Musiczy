import SwiftUI

/// Shows text that fades the same way the main player does when the song changes:
/// the old text fades out (0.3 s), swaps while invisible, then the new text fades in.
struct FadeSwap<Content: View>: View {
    let value: String
    let content: (String) -> Content

    @State private var shown: String
    @State private var opacity: Double = 1
    @State private var token = 0          // so a quick second change cancels the first

    init(_ value: String, @ViewBuilder content: @escaping (String) -> Content) {
        self.value = value
        self.content = content
        _shown = State(initialValue: value)
    }

    var body: some View {
        content(shown)
            .opacity(opacity)
            .onChange(of: value) { _, new in
                token += 1
                let mine = token
                // Same timing as NowPlayingScreen: 0.3 out, swap, 0.4 pause, 0.5 in.
                withAnimation(.easeOut(duration: 0.3)) { opacity = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard mine == token else { return }
                    shown = new
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        guard mine == token else { return }
                        withAnimation(.easeIn(duration: 0.5)) { opacity = 1 }
                    }
                }
            }
    }
}
