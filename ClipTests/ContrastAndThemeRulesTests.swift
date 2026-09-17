import XCTest
import SwiftUI
@testable import Clip

/// WCAG contrast maths and the level thresholds built on it. A theme audit
/// that silently drifts is invisible until a user reports unreadable text -
/// these numbers are the whole contract.
final class ContrastAndThemeRulesTests: XCTestCase {

    // MARK: Contrast.ratio(String, String) - the hex-in/ratio-out pure path

    func test_blackOnWhite_isMaximumContrast() {
        XCTAssertEqual(Contrast.ratio("#000000", "#FFFFFF"), 21.0, accuracy: 0.01)
    }

    func test_sameColorOnItself_isRatioOne() {
        XCTAssertEqual(Contrast.ratio("#336699", "#336699"), 1.0, accuracy: 0.01)
    }

    func test_ratio_isSymmetric_argumentOrderDoesNotMatter() {
        let a = Contrast.ratio("#222222", "#EEEEEE")
        let b = Contrast.ratio("#EEEEEE", "#222222")
        XCTAssertEqual(a, b, accuracy: 0.0001)
    }

    func test_ratio_isMonotonic_asBackgroundDarkens() {
        // A lighter grey than #EEE must always sit closer to a black
        // foreground's contrast than a darker one does - the ratio should
        // strictly increase as the ground gets darker.
        let closeToBlack = Contrast.ratio("#000000", "#333333")
        let further = Contrast.ratio("#000000", "#CCCCCC")
        XCTAssertLessThan(closeToBlack, further)
    }

    func test_invalidHex_returnsZero_ratherThanCrashingOrFakingAPass() {
        XCTAssertEqual(Contrast.ratio("not-a-color", "#FFFFFF"), 0)
    }

    // MARK: ThemeRules.Level thresholds - the policy, not a mirrored literal
    //
    // An approved pass raised body and large-text contrast app-wide from
    // WCAG AA to WCAG AAA, and every one of the 14 built-in themes was
    // corrected to pass at that level. A test that just restates the two
    // resulting numbers catches nothing the next time policy moves - it was
    // exactly that kind of test that went stale here. These assert the
    // relationships the policy actually promises instead: body is stricter
    // than large text, neither level is allowed to fall under its WCAG AA
    // floor, and a pairing that really is too low is reported as a failure
    // rather than passing silently.

    func test_bodyText_isHeldToTheApprovedAAAPolicyValue() {
        XCTAssertEqual(ThemeRules.Level.body.ratio, 7.0)
    }

    func test_largeText_isHeldToTheApprovedAAAPolicyValue() {
        XCTAssertEqual(ThemeRules.Level.largeText.ratio, 4.5)
    }

    func test_bodyText_isStricterThanLargeText() {
        // Body text is smaller and must always clear a higher bar than large
        // text - the relationship the policy exists to preserve, independent
        // of which WCAG tier happens to be in force.
        XCTAssertGreaterThan(ThemeRules.Level.body.ratio, ThemeRules.Level.largeText.ratio)
    }

    func test_bodyAndLargeText_neverFallBelowTheirWCAG_AA_floor() {
        // The AAA pass raised the bar; it must never regress under the WCAG
        // AA minimum these levels are built on, whatever the exact enforced
        // number is.
        XCTAssertGreaterThanOrEqual(ThemeRules.Level.body.ratio, 4.5)
        XCTAssertGreaterThanOrEqual(ThemeRules.Level.largeText.ratio, 3.0)
    }

    func test_aPairingBelowItsRequiredRatio_isActuallyReportedAsFailing() {
        // Proves the checks above can fail at all: a body pairing well under
        // the level's required ratio must come back as a failure, and one
        // that exactly meets it must come back as a pass - so this suite
        // cannot go green just because nothing here is wired up.
        let tooLittleContrast = ThemeRules.Finding(pairing: "test: too little contrast",
                                                    where_: "synthetic",
                                                    ratio: 3.0,
                                                    required: ThemeRules.Level.body.ratio)
        XCTAssertFalse(tooLittleContrast.passes)

        let enoughContrast = ThemeRules.Finding(pairing: "test: enough contrast",
                                                 where_: "synthetic",
                                                 ratio: ThemeRules.Level.body.ratio,
                                                 required: ThemeRules.Level.body.ratio)
        XCTAssertTrue(enoughContrast.passes)
    }

    func test_indicatorAndDecorative_haveNoDistinctAAA_soAAAEqualsAA() {
        // WCAG 2.2 defines no separate AAA figure for these; the level must
        // report the same number twice rather than inventing one.
        XCTAssertEqual(ThemeRules.Level.indicator.aaaRatio, ThemeRules.Level.indicator.ratio)
        XCTAssertEqual(ThemeRules.Level.decorative.aaaRatio, ThemeRules.Level.decorative.ratio)
        XCTAssertEqual(ThemeRules.Level.surface.aaaRatio, ThemeRules.Level.surface.ratio)
    }

    func test_surfaceLevel_isDeliberatelyLoose() {
        // Cards/selection/hairlines are meant to be quiet - 1.06, not 1.5.
        XCTAssertEqual(ThemeRules.Level.surface.ratio, 1.06, accuracy: 0.001)
    }

    func test_everyPairing_hasARatioAtOrAboveItsOwnLevel_forTheDefaultTheme() throws {
        // The audit is only meaningful if the shipped default theme actually
        // clears the bar every pairing claims for itself. This is the single
        // assertion in this file that would have caught the historical bug
        // the doc comment describes (12 presets passing while type tints
        // failed on every light theme) had it existed then.
        let theme = try XCTUnwrap(AppTheme.presets.first)
        let report = ThemeRules.audit(theme)
        XCTAssertTrue(report.passes,
                      "Pairings below their required ratio: " +
                      report.failures.map { "\($0.pairing): \($0.ratio) < \($0.required)" }.joined(separator: "; "))
    }

    func test_everyPairing_hasARatioAtOrAboveItsOwnLevel_forEveryBuiltInPreset() {
        // The default-theme check above would not have caught M-cardAction's
        // own bug (user, 06/09): the card-action fill and its two icons read
        // fine on Aurora but failed specifically on Neon, whose saturated
        // accent tips the hover-composited disc past the point where a
        // same-polarity icon still clears 4.5:1. Every built-in preset -
        // dark and light, `hiddenFromPicker` forms (`clip-dark`) included -
        // must clear every pairing it claims, not just the default.
        var failures: [String] = []
        for preset in AppTheme.presets {
            let report = ThemeRules.audit(preset.prepared())
            for finding in report.failures {
                failures.append("\(preset.id) / \(finding.pairing): \(finding.ratio) < \(finding.required)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "Failing pairings: " + failures.joined(separator: "; "))
    }

    // MARK: ThemeRules.Level.chipFill - the card-action row's own fill

    func test_chipFillLevel_isDeliberatelyLoose() {
        // A floating chip carries its own resting edge (`IconButtonChrome`'s
        // `.cardAction` variant), so its fill-vs-ground step is real but
        // still short of an indicator ring (3:1) - 1.1, not 1.3 or 3.0.
        XCTAssertEqual(ThemeRules.Level.chipFill.ratio, 1.1, accuracy: 0.001)
    }

    func test_chipFillLevel_isStricterThanPlainSurfaceSeparation() {
        // The chip has no border-plus-shadow pair to lean on the way a card
        // or a hovered row does (`RowChrome` gives those two, not this), so
        // it is held to a slightly firmer step than an ordinary adjacent
        // surface.
        XCTAssertGreaterThan(ThemeRules.Level.chipFill.ratio, ThemeRules.Level.surface.ratio)
    }

    // MARK: cardActionFill / cardActionIcon / cardActionDestructiveIcon

    @MainActor
    func test_cardActionIcon_staysInTheThemesOwnPolarity() {
        // The icon must never invert relative to its own theme: white-ish in
        // a dark theme, black-ish in a light one - inverting mid-theme is
        // exactly the "light-mode chip inside a dark theme" regression an
        // early derivation attempt produced on Graphite.
        for preset in AppTheme.presets {
            let theme = preset.prepared()
            let iconLuminance = Contrast.relativeLuminance(NSColor(hex: theme.cardActionIcon.hexString)!)
            if theme.isDark {
                XCTAssertGreaterThan(iconLuminance, 0.5,
                                     "\(theme.id): card action icon should be light-ish in a dark theme")
            } else {
                XCTAssertLessThan(iconLuminance, 0.5,
                                  "\(theme.id): card action icon should be dark-ish in a light theme")
            }
        }
    }

    @MainActor
    func test_cardActionFill_isDistinctFromBothGroundsItRendersOn() {
        // The row's action buttons are only ever visible over a hovered card
        // or a selected one (`ItemActionCluster.isVisible`) - the fill must
        // read as its own chip against both, not just one.
        for preset in AppTheme.presets {
            let theme = preset.prepared()
            let onHover = Contrast.ratio(theme.cardActionFill.hexString, theme.cardHoverBackground.hexString)
            let onSelected = Contrast.ratio(theme.cardActionFill.hexString, theme.selectedBackground.hexString)
            XCTAssertGreaterThanOrEqual(onHover, ThemeRules.Level.chipFill.ratio,
                                        "\(theme.id): card action fill vs cardHoverBackground")
            XCTAssertGreaterThanOrEqual(onSelected, ThemeRules.Level.chipFill.ratio,
                                        "\(theme.id): card action fill vs selectedBackground")
        }
    }

    // MARK: - Tab hover fill and Selected border tokens

    @MainActor
    func test_tabHoverFill_fallbackCompatibility_equalsActionHoverFillWhenUnset() {
        for preset in AppTheme.presets {
            var plain = preset
            plain.palette = nil
            plain.tabHoverFillOverride = nil
            XCTAssertEqual(plain.tabHoverFill.hexString, plain.actionHoverFill.hexString,
                           "\(preset.id): unprepared tabHoverFill should equal actionHoverFill when unset")

            let ready = plain.prepared()
            XCTAssertEqual(ready.tabHoverFill.hexString, ready.actionHoverFill.hexString,
                           "\(preset.id): prepared tabHoverFill should equal actionHoverFill when unset")
        }
    }

    @MainActor
    func test_tabHoverFill_overrideIsolation_changesOnlyTabHoverFill() {
        for preset in AppTheme.presets {
            var base = preset
            base.palette = nil
            let originalReady = base.prepared()
            let originalActionHover = originalReady.actionHoverFill.hexString
            let originalHoverStroke = originalReady.hoverStroke.hexString
            let originalSelectionStroke = originalReady.selectionStroke.hexString
            let originalFocusRing = originalReady.focusRing.hexString

            let testColor = Color(hex: "#123456")
            base.tabHoverFillOverride = testColor

            let ready = base.prepared()
            XCTAssertEqual(ready.tabHoverFill.hexString, testColor.hexString)
            XCTAssertEqual(ready.actionHoverFill.hexString, originalActionHover,
                           "\(preset.id): actionHoverFill should not change when tabHoverFill is overridden")
            XCTAssertEqual(ready.hoverStroke.hexString, originalHoverStroke,
                           "\(preset.id): hoverStroke should not change when tabHoverFill is overridden")
            XCTAssertEqual(ready.selectionStroke.hexString, originalSelectionStroke,
                           "\(preset.id): selectionStroke should not change when tabHoverFill is overridden")
            XCTAssertEqual(ready.focusRing.hexString, originalFocusRing,
                           "\(preset.id): focusRing should not change when tabHoverFill is overridden")
        }
    }

    @MainActor
    func test_selectionStroke_overrideIsolation_doesNotAlterAccentHoverStrokeOrFocusRing() {
        for preset in AppTheme.presets {
            var base = preset
            base.palette = nil
            let originalReady = base.prepared()
            let originalAccent = originalReady.accent.hexString
            let originalHoverStroke = originalReady.hoverStroke.hexString
            let originalFocusRing = originalReady.focusRing.hexString

            let testBorder = Color(hex: "#ABCDEF")
            base.selectionStrokeOverride = testBorder

            let ready = base.prepared()
            XCTAssertEqual(ready.selectionStroke.hexString, testBorder.hexString)
            XCTAssertEqual(ready.accent.hexString, originalAccent,
                           "\(preset.id): accent should not change when selectionStroke is overridden")
            XCTAssertEqual(ready.hoverStroke.hexString, originalHoverStroke,
                           "\(preset.id): hoverStroke should not change when selectionStroke is overridden")
            XCTAssertEqual(ready.focusRing.hexString, originalFocusRing,
                           "\(preset.id): focusRing should not change when selectionStroke is overridden")
        }
    }
}
