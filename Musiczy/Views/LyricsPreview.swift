import SwiftUI

/// A small live picture of the lyrics settings: sample lines, split by "words per line"
/// and drawn at the chosen size. The bright line moves along, like it does in the player.
struct LyricsPreview: View {
    let words: Int
    let size: Double

    @State private var step = 0
    private let timer = Timer.publish(every: 0.7, on: .main, in: .common).autoconnect()

    // ===== PREVIEW BOX: change these numbers =====
    private let boxHeight: CGFloat = 170
    private let sidePadding: CGFloat = 16
    // =============================================

    var body: some View {
        let pieces = LyricsLayout.samplePieces(words: words, size: size)
        let current = pieces.isEmpty ? 0 : step % pieces.count

        GeometryReader { geo in
            let inner = max(geo.size.width - sidePadding * 2, 120)
            // The player's lyrics column, shrunk to fit this box. Text is shrunk by the same amount.
            let font = LyricsLayout.baseFontSize * CGFloat(size) * inner / LyricsLayout.panelWidth
            let row = font * LyricsLayout.rowRatio(words: words)

            VStack(spacing: 0) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { index, text in
                    let distance = abs(index - current)
                    Text(text.isEmpty ? "♪" : text)
                        .font(.system(size: font, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .frame(width: inner, height: row, alignment: .leading)
                        .opacity(distance == 0 ? 1 : (distance == 1 ? 0.55 : (distance == 2 ? 0.28 : 0)))
                        .scaleEffect(distance == 0 ? 1.0 : (distance == 1 ? 0.8 : 0.62), anchor: .leading)
                }
            }
            // Keep the bright line in the middle of the box.
            .offset(y: boxHeight / 2 - row / 2 - CGFloat(current) * row)
            .animation(current == 0 ? nil : Animation.spring(response: 0.5, dampingFraction: 0.9),
                       value: current)
            .frame(width: inner, height: boxHeight, alignment: .topLeading)
            .padding(.leading, sidePadding)
            .clipped()
        }
        .frame(height: boxHeight)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onReceive(timer) { _ in step += 1 }
    }
}
