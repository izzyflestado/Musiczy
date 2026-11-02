import AVFoundation
import AppKit

/// What we learn about an audio file: title, artist, album and cover.
struct AdFileTags {
    var title = ""
    var artist = ""
    var album = ""
    var artwork: Data?
}

/// Reads the tags and cover art of an audio file (used for the ad music).
enum AdFileMetadata {
    static func read(_ url: URL) async -> AdFileTags {
        var tags = AdFileTags()

        // FLAC: macOS doesn't reliably give FLAC tags, so read them ourselves.
        if url.pathExtension.lowercased() == "flac" {
            tags = FlacTags.read(url)
        }

        // MP3, M4A, WAV and so on, plus anything still missing: ask macOS.
        if tags.title.isEmpty || tags.artist.isEmpty || tags.album.isEmpty || tags.artwork == nil {
            let av = await avTags(url)
            if tags.title.isEmpty { tags.title = av.title }
            if tags.artist.isEmpty { tags.artist = av.artist }
            if tags.album.isEmpty { tags.album = av.album }
            if tags.artwork == nil { tags.artwork = av.artwork }
        }

        // Still no cover: look for a picture in the same folder.
        if tags.artwork == nil { tags.artwork = folderCover(next: url) }

        return tags
    }

    private static func avTags(_ url: URL) async -> AdFileTags {
        var out = AdFileTags()
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return out }

        func text(_ id: AVMetadataIdentifier) async -> String {
            guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first,
                  let value = try? await item.load(.stringValue) else { return "" }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        out.title = await text(.commonIdentifierTitle)
        out.artist = await text(.commonIdentifierArtist)
        out.album = await text(.commonIdentifierAlbumName)

        if let art = AVMetadataItem.metadataItems(from: items,
                                                  filteredByIdentifier: .commonIdentifierArtwork).first,
           let data = try? await art.load(.dataValue), !data.isEmpty {
            out.artwork = data
        }
        return out
    }

    private static func folderCover(next url: URL) -> Data? {
        let folder = url.deletingLastPathComponent()
        for name in ["cover", "folder", "front", "album", "albumart", "artwork"] {
            for ext in ["jpg", "jpeg", "png"] {
                let file = folder.appendingPathComponent("\(name).\(ext)")
                if let data = try? Data(contentsOf: file), !data.isEmpty { return data }
            }
        }
        return nil
    }
}

// MARK: - FLAC tags and embedded cover

private enum FlacTags {
    static func read(_ url: URL) -> AdFileTags {
        var tags = AdFileTags()
        guard let fh = try? FileHandle(forReadingFrom: url) else { return tags }
        defer { try? fh.close() }

        // Some FLAC files start with an ID3 header. Skip it if present.
        var offset: UInt64 = 0
        guard let head = try? fh.read(upToCount: 10), head.count == 10 else { return tags }
        if head.prefix(3) == Data("ID3".utf8) {
            let b = [UInt8](head)
            let s1 = Int(b[6] & 0x7f) << 21
            let s2 = Int(b[7] & 0x7f) << 14
            let s3 = Int(b[8] & 0x7f) << 7
            let s4 = Int(b[9] & 0x7f)
            offset = UInt64(10 + s1 + s2 + s3 + s4)
        }

        _ = try? fh.seek(toOffset: offset)
        guard let magic = try? fh.read(upToCount: 4), magic == Data("fLaC".utf8) else { return tags }
        offset += 4

        // Walk the metadata blocks: 4 = text tags, 6 = pictures.
        var coverKind = -1
        while true {
            _ = try? fh.seek(toOffset: offset)
            guard let h = try? fh.read(upToCount: 4), h.count == 4 else { break }
            let hb = [UInt8](h)
            let isLast = (hb[0] & 0x80) != 0
            let type = hb[0] & 0x7f
            let length = (Int(hb[1]) << 16) | (Int(hb[2]) << 8) | Int(hb[3])

            if type == 4 || type == 6 {
                let limit = type == 4 ? 8_000_000 : 40_000_000
                if length < limit, let block = try? fh.read(upToCount: length), block.count == length {
                    let bytes = [UInt8](block)
                    if type == 4 {
                        comments(bytes, into: &tags)
                    } else if let pic = picture(bytes),
                              tags.artwork == nil || (pic.kind == 3 && coverKind != 3) {
                        tags.artwork = pic.data      // kind 3 = front cover, which wins over other pictures
                        coverKind = pic.kind
                    }
                }
            }
            if isLast { break }
            offset += UInt64(4 + length)
        }
        return tags
    }

    /// Vorbis comments: numbers are little-endian.
    private static func comments(_ b: [UInt8], into tags: inout AdFileTags) {
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

        guard let vendor = readInt(), vendor >= 0, i + vendor <= b.count else { return }
        i += vendor
        guard let count = readInt() else { return }

        for _ in 0..<min(count, 500) {
            guard let len = readInt(), len >= 0, i + len <= b.count else { break }
            let entry = String(decoding: b[i..<(i + len)], as: UTF8.self)
            i += len
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = entry[..<eq].uppercased()
            let value = String(entry[entry.index(after: eq)...])
            switch key {
            case "TITLE":  if tags.title.isEmpty { tags.title = value }
            case "ARTIST": if tags.artist.isEmpty { tags.artist = value }
            case "ALBUM":  if tags.album.isEmpty { tags.album = value }
            default: break
            }
        }
    }

    /// FLAC picture block: numbers are big-endian.
    private static func picture(_ b: [UInt8]) -> (kind: Int, data: Data)? {
        var i = 0

        func readInt() -> Int? {
            guard i + 4 <= b.count else { return nil }
            let b0 = Int(b[i]) << 24
            let b1 = Int(b[i + 1]) << 16
            let b2 = Int(b[i + 2]) << 8
            let b3 = Int(b[i + 3])
            i += 4
            return b0 | b1 | b2 | b3
        }

        guard let kind = readInt(),
              let mimeLength = readInt(), mimeLength >= 0, i + mimeLength <= b.count else { return nil }
        i += mimeLength
        guard let descLength = readInt(), descLength >= 0, i + descLength <= b.count else { return nil }
        i += descLength
        i += 16                                   // width, height, depth, colors
        guard let dataLength = readInt(), dataLength > 0, i + dataLength <= b.count else { return nil }
        return (kind, Data(b[i..<(i + dataLength)]))
    }
}
