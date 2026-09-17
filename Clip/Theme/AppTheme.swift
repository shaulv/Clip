import SwiftUI

/// How tightly items are packed in the gallery.
///
/// Density changes real information density, not just column count: the card
/// height, the number of preview lines and the type badge all follow from it.
enum GalleryDensity: String, Codable, CaseIterable, Identifiable {
    case compact, comfortable, spacious
    var id: String { rawValue }

    var columns: Int {
        switch self {
        case .compact:     return 4
        case .comfortable: return 3
        case .spacious:    return 2
        }
    }
    var spacing: CGFloat {
        switch self {
        case .compact:     return 8
        case .comfortable: return 12
        case .spacious:    return 16
        }
    }
    /// Fixed card height keeps the grid scannable at every density.
    var cardHeight: CGFloat {
        switch self {
        case .compact:     return 118
        case .comfortable: return 150
        case .spacious:    return 190
        }
    }
    /// How many lines of text a card shows before truncating.
    var previewLines: Int {
        switch self {
        case .compact:     return 3
        case .comfortable: return 5
        case .spacious:    return 7
        }
    }
    var showsBadge: Bool { self != .compact }

    var title: String {
        switch self {
        case .compact:     return "Compact"
        case .comfortable: return "Comfortable"
        case .spacious:    return "Spacious"
        }
    }
    var symbol: String {
        switch self {
        case .compact:     return "square.grid.3x3"
        case .comfortable: return "square.grid.2x2"
        case .spacious:    return "rectangle.grid.1x2"
        }
    }
}

/// A complete visual design — colors, corner radius, spacing and default layout.
/// This is the "theme that changes design, layout and more".
struct AppTheme: Identifiable, Hashable {
    var id: String
    var name: String
    var symbol: String
    var accent: Color
    var accentSecondary: Color
    var panelBackground: Color
    var cardBackground: Color
    var cardHoverBackground: Color
    var selectedBackground: Color
    var surfaceBackground: Color
    var textPrimary: Color
    var textSecondary: Color
    var textTertiary: Color
    var border: Color
    var cornerRadius: CGFloat
    var usesGradientHeader: Bool
    var defaultLayout: TabLayout
    var defaultDensity: GalleryDensity
    var isDark: Bool

    // MARK: - System appearance

    /// The other preset id to switch to when the OS is dark, if this theme
    /// follows the system rather than pinning one appearance. `nil` on both
    /// this and `systemLightID` means "pins one appearance" — the ordinary
    /// case, unchanged for every existing preset.
    ///
    /// This is the rule the model expresses rather than a view special-casing
    /// it: a theme either carries a light form and a dark form and is picked
    /// by the OS (`systemLightID` and `systemDarkID` both set, on both
    /// forms), or it is a fixed color set that ignores the OS entirely. There
    /// is no third state and no view has to know which one it is looking at —
    /// `ThemeManager` resolves it once, before any color is read.
    var systemLightID: String? = nil
    var systemDarkID: String? = nil

    /// Whether this entry is a light/dark FORM of a system-following theme,
    /// meant to be resolved into rather than chosen directly. Kept in
    /// `AppTheme.presets` (so it is still audited, and still resolvable by
    /// id) but left out of the picker grid, which shows only the umbrella
    /// entry the user actually selects.
    var hiddenFromPicker: Bool = false

    /// True when this theme declares both a light and a dark form.
    var followsSystemAppearance: Bool { systemLightID != nil && systemDarkID != nil }

    /// Picks the light or dark form by the OS, for a system-following theme.
    /// A theme that pins one appearance returns itself unchanged.
    @MainActor
    func resolvedForSystem(isDark systemIsDark: Bool) -> AppTheme {
        guard followsSystemAppearance,
              let lightID = systemLightID, let darkID = systemDarkID else { return self }
        return AppTheme.theme(for: systemIsDark ? darkID : lightID)
    }

    /// How much of the desktop shows through the panel, 0 being opaque.
    ///
    /// This is a theme value rather than a constant because it decides whether
    /// the theme's own colors govern what reaches the screen. At the 0.45-0.55
    /// it used to be fixed at, a bright desktop behind a dark theme lifted the
    /// panel far enough that white-on-panel fell under 2:1 - and the audit never
    /// saw it, because it graded the authored color instead of the rendered one.
    var translucency: Double = 0.12

    /// Optional pins for the derived roles below.
    ///
    /// Derivation is the default because it is what keeps a theme readable
    /// without anyone tending it. These exist for the case derivation cannot
    /// serve: a brand color that must appear exactly, or a type tint someone
    /// wants to choose themselves. `nil` means "work it out".
    var accentTextOverride: Color? = nil
    var selectionTextOverride: Color? = nil

    // MARK: Interaction, all optional

    /// One authored color the interaction states derive from.
    ///
    /// Hover, focus and selection are three meanings that were all drawn in
    /// `accent`, so a theme could not make keyboard focus louder than a pointer
    /// hover even though focus is the one that must never be missed. They share
    /// this by default - a theme that says nothing still reads as one system -
    /// and each can be pinned on its own below when it needs to differ.
    var interactionOverride: Color? = nil
    var hoverStrokeOverride: Color? = nil
    var selectionStrokeOverride: Color? = nil
    var focusRingOverride: Color? = nil
    var actionHoverFillOverride: Color? = nil
    var tabHoverFillOverride: Color? = nil

    /// The card's own row of hover-action icon buttons (copy, open in
    /// Finder, edit, pin, share/move, delete). See the three computed
    /// properties below for why this exists as its own token rather than
    /// reusing `cardBackground`'s or `selectedBackground`'s own text pairing.
    var cardActionFillOverride: Color? = nil
    var cardActionIconOverride: Color? = nil
    var cardActionDestructiveIconOverride: Color? = nil

    // MARK: Status, all optional

    /// Delete, and anything else that removes.
    ///
    /// This was `Color.red`, hard-coded, on every ground the app paints and
    /// graded by nothing. On a light theme it was the least readable thing on
    /// screen and no gate would ever have said so.
    var destructiveOverride: Color? = nil
    var successOverride: Color? = nil
    var warningOverride: Color? = nil
    /// Keyed by `ItemKind.rawValue`, so it survives coding without a custom key.
    var typeTintOverrides: [String: Color] = [:]

    // MARK: Buttons and links, all optional (M11 - one component set)
    //
    // The user's own words: "have a idle, hover, press, focus, selected (if
    // needed) ... make sure to add the colors by need to the theme builder ...
    // one main CTA (blue one), one sub button and one ghost button". Four
    // components, `Views/Components/`, each state a named token here rather
    // than a call-site literal or a dimmed copy of the idle colour - see
    // `controlDisabledFillOverride`'s own comment for why disabled is never
    // opacity.
    var buttonPrimaryFillOverride: Color? = nil
    var buttonPrimaryTextOverride: Color? = nil
    var buttonPrimaryHoverFillOverride: Color? = nil
    var buttonPrimaryPressedFillOverride: Color? = nil

    var buttonSecondaryFillOverride: Color? = nil
    var buttonSecondaryTextOverride: Color? = nil
    var buttonSecondaryBorderOverride: Color? = nil
    var buttonSecondaryHoverFillOverride: Color? = nil
    var buttonSecondaryPressedFillOverride: Color? = nil

    var buttonGhostTextOverride: Color? = nil
    var buttonGhostHoverFillOverride: Color? = nil
    var buttonGhostPressedFillOverride: Color? = nil

    var linkOverride: Color? = nil
    var linkHoverOverride: Color? = nil
    var linkPressedOverride: Color? = nil

    /// One disabled treatment, shared by every button kind and the link.
    ///
    /// "Opacity is never a state" (design-academy, ui-visual-design): dimming
    /// an enabled colour toward the ground multiplies its own contrast down
    /// with it, and four states dimmed to 0.4-0.6 measured between 1.68 and
    /// 2.47 against a 4.5 requirement in exactly this codebase's own
    /// discipline notes. Disabled is graded at `.decorative` (1.5) rather
    /// than `.body` deliberately - the control is not meant to be acted on,
    /// only recognised as present, and a fully-legible disabled label reads
    /// as clickable, which is the opposite of what disabled communicates.
    var controlDisabledFillOverride: Color? = nil
    var controlDisabledTextOverride: Color? = nil

    /// The derived colors, worked out once. See `ResolvedPalette`.
    ///
    /// Nil means "not prepared yet", and every derived property below falls
    /// back to computing its answer the slow way, so a theme that never passes
    /// through `prepared()` is still correct - only slower. Correctness does
    /// not depend on remembering to warm a cache.
    var palette: ResolvedPalette? = nil

    /// A copy carrying its resolved palette. Called once, where the theme is set.
    func prepared() -> AppTheme {
        var copy = self
        copy.palette = nil                 // never resolve against a stale cache
        copy.palette = ResolvedPalette(copy)
        return copy
    }

    // MARK: - Interaction, resolved

    /// The color the interaction states are built from.
    var interaction: Color { palette?.interaction ?? interactionOverride ?? accent }

    /// Ring around a hovered row or action.
    var hoverStroke: Color {
        if let ready = palette?.hoverStroke { return ready }
        return hoverStrokeOverride ?? Self.readable(interaction,
                                             onAll: [cardBackground, cardHoverBackground],
                                             ratio: ThemeRules.Level.indicator.ratio)
    }

    /// Ring around selected controls: selected card or row, active tab, active filter pill, and selected buttons.
    ///
    /// Graded against the selected fill as well as the card. The selected fill
    /// is an accent tint, and the ring was the accent - so on Graphite the ring
    /// sat at 1.16 against the very thing it was supposed to outline. A ring you
    /// cannot see is not a selection.
    var selectionStroke: Color {
        if let ready = palette?.selectionStroke { return ready }
        return selectionStrokeOverride ?? Self.readable(interaction,
                                                 onAll: [cardBackground, selectedBackground],
                                                 ratio: ThemeRules.Level.indicator.ratio)
    }

    /// Keyboard focus. Falls back to the hover ring, so the two match unless a
    /// theme deliberately separates them.
    var focusRing: Color { palette?.focusRing ?? focusRingOverride ?? hoverStroke }

    /// The tinted disc behind a hovered action icon.
    var actionHoverFill: Color {
        palette?.actionHoverFill ?? actionHoverFillOverride ?? interaction.opacity(0.18)
    }

    /// The fill behind an unselected main tab under the pointer.
    var tabHoverFill: Color {
        palette?.tabHoverFill ?? tabHoverFillOverride ?? actionHoverFill
    }

    // MARK: - Card action buttons, resolved (copy/open-in-Finder/edit/pin/
    // share-move/delete - the row a selected or hovered card shows)
    //
    // These used to draw on `.ultraThinMaterial` - a system material with no
    // measurable color - carrying `textSecondary`/`textPrimary`, tuned only
    // ever against `cardBackground`/`cardHoverBackground`/`selectedBackground`,
    // never against the material itself. In a dark theme the material
    // happened to render dark enough that light text still read; in every
    // light theme it rendered close in tone to the icon color it carried,
    // which is exactly the "mid-grey button, darker-grey glyph" a light-mode
    // screenshot showed (user, 06/09). `cardActionFill` replaces the material
    // with a real, audited theme color, and the two icon colors below are
    // tuned against THAT fill rather than against the card behind it.

    /// The fill behind the row's own buttons: a state-layer wash over
    /// `selectedBackground` (Material's model, already used elsewhere in this
    /// file) - darkening, in both light and dark themes alike - then nudged
    /// until it is visibly its own chip against both grounds the row is ever
    /// shown on: a hovered card and a selected one. `IconButtonChrome` also
    /// draws a resting hairline edge around this specific chip (see its own
    /// `.cardAction` variant), so the 1.1:1 floor asked of the pairing below
    /// is the *color* half of "clearly distinguishable, or a visible edge" -
    /// the edge is the other half, always present, not conditional on tone.
    ///
    /// Darkening rather than lightening in a dark theme was the second
    /// attempt, not the first: lightening off `selectedBackground` (which is
    /// often a fairly saturated tint, by design, so a *selected* row reads
    /// clearly) pushed several dark presets' fill close enough to the
    /// crossover that `destructive`'s own 18%-opacity hover wash - itself
    /// already light in a dark theme - tipped the composited disc past the
    /// point where a same-polarity (light) delete glyph could still read.
    /// Darkening instead keeps real headroom under that wash in every
    /// preset, with no exceptions needed.
    var cardActionFill: Color {
        if let ready = palette?.cardActionFill { return ready }
        return cardActionFillOverride ?? Self.derivedCardActionFill(self)
    }

    /// `cardActionFill`'s own derivation, shared with `ResolvedPalette` so
    /// the two can never compute a different answer for the same theme.
    static func derivedCardActionFill(_ theme: AppTheme) -> Color {
        let base = Self.stateLayer(.black, over: theme.selectedBackground, opacity: 0.10)
        return Self.readable(base, onAll: [theme.cardHoverBackground, theme.selectedBackground],
                             ratio: ThemeRules.Level.chipFill.ratio)
    }

    /// `cardActionFill`, with `actionHoverFill`'s own accent-tinted wash
    /// composited on top - the exact stack `IconButtonChrome` paints while
    /// one NON-destructive button in the row is itself hovered or focused.
    var renderedCardActionHover: Color { Self.composited(actionHoverFill, over: cardActionFill) }

    /// `cardActionFill`, with `destructive`'s own 18%-opacity wash composited
    /// on top instead - the delete button draws its OWN tint on hover
    /// (`IconButtonChrome.highlightFill`'s `destructive` branch), not the
    /// shared accent tint every other button in the row uses. Measured
    /// separately because the two washes are different colors: an accent
    /// tint and `destructive`'s own hue rarely lighten (or darken) a fill by
    /// the same amount.
    var renderedCardActionDestructiveHover: Color {
        Self.composited(destructive.opacity(0.18), over: cardActionFill)
    }

    /// `overlay` painted onto `fill`, the color that actually reaches the
    /// screen - a plain static function (not a closure) so `ResolvedPalette`
    /// can call it inside its own initializer without a struct's "self used
    /// before being initialized" definite-initialization check tripping over
    /// an immediately-invoked closure that captures `self`.
    static func composited(_ overlay: Color, over fill: Color) -> Color {
        guard let fillNS = NSColor(hex: fill.hexString),
              let overlayNS = NSColor(hex: overlay.hexString)
        else { return fill }
        return Color(nsColor: Contrast.composite(overlayNS, over: fillNS))
    }

    /// The icon glyph on `cardActionFill` (copy, open in Finder, edit, pin,
    /// share/move) - tuned to clear 4.5:1 (WCAG AA, the icon/large-text tier
    /// every other icon-sized mark in this file is held to - see
    /// `ThemeRules.Level.largeText`) against both the resting fill and the
    /// hovered one, moving toward white in a dark theme and black in a light
    /// one - never the other way. A per-ground "whichever contrasts better"
    /// search (`readable(_:onAll:ratio:)`) can flip that direction case by
    /// case: tried on an early lightened fill, it nudged the icon to
    /// near-black against a fill lightened past the crossover, which draws a
    /// light-mode chip inside an otherwise all-dark theme. Keeping the
    /// theme's own polarity is what "dark themes keep looking as they do
    /// now" requires.
    var cardActionIcon: Color {
        if let ready = palette?.cardActionIcon { return ready }
        return cardActionIconOverride ?? Self.readableInPolarity(
            textPrimary, isDark: isDark,
            onAll: [cardActionFill, renderedCardActionHover],
            ratio: ThemeRules.Level.largeText.ratio)
    }

    /// The delete glyph on `cardActionFill` - `destructive`'s own hue, nudged
    /// again for this specific fill (and its own hover wash) rather than
    /// reused as-is: `destructive` is only guaranteed against
    /// `cardBackground`/`cardHoverBackground`/`selectedBackground`, not
    /// against this new, differently-toned chip.
    var cardActionDestructiveIcon: Color {
        if let ready = palette?.cardActionDestructiveIcon { return ready }
        return cardActionDestructiveIconOverride ?? Self.readableInPolarity(
            destructive, isDark: isDark,
            onAll: [cardActionFill, renderedCardActionDestructiveHover],
            ratio: ThemeRules.Level.largeText.ratio)
    }

    /// Nudges `color` toward white (dark theme) or black (light theme) -
    /// never the other way - until it clears `ratio` on every one of
    /// `grounds` at once. See `cardActionIcon`'s own comment for why a fixed
    /// direction matters here and `readable(_:onAll:ratio:)` does not.
    static func readableInPolarity(_ color: Color, isDark: Bool, onAll grounds: [Color],
                                   ratio target: Double) -> Color {
        guard let base = NSColor(hex: color.hexString) else { return color }
        var best = base
        for step in stride(from: 0.04, through: 1.0, by: 0.04) {
            let overlay = isDark ? NSColor.white : NSColor.black
            let mixed = Contrast.composite(overlay.withAlphaComponent(CGFloat(step)), over: base)
            best = mixed
            if grounds.allSatisfy({ Contrast.ratio(Color(nsColor: mixed).hexString, $0.hexString)
                                    >= target }) { break }
        }
        return Color(nsColor: best)
    }

    // MARK: - Status, resolved

    /// Destructive actions, on whatever ground they land on.
    ///
    /// Derived rather than a flat red: a fixed red is unreadable on some
    /// grounds and garish on others, and this one is nudged until it clears the
    /// ratio the audit asks of it.
    /// Every ground a status color is painted on.
    ///
    /// Deriving against the card alone was not enough: delete sits on a hovered
    /// row and on the selected row too, and it failed on both in every preset.
    private var statusGrounds: [Color] { [cardBackground, cardHoverBackground, selectedBackground] }

    var destructive: Color {
        if let ready = palette?.destructive { return ready }
        return destructiveOverride ?? Self.derivedStatusColor(hex: "#E5484D", onAll: statusGrounds)
    }

    var success: Color {
        if let ready = palette?.success { return ready }
        return successOverride ?? Self.derivedStatusColor(hex: "#30A46C", onAll: statusGrounds)
    }

    var warning: Color {
        if let ready = palette?.warning { return ready }
        return warningOverride ?? Self.derivedStatusColor(hex: "#F5A524", onAll: statusGrounds)
    }

    /// One formula for every status colour: a fixed hex, nudged until it
    /// clears the body-text ratio on every ground it lands on.
    ///
    /// Was copied verbatim into `ResolvedPalette.init` - the same three hex
    /// literals, the same `readable(...)` call, the same ratio - so a change
    /// to the derivation had to be made twice or it silently drifted between
    /// `AppTheme` and its own resolved snapshot. One function, called from
    /// both.
    static func derivedStatusColor(hex: String, onAll grounds: [Color]) -> Color {
        readable(Color(hex: hex), onAll: grounds, ratio: ThemeRules.Level.body.ratio)
    }

    // MARK: - Buttons and links, resolved

    /// One flat, MEASURABLE colour: `wash` tinted onto `ground` at `opacity`.
    ///
    /// This is Material's state-layer model (cited in this codebase's own
    /// `design-academy/disciplines/ui-visual-design`: "treat hover/focus/
    /// pressed as translucent overlays of a single state layer color scaled
    /// by intensity") applied at THEME-RESOLUTION time rather than at render
    /// time. A render-time `.opacity()` composites against whatever happens
    /// to be behind it and cannot be measured by the contrast audit in
    /// isolation; compositing here, once, produces one real `#RRGGBB` the
    /// audit can grade like any other token - the same lesson `ThemeRules`
    /// already learned from grading `white.opacity(0.45)` as pure white.
    static func stateLayer(_ wash: Color, over ground: Color, opacity: Double) -> Color {
        guard let washNS = NSColor(hex: wash.hexString),
              let groundNS = NSColor(hex: ground.hexString) else { return wash }
        return Color(nsColor: Contrast.composite(washNS.withAlphaComponent(CGFloat(opacity)),
                                                  over: groundNS))
    }

    /// `color` mixed toward white or black by `amount` - a bigger, more
    /// deliberate step than a state layer, used for the two states of a
    /// TEXT colour (a link's hover and pressed) rather than a fill.
    static func mixed(_ color: Color, towardWhite: Bool, by amount: Double) -> Color {
        guard let base = NSColor(hex: color.hexString) else { return color }
        let overlay = (towardWhite ? NSColor.white : NSColor.black).withAlphaComponent(CGFloat(amount))
        return Color(nsColor: Contrast.composite(overlay, over: base))
    }

    /// A state layer, guaranteed not to cost the fill its contrast against
    /// `text`.
    ///
    /// Washing `text`'s own colour onto `fill` (the naive Material model) can
    /// move contrast the WRONG way: Graphite's accent clears white text at
    /// 4.62:1 by design - deliberately thin margins, per this file's own
    /// comment on that preset - and lightening it even 8% toward white drops
    /// white below 4.5. `readable` already knows how to nudge a colour until
    /// it clears a ratio against a ground; called with the roles that
    /// pairing actually plays here (the FILL is what may move, `text` is
    /// fixed), it is exactly the fix - the naive layer passes through
    /// untouched when it already clears, and only gets nudged when it does not.
    static func stateLayerKeepingReadable(_ wash: Color, over fill: Color, opacity: Double,
                                          keeping text: Color) -> Color {
        let candidate = stateLayer(wash, over: fill, opacity: opacity)
        return readable(candidate, on: text, ratio: ThemeRules.Level.body.ratio)
    }

    /// The blue CTA's fill. Exactly one per app - this is the theme's own
    /// accent, so "the blue one" stays true to whichever accent a theme picks.
    var buttonPrimaryFill: Color {
        if let ready = palette?.buttonPrimaryFill { return ready }
        return buttonPrimaryFillOverride ?? accent
    }
    /// Label on the primary fill, readable by construction.
    var buttonPrimaryText: Color {
        if let ready = palette?.buttonPrimaryText { return ready }
        return buttonPrimaryTextOverride ?? Self.computedOnAccent(buttonPrimaryFill)
    }
    var buttonPrimaryHoverFill: Color {
        if let ready = palette?.buttonPrimaryHoverFill { return ready }
        return buttonPrimaryHoverFillOverride
            ?? Self.stateLayerKeepingReadable(buttonPrimaryText, over: buttonPrimaryFill,
                                              opacity: 0.08, keeping: buttonPrimaryText)
    }
    var buttonPrimaryPressedFill: Color {
        if let ready = palette?.buttonPrimaryPressedFill { return ready }
        return buttonPrimaryPressedFillOverride
            ?? Self.stateLayerKeepingReadable(buttonPrimaryText, over: buttonPrimaryFill,
                                              opacity: 0.18, keeping: buttonPrimaryText)
    }

    /// The sub button: a quiet, bordered surface - present but not competing
    /// with the one primary CTA on its screen.
    var buttonSecondaryFill: Color {
        if let ready = palette?.buttonSecondaryFill { return ready }
        return buttonSecondaryFillOverride ?? surfaceBackground
    }
    var buttonSecondaryText: Color {
        if let ready = palette?.buttonSecondaryText { return ready }
        return buttonSecondaryTextOverride ?? Self.tuned(textPrimary, on: buttonSecondaryFill,
                                                          to: ThemeRules.Level.body.ratio)
    }
    var buttonSecondaryBorder: Color {
        if let ready = palette?.buttonSecondaryBorder { return ready }
        return buttonSecondaryBorderOverride ?? border
    }
    var buttonSecondaryHoverFill: Color {
        if let ready = palette?.buttonSecondaryHoverFill { return ready }
        return buttonSecondaryHoverFillOverride
            ?? Self.stateLayerKeepingReadable(interaction, over: buttonSecondaryFill,
                                              opacity: 0.08, keeping: buttonSecondaryText)
    }
    var buttonSecondaryPressedFill: Color {
        if let ready = palette?.buttonSecondaryPressedFill { return ready }
        return buttonSecondaryPressedFillOverride
            ?? Self.stateLayerKeepingReadable(interaction, over: buttonSecondaryFill,
                                              opacity: 0.16, keeping: buttonSecondaryText)
    }

    /// The ghost button: text only until it is touched - the lowest-emphasis
    /// of the three, used only where a bordered sub button would be too loud.
    var buttonGhostText: Color {
        if let ready = palette?.buttonGhostText { return ready }
        return buttonGhostTextOverride ?? Self.tuned(textSecondary, on: cardBackground,
                                                      to: ThemeRules.Level.body.ratio)
    }
    var buttonGhostHoverFill: Color {
        if let ready = palette?.buttonGhostHoverFill { return ready }
        return buttonGhostHoverFillOverride
            ?? Self.stateLayerKeepingReadable(interaction, over: cardBackground,
                                              opacity: 0.18, keeping: textPrimary)
    }
    var buttonGhostPressedFill: Color {
        if let ready = palette?.buttonGhostPressedFill { return ready }
        return buttonGhostPressedFillOverride
            ?? Self.stateLayerKeepingReadable(interaction, over: cardBackground,
                                              opacity: 0.24, keeping: textPrimary)
    }

    /// The grounds a link or its text is ever read against.
    private var linkGrounds: [Color] { [cardBackground, panelBackground, surfaceBackground, cardHoverBackground] }

    /// The one link colour, readable on every ground a link renders on.
    var link: Color {
        if let ready = palette?.link { return ready }
        return linkOverride ?? Self.readable(accent, onAll: linkGrounds, ratio: ThemeRules.Level.body.ratio)
    }
    var linkHover: Color {
        if let ready = palette?.linkHover { return ready }
        return linkHoverOverride
            ?? Self.readable(Self.mixed(link, towardWhite: !isDark, by: 0.16),
                             onAll: linkGrounds, ratio: ThemeRules.Level.body.ratio)
    }
    var linkPressed: Color {
        if let ready = palette?.linkPressed { return ready }
        return linkPressedOverride
            ?? Self.readable(Self.mixed(link, towardWhite: !isDark, by: 0.32),
                             onAll: linkGrounds, ratio: ThemeRules.Level.body.ratio)
    }

    /// One disabled treatment for every button kind and the link. See the
    /// property comment on the override for why this is not opacity.
    var controlDisabledFill: Color {
        if let ready = palette?.controlDisabledFill { return ready }
        return controlDisabledFillOverride ?? surfaceBackground
    }
    var controlDisabledText: Color {
        if let ready = palette?.controlDisabledText { return ready }
        return controlDisabledTextOverride ?? Self.readable(textTertiary, onAll: [controlDisabledFill],
                                                             ratio: ThemeRules.Level.decorative.ratio)
    }

    /// Nudges `color` until it clears `ratio` on EVERY ground it is painted on.
    ///
    /// One ground is not enough. A color derived against the card alone is
    /// still free to fail on the hovered row and the selected row, which are
    /// different colors the same thing lands on.
    static func readable(_ color: Color, onAll grounds: [Color], ratio target: Double) -> Color {
        guard let hardest = grounds.min(by: {
            Contrast.ratio(color.hexString, $0.hexString)
                < Contrast.ratio(color.hexString, $1.hexString)
        }) else { return color }
        var candidate = readable(color, on: hardest, ratio: target)
        // Nudging for the hardest ground can cost contrast on another, so keep
        // going until every ground is satisfied or the color runs out of room.
        var guard_ = 0
        while grounds.contains(where: {
            Contrast.ratio(candidate.hexString, $0.hexString) < target
        }), guard_ < 12 {
            guard_ += 1
            guard let worst = grounds.min(by: {
                Contrast.ratio(candidate.hexString, $0.hexString)
                    < Contrast.ratio(candidate.hexString, $1.hexString)
            }) else { break }
            let next = readable(candidate, on: worst, ratio: target)
            if next.hexString == candidate.hexString { break }
            candidate = next
        }
        return candidate
    }

    /// Lightens or darkens `color` until it clears `ratio` on `ground`.
    ///
    /// The direction is decided by the ground, so the same authored red goes
    /// lighter on a dark theme and darker on a light one, and the hue survives
    /// either way.
    static func readable(_ color: Color, on ground: Color, ratio target: Double) -> Color {
        guard let base = NSColor(hex: color.hexString),
              let behind = NSColor(hex: ground.hexString) else { return color }
        if Contrast.ratio(color.hexString, ground.hexString) >= target { return color }

        let goLighter = Contrast.ratio("#FFFFFF", ground.hexString)
                      > Contrast.ratio("#000000", ground.hexString)
        var best = base
        for step in stride(from: 0.04, through: 1.0, by: 0.04) {
            let mixed = Contrast.composite(
                (goLighter ? NSColor.white : NSColor.black).withAlphaComponent(step),
                over: base)
            best = mixed
            if Contrast.ratio(Color(nsColor: mixed).hexString,
                              Color(nsColor: behind).hexString) >= target { break }
        }
        return Color(nsColor: best)
    }

    // MARK: - Corner radius roles

    /// Small, mostly-interactive shapes: buttons, badges, pills, the disc
    /// behind a highlighted row.
    ///
    /// Nine distinct radii (4, 5, 6, 7, 8, 10, 11, plus the container values)
    /// were doing the work of two or three real roles, each one a literal
    /// chosen by eye at its own call site. This is the small end of that
    /// scale, derived from the theme's own `cornerRadius` rather than fixed,
    /// so a sharper theme (Mono) draws sharper controls and a rounder one
    /// (Aurora) draws rounder ones without either being told to.
    var radiusControl: CGFloat { cornerRadius * 0.5 }

    /// Content surfaces: rows, cards, thumbnails, an inline suggestion box —
    /// anything that holds real content rather than acting as a control.
    ///
    /// This is the radius `RowChrome` already used for both list rows and
    /// gallery cards (`cornerRadius * 0.8`) so a grid and a list of the same
    /// items keep rounding the same way; it is named here so every other
    /// content surface in the app can share the one rule instead of picking
    /// its own nearby number.
    var radiusCard: CGFloat { cornerRadius * 0.8 }

    /// The biggest shapes an overlay draws with: the detail sheet, a picker
    /// shell, the panel's own outer edge.
    ///
    /// This is the theme's `cornerRadius` exactly, unscaled — these are the
    /// shapes a theme's roundness is actually about. Several of them used to
    /// hard-code 14, 16 or 18 regardless of which theme was active, which is
    /// why choosing Mono (a 6pt theme) still left the panel edge and the
    /// detail sheet rounded as if Aurora were still selected.
    var radiusContainer: CGFloat { cornerRadius }

    // Convenient gradients
    var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accentSecondary],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Foreground that stays legible on top of `accent`.
    ///
    /// This used to always be white, which fails badly on a light accent — the
    /// label inside an active filter chip became unreadable. Pick whichever of
    /// black or white actually contrasts with the accent in use.
    var onAccent: Color {
        if let ready = palette?.onAccent { return ready }
        return Self.computedOnAccent(accent)
    }

    /// The same rule, callable without a theme, so `ResolvedPalette` and this
    /// property can never drift apart by being written twice.
    static func computedOnAccent(_ accent: Color) -> Color {
        let hex = accent.hexString
        let onWhite = Contrast.ratio("#FFFFFF", hex)
        let onBlack = Contrast.ratio("#000000", hex)
        // White whenever white is readable, not merely whenever white wins.
        //
        // Maximising the ratio put BLACK on Graphite's blue - 5.38 against
        // white's 3.91 - which is arithmetically correct and looks wrong: text
        // on a saturated blue is white everywhere else on the system. Black is
        // now the fallback for accents pale enough that white genuinely fails,
        // which is what it was always for.
        if onWhite >= ThemeRules.Level.body.ratio { return .white }
        return onWhite >= onBlack ? .white : .black
    }

    /// The hue each card kind is known by.
    ///
    /// These are identities, not final colors: "code is green" should hold
    /// across every theme, or the same clip changes meaning when the theme
    /// changes. What varies per theme is how light that green has to be, which
    /// is why nothing paints these directly - see `tint(for:on:)`.
    func baseTint(for kind: ItemKind) -> Color {
        switch kind {
        case .text:      return accent
        case .code:      return Color(red: 0.36, green: 0.80, blue: 0.55)
        case .richText:  return Color(red: 0.70, green: 0.50, blue: 1.00)
        case .emoji:     return Color(red: 1.00, green: 0.76, blue: 0.25)
        case .image:     return Color(red: 1.00, green: 0.42, blue: 0.62)
        case .video:     return Color(red: 1.00, green: 0.55, blue: 0.30)
        case .file:      return Color(red: 0.98, green: 0.68, blue: 0.22)
        case .folder:    return Color(red: 0.35, green: 0.62, blue: 0.98)
        case .url:       return Color(red: 0.25, green: 0.78, blue: 0.85)
        case .color:     return Color(red: 0.95, green: 0.35, blue: 0.40)
        case .colorData: return textTertiary
        }
    }

    /// The tint as it must be painted on a given background.
    ///
    /// The hardcoded table above is why the three light themes were unusable:
    /// the same mid-tone green that reads well on a near-black card sits at
    /// 2.01:1 on white. Tuning against the actual background fixes all of them
    /// at once, and keeps working for themes that do not exist yet.
    func tint(for kind: ItemKind, on background: Color) -> Color {
        if let pinned = typeTintOverrides[kind.rawValue] { return pinned }
        if let table = palette?.tints,
           let ready = table[ResolvedPalette.TintKey(kind: kind.rawValue,
                                                     ground: background)] {
            return ready
        }
        return Self.tuned(baseTint(for: kind), on: background, to: ThemeRules.Level.body.ratio)
    }

    /// Convenience for the common case: a tint painted on a card.
    func tint(for kind: ItemKind) -> Color { tint(for: kind, on: cardBackground) }

    /// The accent, made readable as text on whatever it is written on.
    ///
    /// `accent` itself stays exactly as authored - it is a fill, and a selection
    /// ring or a prominent button wants the color the theme chose. This is the
    /// text form of it, and it is a different color on a card, on the panel and
    /// on the selected row, because those are different backgrounds.
    func accentText(on background: Color) -> Color {
        if let pinned = accentTextOverride { return pinned }
        if let ready = palette?.accentTextByGround[background] { return ready }
        return Self.tuned(accent, on: background, to: ThemeRules.Level.body.ratio)
    }

    /// Primary text, made readable on a background that is not the card.
    func text(on background: Color) -> Color {
        if let pinned = selectionTextOverride, background == selectedBackground { return pinned }
        if let ready = palette?.textByGround[background] { return ready }
        return Self.tuned(textPrimary, on: background, to: ThemeRules.Level.body.ratio)
    }

    /// Secondary text, made readable on a background that is not the card.
    func secondaryText(on background: Color) -> Color {
        if let ready = palette?.secondaryTextByGround[background] { return ready }
        return Self.tuned(textSecondary, on: background, to: ThemeRules.Level.body.ratio)
    }

    /// Tertiary text, made readable on a background that is not the card.
    func tertiaryText(on background: Color) -> Color {
        if let ready = palette?.tertiaryTextByGround[background] { return ready }
        return Self.tuned(textTertiary, on: background, to: ThemeRules.Level.body.ratio)
    }

    /// The panel color as it actually reaches the screen over `backdrop`.
    ///
    /// Used by the audit to grade the worst case rather than the hoped-for one.
    func renderedPanel(over backdrop: Color) -> Color {
        guard translucency > 0,
              let wash = NSColor(hex: panelBackground.hexString),
              let behind = NSColor(hex: backdrop.hexString) else { return panelBackground }
        let translucent = wash.withAlphaComponent(CGFloat(1 - translucency))
        return Color(nsColor: Contrast.composite(translucent, over: behind))
    }

    /// A hovered, unselected tab, as it actually reaches the screen.
    ///
    /// The tab bar paints two translucent layers on top of the panel: its own
    /// container at `surfaceBackground` 60%, then `tabHoverFill` on top of
    /// that. Grading the hover fill as if it were opaque - which is what
    /// `ThemeRules.ratio` does for any background it is handed directly -
    /// reports a contrast the screen never shows, so this resolves the real
    /// stack first.
    func renderedTabHover() -> Color {
        guard let barColor = NSColor(hex: surfaceBackground.opacity(0.6).hexString),
              let panel = NSColor(hex: panelBackground.hexString),
              let hoverColor = NSColor(hex: tabHoverFill.hexString)
        else { return tabHoverFill }
        let barOverPanel = Contrast.composite(barColor, over: panel)
        let hoverOverBar = Contrast.composite(hoverColor, over: barOverPanel)
        return Color(nsColor: hoverOverBar)
    }

    /// A tinted chip: the wash behind it and a label readable on that wash.
    ///
    /// The type glyph and the kind badge both draw their color at 16% over the
    /// row and then write in that same color on top. Grading the label against
    /// the row is therefore the wrong measurement - it is written on the wash,
    /// which is a lighter or darker thing again. Resolving both halves together
    /// keeps them honest.
    /// The three places accent-colored text is written, resolved once.
    ///
    /// Named rather than computed at each call site so nothing quietly writes
    /// the raw accent - which is a fill color, and is allowed to be too quiet
    /// to read.
    var accentOnCard: Color { accentText(on: cardBackground) }
    var accentOnPanel: Color { accentText(on: panelBackground) }
    var accentOnSurface: Color { accentText(on: surfaceBackground) }

    /// An accent-tinted capsule on a card, with a label readable on it.
    var accentChipOnCard: (fill: Color, foreground: Color) {
        palette?.accentChipOnCard ?? Self.chipColors(accent, on: cardBackground)
    }

    /// The default-icon chip a row draws for a kind with no richer preview
    /// (everything but image/video, color and emoji). Resolved from the
    /// palette's tint table when one is available, so a 200-row tab does not
    /// repeat the same `chipColors(tint(for:on:), on:)` search once per row.
    func chipColors(for kind: ItemKind, on background: Color) -> (fill: Color, foreground: Color) {
        let key = ResolvedPalette.TintKey(kind: kind.rawValue, ground: background)
        if let ready = palette?.chipColorsByKind[key] { return ready }
        return Self.chipColors(tint(for: kind, on: background), on: background)
    }

    static func chipColors(_ base: Color, on background: Color) -> (fill: Color, foreground: Color) {
        guard let tint = NSColor(hex: base.hexString),
              let behind = NSColor(hex: background.hexString) else { return (base, base) }
        let fill = Contrast.composite(tint.withAlphaComponent(0.16), over: behind)
        let wash = Color(nsColor: fill)
        return (wash, Self.tuned(base, on: wash, to: ThemeRules.Level.body.ratio))
    }

    /// Internal rather than private: `ResolvedPalette` precomputes the same
    /// answers, and duplicating the rule there would let the two drift.
    static func tuned(_ color: Color, on background: Color, to ratio: Double) -> Color {
        let hex = ColorTuner.adjust(color.hexString, on: background.hexString, to: ratio)
        return NSColor(hex: hex).map(Color.init(nsColor:)) ?? color
    }
}

extension AppTheme {
    static let presets: [AppTheme] = [
        // MARK: Aurora — the default
        AppTheme(
            id: "aurora", name: "Aurora", symbol: "sparkles",
            accent: Color(red: 0.36, green: 0.36, blue: 1.0),
            accentSecondary: Color(red: 0.75, green: 0.28, blue: 1.0),
            panelBackground: Color(red: 0.05, green: 0.06, blue: 0.11),
            cardBackground: Color(red: 0.11, green: 0.12, blue: 0.20),
            cardHoverBackground: Color(red: 0.15, green: 0.16, blue: 0.26),
            selectedBackground: Color(red: 0.22, green: 0.20, blue: 0.42),
            surfaceBackground: Color(red: 0.09, green: 0.10, blue: 0.17),
            // textSecondary/textTertiary: lifted to the smallest lightness
            // that clears AAA (7:1) body text - was 6.9x-ish on both.
            textPrimary: Color(hex: "#FFFFFF"), textSecondary: Color(hex: "#CBCCD1"),
            textTertiary: Color(hex: "#AAAAB2"),
            border: Color(hex: "#262837"),
            cornerRadius: 18,
            usesGradientHeader: true,
            defaultLayout: .gallery, defaultDensity: .comfortable,
            isDark: true
        ),

        // MARK: Graphite — clean macOS-native
        AppTheme(
            id: "graphite", name: "Graphite", symbol: "macwindow",
            // #0A6EF4, threaded between two constraints that pull opposite ways.
            // White on the accent must clear 4.5 (the chip label), which wants a
            // DEEPER blue; the accent as a selection ring on the dark card must
            // clear 3.0, which wants a LIGHTER one. #007DFF failed the first at
            // 3.91 and #0A66DC failed the second at 2.67. This clears both, at
            // 4.62 and 3.08 - thin margins, and deliberately so: there is not
            // much room between them.
            accent: Color(red: 0.039, green: 0.431, blue: 0.957),
            accentSecondary: Color(red: 0.0, green: 0.72, blue: 0.9),
            panelBackground: Color(red: 0.10, green: 0.11, blue: 0.12),
            cardBackground: Color(red: 0.16, green: 0.17, blue: 0.18),
            cardHoverBackground: Color(red: 0.20, green: 0.21, blue: 0.22),
            // Darkened one AAA repair pass: white text on the selection blue
            // measured 5.36:1, short of 7. Same hue, lower lightness.
            selectedBackground: Color(hex: "#0B55B4"),
            surfaceBackground: Color(red: 0.13, green: 0.14, blue: 0.15),
            textPrimary: Color(hex: "#FFFFFF"), textSecondary: Color(hex: "#FFFFFF"),
            textTertiary: Color(hex: "#B6B7B8"),
            border: Color(hex: "#303436"),
            cornerRadius: 10,
            usesGradientHeader: false,
            defaultLayout: .list, defaultDensity: .comfortable,
            isDark: true
        ),

        // MARK: Neon — dark, high-contrast, playful
        AppTheme(
            id: "neon", name: "Neon", symbol: "lightbulb",
            accent: Color(red: 0.0, green: 1.0, blue: 0.85),
            accentSecondary: Color(red: 1.0, green: 0.0, blue: 0.75),
            panelBackground: Color(red: 0.03, green: 0.03, blue: 0.06),
            cardBackground: Color(red: 0.09, green: 0.09, blue: 0.15),
            cardHoverBackground: Color(red: 0.13, green: 0.13, blue: 0.22),
            // Same AAA repair as Graphite's selection, plus surfaceBackground
            // nudged for the surface-separation step that moved under it.
            selectedBackground: Color(hex: "#006257"),
            surfaceBackground: Color(hex: "#11111C"),
            textPrimary: Color(hex: "#FFFFFF"),
            textSecondary: Color(hex: "#FFFFFF"),
            textTertiary: Color(hex: "#A3A3A9"),
            border: Color(hex: "#064542"),
            cornerRadius: 14,
            usesGradientHeader: true,
            defaultLayout: .gallery, defaultDensity: .comfortable,
            isDark: true
        ),

        // MARK: Ivory — light, minimal, paper-like
        AppTheme(
            id: "ivory", name: "Ivory", symbol: "paperplane",
            accent: Color(red: 0.85, green: 0.45, blue: 0.15),
            accentSecondary: Color(hex: "#D3810E"),
            panelBackground: Color(red: 0.98, green: 0.97, blue: 0.95),
            cardBackground: .white,
            cardHoverBackground: Color(red: 0.95, green: 0.93, blue: 0.90),
            selectedBackground: Color(red: 0.96, green: 0.83, blue: 0.68),
            // surfaceBackground/accentSecondary/textTertiary: smallest AAA
            // moves - accentSecondary's chip label needed a deeper amber.
            surfaceBackground: Color(hex: "#F4F0EB"),
            textPrimary: Color(hex: "#000000"), textSecondary: Color(hex: "#474038"),
            textTertiary: Color(hex: "#55504B"),
            border: Color(hex: "#E6E4DF"),
            cornerRadius: 12,
            usesGradientHeader: false,
            defaultLayout: .list, defaultDensity: .comfortable,
            isDark: false
        ),

        // MARK: Sage — calm green
        AppTheme(
            id: "sage", name: "Sage", symbol: "leaf",
            accent: Color(red: 0.35, green: 0.65, blue: 0.45),
            accentSecondary: Color(red: 0.55, green: 0.75, blue: 0.5),
            panelBackground: Color(red: 0.08, green: 0.12, blue: 0.10),
            cardBackground: Color(red: 0.13, green: 0.18, blue: 0.15),
            cardHoverBackground: Color(red: 0.17, green: 0.23, blue: 0.19),
            // Same AAA selection repair as Graphite/Neon.
            selectedBackground: Color(hex: "#2A6241"),
            surfaceBackground: Color(red: 0.11, green: 0.15, blue: 0.13),
            textPrimary: Color(hex: "#FFFFFF"),
            textSecondary: Color(hex: "#FFFFFF"),
            textTertiary: Color(hex: "#B4B8B5"),
            border: Color(hex: "#2B3531"),
            cornerRadius: 16,
            usesGradientHeader: true,
            defaultLayout: .gallery, defaultDensity: .compact,
            isDark: true
        ),

        // MARK: Coral — warm & friendly
        AppTheme(
            id: "coral", name: "Coral", symbol: "drop",
            accent: Color(red: 1.0, green: 0.42, blue: 0.42),
            accentSecondary: Color(red: 1.0, green: 0.62, blue: 0.35),
            panelBackground: Color(red: 0.12, green: 0.09, blue: 0.12),
            cardBackground: Color(red: 0.20, green: 0.14, blue: 0.19),
            cardHoverBackground: Color(red: 0.26, green: 0.17, blue: 0.24),
            selectedBackground: Color(red: 0.55, green: 0.22, blue: 0.28),
            surfaceBackground: Color(red: 0.16, green: 0.11, blue: 0.16),
            textPrimary: Color(hex: "#FFFFFF"), textSecondary: Color(hex: "#F7F7F7"),
            textTertiary: Color(hex: "#B7B2B6"),
            border: Color(hex: "#362E36"),
            cornerRadius: 18,
            usesGradientHeader: true,
            defaultLayout: .gallery, defaultDensity: .comfortable,
            isDark: true
        ),

        // MARK: Midnight
        AppTheme(
            id: "midnight", name: "Midnight", symbol: "moon.stars",
            accent: Color(hex: "#4F7CFF"),
            accentSecondary: Color(hex: "#7B5CFF"),
            panelBackground: Color(hex: "#080A12"),
            cardBackground: Color(hex: "#141826"),
            cardHoverBackground: Color(hex: "#1D2233"),
            selectedBackground: Color(hex: "#2B3358"),
            surfaceBackground: Color(hex: "#101423"),
            textPrimary: Color(hex: "#FFFFFF"),
            textSecondary: Color(hex: "#BFC4D2"),
            textTertiary: Color(hex: "#A0A3B2"),
            border: Color(hex: "#242A3D"),
            cornerRadius: 16,
            usesGradientHeader: true,
            defaultLayout: .gallery, defaultDensity: .comfortable,
            isDark: true
        ),
        // MARK: Nord - the arctic palette, dark
        //
        // Five more themes (user, 06/09), each taken from a design system
        // people already know rather than invented: recognisable at a glance,
        // and each one MEASURED rather than trusted. Four of the five failed
        // their first audit - tertiary text short of the 7:1 the rules ask
        // for, and Tokyo Night's card only 1.05:1 against its own panel - so
        // the exact values below are the ones `ThemeDoctor.repaired` produced,
        // the smallest move that passes, not a hand-nudge that looked right.
        AppTheme(
            id: "nord", name: "Nord", symbol: "snowflake",
            accent: Color(hex: "#88C0D0"),
            accentSecondary: Color(hex: "#B48EAD"),
            panelBackground: Color(hex: "#242933"),
            cardBackground: Color(hex: "#2E3440"),
            cardHoverBackground: Color(hex: "#3B4252"),
            selectedBackground: Color(hex: "#434C5E"),
            surfaceBackground: Color(hex: "#292E39"),
            textPrimary: Color(hex: "#ECEFF4"),
            textSecondary: Color(hex: "#E4E8F0"),
            textTertiary: Color(hex: "#BBC3D0"),
            border: Color(hex: "#3B4252"),
            cornerRadius: 12,
            usesGradientHeader: false,
            defaultLayout: .list, defaultDensity: .comfortable,
            isDark: true
        ),
        // MARK: Tokyo Night
        AppTheme(
            id: "tokyo", name: "Tokyo Night", symbol: "building.2",
            accent: Color(hex: "#7AA2F7"),
            accentSecondary: Color(hex: "#BB9AF7"),
            panelBackground: Color(hex: "#16161E"),
            cardBackground: Color(hex: "#1B1C27"),
            cardHoverBackground: Color(hex: "#24283B"),
            selectedBackground: Color(hex: "#2F3549"),
            surfaceBackground: Color(hex: "#1B1C2A"),
            textPrimary: Color(hex: "#F7F7FB"),
            textSecondary: Color(hex: "#C0CAF5"),
            textTertiary: Color(hex: "#A2ACD0"),
            border: Color(hex: "#2A2E42"),
            cornerRadius: 14,
            usesGradientHeader: true,
            defaultLayout: .gallery, defaultDensity: .comfortable,
            isDark: true
        ),
        // MARK: Solarized - the warm light half of Ethan Schoonover's palette
        AppTheme(
            id: "solarized", name: "Solarized", symbol: "sun.horizon",
            accent: Color(hex: "#1C6C8C"),
            accentSecondary: Color(hex: "#8A6A00"),
            panelBackground: Color(hex: "#FDF6E3"),
            cardBackground: Color(hex: "#FFFEFA"),
            cardHoverBackground: Color(hex: "#F3EAD3"),
            selectedBackground: Color(hex: "#E7DCC0"),
            surfaceBackground: Color(hex: "#F7EFDA"),
            textPrimary: Color(hex: "#0F2E36"),
            textSecondary: Color(hex: "#2E464C"),
            textTertiary: Color(hex: "#435357"),
            border: Color(hex: "#E0D6BC"),
            cornerRadius: 12,
            usesGradientHeader: false,
            defaultLayout: .list, defaultDensity: .comfortable,
            isDark: false
        ),
        // MARK: Primer - GitHub's light neutral
        AppTheme(
            id: "primer", name: "Primer", symbol: "chevron.left.forwardslash.chevron.right",
            accent: Color(hex: "#0757BA"),
            accentSecondary: Color(hex: "#6639BA"),
            panelBackground: Color(hex: "#F6F8FA"),
            cardBackground: Color(hex: "#FFFFFF"),
            cardHoverBackground: Color(hex: "#EEF1F4"),
            selectedBackground: Color(hex: "#DDE4EC"),
            surfaceBackground: Color(hex: "#EDF0F4"),
            textPrimary: Color(hex: "#101418"),
            textSecondary: Color(hex: "#3E434A"),
            textTertiary: Color(hex: "#4B5157"),
            border: Color(hex: "#D8DEE4"),
            cornerRadius: 10,
            usesGradientHeader: false,
            defaultLayout: .list, defaultDensity: .compact,
            isDark: false
        ),
        // MARK: Material - Material 3's dark surface ramp
        AppTheme(
            id: "material", name: "Material", symbol: "square.stack.3d.up",
            accent: Color(hex: "#D0BCFF"),
            accentSecondary: Color(hex: "#9FD8CB"),
            panelBackground: Color(hex: "#141218"),
            cardBackground: Color(hex: "#1D1B20"),
            cardHoverBackground: Color(hex: "#2B2930"),
            selectedBackground: Color(hex: "#36343B"),
            surfaceBackground: Color(hex: "#1A181E"),
            textPrimary: Color(hex: "#F5EFF7"),
            textSecondary: Color(hex: "#CAC4D0"),
            textTertiary: Color(hex: "#ADA7B4"),
            border: Color(hex: "#322F37"),
            cornerRadius: 16,
            usesGradientHeader: false,
            defaultLayout: .gallery, defaultDensity: .comfortable,
            isDark: true
        ),
        // MARK: Forest
        AppTheme(
            id: "forest", name: "Forest", symbol: "leaf",
            accent: Color(hex: "#3FB98C"),
            accentSecondary: Color(hex: "#79D96B"),
            panelBackground: Color(hex: "#0B1512"),
            cardBackground: Color(hex: "#152220"),
            cardHoverBackground: Color(hex: "#1D2E2A"),
            selectedBackground: Color(hex: "#20443A"),
            surfaceBackground: Color(hex: "#111D1A"),
            textPrimary: Color(hex: "#F2FBF7"),
            textSecondary: Color(hex: "#C4D5D0"),
            textTertiary: Color(hex: "#9EAEA8"),
            border: Color(hex: "#1E322D"),
            cornerRadius: 14,
            usesGradientHeader: true,
            defaultLayout: .gallery, defaultDensity: .comfortable,
            isDark: true
        ),
        // MARK: Ember
        AppTheme(
            id: "ember", name: "Ember", symbol: "flame",
            accent: Color(hex: "#FF6B3D"),
            accentSecondary: Color(hex: "#FFB03A"),
            panelBackground: Color(hex: "#140C09"),
            cardBackground: Color(hex: "#231512"),
            cardHoverBackground: Color(hex: "#2E1D18"),
            selectedBackground: Color(hex: "#4A2418"),
            surfaceBackground: Color(hex: "#1F130E"),
            textPrimary: Color(hex: "#FFF6F1"),
            textSecondary: Color(hex: "#D3B7AC"),
            textTertiary: Color(hex: "#B3A099"),
            border: Color(hex: "#33201A"),
            cornerRadius: 12,
            usesGradientHeader: true,
            defaultLayout: .list, defaultDensity: .compact,
            isDark: true
        ),
        // MARK: Paper
        AppTheme(
            id: "paper", name: "Paper", symbol: "doc.plaintext",
            accent: Color(hex: "#2F6BFF"),
            accentSecondary: Color(hex: "#4594FF"),
            panelBackground: Color(hex: "#F0F0EC"),
            cardBackground: Color(hex: "#FFFFFF"),
            cardHoverBackground: Color(hex: "#F1F2F6"),
            selectedBackground: Color(hex: "#DCE6FF"),
            surfaceBackground: Color(hex: "#E9E9E2"),
            textPrimary: Color(hex: "#16181D"),
            textSecondary: Color(hex: "#3A3E48"),
            textTertiary: Color(hex: "#484B55"),
            border: Color(hex: "#E1E2E8"),
            cornerRadius: 10,
            usesGradientHeader: false,
            defaultLayout: .list, defaultDensity: .comfortable,
            isDark: false
        ),
        // MARK: Sand
        AppTheme(
            id: "sand", name: "Sand", symbol: "sun.max",
            accent: Color(hex: "#C9793B"),
            accentSecondary: Color(hex: "#CA8427"),
            panelBackground: Color(hex: "#FBF6EE"),
            cardBackground: Color(hex: "#FFFFFF"),
            cardHoverBackground: Color(hex: "#F3EADD"),
            selectedBackground: Color(hex: "#F6DFC2"),
            surfaceBackground: Color(hex: "#F1E7D8"),
            textPrimary: Color(hex: "#231C13"),
            textSecondary: Color(hex: "#4A4136"),
            textTertiary: Color(hex: "#534A3F"),
            border: Color(hex: "#E6DACA"),
            cornerRadius: 14,
            usesGradientHeader: false,
            defaultLayout: .gallery, defaultDensity: .comfortable,
            isDark: false
        ),
        // MARK: Mono
        AppTheme(
            id: "mono", name: "Mono", symbol: "circle.lefthalf.filled",
            accent: Color(hex: "#8A8A8A"),
            accentSecondary: Color(hex: "#BDBDBD"),
            panelBackground: Color(hex: "#0F0F0F"),
            cardBackground: Color(hex: "#1A1A1A"),
            cardHoverBackground: Color(hex: "#232323"),
            selectedBackground: Color(hex: "#333333"),
            surfaceBackground: Color(hex: "#171717"),
            textPrimary: Color(hex: "#FAFAFA"),
            textSecondary: Color(hex: "#C2C2C2"),
            textTertiary: Color(hex: "#A5A5A5"),
            border: Color(hex: "#2A2A2A"),
            cornerRadius: 6,
            usesGradientHeader: false,
            defaultLayout: .list, defaultDensity: .compact,
            isDark: true
        ),

        // MARK: Clip — the new default, system-following
        //
        // Two forms, picked by the OS rather than authored by hand: the DARK
        // form's literal colours are Graphite's own, unchanged — Graphite is
        // already what Settings renders (SETTINGS-DESIGN.md § "Clip's
        // adopted tokens"; SettingsPalette.swift's own doc comment), so
        // matching the panel to "the Settings design" means matching
        // Graphite exactly rather than inventing a new palette. The LIGHT
        // form's backgrounds are `NSColor.windowBackgroundColor` /
        // `.controlBackgroundColor` resolved under `.aqua` — the same source
        // Settings itself reads for its native chrome — with the same
        // Graphite accent carried over so the two forms read as one theme,
        // not two. Both are audited like any other preset (see qa-probe.py
        // 38b) and both went through `ThemeDoctor.repaired` before these
        // literals were hand-written back in, same as every AAA-repaired
        // preset above.
        AppTheme(
            id: "clip", name: "Clip", symbol: "circle.righthalf.filled",
            accent: Color(hex: "#0A6EF4"),
            // AAA repair pass (ThemeDoctor.repaired, see qa-probe.py 38d):
            // the chip label on this needed a deeper cyan than the raw
            // measured value - #00B8E6 cleared 4.62 on white, short of 7.
            accentSecondary: Color(hex: "#009BC2"),
            // NSColor.windowBackgroundColor / .controlBackgroundColor under
            // NSAppearance(named: .aqua), resolved to sRGB — Settings' own
            // native light chrome, not an eyeballed off-white.
            panelBackground: Color(hex: "#FFFFFF"),
            // AAA repair: card nudged one step off pure white so hover has
            // room to read as a step, not a rounding error.
            cardBackground: Color(hex: "#F7F7F7"),
            cardHoverBackground: Color(hex: "#EFF0F5"),
            selectedBackground: Color(hex: "#DCE6FF"),
            surfaceBackground: Color(hex: "#EFEFEA"),
            // textPrimary: NSColor.labelColor under .aqua. textSecondary/
            // textTertiary/border: Paper's own AAA-repaired neutrals — the
            // one other light preset built on this same near-white ground,
            // so the two forms of Clip and Clip's nearest light sibling
            // agree on what "readable gray" means rather than each preset
            // inventing its own.
            textPrimary: Color(hex: "#000000"), textSecondary: Color(hex: "#3A3E48"),
            textTertiary: Color(hex: "#484B55"),
            border: Color(hex: "#E1E2E8"),
            cornerRadius: 10,
            usesGradientHeader: false,
            defaultLayout: .list, defaultDensity: .comfortable,
            isDark: false,
            systemLightID: "clip", systemDarkID: "clip-dark"
        ),
        // The dark form. Not offered in the picker on its own — `hiddenFromPicker`
        // keeps it out of the grid, but it stays a real, audited preset so
        // `AppTheme.theme(for:)` can resolve it and `auditThemes`/
        // `auditThemesRepaired` grade it like every other built-in.
        AppTheme(
            id: "clip-dark", name: "Clip Dark", symbol: "circle.righthalf.filled",
            accent: Color(hex: "#0A6EF4"),
            accentSecondary: Color(hex: "#00B8E6"),
            panelBackground: Color(red: 0.10, green: 0.11, blue: 0.12),
            cardBackground: Color(red: 0.16, green: 0.17, blue: 0.18),
            cardHoverBackground: Color(red: 0.20, green: 0.21, blue: 0.22),
            selectedBackground: Color(hex: "#0B55B4"),
            surfaceBackground: Color(red: 0.13, green: 0.14, blue: 0.15),
            textPrimary: Color(hex: "#FFFFFF"), textSecondary: Color(hex: "#FFFFFF"),
            textTertiary: Color(hex: "#B6B7B8"),
            border: Color(hex: "#303436"),
            cornerRadius: 10,
            usesGradientHeader: false,
            defaultLayout: .list, defaultDensity: .comfortable,
            isDark: true,
            systemLightID: "clip", systemDarkID: "clip-dark",
            hiddenFromPicker: true
        ),
    ]

    /// Resolves a theme id, including user-made ones (`custom:<uuid>`).
    /// Main-actor because custom themes live in an observable store the UI owns.
    @MainActor
    static func theme(for id: String) -> AppTheme {
        if id.hasPrefix("custom:") {
            if let custom = CustomThemeStore.shared.theme(withID: id) { return custom.appTheme }
            return presets[0]
        }
        return presets.first { $0.id == id } ?? presets[0]
    }
}

extension Color {
    /// Convenience for the preset table.
    init(hex: String) {
        self = NSColor(hex: hex).map(Color.init(nsColor:)) ?? .gray
    }
}
