import AppKit
import SwiftUI

/// The colors in a copied image, found by counting rather than by a model.
///
/// A screenshot of a site, a poster, a photograph of a room - all of them are
/// palettes somebody already chose. Extracting them costs nothing: the image is
/// already on this Mac, and k-means over a downsampled copy is arithmetic.
/// Vision models are the expensive way to answer a question pixels answer for
/// free.
enum ImagePalette {

    /// Up to `count` representative colors, most-used first.
    ///
    /// The image is downsampled hard before anything else happens. Palette
    /// extraction does not need resolution, and a 4K screenshot at full size is
    /// eight million points of arithmetic for an answer that five thousand gives
    /// just as well.
    static func colors(from image: NSImage, count: Int = 5) -> [Color] {
        guard let pixels = sample(image), pixels.count > count else { return [] }

        // k-means, seeded by spreading the initial centres across the sample
        // rather than at random: a random seed makes the same image produce a
        // different palette each time, which reads as a bug.
        var centres: [SIMD3<Double>] = stride(from: 0, to: pixels.count,
                                              by: max(1, pixels.count / count))
            .prefix(count)
            .map { pixels[$0] }

        for _ in 0..<12 {
            var sums = Array(repeating: SIMD3<Double>(0, 0, 0), count: centres.count)
            var counts = Array(repeating: 0, count: centres.count)
            for pixel in pixels {
                var best = 0
                var bestDistance = Double.greatestFiniteMagnitude
                for (i, centre) in centres.enumerated() {
                    let d = pixel - centre
                    let distance = (d * d).sum()
                    if distance < bestDistance { bestDistance = distance; best = i }
                }
                sums[best] += pixel
                counts[best] += 1
            }
            for i in centres.indices where counts[i] > 0 {
                centres[i] = sums[i] / Double(counts[i])
            }
            // A centre nobody claimed is noise; leaving it in returns a color
            // the image does not contain.
            centres = zip(centres, counts).filter { $0.1 > 0 }.map(\.0)
            if centres.isEmpty { return [] }
        }

        // Ordered by how much of the image they account for, so the first
        // color is the one the image actually looks like.
        var weights = Array(repeating: 0, count: centres.count)
        for pixel in pixels {
            var best = 0
            var bestDistance = Double.greatestFiniteMagnitude
            for (i, centre) in centres.enumerated() {
                let d = pixel - centre
                let distance = (d * d).sum()
                if distance < bestDistance { bestDistance = distance; best = i }
            }
            weights[best] += 1
        }
        return zip(centres, weights)
            .sorted { $0.1 > $1.1 }
            .map { Color(nsColor: NSColor(srgbRed: CGFloat($0.0.x), green: CGFloat($0.0.y),
                                          blue: CGFloat($0.0.z), alpha: 1)) }
    }

    /// A small grid of sRGB samples, alpha and near-duplicates discarded.
    ///
    /// Draws the source `NSImage` straight into the small sampling grid,
    /// rather than first materialising it at full resolution via
    /// `tiffRepresentation` the way this used to. A 24-megapixel photo pasted
    /// in used to mean decoding and holding roughly 190MB just to average it
    /// straight back down to 4096 samples a moment later - harmless for a
    /// small screenshot, a real stall-and-spike risk for a large one.
    /// `NSImage` already knows how to downsample its own backing
    /// representation while drawing, so a huge image now costs the same as a
    /// small one.
    private static func sample(_ image: NSImage) -> [SIMD3<Double>]? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }

        let side = 64
        guard let scaled = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                  from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        var out: [SIMD3<Double>] = []
        out.reserveCapacity(side * side)
        for x in 0..<side {
            for y in 0..<side {
                guard let color = scaled.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.5 else { continue }
                out.append(SIMD3(Double(color.redComponent),
                                 Double(color.greenComponent),
                                 Double(color.blueComponent)))
            }
        }
        return out.isEmpty ? nil : out
    }
}
