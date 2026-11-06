import AppKit

extension SettingsKey {
    static let lyricsWords = "lyricsWords"
    static let lyricsSize = "lyricsSize"
}

/// Default and range of each lyrics slider. Change the numbers here.
enum LyricsDefault {
    static let words = 4                          // words per line
    static let maxWords = 8                       // the most words on one line that is still easy to read
    static let size: Double = 1.0                 // 1 = the normal lyric size
    static let sizeRange: ClosedRange<Double> = 0.6...1.4
}

/// Splits lyric lines by the lyrics settings (words per line and size).
enum LyricsLayout {
    /// Lyric font size at 100%. The player uses the same number.
    static let baseFontSize: CGFloat = 50

    /// The width one lyric line gets on this screen: the narrowest lyrics column (the split style).
    static var panelWidth: CGFloat {
        let screenWidth = NSScreen.main?.frame.width ?? 1440
        return max(screenWidth / 2 - 80, 300)
    }

    /// How wide a piece of text is when drawn in the lyrics font.
    private static func textWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: - Splitting

    /// Cuts one lyric line into pieces of at most `words` words. A piece is also never wider
    /// than the lyrics column, so no line ever has to wrap to a second row.
    static func pieces(of text: String, words: Int, size: Double) -> [String] {
        let all = text.split(separator: " ").map(String.init)
        guard all.count > 1 else { return [text] }

        let limit = max(words, 1)
        let font = baseFontSize * CGFloat(size)
        let room = panelWidth * 0.95        // a little spare room, so text never touches the edge

        // Pieces of nearly the same length: 9 words with a limit of 6 gives 5 + 4, not 6 + 3.
        let count = (all.count + limit - 1) / limit
        var groups: [[String]] = []
        var start = 0
        for i in 0..<count {
            let left = count - i
            let take = (all.count - start + left - 1) / left
            groups.append(Array(all[start..<(start + take)]))
            start += take
        }

        // Too wide for the column? Cut it in half until it fits.
        func fit(_ group: [String]) -> [[String]] {
            guard group.count > 1,
                  LyricsLayout.textWidth(group.joined(separator: " "), fontSize: font) > room
            else { return [group] }
            let middle = (group.count + 1) / 2
            return fit(Array(group[..<middle])) + fit(Array(group[middle...]))
        }

        return groups.flatMap(fit).map { $0.joined(separator: " ") }
    }

    /// Splits all lyric lines. The pieces of one line share that line's time by length.
    static func layout(_ lines: [LyricLine], words: Int, size: Double) -> [LyricLine] {
        var out: [LyricLine] = []
        out.reserveCapacity(lines.count)

        for (i, line) in lines.enumerated() {
            let parts = pieces(of: line.text, words: words, size: size)
            if parts.count <= 1 {
                out.append(line)
                continue
            }

            let nextTime = i + 1 < lines.count ? lines[i + 1].time : line.time + 4
            let totalChars = Double(max(parts.reduce(0) { $0 + $1.count }, 1))
            // A line is sung in a few seconds. Don't stretch its words over a long gap (a solo, say).
            let sung = max(2.0, totalChars * 0.09)
            let span = max(min(nextTime - line.time, sung), 0.5)

            var t = line.time
            for part in parts {
                out.append(LyricLine(time: t, text: part))
                t += span * Double(part.count) / totalChars
            }
        }
        return out
    }

    // MARK: - For the Settings window

    /// A sentence of average words, used to work out how many words fit on one line.
    private static let sample = "I never knew you were the someone waiting for me"

    /// How many words fit on one line at this size (never more than the slider's maximum).
    static func maxWordsThatFit(size: Double) -> Int {
        let font = baseFontSize * CGFloat(size)
        let count = sample.split(separator: " ").count
        let perWord = (textWidth(sample, fontSize: font) + textWidth(" ", fontSize: font)) / CGFloat(count)
        guard perWord > 0 else { return LyricsDefault.maxWords }
        let fit = Int((panelWidth * 0.95 / perWord).rounded(.down))
        return min(max(fit, 1), LyricsDefault.maxWords)
    }

    /// Sample lyrics for the preview, already split the way the player would split them.
    static func samplePieces(words: Int, size: Double) -> [String] {
        let lines = ["I never knew you were the someone waiting for me",
                     "Now I see the light that shines in your eyes",
                     "Hold me close and never let me go"]
        return lines.flatMap { pieces(of: $0, words: words, size: size) }
    }
}

