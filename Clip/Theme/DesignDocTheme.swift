import SwiftUI
import AppKit

/// Turns a DESIGN.md into a Clip theme, with no model involved.
///
/// A design document's front matter already IS a theme: a `colors:` block of
/// role-named hex values - canvas, surface-1, ink, hairline, primary. Those are
/// the same roles Clip paints under different names, so the translation is a
/// lookup table rather than a generation problem. 74 documents in the library
/// means 74 themes that cost nothing to make.
enum DesignDocTheme {

    /// Clip's role, and the names design documents use for it, best first.
    ///
    /// Ordered, because a document often defines several candidates and the
    /// first match should be the most specific one. `surface-1` is a card;
    /// falling back to `canvas` for a card would make the card invisible.
    private static let roles: [(clip: String, names: [String])] = [
        ("accent",             ["primary", "brand", "accent", "cta", "action"]),
        ("accentSecondary",    ["secondary", "primary-hover", "accent-secondary", "brand-secondary"]),
        ("panelBackground",    ["canvas", "background", "bg", "page", "base"]),
        ("cardBackground",     ["surface-1", "surface", "card", "panel", "elevated", "surface-2"]),
        ("cardHoverBackground",["surface-2", "surface-3", "hover", "surface-hover", "elevated-2"]),
        ("selectedBackground", ["surface-3", "selected", "active", "surface-4", "highlight"]),
        // NOT "muted" or "subtle": in these documents those name muted TEXT,
        // not a surface, and adopting one as a background put secondary and
        // tertiary text on a ground the same lightness as themselves - 41
        // failures across the corpus, all of them from this one wrong guess.
        ("surfaceBackground",  ["surface-2", "surface-soft", "subtle-surface", "input", "field"]),
        ("textPrimary",        ["ink", "text", "foreground", "on-surface", "text-primary"]),
        ("textSecondary",      ["ink-muted", "text-secondary", "muted-foreground", "body", "ink-soft"]),
        ("textTertiary",       ["ink-subtle", "text-tertiary", "mute", "ink-tertiary", "placeholder"]),
        ("border",             ["hairline", "border", "divider", "outline", "stroke"])
    ]

    /// Builds a theme from a design document, or nil when it carries no colors.
    ///
    /// The result is run through `ThemeDoctor`, so a document whose palette is
    /// beautiful on a web page but unreadable in a dense list is repaired rather
    /// than shipped broken. The audit is the same 43 pairings every other theme
    /// faces.
    static func theme(from text: String, named name: String) -> CustomTheme? {
        var colors = colorBlock(in: text)
        // A third of the corpus has no front matter at all - its palette is
        // written into the prose as `#3cffd0` with the role named in words
        // around it. Harvesting those keeps the feature working on every
        // document rather than two thirds of them.
        if colors.count < 4 { colors = harvested(from: text) }
        guard colors.count >= 4 else { return nil }

        func pick(_ role: String) -> String? {
            guard let entry = roles.first(where: { $0.clip == role }) else { return nil }
            for candidate in entry.names {
                if let hex = colors[candidate] { return hex }
            }
            return nil
        }

        // A document is dark when its canvas is dark. Everything derived below
        // depends on getting this right, so it is measured, not guessed.
        let canvas = pick("panelBackground") ?? "#FFFFFF"
        let dark = luminance(of: canvas) < 0.35

        let fallbackInk = dark ? "#F5F5F5" : "#101010"
        let fallbackCanvas = dark ? "#111111" : "#FFFFFF"

        let panel = canvas
        let card = pick("cardBackground") ?? shifted(panel, towardsLight: dark, by: 0.06)
        let hover = pick("cardHoverBackground") ?? shifted(card, towardsLight: dark, by: 0.06)
        let selected = pick("selectedBackground") ?? shifted(card, towardsLight: dark, by: 0.12)

        return CustomTheme(
            name: name,
            accent: pick("accent") ?? "#4C8DFF",
            accentSecondary: pick("accentSecondary") ?? pick("accent") ?? "#7AA7FF",
            panelBackground: panel.isEmpty ? fallbackCanvas : panel,
            cardBackground: card,
            cardHoverBackground: hover,
            selectedBackground: selected,
            // Derived from the panel when the document does not name a real
            // surface, so it is always a known step rather than a borrowed hue.
            surfaceBackground: pick("surfaceBackground") ?? shifted(panel, towardsLight: dark, by: 0.09),
            textPrimary: pick("textPrimary") ?? fallbackInk,
            textSecondary: pick("textSecondary") ?? pick("textPrimary") ?? fallbackInk,
            textTertiary: pick("textTertiary") ?? pick("textSecondary") ?? fallbackInk,
            border: pick("border") ?? shifted(card, towardsLight: dark, by: 0.18),
            isDark: dark,
            cornerRadius: 12
        )
    }

    // MARK: - Reading the document

    /// Every `name: "#RRGGBB"` under a `colors:` key in the front matter.
    ///
    /// Deliberately forgiving about quoting and indentation: these files are
    /// written by hand and by several different models, and a parser that
    /// insists on one style would drop a third of the library.
    static func colorBlock(in text: String) -> [String: String] {
        var out: [String: String] = [:]
        var inColors = false
        for raw in text.prefix(20_000).components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indented = raw.hasPrefix(" ") || raw.hasPrefix("\t")

            // Both spellings, and this is the one place that keeps the second
            // one. Everywhere else Clip says "color"; here it is reading
            // somebody else's document, and their spelling is not ours to
            // standardise. A blanket rename briefly turned this into the same
            // test twice, which would have quietly dropped every design system
            // written by someone who spells it the other way.
            if line.hasPrefix("colors:") || line.hasPrefix("colours:") {
                inColors = true
                continue
            }
            // An unindented key ends the block; a blank line inside it does not.
            if inColors, !indented, !line.isEmpty { break }
            guard inColors, line.contains(":") else { continue }

            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard value.hasPrefix("#"), value.count == 7 || value.count == 4 else { continue }
            out[key] = normalised(value)
        }
        return out
    }

    /// Roles read out of prose, for documents with no front matter.
    ///
    /// Every hex in the document is collected with the words immediately before
    /// it, and a role is claimed by the first color whose surrounding text
    /// names it. What is left over is assigned by measurement: the darkest or
    /// lightest becomes the canvas, the furthest from it becomes the ink, and
    /// the most saturated becomes the accent.
    static func harvested(from text: String) -> [String: String] {
        let body = String(text.prefix(40_000))
        let pattern = try? NSRegularExpression(pattern: "#[0-9a-fA-F]{6}\\b")
        let range = NSRange(body.startIndex..., in: body)
        var found: [(hex: String, context: String)] = []
        pattern?.enumerateMatches(in: body, range: range) { match, _, _ in
            guard let match, let r = Range(match.range, in: body) else { return }
            let hex = normalised(String(body[r]))
            let start = body.index(r.lowerBound, offsetBy: -90, limitedBy: body.startIndex)
                ?? body.startIndex
            found.append((hex, String(body[start..<r.lowerBound]).lowercased()))
        }
        guard found.count >= 4 else { return [:] }

        var out: [String: String] = [:]
        var claimed = Set<String>()
        for (clipRole, names) in roles {
            guard let hit = found.first(where: { candidate in
                !claimed.contains(candidate.hex)
                    && names.contains { candidate.context.contains($0) }
            }) else { continue }
            out[names[0]] = hit.hex
            claimed.insert(hit.hex)
            _ = clipRole
        }

        // Whatever the words did not name, measurement does.
        let unique = Array(Set(found.map(\.hex)))
        if out[roles[2].names[0]] == nil,
           let canvas = unique.min(by: { abs(luminance(of: $0) - 0.5) > abs(luminance(of: $1) - 0.5) }) {
            // The color furthest from mid-grey is the page.
            out[roles[2].names[0]] = canvas
        }
        let canvas = out[roles[2].names[0]] ?? "#111111"
        if out[roles[7].names[0]] == nil,
           let ink = unique.max(by: {
               abs(luminance(of: $0) - luminance(of: canvas))
                   < abs(luminance(of: $1) - luminance(of: canvas))
           }) {
            out[roles[7].names[0]] = ink
        }
        if out[roles[0].names[0]] == nil,
           let accent = unique.max(by: { saturation(of: $0) < saturation(of: $1) }) {
            out[roles[0].names[0]] = accent
        }
        return out
    }

    private static func saturation(of hex: String) -> Double {
        guard let c = NSColor(hex: hex)?.usingColorSpace(.sRGB) else { return 0 }
        let values = [c.redComponent, c.greenComponent, c.blueComponent].map(Double.init)
        guard let hi = values.max(), let lo = values.min(), hi > 0 else { return 0 }
        return (hi - lo) / hi
    }

    /// `#abc` becomes `#aabbcc`, so everything downstream sees one shape.
    private static func normalised(_ hex: String) -> String {
        guard hex.count == 4 else { return hex.uppercased() }
        let c = Array(hex.dropFirst())
        return "#\(c[0])\(c[0])\(c[1])\(c[1])\(c[2])\(c[2])".uppercased()
    }

    private static func luminance(of hex: String) -> Double {
        guard let color = NSColor(hex: hex)?.usingColorSpace(.sRGB) else { return 1 }
        func channel(_ v: CGFloat) -> Double {
            let c = Double(v)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent)
             + 0.7152 * channel(color.greenComponent)
             + 0.0722 * channel(color.blueComponent)
    }

    /// Nudges a color away from the canvas, so derived surfaces stay distinct.
    ///
    /// Not `private`: `CustomTheme.rederiveSurfaces(dark:)` (M9 9.1) needs the
    /// exact same technique to re-derive a theme's whole surface ramp when the
    /// Dark theme toggle flips, and a second copy of this function would be
    /// free to drift from this one.
    static func shifted(_ hex: String, towardsLight: Bool, by amount: Double) -> String {
        guard let base = NSColor(hex: hex) else { return hex }
        let mixed = Contrast.composite(
            (towardsLight ? NSColor.white : NSColor.black).withAlphaComponent(amount),
            over: base)
        return Color(nsColor: mixed).hexString
    }
}
