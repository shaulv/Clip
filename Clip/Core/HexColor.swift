import Foundation

/// Recognising a copied color, with or without the hash.
///
/// `#3CFFD0` was a color and `3CFFD0` was a wall of text, which is backwards:
/// the hash is punctuation. Design tools, spreadsheet cells, config files and
/// half the CSS in the world hand you the digits on their own, and those are
/// the copies most worth previewing as a swatch.
///
/// **The care is in what a bare hex string can also be.** `123456` is a six
/// digit number. `deface`, `accede` and `defaced` are words. A git short SHA is
/// exactly this shape and gets copied constantly. So the bare form is accepted
/// only under conditions that make a false positive rare and harmless:
///
/// - the *whole* clipping is that one token, never a hex found inside prose;
/// - it is 3, 6 or 8 digits, the lengths a color actually comes in;
/// - it contains at least one letter, so `123456` stays a number.
///
/// The remaining collisions are real and accepted: `abcdef` and `facade` become
/// swatches. Both are still perfectly pasteable text - the only cost is a
/// colored card instead of a grey one - and a "Move to" is one click. The
/// reverse mistake, refusing every color anybody copied without a hash, is the
/// one people notice fifty times a day.
///
/// One place, because there were two: the capture path recognised hashed
/// colors and the drop path recognised none at all, so the same string became
/// two different things depending on how it arrived.
enum HexColor {

    /// The canonical `#RRGGBB` form of a copied color, or nil.
    static func normalised(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 9 else { return nil }

        let hashed = text.hasPrefix("#")
        let digits = hashed ? String(text.dropFirst()) : text
        guard [3, 6, 8].contains(digits.count) else { return nil }
        guard digits.allSatisfy(\.isHexDigit) else { return nil }

        // Without the hash there is nothing to say this is a color rather than
        // a number, so require the one signal a color has and a number cannot.
        if !hashed, !digits.contains(where: { $0.isLetter }) { return nil }

        return "#" + digits.uppercased()
    }

    static func matches(_ raw: String) -> Bool { normalised(raw) != nil }
}
