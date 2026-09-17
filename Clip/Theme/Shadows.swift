import SwiftUI

/// Elevation, named by the role each shadow plays - the same reasoning
/// `Spacing` and `Typography` apply to gaps and type, applied here to lift.
///
/// Global rather than per-`AppTheme`: every shadow already in the app is
/// authored in the same colour (black, translucent) regardless of theme - what
/// a theme actually controls is what a surface looks like with nothing behind
/// it, not how far it appears to float above the next one. Written for the M9
/// token-coverage gate (`run_m9_theme_builder`, W2), which fails on a bare
/// `.shadow(radius: N)` outside this file.
enum Shadows {
    struct Spec { let radius: CGFloat; let y: CGFloat; let opacity: Double }

    /// A card resting one step above the surface behind it: the theme
    /// assistant strip, the mini-preview, the accessibility report.
    static let card = Spec(radius: 10, y: 4, opacity: 0.18)
    /// A sheet or popover, floating well above the window under it.
    static let overlay = Spec(radius: 24, y: 10, opacity: 0.4)
    /// A tooltip or transient hint - the lightest lift the app draws.
    static let tooltip = Spec(radius: 6, y: 2, opacity: 0.25)
}

extension View {
    /// Applies a `Shadows` role in one call, so a call site names the role it
    /// wants rather than repeating that role's three numbers.
    func elevation(_ spec: Shadows.Spec) -> some View {
        shadow(color: .black.opacity(spec.opacity), radius: spec.radius, y: spec.y)
    }
}
