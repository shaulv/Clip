import SwiftUI

/// The theme a window's own chrome should draw with, when that is not the
/// theme the clipboard panel is using.
///
/// Set once, at the root of the Settings window, and read by the shared
/// controls. Every one of `PrimaryButton`, `SecondaryButton`, `GhostButton`
/// and `ClipLink` used to fall back to `ThemeManager.theme` - the PANEL's
/// theme - unless a call site remembered to pass `theme:`. That is invisible
/// while the two agree and wrong the moment they do not: with Settings pinned
/// to Light while the Mac was dark, every button and every shortcut chip in
/// Settings stayed near-black on a light page (Shortcuts measured 6.6% of the
/// pane, 07/09).
///
/// Fixed here rather than at the call sites on purpose. There are dozens of
/// them, a missed one looks exactly like this bug, and a control added
/// tomorrow would have to remember too. One decision at the root covers all
/// of them, including the ones not written yet.
private struct ClipChromeThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme? = nil
}

extension EnvironmentValues {
    var clipChromeTheme: AppTheme? {
        get { self[ClipChromeThemeKey.self] }
        set { self[ClipChromeThemeKey.self] = newValue }
    }
}


/// A small reusable "type chip" showing a symbol glyph + optional label,
/// colored by the currently active theme's accent.
struct TypeGlyph: View {
    let kind: ItemKind
    let size: CGFloat
    let accent: Color
    /// What the chip is drawn on, so its label can be resolved against the wash
    /// rather than against a card it may not be sitting on.
    var background: Color = .clear

    private var chip: (fill: Color, foreground: Color) {
        guard background != .clear else { return (accent.opacity(0.16), accent) }
        return AppTheme.chipColors(accent, on: background)
    }

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(chip.foreground)
            .frame(width: size, height: size)
            .background(chip.fill, in: RoundedRectangle(cornerRadius: size * 0.28))
    }
}

/// Short kind badge (TXT / IMG / URL ...).
struct KindBadge: View {
    let kind: ItemKind
    let accent: Color
    var corner: CGFloat = 5
    var background: Color = .clear

    private var chip: (fill: Color, foreground: Color) {
        guard background != .clear else { return (accent.opacity(0.16), accent) }
        return AppTheme.chipColors(accent, on: background)
    }

    var body: some View {
        Text(kind.badge)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(chip.foreground)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(chip.fill, in: RoundedRectangle(cornerRadius: corner))
    }
}

// MARK: - Hex colors

extension NSColor {
    /// Parses "#RGB", "#RRGGBB" or "#RRGGBBAA".
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }

        if s.count == 3 {
            // Expand shorthand: "abc" -> "aabbcc".
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }

        let r, g, b, a: CGFloat
        if s.count == 6 {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        } else {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
