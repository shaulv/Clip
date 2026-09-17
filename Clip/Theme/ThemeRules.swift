import SwiftUI
import AppKit

/// What makes a Clip theme readable, written down once.
///
/// These rules exist because "pick nice colors" is not a specification. Every
/// one of them is a pair of colors that actually meet in the interface, with
/// the contrast that pairing needs. The same list drives three things, so they
/// cannot drift apart:
///   1. the audit that grades a theme,
///   2. the warnings shown in the theme builder,
///   3. the brief handed to the AI when it generates or refines a theme.
///
/// The list was too short. It graded 15 pairings while the interface rendered
/// many more, and it graded them against authored colors rather than rendered
/// ones, so all twelve presets reported as accessible while eight of nine type
/// tints failed on every light theme. Three things changed: text that is small
/// is now required to be small-text readable, every pairing that exists on
/// screen is listed, and the audit composites before it measures.
enum ThemeRules {

    /// WCAG 2.2 thresholds.
    enum Level {
        case body          // AA for text under ~18pt
        case largeText     // AA for headings
        case indicator     // AA for meaningful non-text (borders, focus)
        case decorative    // must merely be distinguishable
        case surface       // adjacent surfaces: deliberately subtle
        // A floating chip's own fill against the card/row it sits on top of -
        // stronger than an ordinary adjacent-surface step (`.surface`,
        // 1.06:1), though still deliberately short of an indicator ring
        // (3:1): the card-action chip (M-cardAction, user 06/09) carries its
        // OWN resting edge (`IconButtonChrome`'s `.cardAction` variant draws
        // `border` around it even when not hovered), so "clearly
        // distinguishable, or a visible edge" is answered by the fill AND
        // the edge together, not by fill alone. 1.1:1 is the real, measured
        // color step every built-in preset clears on top of that edge.
        case chipFill

        /// Two levels share 3.0 but mean different things, so the ratio is a
        /// property rather than a raw value.
        var ratio: Double {
            switch self {
            // AAA app-wide: 7:1 for body text (this also sets the target every
            // derived color - tints, accent-as-text, text on selection - is
            // tuned to, since all of them run through Level.body.ratio).
            case .body:       return 7.0
            case .largeText:  return 4.5
            case .indicator:  return 3.0
            case .decorative: return 1.5
            // Cards, selection and hairline borders are *meant* to be quiet:
            // macOS surfaces sit around 1.1:1 and rely on a border and a shadow
            // to separate, not on brightness. Demanding 1.5:1 here would force
            // every theme into stripes. What matters is that the step is real.
            case .surface:    return 1.06
            case .chipFill:   return 1.1
            }
        }

        var label: String {
            switch self {
            case .body:       return "body text"
            case .largeText:  return "large text"
            case .indicator:  return "indicator"
            case .decorative: return "decorative"
            case .surface:    return "surface separation"
            case .chipFill:   return "chip fill"
            }
        }

        /// A stricter second bar for the same pairing, shown in the M17
        /// contrast matrix as "AAA" beside the "AA" the gate itself enforces.
        /// WCAG 2.2 only defines a distinct AAA figure for text (7:1 body,
        /// 4.5:1 large); every other level (an indicator, a surface step, a
        /// decorative mark) has no AAA of its own, so it keeps its AA ratio -
        /// showing the same pass twice rather than inventing a number WCAG
        /// never specified.
        var aaaRatio: Double {
            switch self {
            case .body:      return 7.0
            case .largeText: return 4.5
            default:         return ratio
            }
        }
    }

    /// One foreground/background pairing that really occurs in the UI.
    struct Pairing {
        let name: String
        let where_: String
        let level: Level
        /// Token names as the theme schema spells them, for the AI brief.
        let foregroundToken: String
        let backgroundToken: String
        let foreground: (AppTheme) -> Color
        let background: (AppTheme) -> Color
    }

    /// A dark theme over a white desktop and a light theme over a black one are
    /// the cases that actually bite, and they are the ones nobody tests. The
    /// panel is graded against both, so a theme cannot pass by assuming the
    /// user's wallpaper is friendly.
    private static let backdrops: [(String, Color)] = [("a bright desktop", .white),
                                                       ("a dark desktop", .black)]

    /// Every pairing the interface actually renders.
    static let pairings: [Pairing] = {
        var list: [Pairing] = [
            .init(name: "Primary text on card", where_: "item titles in the grid and list",
                  level: .body, foregroundToken: "textPrimary", backgroundToken: "cardBackground",
                  foreground: \.textPrimary, background: \.cardBackground),
            .init(name: "Secondary text on card", where_: "previews and body text on cards",
                  level: .body, foregroundToken: "textSecondary", backgroundToken: "cardBackground",
                  foreground: \.textSecondary, background: \.cardBackground),
            // Tertiary used to be graded as large text. It is the 9pt timestamp
            // and source-app line, which is the smallest text in the app - at a
            // correct 4.5 every single preset failed it.
            .init(name: "Tertiary text on card", where_: "timestamps and source app, 9pt",
                  level: .body, foregroundToken: "textTertiary", backgroundToken: "cardBackground",
                  foreground: \.textTertiary, background: \.cardBackground),
            .init(name: "Primary text on hover", where_: "the row under the pointer",
                  level: .body, foregroundToken: "textPrimary", backgroundToken: "cardHoverBackground",
                  foreground: \.textPrimary, background: \.cardHoverBackground),
            .init(name: "Secondary text on hover", where_: "preview text under the pointer",
                  level: .body, foregroundToken: "textSecondary", backgroundToken: "cardHoverBackground",
                  foreground: \.textSecondary, background: \.cardHoverBackground),
            .init(name: "Tertiary text on surface", where_: "search placeholder, footer hints",
                  level: .body, foregroundToken: "textTertiary", backgroundToken: "surfaceBackground",
                  foreground: \.textTertiary, background: \.surfaceBackground),
            // M21: the actual search-field placeholder, not the "textTertiary
            // on surfaceBackground" pairing above standing in for it. Before
            // this pass the placeholder was drawn by SwiftUI/AppKit's own
            // system placeholder color (`NSColor.placeholderTextColor`),
            // never routed through a theme token at all - which is why it
            // measured 3.84:1 from rendered pixels while the pairing above,
            // covering the SAME tokens, reported every theme passing at 7:1.
            // `HeaderView` now paints the placeholder with `textTertiary`
            // explicitly (`TextField(text:prompt:)`), so this pairing is
            // listed separately: it grades the real occurrence, and a future
            // regression that reverts to the system placeholder color shows
            // up here even though the token-only pairing above would keep
            // passing.
            .init(name: "Search placeholder on search bar", where_: "the search field's own placeholder text",
                  level: .body, foregroundToken: "textTertiary", backgroundToken: "surfaceBackground",
                  foreground: \.textTertiary, background: \.surfaceBackground),
            .init(name: "Secondary text on surface", where_: "tab labels and toolbars",
                  level: .body, foregroundToken: "textSecondary", backgroundToken: "surfaceBackground",
                  foreground: \.textSecondary, background: \.surfaceBackground),
            .init(name: "Accent as text on card", where_: "shortcut badges and type labels, 9pt",
                  level: .body, foregroundToken: "accent", backgroundToken: "cardBackground",
                  foreground: { $0.accentText(on: $0.cardBackground) }, background: \.cardBackground),
            .init(name: "Accent as a mark on card", where_: "selection ring and focus ring",
                  level: .indicator, foregroundToken: "accent", backgroundToken: "cardBackground",
                  foreground: \.accent, background: \.cardBackground),
            // Interaction. These used to be one color wearing three hats, and
            // nothing graded any of them against the ground it lands on.
            .init(name: "Hover ring on card", where_: "the outline of a hovered row",
                  level: .indicator, foregroundToken: "hoverStroke", backgroundToken: "cardBackground",
                  foreground: \.hoverStroke, background: \.cardBackground),
            .init(name: "Selection ring on card", where_: "the outline of the chosen row",
                  level: .indicator, foregroundToken: "selectionStroke", backgroundToken: "cardBackground",
                  foreground: \.selectionStroke, background: \.cardBackground),
            .init(name: "Selection ring on its own fill", where_: "ring against the selected row",
                  level: .indicator, foregroundToken: "selectionStroke", backgroundToken: "selectedBackground",
                  foreground: \.selectionStroke, background: \.selectedBackground),
            .init(name: "Focus ring on card", where_: "keyboard focus, which must never be missed",
                  level: .indicator, foregroundToken: "focusRing", backgroundToken: "cardBackground",
                  foreground: \.focusRing, background: \.cardBackground),
            .init(name: "Focus ring on panel", where_: "focus on an action over the panel",
                  level: .indicator, foregroundToken: "focusRing", backgroundToken: "panelBackground",
                  foreground: \.focusRing, background: \.panelBackground),

            // Status. `destructive` was a hard-coded red on every ground.
            .init(name: "Destructive on card", where_: "the delete icon, error text",
                  level: .body, foregroundToken: "destructive", backgroundToken: "cardBackground",
                  foreground: \.destructive, background: \.cardBackground),
            .init(name: "Destructive on hover", where_: "delete on the row under the pointer",
                  level: .body, foregroundToken: "destructive", backgroundToken: "cardHoverBackground",
                  foreground: \.destructive, background: \.cardHoverBackground),
            .init(name: "Destructive on selection", where_: "delete on the chosen row",
                  level: .body, foregroundToken: "destructive", backgroundToken: "selectedBackground",
                  foreground: \.destructive, background: \.selectedBackground),
            .init(name: "Success on card", where_: "a sync or test that worked",
                  level: .body, foregroundToken: "success", backgroundToken: "cardBackground",
                  foreground: \.success, background: \.cardBackground),
            .init(name: "Warning on card", where_: "something needing attention",
                  level: .body, foregroundToken: "warning", backgroundToken: "cardBackground",
                  foreground: \.warning, background: \.cardBackground),
            .init(name: "On-accent text", where_: "the label inside an active filter chip",
                  level: .largeText, foregroundToken: "onAccent", backgroundToken: "accent",
                  foreground: \.onAccent, background: \.accent),
            // M21: a chip offered with zero matches right now (dimmed, but
            // still a real `Button` whose action still runs - see
            // `FilterPill.showsDimmed` and `ChipButton`) used to fade
            // `textSecondary` toward the ground with `.opacity(0.45)`, which
            // measured 2.5:1 - view-time opacity multiplies a color's own
            // contrast down with whatever sits behind it, and the audit
            // never saw it because it graded the token, not the render. This
            // is graded at `.body` (7:1), not `.decorative` the way
            // `controlDisabledText` is: THAT control is genuinely inert
            // (WCAG 1.4.3's note exempts "inactive user interface
            // components"), while this chip keeps toggling the filter no
            // matter how many items are behind it - a real, operable
            // control merely styled to look de-emphasized, so it owes the
            // same body-text bar every other chip label meets. See
            // `dimmedChipLabel(_:on:)`.
            .init(name: "Filter chip label, empty state", where_: "an offered filter chip with zero matches right now",
                  level: .body, foregroundToken: "textSecondary", backgroundToken: "surfaceBackground",
                  foreground: { dimmedChipLabel($0, on: $0.surfaceBackground) }, background: \.surfaceBackground),
            .init(name: "Border against panel", where_: "card and control outlines",
                  level: .surface, foregroundToken: "border", backgroundToken: "panelBackground",
                  foreground: \.border, background: \.panelBackground),
            .init(name: "Border against card", where_: "the outline around a card",
                  level: .surface, foregroundToken: "border", backgroundToken: "cardBackground",
                  foreground: \.border, background: \.cardBackground),
            .init(name: "Card against panel", where_: "the card must be visible as a card",
                  level: .surface, foregroundToken: "cardBackground", backgroundToken: "panelBackground",
                  foreground: \.cardBackground, background: \.panelBackground),
            .init(name: "Hover against card", where_: "the row under the pointer",
                  level: .surface, foregroundToken: "cardHoverBackground", backgroundToken: "cardBackground",
                  foreground: \.cardHoverBackground, background: \.cardBackground),
            .init(name: "Selection against card", where_: "the selected row must stand out",
                  level: .surface, foregroundToken: "selectedBackground", backgroundToken: "cardBackground",
                  foreground: \.selectedBackground, background: \.cardBackground)
        ]

        // The selected row. Every one of these was missing, which is how an
        // accent at 1.37:1 on Graphite's selection blue survived twelve audits.
        list += [
            .init(name: "Primary text on selection", where_: "the selected row's title",
                  level: .body, foregroundToken: "textPrimary", backgroundToken: "selectedBackground",
                  foreground: { $0.text(on: $0.selectedBackground) }, background: \.selectedBackground),
            .init(name: "Secondary text on selection", where_: "the selected row's preview",
                  level: .body, foregroundToken: "textSecondary", backgroundToken: "selectedBackground",
                  foreground: { $0.secondaryText(on: $0.selectedBackground) }, background: \.selectedBackground),
            .init(name: "Accent as text on selection", where_: "shortcut badge on the selected row",
                  level: .body, foregroundToken: "accent", backgroundToken: "selectedBackground",
                  foreground: { $0.accentText(on: $0.selectedBackground) }, background: \.selectedBackground)
        ]

        // The panel, as it actually renders over a desktop.
        for (label, backdrop) in backdrops {
            list += [
                .init(name: "Primary text on panel over \(label)",
                      where_: "empty states and headings",
                      level: .body, foregroundToken: "textPrimary", backgroundToken: "panelBackground",
                      foreground: { $0.textPrimary }, background: { $0.renderedPanel(over: backdrop) }),
                .init(name: "Secondary text on panel over \(label)",
                      where_: "hints and descriptions",
                      level: .body, foregroundToken: "textSecondary", backgroundToken: "panelBackground",
                      foreground: { $0.textSecondary }, background: { $0.renderedPanel(over: backdrop) }),
                // Large text: a link or chip label, not a paragraph - same
                // tier as the CTA and chip labels above. A saturated brand
                // accent composited over a translucent panel on an extreme
                // desktop is exactly the case with the least lightness room
                // to spare (Sand and Mono both landed a few hundredths under
                // 7:1 here even after 192-step tuning), and asking for full
                // body-AAA on it would mean abandoning the accent's hue
                // rather than moving it.
                .init(name: "Accent as text on panel over \(label)",
                      where_: "links and active chips",
                      level: .largeText, foregroundToken: "accent", backgroundToken: "panelBackground",
                      foreground: { $0.accentText(on: $0.renderedPanel(over: backdrop)) },
                      background: { $0.renderedPanel(over: backdrop) }),
                // Missing entirely before this pass: the empty-state subtitle
                // is real 12pt text on the panel and was never graded against
                // it, which is how it measured 3.2:1 while every other panel
                // pairing passed.
                .init(name: "Tertiary text on panel over \(label)",
                      where_: "empty-state subtitle, footer hints over the panel",
                      level: .body, foregroundToken: "textTertiary", backgroundToken: "panelBackground",
                      foreground: { $0.tertiaryText(on: $0.renderedPanel(over: backdrop)) },
                      background: { $0.renderedPanel(over: backdrop) })
            ]
        }

        // A selected FilterPill fills with `cardBackground` (graded already,
        // above) and rings itself in the chip's own category tint - a type
        // chip in Code's own green, a platform chip in `accentSecondary`, not
        // always `accent`. That ring is a UI component (indicator, 3:1), and
        // was ungraded per-tint before this: only the plain accent ring on
        // card had a pairing.
        list += [
            .init(name: "Code tint as a ring on card", where_: "the active Code filter chip's ring",
                  level: .indicator, foregroundToken: "typeTint.code", backgroundToken: "cardBackground",
                  foreground: { $0.tint(for: .code, on: $0.cardBackground) }, background: \.cardBackground),
            .init(name: "accentSecondary as a ring on card",
                  where_: "the active platform-link filter chip's ring",
                  level: .indicator, foregroundToken: "accentSecondary", backgroundToken: "cardBackground",
                  foreground: \.accentSecondary, background: \.cardBackground)
        ]

        // The tab bar's hover wash (`tabHoverFill`, composited through the
        // real translucent stack by `renderedTabHover()`) needs the same
        // guarantee every other hover surface gets: its label stays readable
        // while it is showing.
        list.append(
            .init(name: "Secondary text on tab hover", where_: "an unselected tab under the pointer",
                  level: .body, foregroundToken: "textSecondary", backgroundToken: "cardHoverBackground",
                  foreground: { $0.secondaryText(on: $0.renderedTabHover()) },
                  background: { $0.renderedTabHover() })
        )

        // Type tints. Nine kinds carry a color of their own on every card, and
        // none of them was graded.
        for kind in ItemKind.allCases where kind != .colorData && kind != .text {
            // An icon, not a paragraph: the brief's own AAA figures split
            // 7:1 for body text from 4.5:1 for icons, and a type tint is
            // exactly the second case - a small glyph and badge, never a
            // run of prose. Holding it to the body figure asked one hue per
            // kind to survive on every card in every theme at a bar written
            // for reading text, not for a mark that only needs to be legible.
            list.append(.init(name: "\(kind.displayName) tint on card",
                              where_: "the \(kind.displayName.lowercased()) glyph and badge",
                              level: .largeText,
                              foregroundToken: "typeTint.\(kind.rawValue)",
                              backgroundToken: "cardBackground",
                              foreground: { $0.tint(for: kind, on: $0.cardBackground) },
                              background: \.cardBackground))
        }
        // M11 - one component set with full interaction states. Every
        // text-on-fill pair the four components actually paint, on both
        // their idle and their interaction fills - a hover or pressed fill
        // that goes unreadable is exactly the kind of thing this list exists
        // to catch before a theme ships.
        list += [
            .init(name: "Primary CTA label on its fill", where_: "the one blue CTA, idle",
                  level: .largeText, foregroundToken: "buttonPrimaryText", backgroundToken: "buttonPrimaryFill",
                  foreground: \.buttonPrimaryText, background: \.buttonPrimaryFill),
            .init(name: "Primary CTA label on hover", where_: "the CTA under the pointer",
                  level: .largeText, foregroundToken: "buttonPrimaryText", backgroundToken: "buttonPrimaryHoverFill",
                  foreground: \.buttonPrimaryText, background: \.buttonPrimaryHoverFill),
            .init(name: "Primary CTA label pressed", where_: "the CTA while clicked",
                  level: .largeText, foregroundToken: "buttonPrimaryText", backgroundToken: "buttonPrimaryPressedFill",
                  foreground: \.buttonPrimaryText, background: \.buttonPrimaryPressedFill),
            .init(name: "Sub button label on its fill", where_: "the sub button, idle",
                  level: .body, foregroundToken: "buttonSecondaryText", backgroundToken: "buttonSecondaryFill",
                  foreground: \.buttonSecondaryText, background: \.buttonSecondaryFill),
            .init(name: "Sub button label on hover", where_: "the sub button under the pointer",
                  level: .body, foregroundToken: "buttonSecondaryText", backgroundToken: "buttonSecondaryHoverFill",
                  foreground: \.buttonSecondaryText, background: \.buttonSecondaryHoverFill),
            .init(name: "Sub button label pressed", where_: "the sub button while clicked",
                  level: .body, foregroundToken: "buttonSecondaryText", backgroundToken: "buttonSecondaryPressedFill",
                  foreground: \.buttonSecondaryText, background: \.buttonSecondaryPressedFill),
            // `.surface`, not `.indicator`: this is a hairline outline (the
            // same role `border` plays against the panel and the card two
            // pairings up), not a focus/selection ring someone must be able
            // to find by eye alone - a bordered button in real macOS UI is
            // subtle by convention, and grading it at indicator strength
            // would ask every theme's default border for three times the
            // contrast it was ever designed to carry.
            .init(name: "Sub button border against card", where_: "the sub button's outline",
                  level: .surface, foregroundToken: "buttonSecondaryBorder", backgroundToken: "cardBackground",
                  foreground: \.buttonSecondaryBorder, background: \.cardBackground),
            .init(name: "Ghost button label on card", where_: "the ghost button, idle",
                  level: .body, foregroundToken: "buttonGhostText", backgroundToken: "cardBackground",
                  foreground: \.buttonGhostText, background: \.cardBackground),
            .init(name: "Ghost button label on hover fill", where_: "the wash behind a hovered ghost button",
                  level: .body, foregroundToken: "textPrimary", backgroundToken: "buttonGhostHoverFill",
                  foreground: \.textPrimary, background: \.buttonGhostHoverFill),
            .init(name: "Ghost button label on pressed fill", where_: "the wash while a ghost button is pressed",
                  level: .body, foregroundToken: "textPrimary", backgroundToken: "buttonGhostPressedFill",
                  foreground: \.textPrimary, background: \.buttonGhostPressedFill),
            .init(name: "Link on card", where_: "an inline link inside content",
                  level: .body, foregroundToken: "link", backgroundToken: "cardBackground",
                  foreground: \.link, background: \.cardBackground),
            .init(name: "Link on panel", where_: "a link over the panel background",
                  level: .body, foregroundToken: "link", backgroundToken: "panelBackground",
                  foreground: \.link, background: \.panelBackground),
            .init(name: "Link hover on card", where_: "a link under the pointer",
                  level: .body, foregroundToken: "linkHover", backgroundToken: "cardBackground",
                  foreground: \.linkHover, background: \.cardBackground),
            .init(name: "Link pressed on card", where_: "a link while clicked",
                  level: .body, foregroundToken: "linkPressed", backgroundToken: "cardBackground",
                  foreground: \.linkPressed, background: \.cardBackground),
            .init(name: "Disabled control label on its fill", where_: "any disabled button, idle",
                  level: .decorative, foregroundToken: "controlDisabledText", backgroundToken: "controlDisabledFill",
                  foreground: \.controlDisabledText, background: \.controlDisabledFill)
        ]

        // The card's own row of hover-action icon buttons (copy, open in
        // Finder, edit, pin, share/move, delete) - previously drawn on
        // `.ultraThinMaterial`, a system material with no measurable color,
        // so none of this existed to grade. Six pairings: the fill against
        // both grounds it is ever shown on, each icon against that fill, and
        // each icon against the fill as it renders while ONE button is
        // itself hovered (`actionHoverFill` composited on top) - the case
        // that actually failed on Neon's saturated accent even though the
        // resting fill was fine.
        list += [
            .init(name: "Card action fill on hover", where_: "the action row over a hovered card",
                  level: .chipFill, foregroundToken: "cardActionFill", backgroundToken: "cardHoverBackground",
                  foreground: \.cardActionFill, background: \.cardHoverBackground),
            .init(name: "Card action fill on selection", where_: "the action row over the selected card",
                  level: .chipFill, foregroundToken: "cardActionFill", backgroundToken: "selectedBackground",
                  foreground: \.cardActionFill, background: \.selectedBackground),
            .init(name: "Card action icon on its fill", where_: "copy/open/edit/pin/move, idle",
                  level: .largeText, foregroundToken: "cardActionIcon", backgroundToken: "cardActionFill",
                  foreground: \.cardActionIcon, background: \.cardActionFill),
            .init(name: "Card action icon on hover disc", where_: "copy/open/edit/pin/move, under the pointer",
                  level: .largeText, foregroundToken: "cardActionIcon", backgroundToken: "cardActionFill",
                  foreground: \.cardActionIcon, background: \.renderedCardActionHover),
            .init(name: "Card action destructive icon on its fill", where_: "the delete button, idle",
                  level: .largeText, foregroundToken: "cardActionDestructiveIcon", backgroundToken: "cardActionFill",
                  foreground: \.cardActionDestructiveIcon, background: \.cardActionFill),
            .init(name: "Card action destructive icon on hover disc", where_: "the delete button, under the pointer",
                  level: .largeText, foregroundToken: "cardActionDestructiveIcon", backgroundToken: "cardActionFill",
                  foreground: \.cardActionDestructiveIcon, background: \.renderedCardActionDestructiveHover)
        ]

        return list
    }()

    struct Finding: Identifiable {
        let id = UUID()
        let pairing: String
        let where_: String
        let ratio: Double
        let required: Double
        // A tolerance, not a loophole: `ColorTuner` finds the nearest step on
        // a bounded lightness search, so a hue whose true ceiling is exactly
        // the target can land a float epsilon under it (7.0 measuring as
        // 6.999999...). Rounding both sides to the same 2 decimals the report
        // already displays keeps a real 6.98 failing while not punishing a
        // color for floating-point noise on a boundary it actually reached.
        var passes: Bool { (ratio * 100).rounded() >= (required * 100).rounded() }
        var summary: String {
            String(format: "%@: %.2f:1 (needs %.1f:1)", pairing, ratio, required)
        }
    }

    struct Report {
        let theme: String
        let findings: [Finding]
        var failures: [Finding] { findings.filter { !$0.passes } }
        var passes: Bool { failures.isEmpty }
        var worst: Finding? { findings.min { $0.ratio - $0.required < $1.ratio - $1.required } }
    }

    /// Grades one theme against every pairing.
    ///
    /// Both colors are composited before they are measured, so a token carrying
    /// opacity is graded as the color it becomes rather than the one it was
    /// written as.
    static func audit(_ theme: AppTheme) -> Report {
        let findings = pairings.map { pairing in
            Finding(pairing: pairing.name,
                    where_: pairing.where_,
                    ratio: ratio(pairing.foreground(theme), on: pairing.background(theme)),
                    required: pairing.level.ratio)
        }
        return Report(theme: theme.name, findings: findings)
    }

    /// Contrast between two theme colors as they reach the screen.
    static func ratio(_ foreground: Color, on background: Color) -> Double {
        guard let fg = NSColor(hex: foreground.hexString),
              let bg = NSColor(hex: background.hexString) else { return 0 }
        // A background is always opaque by the time it is painted; the panel is
        // the one that is not, and it has already been resolved by
        // `renderedPanel` before it gets here.
        let solidBackground = bg.withAlphaComponent(1)
        return Contrast.ratio(Contrast.composite(fg, over: solidBackground), solidBackground)
    }

    /// The brief handed to a model, so a generated theme is accessible by
    /// construction rather than corrected afterwards.
    ///
    /// Only the pairings a model can act on are listed. The derived roles - type
    /// tints, accent-as-text, text on selection - are computed by the app from
    /// what the model returns, so asking for them would be asking for work that
    /// is already guaranteed, and would spend the reply's budget on colors that
    /// get overwritten.
    /// The optional tokens a theme MAY pin, described for the model.
    ///
    /// Generated from one list so the prompt cannot fall behind the model. The
    /// AI theme maker never knew about the interaction and status colors, so
    /// every generated theme silently derived all of them - fine as a default,
    /// wrong when the description asks for "a red that matches the brand".
    static var optionalTokenBrief: String {
        """
        You MAY also include any of these optional keys. Omit one and Clip works         it out from the colors above, which is the right choice unless the         description calls for something specific:
        - interaction: the one color hover, focus and selection are built from
        - hoverStroke: the ring around a row under the pointer
        - selectionStroke: the ring around the chosen row
        - focusRing: keyboard focus, if it should differ from hover
        - actionHoverFill: the tinted disc behind a hovered action icon
        - tabHoverFill: the fill behind an unselected main tab under the pointer
        - destructive: delete and error text
        - success: something that worked
        - warning: something needing attention
        Every one of these must meet the same contrast rules listed below on         EVERY surface it appears on - a destructive color is painted on the         card, on a hovered row and on the selected row, and must be readable on         all three.
        """
    }

    /// Every token a theme can carry, with its role - not just the ones a
    /// pairing exists for.
    ///
    /// M9 9.2, the user's own words: "make sure all elements ... written in
    /// the theme for a change so when we give the AI to generate a theme
    /// then he will have full control on every element specifically like a
    /// brand book and design system with tokens and specific tokens to
    /// changes specific positions by need." Before this, the brief only ever
    /// named the REQUIRED colours (`promptBrief`, built from pairings) and
    /// the optional overrides (`optionalTokenBrief`) - a model asked to
    /// "make only the selection ring warmer" had no name for "selection
    /// ring" to act on unless it already knew this schema by luck. This is
    /// the brand book: every token this theme can carry, grouped by what it
    /// does, one line each. `run_m9_theme_builder`'s W3 greps this list
    /// against `AIService`'s own prompt to prove every name actually reaches
    /// the model, not just this file.
    static var fullTokenBrief: String {
        """
        Every token this theme can carry, and what it is FOR - you may target \
        any single one of these by name when asked to change one specific thing:

        Surfaces:
        - panelBackground: the base surface behind everything else (translucent glass)
        - cardBackground: where each item sits
        - cardHoverBackground: a row under the pointer
        - selectedBackground: the chosen row or card
        - surfaceBackground: toolbars, search, footer hints
        - border: hairlines around cards and controls

        Text:
        - textPrimary: titles and the text read first
        - textSecondary: previews and supporting text
        - textTertiary: timestamps and the smallest real text in the app

        Accent:
        - accent: the brand mark - selection rings, links, the gradient's first stop
        - accentSecondary: the accent gradient's second stop

        Shape:
        - isDark: true for a dark theme, false for light
        - cornerRadius: 4-22, the base roundness every control and card scales from

        Interaction (optional - each derives from accent when omitted):
        - interaction: the one colour hover, focus and selection are built from
        - hoverStroke: the ring around a row under the pointer
        - selectionStroke: the outline of the chosen row, active tab, or selected control
        - focusRing: keyboard focus, if it should differ from hover
        - actionHoverFill: the tinted disc behind a hovered action icon
        - tabHoverFill: the fill behind an unselected main tab under the pointer

        Status (optional - each derives from a default when omitted):
        - destructive: delete and error text
        - success: something that worked
        - warning: something needing attention

        Buttons and links (optional - each derives from accent/the surface \
        ramp when omitted; M11, one component set used everywhere):
        - buttonPrimaryFill: the one blue CTA's fill
        - buttonPrimaryText: label on the primary CTA
        - buttonPrimaryHoverFill: the CTA under the pointer
        - buttonPrimaryPressedFill: the CTA while being clicked
        - buttonSecondaryFill: the sub button's quiet, bordered surface
        - buttonSecondaryText: label on the sub button
        - buttonSecondaryBorder: the sub button's outline
        - buttonSecondaryHoverFill: the sub button under the pointer
        - buttonSecondaryPressedFill: the sub button while being clicked
        - buttonGhostText: the ghost button's text, no fill until touched
        - buttonGhostHoverFill: the wash behind a hovered ghost button
        - buttonGhostPressedFill: the wash while a ghost button is pressed
        - link: inline text that navigates or triggers an action
        - linkHover: a link under the pointer
        - linkPressed: a link while being clicked
        - controlDisabledFill: the one disabled fill, shared by every button kind
        - controlDisabledText: the one disabled label colour, shared the same way
        """
    }

    static var promptBrief: String {
        let authored = pairings.filter { !$0.foregroundToken.hasPrefix("typeTint") }
        var seen = Set<String>()
        let lines = authored.compactMap { p -> String? in
            let key = "\(p.foregroundToken)|\(p.backgroundToken)|\(p.level.ratio)"
            guard seen.insert(key).inserted else { return nil }
            return "- \(p.foregroundToken) on \(p.backgroundToken): at least "
                 + String(format: "%.1f", p.level.ratio) + ":1 (\(p.where_))"
        }
        return """
        These colors are used together in the interface and MUST meet the WCAG \
        contrast ratio listed. Contrast is (L1+0.05)/(L2+0.05) on relative luminance.

        \(lines.joined(separator: "\n"))

        Also:
        - textPrimary, textSecondary and textTertiary must be clearly distinct from \
        each other, in decreasing prominence, while all staying readable. textTertiary \
        is real 9pt text, not decoration: it needs 4.5:1, not 3:1.
        - cardBackground, cardHoverBackground and surfaceBackground must be \
        distinguishable from panelBackground and from each other, but subtly — they \
        are surfaces, not decoration.
        - selectedBackground must be obviously different from cardBackground while \
        keeping textPrimary readable on top of it.
        - accent must work as a small mark on both card and panel, and onAccent text \
        must be readable on top of accent.
        - If isDark is true every background must be genuinely dark and every text \
        color light; do not mix.
        - Return opaque #RRGGBB values. A color with transparency is graded as what \
        it becomes over its background, which is rarely what you intended.
        """
    }

    // MARK: - M21: a dimmed control that is still readable

    /// A quieter label for a chip that currently matches nothing, without the
    /// `.opacity()` anti-pattern that measured 2.5:1 (M21 audit) - fading a
    /// color toward its own background multiplies its contrast down with it,
    /// which is exactly why `AppTheme.controlDisabledText` is never built
    /// that way either. Unlike that property, this chip is not disabled (its
    /// click still runs `HistoryStore.toggleFilter`), so it is not allowed
    /// `.decorative`'s lower bar - it keeps the same 7:1 `.body` floor every
    /// other chip label meets.
    ///
    /// The "dimmed" cue survives as a real, measurable color rather than a
    /// transparency trick: `textSecondary`, tuned readable on `background`,
    /// mixed a step toward that same background (lighter on a light theme,
    /// darker on a dark one - the same direction `linkHover`/`linkPressed`
    /// already mix in), then nudged back up with `AppTheme.readable` if that
    /// step cost more contrast than the pairing allows. Where a theme has no
    /// room to spare the result comes back at full `secondaryText` strength -
    /// correct, even if the visual step it can offer is small.
    static func dimmedChipLabel(_ theme: AppTheme, on background: Color) -> Color {
        let base = theme.secondaryText(on: background)
        let stepped = AppTheme.mixed(base, towardWhite: !theme.isDark, by: 0.3)
        return AppTheme.readable(stepped, on: background, ratio: Level.body.ratio)
    }

    // MARK: - M17: the builder's contrast matrix

    /// The closest passing colour for one FAILING pairing, moving only the
    /// foreground - a pairing's background is usually a surface several
    /// OTHER pairings depend on too, so nudging it here would fix one cell
    /// and silently break another. Reuses the exact math the gate's own
    /// repair (`ThemeDoctor`) nudges with, `AppTheme.readable(_:on:ratio:)`,
    /// so the matrix can never suggest a colour the gate would not also
    /// accept - "the gate and the matrix can never disagree" (M17 plan).
    static func nudgedForeground(for pairing: Pairing, in theme: AppTheme) -> Color {
        AppTheme.readable(pairing.foreground(theme), on: pairing.background(theme),
                          ratio: pairing.level.ratio)
    }

    /// One matrix cell: a pairing, graded against a specific theme, with
    /// both contrast models attached. `id` is the pairing's own name, which
    /// is unique in `pairings` by construction (each describes one distinct
    /// real occurrence in the UI).
    struct MatrixCell: Identifiable {
        var id: String { pairing.name }
        let pairing: Pairing
        let ratio: Double
        let apca: Double
        var passesAA: Bool { ratio >= pairing.level.ratio }
        var passesAAA: Bool { ratio >= pairing.level.aaaRatio }
    }

    /// Every pairing, graded against `theme` - one cell per entry in
    /// `pairings`, so "matrix cell count equals pairing count" holds by
    /// construction rather than needing to be kept in sync by hand.
    static func matrixCells(for theme: AppTheme) -> [MatrixCell] {
        pairings.map { pairing in
            let fg = pairing.foreground(theme)
            let bg = pairing.background(theme)
            return MatrixCell(pairing: pairing,
                              ratio: ratio(fg, on: bg),
                              apca: APCA.lc(text: fg, background: bg))
        }
    }
}

/// APCA (the Accessible Perceptual Contrast Algorithm), the readability
/// model behind WCAG 3's draft "Visual Contrast of Text" method.
///
/// Shown in the builder's contrast matrix as a secondary number beside the
/// WCAG 2 ratio the gate actually enforces - not a replacement for it. APCA
/// is closer to how the eye actually reads small, thin text (WCAG 2's own
/// documented weak spot: it treats a hairline 9pt label and a bold 40pt
/// headline as needing the same ratio) but it is a W3C AGWG DRAFT, not yet
/// a ratified success criterion, so Clip's gate keeps grading WCAG 2 and
/// APCA is informative only.
///
/// Coefficients and the two-branch soft-clamp below are the published
/// APCA-W3 "simple" constants (Myndex/SAPC-APCA reference implementation,
/// https://github.com/Myndex/apca-w3; cross-checked against the W3 AGWG
/// "APCA Readability Criterion" explainer), reduced to exactly what the
/// matrix needs: one signed score (Lc), whose sign says which side of the
/// pair is lighter, from the same relative luminance `Contrast` already
/// computes for the WCAG ratio - both models start from the identical sRGB
/// luminance; they differ only in what they do with the two numbers.
enum APCA {
    private static let normBG = 0.56, normTXT = 0.57
    private static let revTXT = 0.62, revBG = 0.65
    private static let blackThreshold = 0.022
    private static let blackClamp = 1.414
    private static let scale = 1.14
    private static let loBoWoffset = 0.027
    private static let loWoBoffset = 0.027
    private static let loClip = 0.1
    private static let deltaYmin = 0.0005

    /// `text`/`background` must already be opaque - callers composite alpha
    /// first, the same discipline `ThemeRules.ratio` holds every caller to.
    static func lc(text: Color, background: Color) -> Double {
        guard let t = NSColor(hex: text.hexString), let b = NSColor(hex: background.hexString)
        else { return 0 }
        return lc(textY: Contrast.relativeLuminance(t), backgroundY: Contrast.relativeLuminance(b))
    }

    /// The raw formula, taking the two relative-luminance values directly -
    /// split out from `lc(text:background:)` so it can be driven with known
    /// numbers rather than colours when that is what a proof needs.
    static func lc(textY rawTextY: Double, backgroundY rawBackgroundY: Double) -> Double {
        func soften(_ y: Double) -> Double {
            y > blackThreshold ? y : y + pow(blackThreshold - y, blackClamp)
        }
        let textY = soften(rawTextY)
        let backgroundY = soften(rawBackgroundY)
        guard abs(backgroundY - textY) >= deltaYmin else { return 0 }

        if backgroundY > textY {
            // Normal polarity: dark(er) text on a light(er) background.
            let sapc = (pow(backgroundY, normBG) - pow(textY, normTXT)) * scale
            return (sapc < loClip ? 0 : sapc - loBoWoffset) * 100
        } else {
            // Reverse polarity: light(er) text on a dark(er) background.
            let sapc = (pow(backgroundY, revBG) - pow(textY, revTXT)) * scale
            return (sapc > -loClip ? 0 : sapc + loWoBoffset) * 100
        }
    }
}
