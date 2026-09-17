import SwiftUI

/// The app's type scale, named by the role each size plays rather than by its
/// number - the same reasoning `Spacing` applies to gaps, applied here to text.
///
/// A theme controls colour, radius and translucency; it does not reshape type,
/// so this scale sits BESIDE `AppTheme` rather than inside it, exactly the way
/// `Spacing` already does. That boundary is deliberate, not an oversight: 9.2
/// of the M9 plan ("make sure all elements ... written in the theme ... so the
/// AI has full control") is about colour and shape, which a generated theme
/// should be free to redraw - not about typography, which is Clip's own voice
/// and stays constant no matter which theme is active.
///
/// Written for the M9 token-coverage gate (`run_m9_theme_builder`, W2), which
/// fails on a bare `.font(.system(size: N))` anywhere outside this file: every
/// size that literal used to spell out at its call site is named here once,
/// by what it is FOR, so a reviewer reads "this is a swatch's role text" at
/// the call site instead of reverse-engineering an 11 from context.
enum Typography {
    /// A sheet's own name: the theme-name field at the top of the builder.
    static let heading = Font.system(size: 15, weight: .semibold)
    /// A dialog's own title, or a label that headlines its own row/section.
    static let subheading = Font.system(size: 13, weight: .semibold)
    /// Regular reading text: a swatch's colour name, a control's own label.
    static let body = Font.system(size: 12)
    /// The same size, for a value that must align digit-for-digit (a typed hex).
    static let bodyMono = Font.system(size: 12, design: .monospaced)
    /// Body reading size, emphasised - a notice's own message headline,
    /// where the row also carries a smaller kind badge beside it.
    static let bodyStrong = Font.system(size: 12, weight: .semibold)
    /// Reading size for rendered markdown - notes and skills are read at
    /// length, not scanned, so this sits a half-step above `body`.
    static let markdownBody = Font.system(size: 12.5)
    /// A secondary field label, one step down from `body`.
    static let label = Font.system(size: 11)
    /// A label that also headlines its row, without going as loud as `subheading`.
    static let labelStrong = Font.system(size: 11, weight: .semibold)
    /// An icon-led action's own text ("+ Add color", "Paste a color").
    static let labelMedium = Font.system(size: 11, weight: .medium)
    /// Inline code or a fenced block, at reading size.
    static let labelMono = Font.system(size: 11, design: .monospaced)
    /// A hint, a role description, an "Auto" badge - explanatory text beneath
    /// or beside a control rather than the control's own label.
    static let caption = Font.system(size: 10)
    /// A hex readout beside a swatch, or any short value that must align.
    /// A caption that has to carry weight - a button's own word, not prose.
    static let captionStrong = Font.system(size: 10, weight: .semibold)
    static let captionMono = Font.system(size: 10, design: .monospaced)
    /// The same size and face, emphasised - a log row's own level tag
    /// (`[error]`) set apart from the timestamp and message beside it.
    static let captionMonoStrong = Font.system(size: 10, weight: .semibold, design: .monospaced)
    /// The smallest real text the app draws: a status pill like "Edited".
    static let micro = Font.system(size: 9, weight: .bold, design: .rounded)

    /// A button's own label - `PrimaryButton`/`SecondaryButton`/`GhostButton`
    /// (M11, `Views/Components/`), regular size. One step up from `body`
    /// and semibold, so the one CTA on a screen reads as an action rather
    /// than as a sentence.
    static let buttonLabel = Font.system(size: 12, weight: .semibold)
    /// The same role, small size - a button inline with a compact row.
    static let buttonLabelSmall = Font.system(size: 11, weight: .semibold)

    /// Rendered markdown's own three heading levels (`# `, `## `, `### `).
    static let markdownH1 = Font.system(size: 21, weight: .bold)
    /// A glyph shown as a specimen rather than as an icon in a row - the
    /// contrast matrix's own preview tile, where the point is to see the
    /// colour on a shape big enough to judge.
    static let specimenGlyph = Font.system(size: 22)
    static let markdownH2 = Font.system(size: 17, weight: .bold)
    static let markdownH3 = Font.system(size: 14, weight: .bold)
}
