import SwiftUI
import AppKit

/// Repairs a theme's authored colors until it passes.
///
/// The app derives the colors it can - type tints, accent-as-text, text on the
/// selected row - so those are right by construction. What it cannot derive is
/// the handful a theme actually authors: if a model returns a secondary text
/// color that is too close to the card, no amount of downstream cleverness
/// makes that pair readable, because both halves are the theme's own.
///
/// So those are measured and nudged here. It runs after the model has had its
/// own chance to fix the failures it was shown: a model that corrects its own
/// palette keeps its intent, and this is the floor underneath that, not a
/// replacement for it. Only lightness moves, so a repaired theme is still
/// recognisably the theme that was asked for.
enum ThemeDoctor {

    /// A repaired copy, or the original when nothing needed moving.
    static func repaired(_ theme: CustomTheme, depth: Int = 0) -> CustomTheme {
        var fixed = theme
        let body = ThemeRules.Level.body.ratio
        let surface = ThemeRules.Level.surface.ratio

        // The panel is translucent, so text on it is graded against what the
        // panel becomes over a bright desktop and over a dark one.
        let rendered = theme.appTheme
        let panels = [rendered.renderedPanel(over: .white).hexString,
                      rendered.renderedPanel(over: .black).hexString]
        let cards = [theme.cardBackground, theme.cardHoverBackground, theme.selectedBackground]
        let readingSurfaces = cards + [theme.surfaceBackground] + panels

        fixed.textPrimary = ColorTuner.adjust(theme.textPrimary, on: readingSurfaces, to: body)
        fixed.textSecondary = ColorTuner.adjust(theme.textSecondary, on: readingSurfaces, to: body)
        fixed.textTertiary = ColorTuner.adjust(theme.textTertiary,
                                               on: [theme.cardBackground, theme.surfaceBackground],
                                               to: body)
        // A border has to be visible against both things it separates.
        fixed.border = ColorTuner.adjust(theme.border,
                                         on: [theme.panelBackground, theme.cardBackground],
                                         to: surface)

        // Surfaces are steps away from the panel, not text: they are nudged only
        // when the step has collapsed to nothing, and only far enough to exist.
        fixed.cardBackground = ColorTuner.adjust(theme.cardBackground,
                                                 on: [theme.panelBackground], to: surface)
        fixed.cardHoverBackground = ColorTuner.adjust(theme.cardHoverBackground,
                                                      on: [fixed.cardBackground], to: surface)
        fixed.selectedBackground = ColorTuner.adjust(theme.selectedBackground,
                                                     on: [fixed.cardBackground], to: surface)
        // The separation-from-card nudge above never checked whether text
        // could still land on the result: three presets kept a selection fill
        // light enough that white read 5.36:1 on it, and every derived color
        // that gets tuned against `selectedBackground` - primary/secondary
        // text, the accent, destructive - inherited the same ceiling no
        // matter how far ITS OWN hue moved. WCAG's ratio is symmetric in the
        // two luminances, so `ColorTuner.adjust` can tune the *background's*
        // lightness the same way it tunes a foreground's: against the most
        // extreme label this fill will ever carry (near-white on a dark
        // theme, near-black on a light one), keeping the fill's own hue.
        let extremeLabel = theme.isDark ? "#FFFFFF" : "#000000"
        fixed.selectedBackground = ColorTuner.adjust(fixed.selectedBackground,
                                                      on: extremeLabel, to: body)

        // The accent is authored too, and was never repaired - which is why a
        // brand palette imported from a design document failed "accent as a
        // mark on card" 18 times out of 74. A brand blue chosen for a hero
        // section on white is not automatically visible as a 2pt ring on a
        // near-black card.
        let indicator = ThemeRules.Level.indicator.ratio
        fixed.accent = ColorTuner.adjust(theme.accent,
                                         on: [fixed.cardBackground, theme.panelBackground],
                                         to: indicator)
        fixed.accentSecondary = ColorTuner.adjust(theme.accentSecondary,
                                                  on: [fixed.cardBackground], to: indicator)
        // Surface is a reading ground in its own right: secondary and tertiary
        // text land on it and were failing there 43 times between them.
        fixed.surfaceBackground = ColorTuner.adjust(theme.surfaceBackground,
                                                    on: [theme.panelBackground], to: surface)
        fixed.textSecondary = ColorTuner.adjust(fixed.textSecondary,
                                                on: readingSurfaces + [fixed.surfaceBackground],
                                                to: body)
        fixed.textTertiary = ColorTuner.adjust(fixed.textTertiary,
                                               on: [fixed.cardBackground, fixed.surfaceBackground],
                                               to: body)

        // Keeping the repair only when it helps means a theme this cannot fix -
        // a hue with nowhere to go - is handed back as authored rather than
        // returned as a mangled version of itself that fails just as hard.
        let before = ThemeRules.audit(theme.appTheme).failures.count
        let after = ThemeRules.audit(fixed.appTheme).failures.count
        guard after < before else { return theme }
        // One pass moves the grounds the next pass has to grade against, so a
        // second pass finds failures the first could not have seen. Bounded, so
        // a palette with nowhere left to go stops rather than spinning.
        if after > 0, depth < 3 { return repaired(fixed, depth: depth + 1) }
        return fixed
    }

    /// What repairing would change, for the builder to show before it acts.
    static func changes(_ theme: CustomTheme) -> [(token: String, from: String, to: String)] {
        let fixed = repaired(theme)
        let pairs: [(String, String, String)] = [
            ("Text, primary", theme.textPrimary, fixed.textPrimary),
            ("Text, secondary", theme.textSecondary, fixed.textSecondary),
            ("Text, tertiary", theme.textTertiary, fixed.textTertiary),
            ("Border", theme.border, fixed.border),
            ("Card", theme.cardBackground, fixed.cardBackground),
            ("Card hover", theme.cardHoverBackground, fixed.cardHoverBackground),
            ("Selection", theme.selectedBackground, fixed.selectedBackground)
        ]
        return pairs.filter { $0.1.caseInsensitiveCompare($0.2) != .orderedSame }
            .map { (token: $0.0, from: $0.1, to: $0.2) }
    }

    // MARK: - M30: why a pairing is still red after "Fix all failing"

    /// Why one pairing, named the way `ThemeRules.Pairing.name` spells it,
    /// stayed red after `repaired` ran.
    ///
    /// Three genuinely different situations look identical from the matrix -
    /// one still-red cell - and deserve different sentences:
    ///   - `collidesWith`: the color CAN reach its own target in isolation,
    ///     but doing so would push a different, real pairing below ITS OWN
    ///     bar, because the two share a token and were tuned together. This
    ///     is the case a gate found up to ten of in one theme.
    ///   - `noRoom`: no color at all - not even pure black or pure white -
    ///     reaches the target against this one background. A real WCAG
    ///     ceiling (proved for the accent/cardBackground case, section
    ///     144g5), not a collision with anything else.
    ///   - `unresolved`: the failing token is not one this tool moves
    ///     directly (a derived value like a type tint), or no cause could be
    ///     pinned down. Rare, and still told honestly rather than guessed at.
    enum StuckReason: Equatable {
        case collidesWith(pairing: String, sharedToken: String)
        case noRoom
        case unresolved
    }

    /// Computed on request, for the ONE pairing the user is looking at - not
    /// for the whole matrix on every render. The check itself is cheap (a
    /// single nudge plus two full audits), but running it for all ~65
    /// pairings on every keystroke of a slider drag is not, so callers ask
    /// only about pairings that are actually still failing.
    ///
    /// The method: try the nudge `ContrastMatrixView`'s own "Apply" link
    /// would make - the exact same `ThemeRules.nudgedForeground` call, so
    /// this can never disagree with what that button does - then look at
    /// what a full re-audit says broke. Only a pairing sharing this one's
    /// foreground or background token can possibly have changed, since
    /// nothing else moved.
    static func explainStuck(_ pairingName: String, in theme: CustomTheme) -> StuckReason {
        guard let pairing = ThemeRules.pairings.first(where: { $0.name == pairingName }) else {
            return .unresolved
        }
        // A derived foreground (a type tint, say) is not a token this tool
        // moves on its own - naming a "collision" for it would be a guess,
        // not a finding.
        guard CustomTheme.allTokenNames.contains(pairing.foregroundToken) else { return .unresolved }

        let rendered = theme.appTheme
        let isolatedBest = ThemeRules.nudgedForeground(for: pairing, in: rendered)
        let isolatedRatio = ThemeRules.ratio(isolatedBest, on: pairing.background(rendered))
        // Not even the best color THIS one background could ever be handed
        // reaches the bar - nothing else could be the cause.
        guard meetsRatio(isolatedRatio, pairing.level.ratio) else { return .noRoom }

        var candidate = theme
        guard candidate.setToken(pairing.foregroundToken, hex: isolatedBest.hexString) else {
            return .unresolved
        }

        let before = ThemeRules.audit(theme.appTheme).findings
        let after = ThemeRules.audit(candidate.appTheme).findings
        let stuckTokens = Set([pairing.foregroundToken, pairing.backgroundToken])

        // Among pairings that passed before this token moved and fail after,
        // the one with the largest shortfall is named - the clearest single
        // trade this token's move would make.
        var worst: (name: String, deficit: Double)?
        for (b, a) in zip(before, after) where a.pairing != pairingName {
            guard b.passes, !a.passes else { continue }
            guard let collidingDef = ThemeRules.pairings.first(where: { $0.name == a.pairing }),
                  stuckTokens.contains(collidingDef.foregroundToken)
                    || stuckTokens.contains(collidingDef.backgroundToken)
            else { continue }
            let deficit = a.required - a.ratio
            if worst == nil || deficit > worst!.deficit { worst = (a.pairing, deficit) }
        }
        guard let found = worst,
              let collidingDef = ThemeRules.pairings.first(where: { $0.name == found.name })
        else { return .unresolved }

        let shared = Set([collidingDef.foregroundToken, collidingDef.backgroundToken])
            .intersection(stuckTokens).first ?? pairing.foregroundToken
        return .collidesWith(pairing: found.name, sharedToken: shared)
    }

    /// The same tolerance `ThemeRules.Finding.passes` grades with - a color
    /// that reaches its target to the float epsilon (7.0 measuring as
    /// 6.999999...) is a pass, not a ceiling.
    private static func meetsRatio(_ ratio: Double, _ required: Double) -> Bool {
        (ratio * 100).rounded() >= (required * 100).rounded()
    }

    // MARK: - M30 redesign: what the person actually experiences, no jargon

    /// What a level means for someone who is not going to look up WCAG -
    /// never shown as a name or a number, only as a verb describing what
    /// goes wrong. Kept here (not in the view) so the view's copy and a
    /// probe's expectation are reading the exact same word, not two hand
    /// -typed copies of it.
    private static func plainVerb(for level: ThemeRules.Level) -> String {
        switch level {
        case .body, .largeText: return "hard to read"
        case .indicator, .surface, .chipFill: return "hard to notice"
        case .decorative: return "hard to tell apart"
        }
    }

    /// M33: the card's own title - where he'll actually see this, in the
    /// exact plain-English location `ThemeRules.Pairing.where_` already
    /// writes, promoted to the first thing a person reads on the card. The
    /// location is the one detail he recognises without translation; the
    /// verdict about what goes wrong there is secondary and lives in
    /// `plainProblem` below. Twelve cards used to bury this identical
    /// location clause at the tail of an identical opening sentence - a
    /// wall of "This will be hard to read here" twelve times over, with
    /// nothing to scan but the last few words of each. Leading with it
    /// instead is what actually lets him find the one he cares about.
    static func plainLocationTitle(for pairing: ThemeRules.Pairing) -> String {
        let text = pairing.where_
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// The short problem clause a card shows under its own location title -
    /// what will go wrong, and nothing else. The location itself moved to
    /// `plainLocationTitle` above, so this never repeats it.
    static func plainProblem(for pairing: ThemeRules.Pairing) -> String {
        let verb = plainVerb(for: pairing.level)
        return verb.prefix(1).uppercased() + verb.dropFirst() + "."
    }

    /// The stuck-case sentence, in his terms - never "WCAG ceiling", never
    /// the standard's name. Names the other real thing that would break,
    /// using ITS OWN plain-English location, or - when there is truly
    /// nothing else to blame - says his exact colour has nowhere left to
    /// go here at all, and points at the one control the card offers
    /// instead (M33: `IssueCard.closestColourRow`, not the slider - a
    /// slider that cannot reach a working state at either end is not a
    /// real option, so the sentence no longer tells him to "try" one).
    /// `nil` for `.unresolved`: nothing false to claim.
    ///
    /// M34: the `.noRoom` line used to be three lines that repeated on
    /// every stuck card down a scrolling list, word for word ("Use the
    /// closest colour below, or pick a different colour for this."). Read
    /// three times in a row it stopped being read at all. `closestColourRow`
    /// already carries a button labelled "Use the closest colour" right
    /// underneath this line, so the line itself only needs to say what's
    /// true and let the button say what it does.
    static func plainCollisionSentence(for reason: StuckReason) -> String? {
        switch reason {
        case .collidesWith(let collidingName, _):
            guard let colliding = ThemeRules.pairings.first(where: { $0.name == collidingName })
            else { return nil }
            return "Making this one right would make \(colliding.where_) "
                 + "\(plainVerb(for: colliding.level)) instead."
        case .noRoom:
            return "This color can't read well here, even at its best."
        case .unresolved:
            return nil
        }
    }
}
