import AppKit
import SwiftUI

/// Picks a few vivid, different colors from a cover, for glows on a black background.
enum CoverPalette {

    /// Up to `count` colors, most common first. A grey cover gives white and grey.
    static func colors(from image: NSImage, count: Int = 4) -> [Color] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }

        // Shrink the cover to 48 x 48 so this takes a millisecond or two.
        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return [] }

        // Sort the pixels into 12 hue groups. Vivid, bright pixels count more than dull ones.
        struct Bucket { var weight = 0.0, h = 0.0, s = 0.0, v = 0.0 }
        let groups = 12
        var buckets = [Bucket](repeating: Bucket(), count: groups)

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let (h, s, v) = hsv(Double(pixels[i]) / 255,
                                Double(pixels[i + 1]) / 255,
                                Double(pixels[i + 2]) / 255)
            guard s > 0.25, v > 0.2 else { continue }          // skip greys and near-black
            let w = s * v
            let index = min(Int(h * Double(groups)), groups - 1)
            buckets[index].weight += w
            buckets[index].h += h * w
            buckets[index].s += s * w
            buckets[index].v += v * w
        }

        let ranked = buckets.enumerated()
            .filter { $0.element.weight > 0 }
            .sorted { $0.element.weight > $1.element.weight }
        let total = ranked.reduce(0.0) { $0 + $1.element.weight }
        guard total > 0 else { return [Color(white: 0.95), Color(white: 0.55)] }   // black and white cover

        var picked: [(h: Double, s: Double, v: Double)] = []
        var used: [Int] = []
        for (index, bucket) in ranked {
            guard picked.count < count, bucket.weight / total > 0.03 else { continue }
            // Skip a hue that sits right next to one we already took.
            let gap = used.map { min(abs($0 - index), groups - abs($0 - index)) }.min() ?? groups
            guard gap > 1 else { continue }
            used.append(index)
            picked.append((bucket.h / bucket.weight, bucket.s / bucket.weight, bucket.v / bucket.weight))
        }

        // Only one color family (a mostly blue cover, say): add a neighbour so the border still has movement.
        if picked.count == 1 {
            let p = picked[0]
            picked.append(((p.h + 0.08).truncatingRemainder(dividingBy: 1), p.s * 0.8, p.v))
        }

        // Boost them a little: glows look best vivid and bright on black.
        return picked.map {
            Color(hue: $0.h, saturation: min(1, max($0.s, 0.7)), brightness: min(1, max($0.v, 0.85)))
        }
    }
    
    /// The cover's average color, made very dark, for a plain background.
    /// `level` is how bright the result is: 0 = black, 1 = full brightness.
    static func darkAverage(from image: NSImage, level: Double = 0.16) -> Color {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .black }

        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return .black }

        var r = 0.0, g = 0.0, b = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            r += Double(pixels[i])
            g += Double(pixels[i + 1])
            b += Double(pixels[i + 2])
        }
        let n = Double(side * side) * 255
        let (h, s, _) = hsv(r / n, g / n, b / n)
        // Averages come out dull, so give the color a little more saturation before darkening it.
        return Color(hue: h, saturation: min(1, s * 1.3), brightness: level)
    }

    private static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        guard d > 0 else { return (0, 0, mx) }
        var h: Double
        if mx == r      { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == g { h = (b - r) / d + 2 }
        else            { h = (r - g) / d + 4 }
        h /= 6
        if h < 0 { h += 1 }
        return (h, d / mx, mx)
    }
}
