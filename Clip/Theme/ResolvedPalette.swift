import SwiftUI

/// The colors a theme works out for itself, computed once instead of per read.
///
/// Every derived color in `AppTheme` is the answer to "nudge this until it
/// clears the contrast ratio on every ground it lands on". That answer is a
/// search: it converts colors to hex strings, parses them back, and iterates up
/// to twelve times, several times over. It is also a *pure function of the
/// theme*, so the answer cannot change until the theme does.
///
/// It was written as a set of computed properties, which meant the search ran
/// again on every single read. Measured on a 745-item library, eight derived
/// colors cost **1.5 ms per row**: thirty visible rows spent roughly 45 ms per
/// frame re-deriving colors that had not changed, against a 16 ms budget. That
/// was the app's single largest source of lag, and it was invisible in the
/// search code where everyone had been looking.
///
/// Nothing about the resulting colors changes. This type only decides *when*
/// they are worked out.
struct ResolvedPalette {

    let interaction: Color
    let hoverStroke: Color
    let selectionStroke: Color
    let focusRing: Color
    let actionHoverFill: Color
    let tabHoverFill: Color
    let destructive: Color
    let success: Color
    let warning: Color
    let onAccent: Color

    // The card's own row of hover-action icon buttons. See `AppTheme`'s own
    // doc comments on these three for the rationale.
    let cardActionFill: Color
    let cardActionIcon: Color
    let cardActionDestructiveIcon: Color

    // M11 - one component set with full interaction states.
    let buttonPrimaryFill: Color
    let buttonPrimaryText: Color
    let buttonPrimaryHoverFill: Color
    let buttonPrimaryPressedFill: Color
    let buttonSecondaryFill: Color
    let buttonSecondaryText: Color
    let buttonSecondaryBorder: Color
    let buttonSecondaryHoverFill: Color
    let buttonSecondaryPressedFill: Color
    let buttonGhostText: Color
    let buttonGhostHoverFill: Color
    let buttonGhostPressedFill: Color
    let link: Color
    let linkHover: Color
    let linkPressed: Color
    let controlDisabledFill: Color
    let controlDisabledText: Color

    /// Type tints, pre-tuned for the grounds cards are actually painted on.
    ///
    /// `tint(for:on:)` runs its own contrast search per card, per kind, per
    /// background. Three grounds times eleven kinds is thirty-three answers,
    /// and a list of thirty rows asks for them thirty times a frame.
    let tints: [TintKey: Color]

    /// `accentText(on:)`, `text(on:)`, `secondaryText(on:)` and
    /// `tertiaryText(on:)`, pre-tuned for the same fixed set of grounds.
    ///
    /// These four were the ones `tints` did not cover, and a row calls several
    /// of them: a list row alone reads `text(on:)` once and `tertiaryText(on:)`
    /// up to six times, per row, per render. Each miss was a fresh
    /// `Color` -> `NSColor` -> hex -> `NSColor` round trip through
    /// `ColorTuner.adjust`, which is exactly the cost `ResolvedPalette`
    /// exists to pay once instead of per read.
    let accentTextByGround: [Color: Color]
    let textByGround: [Color: Color]
    let secondaryTextByGround: [Color: Color]
    let tertiaryTextByGround: [Color: Color]

    /// `chipColors(for:on:)`, pre-tuned for the same fixed grounds - the
    /// default-icon chip a row draws when an item has no richer preview.
    let chipColorsByKind: [TintKey: (fill: Color, foreground: Color)]

    /// The one accent-based chip a card's own tag row draws, resolved once
    /// rather than on every card that carries a tag.
    let accentChipOnCard: (fill: Color, foreground: Color)

    struct TintKey: Hashable {
        let kind: String
        let ground: Color
    }

    /// The grounds a card is ever drawn on.
    static func grounds(of theme: AppTheme) -> [Color] {
        [theme.cardBackground, theme.cardHoverBackground, theme.selectedBackground,
         theme.panelBackground, theme.surfaceBackground]
    }

    init(_ theme: AppTheme) {
        interaction = theme.interactionOverride ?? theme.accent
        let base = interaction

        hoverStroke = theme.hoverStrokeOverride
            ?? AppTheme.readable(base,
                                 onAll: [theme.cardBackground, theme.cardHoverBackground],
                                 ratio: ThemeRules.Level.indicator.ratio)
        selectionStroke = theme.selectionStrokeOverride
            ?? AppTheme.readable(base,
                                 onAll: [theme.cardBackground, theme.selectedBackground],
                                 ratio: ThemeRules.Level.indicator.ratio)
        focusRing = theme.focusRingOverride ?? hoverStroke
        actionHoverFill = theme.actionHoverFillOverride ?? base.opacity(0.18)
        tabHoverFill = theme.tabHoverFillOverride ?? actionHoverFill

        let statusGrounds = [theme.cardBackground, theme.cardHoverBackground,
                             theme.selectedBackground]
        destructive = theme.destructiveOverride
            ?? AppTheme.derivedStatusColor(hex: "#E5484D", onAll: statusGrounds)
        success = theme.successOverride
            ?? AppTheme.derivedStatusColor(hex: "#30A46C", onAll: statusGrounds)
        warning = theme.warningOverride
            ?? AppTheme.derivedStatusColor(hex: "#F5A524", onAll: statusGrounds)

        onAccent = AppTheme.computedOnAccent(theme.accent)

        // Card action buttons. `theme` here carries none of these as computed
        // properties (it is the palette-less copy `prepared()` builds
        // against), so the fill is worked out the same way `AppTheme.
        // cardActionFill` would, then each icon is tuned against it and
        // against that same fill with ITS OWN hover wash composited on top -
        // the accent tint for the ordinary icons, `destructive`'s own tint
        // for the delete icon - matching the two different stacks
        // `IconButtonChrome.highlightFill` actually paints.
        let cardActionFillValue = theme.cardActionFillOverride
            ?? AppTheme.derivedCardActionFill(theme)
        cardActionFill = cardActionFillValue
        let cardActionHoverGround = AppTheme.composited(actionHoverFill, over: cardActionFillValue)
        let cardActionDestructiveHoverGround = AppTheme.composited(destructive.opacity(0.18),
                                                                    over: cardActionFillValue)
        cardActionIcon = theme.cardActionIconOverride
            ?? AppTheme.readableInPolarity(theme.textPrimary, isDark: theme.isDark,
                                           onAll: [cardActionFillValue, cardActionHoverGround],
                                           ratio: ThemeRules.Level.largeText.ratio)
        cardActionDestructiveIcon = theme.cardActionDestructiveIconOverride
            ?? AppTheme.readableInPolarity(destructive, isDark: theme.isDark,
                                           onAll: [cardActionFillValue, cardActionDestructiveHoverGround],
                                           ratio: ThemeRules.Level.largeText.ratio)

        // M11 - one component set with full interaction states. `theme` here
        // is the palette-less copy `prepared()` builds against, so reading
        // its overrides directly (rather than its computed properties) keeps
        // this block independent of that detail, the same as every block above.
        buttonPrimaryFill = theme.buttonPrimaryFillOverride ?? theme.accent
        buttonPrimaryText = theme.buttonPrimaryTextOverride
            ?? AppTheme.computedOnAccent(buttonPrimaryFill)
        buttonPrimaryHoverFill = theme.buttonPrimaryHoverFillOverride
            ?? AppTheme.stateLayerKeepingReadable(buttonPrimaryText, over: buttonPrimaryFill,
                                                  opacity: 0.08, keeping: buttonPrimaryText)
        buttonPrimaryPressedFill = theme.buttonPrimaryPressedFillOverride
            ?? AppTheme.stateLayerKeepingReadable(buttonPrimaryText, over: buttonPrimaryFill,
                                                  opacity: 0.18, keeping: buttonPrimaryText)

        buttonSecondaryFill = theme.buttonSecondaryFillOverride ?? theme.surfaceBackground
        buttonSecondaryText = theme.buttonSecondaryTextOverride
            ?? AppTheme.tuned(theme.textPrimary, on: buttonSecondaryFill, to: ThemeRules.Level.body.ratio)
        buttonSecondaryBorder = theme.buttonSecondaryBorderOverride ?? theme.border
        buttonSecondaryHoverFill = theme.buttonSecondaryHoverFillOverride
            ?? AppTheme.stateLayerKeepingReadable(base, over: buttonSecondaryFill,
                                                  opacity: 0.08, keeping: buttonSecondaryText)
        buttonSecondaryPressedFill = theme.buttonSecondaryPressedFillOverride
            ?? AppTheme.stateLayerKeepingReadable(base, over: buttonSecondaryFill,
                                                  opacity: 0.16, keeping: buttonSecondaryText)

        buttonGhostText = theme.buttonGhostTextOverride
            ?? AppTheme.tuned(theme.textSecondary, on: theme.cardBackground, to: ThemeRules.Level.body.ratio)
        buttonGhostHoverFill = theme.buttonGhostHoverFillOverride
            ?? AppTheme.stateLayerKeepingReadable(base, over: theme.cardBackground,
                                                  opacity: 0.18, keeping: theme.textPrimary)
        buttonGhostPressedFill = theme.buttonGhostPressedFillOverride
            ?? AppTheme.stateLayerKeepingReadable(base, over: theme.cardBackground,
                                                  opacity: 0.24, keeping: theme.textPrimary)

        let linkGrounds = [theme.cardBackground, theme.panelBackground,
                           theme.surfaceBackground, theme.cardHoverBackground]
        link = theme.linkOverride
            ?? AppTheme.readable(theme.accent, onAll: linkGrounds, ratio: ThemeRules.Level.body.ratio)
        linkHover = theme.linkHoverOverride
            ?? AppTheme.readable(AppTheme.mixed(link, towardWhite: !theme.isDark, by: 0.16),
                                 onAll: linkGrounds, ratio: ThemeRules.Level.body.ratio)
        linkPressed = theme.linkPressedOverride
            ?? AppTheme.readable(AppTheme.mixed(link, towardWhite: !theme.isDark, by: 0.32),
                                 onAll: linkGrounds, ratio: ThemeRules.Level.body.ratio)

        controlDisabledFill = theme.controlDisabledFillOverride ?? theme.surfaceBackground
        controlDisabledText = theme.controlDisabledTextOverride
            ?? AppTheme.readable(theme.textTertiary, onAll: [controlDisabledFill],
                                 ratio: ThemeRules.Level.decorative.ratio)

        var table: [TintKey: Color] = [:]
        for ground in Self.grounds(of: theme) {
            for kind in ItemKind.allCases {
                let key = TintKey(kind: kind.rawValue, ground: ground)
                if table[key] != nil { continue }
                table[key] = theme.typeTintOverrides[kind.rawValue]
                    ?? AppTheme.tuned(theme.baseTint(for: kind), on: ground,
                                      to: ThemeRules.Level.body.ratio)
            }
        }
        tints = table

        // Same shape as `tints` above, for the four "readable text on a
        // ground" answers a row reaches for by name instead of by kind.
        var accentTextTable: [Color: Color] = [:]
        var textTable: [Color: Color] = [:]
        var secondaryTextTable: [Color: Color] = [:]
        var tertiaryTextTable: [Color: Color] = [:]
        for ground in Self.grounds(of: theme) {
            accentTextTable[ground] = theme.accentTextOverride
                ?? AppTheme.tuned(theme.accent, on: ground, to: ThemeRules.Level.body.ratio)
            textTable[ground] = (theme.selectionTextOverride.flatMap { override in
                    ground == theme.selectedBackground ? override : nil
                })
                ?? AppTheme.tuned(theme.textPrimary, on: ground, to: ThemeRules.Level.body.ratio)
            secondaryTextTable[ground] =
                AppTheme.tuned(theme.textSecondary, on: ground, to: ThemeRules.Level.body.ratio)
            tertiaryTextTable[ground] =
                AppTheme.tuned(theme.textTertiary, on: ground, to: ThemeRules.Level.body.ratio)
        }
        accentTextByGround = accentTextTable
        textByGround = textTable
        secondaryTextByGround = secondaryTextTable
        tertiaryTextByGround = tertiaryTextTable

        // The default-icon chip is always `chipColors(tint(for:on:), on:)`, so
        // it can be keyed exactly like `tints` and built from it directly.
        var chipTable: [TintKey: (fill: Color, foreground: Color)] = [:]
        for (key, tint) in table {
            chipTable[key] = AppTheme.chipColors(tint, on: key.ground)
        }
        chipColorsByKind = chipTable

        accentChipOnCard = AppTheme.chipColors(theme.accent, on: theme.cardBackground)
    }
}

/// Deliberately invisible to equality and hashing.
///
/// The palette is *derived* from the theme, so two themes that are equal always
/// resolve to the same palette, and one that carries a cached palette must
/// still compare equal to the same theme without one. Letting the cache take
/// part in equality would make `theme != theme.prepared()`, which would break
/// every place that compares a theme to decide whether anything changed.
extension ResolvedPalette: Equatable, Hashable {
    static func == (lhs: ResolvedPalette, rhs: ResolvedPalette) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}
