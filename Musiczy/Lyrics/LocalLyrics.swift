import Foundation

/// Looks for lyrics stored on your Mac next to or inside the audio file.
/// Everything is read-only. Runs on a background thread.
enum LocalLyrics {

    // MARK: - Finding the file (Spotlight, via the built-in mdfind tool)
    
    static func sidecarOnly(_ urls: [URL]) -> [LyricLine]? {
        for url in urls {
            let file = url.deletingPathExtension().appendingPathExtension("lrc")
            guard let text = (try? String(contentsOf: file, encoding: .utf8))
                    ?? (try? String(contentsOf: file, encoding: .isoLatin1)) else { continue }
            let lines = LyricsService.parse(text)
            if !lines.isEmpty { return lines }
        }
        return nil
    }

    static func embeddedOnly(_ urls: [URL], artist: String) -> [LyricLine]? {
        for url in urls where url.pathExtension.lowercased() == "flac" {
            if let lines = flacLyrics(url, artist: artist) { return lines }
        }
        return nil
    }

    static func candidateFiles(title: String, artist: String) -> [URL] {
        let safe = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        guard !safe.isEmpty else { return [] }

        let query = "kMDItemContentTypeTree == \"public.audio\" && (kMDItemTitle == \"\(safe)\"cd || kMDItemFSName == \"*\(safe)*\"cd)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = [query]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let paths = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init)
        let urls = paths.prefix(30).map { URL(fileURLWithPath: $0) }

        // Files whose path contains the artist name go first.
        let a = artist.lowercased()
        guard !a.isEmpty else { return Array(urls) }
        let matching = urls.filter { $0.path.lowercased().contains(a) }
        let others = urls.filter { !$0.path.lowercased().contains(a) }
        return matching + others
    }

    // MARK: - FLAC embedded lyrics

    private static func flacLyrics(_ url: URL, artist: String) -> [LyricLine]? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        // Some FLAC files start with an ID3 header. Skip it if present.
        var offset: UInt64 = 0
        guard let head = try? fh.read(upToCount: 10), head.count == 10 else { return nil }
        if head.prefix(3) == Data("ID3".utf8) {
            let b = [UInt8](head)
            let s1 = Int(b[6] & 0x7f) << 21
            let s2 = Int(b[7] & 0x7f) << 14
            let s3 = Int(b[8] & 0x7f) << 7
            let s4 = Int(b[9] & 0x7f)
            offset = UInt64(10 + s1 + s2 + s3 + s4)
        }

        _ = try? fh.seek(toOffset: offset)
        guard let magic = try? fh.read(upToCount: 4), magic == Data("fLaC".utf8) else { return nil }
        offset += 4

        // Walk the metadata blocks until we hit the comment block (type 4).
        while true {
            _ = try? fh.seek(toOffset: offset)
            guard let h = try? fh.read(upToCount: 4), h.count == 4 else { return nil }
            let hb = [UInt8](h)
            let isLast = (hb[0] & 0x80) != 0
            let type = hb[0] & 0x7f
            let length = (Int(hb[1]) << 16) | (Int(hb[2]) << 8) | Int(hb[3])

            if type == 4 {
                guard length < 8_000_000,
                      let block = try? fh.read(upToCount: length),
                      block.count == length else { return nil }
                return lyricsFromComments([UInt8](block), artist: artist)
            }
            if isLast { return nil }
            offset += UInt64(4 + length)
        }
    }

    private static func lyricsFromComments(_ b: [UInt8], artist: String) -> [LyricLine]? {
        var i = 0

        func readInt() -> Int? {
            guard i + 4 <= b.count else { return nil }
            let b0 = Int(b[i])
            let b1 = Int(b[i + 1]) << 8
            let b2 = Int(b[i + 2]) << 16
            let b3 = Int(b[i + 3]) << 24
            i += 4
            return b0 | b1 | b2 | b3
        }

        guard let vendorLength = readInt(), i + vendorLength <= b.count else { return nil }
        i += vendorLength
        guard let count = readInt() else { return nil }

        var tags: [String: String] = [:]
        for _ in 0..<min(count, 500) {
            guard let len = readInt(), len >= 0, i + len <= b.count else { break }
            let entry = String(decoding: b[i..<(i + len)], as: UTF8.self)
            i += len
            if let eq = entry.firstIndex(of: "=") {
                let key = entry[..<eq].uppercased()
                if tags[key] == nil { tags[key] = String(entry[entry.index(after: eq)...]) }
            }
        }

        // Make sure this is really the same artist (skips wrong files with the same title).
        if let tagArtist = tags["ARTIST"]?.lowercased(), !tagArtist.isEmpty, !artist.isEmpty {
            let a = artist.lowercased()
            if !(tagArtist.contains(a) || a.contains(tagArtist)) { return nil }
        }

        for key in ["SYNCEDLYRICS", "LYRICS"] {
            if let text = tags[key] {
                let lines = LyricsService.parse(text)
                if !lines.isEmpty { return lines }
            }
        }
        return nil
    }
}

// MARK: - Local first, then LRCLIB

extension LyricsService {
    /// Order: .lrc file next to the song, then LRCLIB, then lyrics embedded in a FLAC file.
    static func fetchLocalFirst(title: String, artist: String, duration: Double,
                                completion: @escaping ([LyricLine]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let files = LocalLyrics.candidateFiles(title: title, artist: artist)

            if let side = LocalLyrics.sidecarOnly(files) {
                DispatchQueue.main.async { completion(side) }
                return
            }

            LyricsService.fetch(title: title, artist: artist, duration: duration) { online in
                if !online.isEmpty { completion(online); return }
                DispatchQueue.global(qos: .utility).async {
                    let embedded = LocalLyrics.embeddedOnly(files, artist: artist) ?? []
                    DispatchQueue.main.async { completion(embedded) }
                }
            }
        }
    }
}
