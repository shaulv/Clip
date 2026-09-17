import SwiftUI
import AppKit

/// Moves a color until it is readable, without changing what color it is.
///
/// Themes are authored as a handful of colors, but the interface needs many
/// more: the same accent has to work as a mark on a card, on the panel, and on
/// the selected row, and those three backgrounds are nothing like each other. A
/// single authored value cannot satisfy all three, which is exactly how the
/// selected row ended up painting a 1.37:1 accent on Graphite's selection blue.
///
/// So the ratio-bearing colors are derived rather than authored: hue and
/// saturation are kept, and only lightness moves, by the smallest amount that
/// reaches the target. The result still reads as the theme's color - a tuned
/// coral is a lighter or darker coral, never a different hue.
enum ColorTuner {

    /// Lightness steps are searched, not solved: contrast is not monotonic in a
    /// way worth inverting analytically. 48 steps landed within half a percent
    /// of the boundary, which was enough for AA but left the AAA bar (7:1, a
    /// much narrower passing band on a saturated hue) missing by 0.01 on real
    /// presets - Sage's "Accent as text on selection" measured 6.99. 192 steps
    /// still runs in the same frame budget and closes that gap.
    private static let steps = 192

    /// `hex` adjusted so it reaches `ratio` against `background`.
    ///
    /// Returns the *nearest* passing lightness, so a color that already passes
    /// comes back untouched and one that fails moves as little as possible.
    /// When no lightness reaches the target - a mid-grey background leaves a
    /// saturated hue nowhere to go - the best available is returned rather than
    /// an arbitrary black or white, and the audit reports the shortfall instead
    /// of the theme silently claiming a color it does not have.
    static func adjust(_ hex: String, on background: String, to ratio: Double) -> String {
        let key = Key(hex: hex, background: background, ratio: ratio)
        if let cached = cache.withLock({ $0[key] }) { return cached }

        let result = compute(hex, on: background, to: ratio)
        cache.withLock { $0[key] = result }
        return result
    }

    private static func compute(_ hex: String, on background: String, to ratio: Double) -> String {
        guard let color = NSColor(hex: hex), let base = NSColor(hex: background) else { return hex }
        // The foreground is graded as it renders: a color carrying opacity is
        // flattened onto its background first, or every alpha-bearing token
        // would be scored as if it were solid.
        let flattened = Contrast.composite(color, over: base)
        if Contrast.ratio(flattened, base) >= ratio { return hex }

        var hsl = HSL(flattened)
        let origin = hsl.l
        var best = (lightness: origin, ratio: Contrast.ratio(flattened, base))

        // Tuning happens on the *flattened* color, which is already opaque.
        // Re-applying the original alpha here was a real bug: a 72% white tuned
        // towards white stayed 72% white over the same background, so it could
        // never reach the ratio and reported a failure the theme did not have.
        for step in 0...steps {
            let candidate = Double(step) / Double(steps)
            hsl.l = candidate
            let solid = hsl.color()
            let r = Contrast.ratio(solid, base)
            // Among passing candidates prefer the one closest to the original,
            // so "make it readable" never means "make it white".
            if r >= ratio {
                if best.ratio < ratio || abs(candidate - origin) < abs(best.lightness - origin) {
                    best = (candidate, r)
                }
            } else if best.ratio < ratio, r > best.ratio {
                best = (candidate, r)
            }
        }
        hsl.l = best.lightness
        return hsl.color().hex
    }

    /// `hex` adjusted so it reaches `ratio` against *every* background it is
    /// drawn on.
    ///
    /// One background is not the real problem. Secondary text appears on the
    /// card, on the hover state, on the surface and on the panel, and a value
    /// tuned against only the first can fail on the third. Satisfying the whole
    /// set at once is the difference between a theme that passes an audit and
    /// one that is readable everywhere it is used.
    static func adjust(_ hex: String, on backgrounds: [String], to ratio: Double) -> String {
        guard let color = NSColor(hex: hex), !backgrounds.isEmpty else { return hex }
        let bases = backgrounds.compactMap { NSColor(hex: $0) }
        guard !bases.isEmpty else { return hex }

        func worst(_ candidate: NSColor) -> Double {
            bases.map { Contrast.ratio(Contrast.composite(candidate, over: $0), $0) }.min() ?? 0
        }

        let flattened = Contrast.composite(color, over: bases[0])
        if worst(flattened) >= ratio { return hex }

        var hsl = HSL(flattened)
        let origin = hsl.l
        var best: (lightness: Double, ratio: Double) = (origin, worst(flattened))
        for step in 0...steps {
            let candidate = Double(step) / Double(steps)
            hsl.l = candidate
            let r = worst(hsl.color())
            if r >= ratio {
                if best.ratio < ratio || abs(candidate - origin) < abs(best.lightness - origin) {
                    best = (candidate, r)
                }
            } else if best.ratio < ratio, r > best.ratio {
                best = (candidate, r)
            }
        }
        hsl.l = best.lightness
        return hsl.color().hex
    }

    // MARK: - Cache
    //
    // Every card asks for its type tint on every render. Without this the bisect
    // above would run tens of thousands of times a second while scrolling.

    private struct Key: Hashable { let hex: String; let background: String; let ratio: Double }
    private static let cache = Mutex<[Key: String]>([:])

    /// Clears memoised colors. Only the tests need this; the key already
    /// carries everything an answer depends on.
    static func resetCache() { cache.withLock { $0.removeAll() } }
}

/// Minimal lock so the tuner is safe to call from any renderer.
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

/// Hue/saturation/lightness, so only brightness moves when a color is tuned.
struct HSL {
    var h: Double, s: Double, l: Double

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Double(c.redComponent), g = Double(c.greenComponent), b = Double(c.blueComponent)
        let maxV = max(r, g, b), minV = min(r, g, b)
        let delta = maxV - minV
        l = (maxV + minV) / 2
        if delta == 0 { h = 0; s = 0; return }
        s = delta / (1 - abs(2 * l - 1))
        switch maxV {
        case r: h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
        case g: h = 60 * (((b - r) / delta) + 2)
        default: h = 60 * (((r - g) / delta) + 4)
        }
        if h < 0 { h += 360 }
    }

    func color(alpha: CGFloat = 1) -> NSColor {
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<60:   (r, g, b) = (c, x, 0)
        case ..<120:  (r, g, b) = (x, c, 0)
        case ..<180:  (r, g, b) = (0, c, x)
        case ..<240:  (r, g, b) = (0, x, c)
        case ..<300:  (r, g, b) = (x, 0, c)
        default:      (r, g, b) = (c, 0, x)
        }
        return NSColor(srgbRed: CGFloat(r + m), green: CGFloat(g + m),
                       blue: CGFloat(b + m), alpha: alpha)
    }
}

extension NSColor {
    /// `#RRGGBB`, alpha dropped: this is the *flattened* color, and callers
    /// composite before asking for it.
    var hex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}
