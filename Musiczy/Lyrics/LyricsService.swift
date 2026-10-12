import Foundation

/// One line of lyrics and the second it should appear.
struct LyricLine: Equatable {
    let time: Double
    let text: String
}

/// Looks up time-synced lyrics on LRCLIB (free, no account or API key).
enum LyricsService {
    /// Tries LRCLIB's exact match first, then falls back to a search.
    static func fetch(title: String, artist: String, duration: Double,
                      completion: @escaping ([LyricLine]) -> Void) {
        get(title: title, artist: artist, duration: duration) { lines in
            if !lines.isEmpty {
                completion(lines)
            } else {
                search(title: title, artist: artist, duration: duration, completion: completion)
            }
        }
    }

    private static func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        // LRCLIB asks clients to identify themselves.
        request.setValue("Musiczy/1.0 (https://github.com/izzyflestado/Musiczy)",
                         forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        return request
    }

    /// Exact lookup: /api/get (needs the title, artist and, ideally, the length to match).
    private static func get(title: String, artist: String, duration: Double,
                            completion: @escaping ([LyricLine]) -> Void) {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var items = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        if duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        components.queryItems = items

        guard let url = components.url else {
            completion([])
            return
        }

        URLSession.shared.dataTask(with: makeRequest(url)) { data, _, _ in
            var lines: [LyricLine] = []
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let synced = json["syncedLyrics"] as? String {
                lines = parse(synced)
            }
            DispatchQueue.main.async { completion(lines) }
        }.resume()
    }

    /// Fallback: /api/search, taking the first synced result whose length is within 3 seconds.
    private static func search(title: String, artist: String, duration: Double,
                               completion: @escaping ([LyricLine]) -> Void) {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]

        guard let url = components.url else {
            completion([])
            return
        }

        URLSession.shared.dataTask(with: makeRequest(url)) { data, _, _ in
            var lines: [LyricLine] = []
            if let data,
               let results = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for item in results {
                    guard let synced = item["syncedLyrics"] as? String, !synced.isEmpty else { continue }
                    if duration > 0, let d = item["duration"] as? Double, abs(d - duration) > 3 { continue }
                    let parsed = parse(synced)
                    if !parsed.isEmpty {
                        lines = parsed
                        break
                    }
                }
            }
            DispatchQueue.main.async { completion(lines) }
        }.resume()
    }

    /// Rejects junk: too few real lines, mostly empty lines, or the same line over and over.
    static func usable(_ lines: [LyricLine]) -> [LyricLine]? {
        let texts = lines.map { $0.text }.filter { !$0.isEmpty }
        guard texts.count >= 3,
              Double(texts.count) / Double(lines.count) > 0.5,
              Set(texts).count >= 3,
              Double(Set(texts).count) / Double(texts.count) > 0.25 else { return nil }

        // Real synced lyrics have mostly different times spread over the song.
        let times = lines.map { $0.time }
        guard Double(Set(times).count) / Double(lines.count) > 0.8,
              (times.max() ?? 0) - (times.min() ?? 0) > 20 else { return nil }
        return lines
    }

    static func parse(_ lrc: String) -> [LyricLine] {
        var lrc = lrc.replacingOccurrences(of: "\\r", with: "")
                     .replacingOccurrences(of: "\\n", with: "\n")

        // Some files use a plain "n" as the line separator, right before the next timestamp.
        let brokenBreak = #"n(?=\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\])"#
        if lrc.range(of: brokenBreak, options: .regularExpression) != nil {
            lrc = lrc.replacingOccurrences(of: brokenBreak, with: "\n", options: .regularExpression)
            // The last line has the same stray "n" at the very end.
            let trimmed = lrc.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix("n") { lrc = String(trimmed.dropLast()) }
        }
        let stampPattern = #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#
        let stamp = try! NSRegularExpression(pattern: stampPattern)
        var result: [LyricLine] = []

        for raw in lrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = stamp.matches(in: raw, range: NSRange(location: 0, length: ns.length))

            // Only the timestamps at the very start of the line count as the line's time.
            var leading: [NSTextCheckingResult] = []
            var cursor = 0
            for m in matches {
                if m.range.location == cursor {
                    leading.append(m)
                    cursor = m.range.location + m.range.length
                } else { break }
            }
            guard !leading.isEmpty else { continue }

            // Everything after them is the text. Remove inline [mm:ss.xx] and <mm:ss.xx> word tags.
            var text = ns.substring(from: cursor)
            text = text.replacingOccurrences(of: stampPattern, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#,
                                             with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            for m in leading {
                let mins = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let secs = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound {
                    frac = Double("0." + ns.substring(with: m.range(at: 3))) ?? 0
                }
                result.append(LyricLine(time: mins * 60 + secs + frac, text: text))
            }
        }

        // Drop the same line repeated back to back within 1.5 seconds.
        var cleaned: [LyricLine] = []
        for line in result.sorted(by: { $0.time < $1.time }) {
            if let last = cleaned.last, last.text == line.text, line.time - last.time < 1.5 { continue }
            cleaned.append(line)
        }
        return usable(splitLong(cleaned)) ?? []
    }
    // ===== MAX CHARACTERS PER LINE: change this number =====
    static let maxChars = 38
    // =======================================================

    /// Splits lines that are too long into shorter ones, sharing out the time.
    static func splitLong(_ lines: [LyricLine]) -> [LyricLine] {
        var out: [LyricLine] = []
        for (i, line) in lines.enumerated() {
            let pieces = chunk(line.text)
            if pieces.count <= 1 {
                out.append(line)
                continue
            }
            let end = i + 1 < lines.count ? lines[i + 1].time : line.time + 4 * Double(pieces.count)
            let span = max(end - line.time, 0.5)
            let totalChars = Double(pieces.reduce(0) { $0 + $1.count })
            var t = line.time
            for piece in pieces {
                out.append(LyricLine(time: t, text: piece))
                t += span * Double(piece.count) / totalChars
            }
        }
        return out
    }

    /// Cuts one long text into pieces of similar length, preferring to break after punctuation.
    static func chunk(_ text: String) -> [String] {
        guard text.count > maxChars else { return [text] }

        let words = text.split(separator: " ").map(String.init)
        let count = Int((Double(text.count) / Double(maxChars)).rounded(.up))
        let target = text.count / count

        var pieces: [String] = []
        var current = ""
        for word in words {
            current = current.isEmpty ? word : current + " " + word

            let endsSentence = [",", ".", "!", "?", ";"].contains { word.hasSuffix($0) }
            let longEnough = current.count >= target
            let niceBreak = endsSentence && current.count >= Int(Double(target) * 0.6)

            if pieces.count < count - 1 && (longEnough || niceBreak) {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
