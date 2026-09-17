import SwiftUI
import AppKit

/// M30 redesign: guidance about the colours HE picked, not an audit he has
/// to interpret.
///
/// The M17 version reported compliance - "38 of 65 pairs need attention",
/// every pairing shown with a WCAG ratio, an AA/AAA badge and an APCA score
/// at once. A real screenshot showed the actual failure mode: when nothing
/// is wrong the header reads "All 65 pairs pass" and the panel is LONGEST
/// exactly when there is nothing to do, two rows both titled "Accent" were
/// impossible to tell apart, and "3.9:1" beside "AA AAA" badges reads as a
/// contradiction unless you already know a non-text mark only needs 3:1.
///
/// So the default view now says what will happen to a person looking at the
/// app - "This will be hard to read here. You'll see it in the timestamps
/// under each item." - never "AA", "AAA", "APCA", "pairing" or a bare ratio.
/// Every number is still here, honest and unchanged, behind "Show the full
/// check" for whoever wants it (`ThemeRules.pairings` still drives both, so
/// the two can never disagree - M17's own rule, kept).
///
/// The fix offered is local (one problem, one control - a lightness slider
/// between his exact colour and the nearest one that reads well, HIS hue
/// never touched) and reversible before it's applied (drag, watch the live
/// reading, "Use this colour" - never a colour just handed to him). "Fix
/// everything at once" still exists but is secondary and states how many
/// colours it will change before it changes them (`ThemeDoctor.changes`,
/// M17's own preview-before-acting call, now actually wired to a button).
///
/// The stuck case (`ThemeDoctor.explainStuck`) is explained the same way -
/// never "WCAG ceiling", never the standard's name: which other real thing
/// in the app would go wrong, in the same plain sentence.
///
/// M33 polish pass on the above, from a real screenshot of the shipped M30
/// panel: three things still failed the same "guidance, not an audit" goal.
/// (1) every card's opening sentence was identical ("This will be hard to
/// read here. You'll see it in ...") with the only distinguishing word
/// buried at the end - the location now leads as the card's own title
/// (`ThemeDoctor.plainLocationTitle`), the verdict is the short line under
/// it (`ThemeDoctor.plainProblem`, shortened to match). (2) the "Aa" chip
/// was too small and too generic to be the evidence the whole card rests
/// on - `IssueCard.preview` now renders the real thing per pairing (real
/// text at its real size/weight, a real ring, a real icon glyph, or the
/// two real surfaces side by side), at a size meant to actually be read.
/// (3) the lightness slider could dead-end at its own maximum still
/// reading "Still hard to see" with nothing to do about it - when
/// `ThemeDoctor.explainStuck` reports `.noRoom` (his hue truly has nowhere
/// to go on this surface, not even at pure black or white),
/// `IssueCard.closestColourRow` replaces the slider with the one honest
/// action left: commit the closest this colour gets, in one click, still
/// labelled as the closest rather than as fixed. The ranked order also
/// changed: `ContrastMatrixView.rankedFailing` now groups by which of the
/// app's real visibility states a pairing needs before he would ever see it
/// (a card at rest, ahead of hover, ahead of selection, ahead of keyboard
/// focus, ahead of a state he may never produce) and keeps worst-first only
/// as the tie-break inside a group - see that function's own comment.
struct ContrastMatrixView: View {
    @Binding var theme: CustomTheme
    @Binding var selectedToken: String?
    /// M19: an Inspect click's own token set also highlights every matrix
    /// cell either token appears in, for 600ms - the same "the color that
    /// controls the element" answer the token column's own flash gives,
    /// read here instead of duplicating the flash/clear timer. Only used
    /// inside the full-check disclosure now; the default view has no
    /// columns to highlight.
    @ObservedObject private var inspect = ThemeInspectRegistry.shared
    /// Collapsed every time the builder opens, never remembered open - the
    /// same reasoning `ThemeBuilderView.assistantExpanded` states for its
    /// own hand-rolled header, actually enforced here: on the shared
    /// `ThemeBuilderState` (reset in `ThemeBuilderWindowController.open`),
    /// not a plain `@State`, because the window's SwiftUI content is built
    /// ONCE and reused across every open/close
    /// (`ThemeBuilderWindowController.hasBuiltContent`) - a local `@State`
    /// would only ever initialize on the first open of a process's whole
    /// lifetime, not "every time". Not a `DisclosureGroup` either way
    /// (section 144a's own gate: zero of them anywhere in this directory).
    @Binding var showFullAudit: Bool
    @State private var pendingFixAllChanges: [(token: String, from: String, to: String)]?

    /// T3-M9: `SettingsPalette.note` and the bare (unstyled) `Text` this
    /// panel used to paint its heading and row labels with both resolve by
    /// the SYSTEM's light/dark appearance (`NSAppearance.bestMatch`), not by
    /// this theme's OWN resolved mode - so a light custom theme (ivory)
    /// rendered on a machine set to system Dark Mode painted near-white text
    /// over this panel's own light `panelBackground`, unreadable. Every other
    /// label in this file already reads through `theme.appTheme` (see
    /// `matrixColumn`'s `textPrimary`); this is the same fix applied to the
    /// two spots that had drifted from it, going through the same per-mode
    /// resolution path the rest of the app already uses
    /// (`AppTheme.secondaryText(on:)`, tuned to AAA for the actual ground it
    /// paints on) rather than a new hardcoded hex or an opacity nudge on a
    /// dark-derived color.
    private var t: AppTheme { theme.appTheme }
    private var panelNote: Color { t.secondaryText(on: t.panelBackground) }

    private var cells: [ThemeRules.MatrixCell] { ThemeRules.matrixCells(for: theme.appTheme) }
    private var failing: [ThemeRules.MatrixCell] { cells.filter { !$0.passesAA } }
    /// M33: grouped by what he'd actually notice first, worst-first only as
    /// the tie-break inside a group - see `Self.rankedFailing` below for the
    /// reasoning. `QABridge`'s `m17_matrixIssueOrder` calls the SAME static
    /// function rather than re-deriving the sort, so the panel and the
    /// probe reading it can never quietly disagree.
    private var rankedFailing: [ThemeRules.MatrixCell] { Self.rankedFailing(for: theme.appTheme) }

    /// One "column" per surface token, in first-seen order - unchanged from
    /// M17, kept only for the full-check disclosure now.
    private var columns: [(token: String, cells: [ThemeRules.MatrixCell])] {
        var order: [String] = []
        var byBackground: [String: [ThemeRules.MatrixCell]] = [:]
        for cell in cells {
            let key = cell.pairing.backgroundToken
            if byBackground[key] == nil { order.append(key) }
            byBackground[key, default: []].append(cell)
        }
        return order.map { (token: $0, cells: byBackground[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.group) {
                    ForEach(rankedFailing) { cell in
                        IssueCard(cell: cell, theme: $theme, selectedToken: $selectedToken)
                    }
                    if !failing.isEmpty {
                        fixEverythingRow
                    }
                    fullAuditToggle
                    if showFullAudit {
                        ForEach(columns, id: \.token) { column in
                            matrixColumn(column)
                        }
                    }
                }
                .padding(Spacing.related)
            }
        }
        // M21: was `Color(nsColor: .underPageBackgroundColor)` - a flat
        // system gray that matches no themed surface in the app. See the
        // M21 note this file used to carry: `panelBackground` is the same
        // base surface the component gallery two panels over already sits
        // on, so this reads as one more themed surface, not a bolted-on
        // system list.
        .background(theme.appTheme.panelBackground)
    }

    // MARK: - Header: quiet when there is nothing to say

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if failing.isEmpty {
                HStack(spacing: Spacing.inline) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.appTheme.success)
                    Text("Everything reads well.").font(Typography.subheading)
                        .foregroundStyle(t.textPrimary)
                }
                .accessibilityIdentifier("matrixSummary.allClear")
            } else {
                Text("\(failing.count) color\(failing.count == 1 ? "" : "s") may be hard to see")
                    .font(Typography.subheading)
                    .foregroundStyle(t.textPrimary)
                    .accessibilityIdentifier("matrixSummary.issueCount")
            }
        }
        .padding(Spacing.related)
    }

    // MARK: - "Fix everything at once": secondary, and says its cost first

    private var fixEverythingRow: some View {
        Group {
            if let pending = pendingFixAllChanges {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(pending.isEmpty
                         ? "There's nothing left this can change on its own."
                         : "This will change \(pending.count) color\(pending.count == 1 ? "" : "s") "
                         + "you picked, all at once.")
                        .font(Typography.caption)
                        .foregroundStyle(panelNote)
                    HStack {
                        // T3-M10: every control in this row omitted `theme:`,
                        // so it fell back to the LIVE `themeManager.theme`
                        // instead of the DRAFT theme this whole panel is
                        // grading - the same class of bug as the footer's
                        // Cancel/Save (see `ThemeBuilderView`).
                        ClipLink("Cancel", size: .small, theme: t) { pendingFixAllChanges = nil }
                        Spacer()
                        if !pending.isEmpty {
                            SecondaryButton("Change them", size: .small, theme: t) {
                                theme = ThemeDoctor.repaired(theme)
                                pendingFixAllChanges = nil
                            }
                        }
                    }
                }
                .accessibilityIdentifier("matrixFixAll.confirm")
            } else {
                HStack {
                    Spacer()
                    ClipLink("Fix everything at once", size: .small, theme: t) {
                        pendingFixAllChanges = ThemeDoctor.changes(theme)
                    }
                }
                .accessibilityIdentifier("matrixFixAll.trigger")
            }
        }
    }

    // MARK: - The full check: every number, collapsed by default

    private var fullAuditToggle: some View {
        HStack(spacing: Spacing.inline) {
            Text(showFullAudit ? "Hide the full check" : "Show the full check (\(cells.count) pairs)")
                .font(Typography.caption)
                .foregroundStyle(panelNote)
            Image(systemName: showFullAudit ? "chevron.up" : "chevron.down")
                .font(Typography.micro)
                .foregroundStyle(panelNote)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { showFullAudit.toggle() } }
        .accessibilityIdentifier("matrixFullAudit.toggle")
    }

    private func matrixColumn(_ column: (token: String, cells: [ThemeRules.MatrixCell])) -> some View {
        let isSelectedColumn = selectedToken == column.token
        return VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(Self.displayName(column.token))
                .font(Typography.labelStrong)
                .foregroundStyle(isSelectedColumn ? theme.appTheme.accent : theme.appTheme.textPrimary)
            ForEach(column.cells) { cell in
                matrixCellRow(cell)
            }
        }
    }

    /// Read-only technical detail - ratio, AA/AAA, APCA - for whoever wants
    /// the audit. The plain-language guidance and every fix control live in
    /// `IssueCard` above; this never duplicates them.
    private func matrixCellRow(_ cell: ThemeRules.MatrixCell) -> some View {
        let t = theme.appTheme
        let highlighted = selectedToken == cell.pairing.foregroundToken
                        || selectedToken == cell.pairing.backgroundToken
                        || inspect.flashedTokens.contains(cell.pairing.foregroundToken)
                        || inspect.flashedTokens.contains(cell.pairing.backgroundToken)
        return HStack(spacing: Spacing.tight) {
            swatchPair(cell)
            VStack(alignment: .leading, spacing: Spacing.inline) {
                Text(cell.pairing.name).font(Typography.body)
                Text(cell.pairing.where_).font(Typography.caption)
                    .foregroundStyle(panelNote).lineLimit(1)
            }
            Spacer(minLength: Spacing.tight)
            VStack(alignment: .trailing, spacing: Spacing.inline) {
                HStack(spacing: Spacing.inline) {
                    Text(String(format: "%.1f:1", cell.ratio)).font(Typography.captionMono)
                    Text(cell.passesAA ? "Passes" : "Fails")
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(cell.passesAA ? t.success : t.destructive)
                    if cell.passesAAA {
                        Text("+ extra safe margin").font(Typography.caption).foregroundStyle(t.success)
                    }
                }
                Text("needs \(String(format: "%.1f", cell.pairing.level.ratio)):1 (\(cell.pairing.level.label)) "
                   + "\u{2022} APCA \(Int(cell.apca.rounded()))")
                    .font(Typography.caption).foregroundStyle(panelNote)
            }
        }
        .padding(Spacing.tight)
        // T3-M10: was `SettingsPalette.hover` (`Color.primary.opacity(0.07)`)
        // - `Color.primary` follows SwiftUI's `colorScheme` environment,
        // which nothing in this window forces, so it actually painted per
        // the SYSTEM's real appearance. `cardHoverBackground` is this
        // theme's own "a row under the pointer" token.
        .background(highlighted ? t.cardHoverBackground : Color.clear,
                    in: RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { selectedToken = cell.pairing.foregroundToken }
        .accessibilityIdentifier("matrixCell.\(cell.pairing.foregroundToken).\(cell.pairing.backgroundToken)")
    }

    private func swatchPair(_ cell: ThemeRules.MatrixCell) -> some View {
        let t = theme.appTheme
        return ZStack {
            Circle().fill(cell.pairing.background(t)).frame(width: 20, height: 20)
                .overlay(Circle().stroke(t.border, lineWidth: 1))
            Circle().fill(cell.pairing.foreground(t)).frame(width: 14, height: 14)
                .overlay(Circle().stroke(t.border, lineWidth: 1))
        }
        .frame(width: 24, height: 24)
    }

    /// A token name as the schema spells it, split at camel-case boundaries
    /// into words - "cardHoverBackground" reads as "card Hover Background".
    /// Only used inside the full-check disclosure now.
    fileprivate static func displayName(_ token: String) -> String {
        guard let last = token.split(separator: ".").last else { return token }
        var words = ""
        for (i, char) in last.enumerated() {
            if i > 0, char.isUppercase { words.append(" ") }
            words.append(char)
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// M33: the ranking axis a person's attention should actually follow.
///
/// M17/M30 sorted the failing list by one axis only - furthest below its
/// own bar first, the ranking a machine would pick because a number sorts
/// cleanly. That axis alone put a keyboard-only focus ring above a card's
/// own item titles whenever the ring's shortfall happened to be numerically
/// bigger, which is backwards as a scan order: almost nobody tabs through
/// the app before they look at a card. So the primary axis is now which of
/// the app's actual visibility states this pairing needs before he would
/// ever see it at all - resting-state content he looks at with no
/// interaction, ahead of a state that only shows up mid-hover, mid-
/// selection or mid-keyboard-focus, ahead again of a state he may never
/// produce at all (a disabled control, a chip nobody has ever seen with
/// zero matches). Worst-first survives only as the tie-break inside one
/// group, where it is still the right call - among several always-visible
/// problems, the worst one earns first position.
extension ContrastMatrixView {
    /// Tier 0 - on screen at rest, no interaction needed (a card's own
    /// content, the toolbar, the panel). Tier 1 - resting-state chrome one
    /// step out (a button's own idle label, an inline link). Tier 2 - only
    /// visible while the pointer is over something. Tier 3 - only visible
    /// once a row is selected. Tier 4 - only visible via keyboard focus.
    /// Tier 5 - states he is least likely to ever produce just by using the
    /// app (a disabled control, a button held down, a filter chip with zero
    /// matches). Read from the pairing's own `name`/`backgroundToken` - the
    /// same data already on every cell - rather than a new field, since the
    /// wording of every pairing name already says which state it is.
    static func visibilityTier(_ cell: ThemeRules.MatrixCell) -> Int {
        let name = cell.pairing.name.lowercased()
        if name.contains("disabled") || name.contains("pressed") || name.contains("empty state") { return 5 }
        if name.contains("focus") { return 4 }
        if name.contains("selection") || name.contains("selected") { return 3 }
        if name.contains("hover") { return 2 }
        switch cell.pairing.backgroundToken {
        case "cardBackground", "surfaceBackground", "panelBackground": return 0
        default: return 1
        }
    }

    /// The failing pairings, in the order the panel actually lists them.
    /// `QABridge`'s `m17_matrixIssueOrder` calls this exact function for its
    /// own read rather than re-sorting `ThemeRules.matrixCells` a second
    /// time, so a probe can never end up reading an order the panel itself
    /// does not render.
    static func rankedFailing(for theme: AppTheme) -> [ThemeRules.MatrixCell] {
        ThemeRules.matrixCells(for: theme).filter { !$0.passesAA }.sorted { lhs, rhs in
            let lt = visibilityTier(lhs), rt = visibilityTier(rhs)
            if lt != rt { return lt < rt }
            return (lhs.ratio - lhs.pairing.level.ratio) < (rhs.ratio - rhs.pairing.level.ratio)
        }
    }

    /// M33: which kind of real thing a pairing's preview should render -
    /// `IssueCard.preview` calls this exact function rather than deciding
    /// its own copy of the same rule, so `QABridge` can read the identical
    /// category a probe checks against instead of a second, hand-kept
    /// classification that could quietly drift from what actually renders.
    enum PreviewKind: String { case text, ring, surfaceStep, icon }

    /// A `typeTint.*` token is always an icon and badge, never a paragraph
    /// (`ThemeRules`' own comment on why those grade at `.largeText` says
    /// so). Every `.indicator` pairing's own name says "ring" or "mark".
    /// `.surface` is always one surface measured against another. Anything
    /// left is real reading text.
    static func previewKind(for pairing: ThemeRules.Pairing) -> PreviewKind {
        if pairing.foregroundToken.hasPrefix("typeTint.")
            || pairing.foregroundToken == "cardActionIcon"
            || pairing.foregroundToken == "cardActionDestructiveIcon" { return .icon }
        switch pairing.level {
        case .indicator: return .ring
        case .surface, .chipFill: return .surfaceStep
        case .largeText, .body, .decorative: return .text
        }
    }
}

/// One problem, shown where it lives: the actual text on its actual
/// background (point 5, Miro's own affected-element preview), the plain
/// sentence describing what a person will experience, and - when his exact
/// colour has somewhere to go - a slider between that exact colour and the
/// nearest one that reads well, so he stays in control of the final value
/// rather than being handed a computed one to take or leave.
private struct IssueCard: View {
    let cell: ThemeRules.MatrixCell
    @Binding var theme: CustomTheme
    @Binding var selectedToken: String?

    /// 0 = his exact colour, unchanged. 1 = the nearest colour, same hue,
    /// that reaches the bar this pairing needs. Starts at the recommended
    /// end so one tap on "Use this colour" takes the smallest fix; dragging
    /// back shows him why the fix was needed in the first place.
    @State private var fraction: Double = 1

    private var t: AppTheme { theme.appTheme }
    private var reason: ThemeDoctor.StuckReason { ThemeDoctor.explainStuck(cell.pairing.name, in: theme) }
    /// A derived value (a type tint, say) is not a token this view can
    /// write back to - no slider is offered for one, only the sentence.
    private var canAdjust: Bool { CustomTheme.allTokenNames.contains(cell.pairing.foregroundToken) }
    private var originHex: String? { canAdjust ? theme.hex(forToken: cell.pairing.foregroundToken) : nil }

    /// His colour, unchanged, at whatever point the slider currently sits
    /// between it and the nearest readable one - same hue and saturation
    /// throughout, only lightness moves (the same rule `ColorTuner` itself
    /// holds everywhere else in this app).
    private var previewColor: Color {
        guard canAdjust, let originHex, let originNS = NSColor(hex: originHex) else {
            return cell.pairing.foreground(t)
        }
        let nudged = ThemeRules.nudgedForeground(for: cell.pairing, in: t)
        guard let targetNS = NSColor(hex: nudged.hexString) else { return cell.pairing.foreground(t) }
        var hsl = HSL(originNS)
        let targetHSL = HSL(targetNS)
        hsl.l = hsl.l + (targetHSL.l - hsl.l) * fraction
        return Color(nsColor: hsl.color())
    }
    private var previewRatio: Double { ThemeRules.ratio(previewColor, on: cell.pairing.background(t)) }
    private var previewReads: Bool { previewRatio >= cell.pairing.level.ratio }
    /// M33: the slider's own top end is `nudgedForeground` - the nearest
    /// lightness this exact hue can reach. When even that end still fails
    /// (`ThemeDoctor.StuckReason.noRoom`), every point between it and his
    /// original colour fails too, so a slider offers him zero working
    /// destinations to drag toward - a control with no reachable "on"
    /// position reads as broken, not as a choice. `closestColourRow`
    /// replaces it in that one case; every other case keeps the slider.
    private var isStuck: Bool { reason == .noRoom }

    /// The shared, testable classification - `ContrastMatrixView.
    /// previewKind(for:)` - so this view and `QABridge`'s own read of it
    /// can never disagree about which kind of real thing a pairing is.
    private var previewKind: ContrastMatrixView.PreviewKind {
        ContrastMatrixView.previewKind(for: cell.pairing)
    }

    /// Rendering detail for the `.text` case only: `.largeText` pairings
    /// are button/chip labels in this list (the CTA fills, the chip
    /// labels, the panel-over-desktop links), so they preview at the
    /// app's own button-label weight; `.body`/`.decorative` preview at
    /// plain reading weight.
    private var textPreview: (font: Font, sample: String) {
        cell.pairing.level == .largeText
            ? (Typography.buttonLabel, "Label")
            : (Typography.body, "Sample text")
    }

    /// The real SF Symbol this type tint actually badges a card with
    /// (`ItemKind.symbol`) - the same glyph the item grid draws, not a
    /// stand-in shape.
    private var iconSymbol: String {
        guard let raw = cell.pairing.foregroundToken.split(separator: ".").last,
              let kind = ItemKind(rawValue: String(raw))
        else { return "questionmark" }
        return kind.symbol
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(alignment: .top, spacing: Spacing.related) {
                preview
                VStack(alignment: .leading, spacing: Spacing.inline) {
                    // M33: the location leads - it is the one detail he
                    // recognises without translation, and the reason
                    // twelve of these used to read as one identical wall
                    // (every card opened "This will be hard to read here.
                    // You'll see it in ...", differing only in the last
                    // few words). The verdict is now the short line under
                    // it, not the sentence's own tail.
                    // T3-M7: this caption used to have no line limit of its
                    // own, which let the narrow column truncate it mid-word
                    // ("hovere...") instead of at a whole word. Two lines,
                    // wrapping at word breaks, is enough room for every
                    // caption in the set (confirmed against the longest one)
                    // without widening the card or moving anything else in
                    // it - the 4px scale and every other token here are
                    // unchanged.
                    Text(ThemeDoctor.plainLocationTitle(for: cell.pairing))
                        .font(Typography.labelStrong)
                        .foregroundStyle(t.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("matrixIssue.title.\(cell.pairing.foregroundToken)"
                                                + ".\(cell.pairing.backgroundToken)")
                    Text(ThemeDoctor.plainProblem(for: cell.pairing))
                        .font(Typography.caption)
                        // T3-M9: was `SettingsPalette.note` (system-appearance
                        // bound); this card paints on `t.panelBackground`, so
                        // it resolves per THIS theme's own mode the same way
                        // `t.textPrimary` above does.
                        .foregroundStyle(t.secondaryText(on: t.panelBackground))
                        .accessibilityIdentifier("matrixIssue.problem.\(cell.pairing.foregroundToken)"
                                                + ".\(cell.pairing.backgroundToken)")
                    if let collision = ThemeDoctor.plainCollisionSentence(for: reason) {
                        Text(collision).font(Typography.caption).foregroundStyle(t.warning)
                            .accessibilityIdentifier("matrixIssue.collision.\(cell.pairing.foregroundToken)"
                                                    + ".\(cell.pairing.backgroundToken)")
                    }
                }
                Spacer(minLength: Spacing.tight)
            }
            if canAdjust {
                if isStuck {
                    closestColourRow
                } else {
                    sliderRow
                }
            }
        }
        .padding(Spacing.tight)
        // T3-M10: same fix as `matrixCellRow` above - `cardHoverBackground`
        // instead of `SettingsPalette.hover`.
        .background(t.cardHoverBackground, in: RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous)
            .strokeBorder(t.border, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { selectedToken = cell.pairing.foregroundToken }
        .accessibilityIdentifier("matrixIssue.\(cell.pairing.foregroundToken).\(cell.pairing.backgroundToken)")
    }

    /// The pair as it actually renders. M33: a single "Aa" chip stood in
    /// for a paragraph, an icon badge, a focus ring and a surface step
    /// alike - the one place a person is meant to judge the problem with
    /// his own eyes, showing him the least of what any of those four
    /// actually look like. This renders the real one: real sample text at
    /// its real size and weight for a text pairing, the real glyph for an
    /// icon/badge pairing, a real ring for an indicator pairing, and the
    /// two real surfaces side by side for a surface-step pairing - always
    /// on the real background this pairing actually renders over, at a
    /// size big enough to actually read rather than a 40x32 chip.
    private var preview: some View {
        let bg = cell.pairing.background(t)
        return Group {
            switch previewKind {
            case .text:
                Text(textPreview.sample)
                    .font(textPreview.font)
                    .foregroundStyle(previewColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, Spacing.tight)
            case .ring:
                RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous)
                    .strokeBorder(previewColor, lineWidth: 2)
                    .padding(Spacing.inline)
            case .icon:
                Image(systemName: iconSymbol)
                    .font(Typography.specimenGlyph)
                    .foregroundStyle(previewColor)
            case .surfaceStep:
                HStack(spacing: Spacing.inline) {
                    RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous)
                        .fill(bg)
                        .overlay(RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous)
                            .strokeBorder(t.border, lineWidth: 1))
                    RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous)
                        .fill(previewColor)
                        .overlay(RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous)
                            .strokeBorder(t.border, lineWidth: 1))
                }
                .padding(Spacing.inline)
            }
        }
        .frame(width: 96, height: 56)
        .background(bg, in: RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous)
            .strokeBorder(t.border, lineWidth: 1))
        .accessibilityIdentifier("matrixIssue.preview.\(cell.pairing.foregroundToken)"
                                + ".\(cell.pairing.backgroundToken)")
    }

    private var sliderRow: some View {
        VStack(alignment: .leading, spacing: Spacing.inline) {
            // T3-M10: native `NSSlider` chrome forced to the draft theme's
            // own mode, same reasoning as `ThemeBuilderView`'s corner-radius
            // slider and the name field/switch.
            Slider(value: $fraction, in: 0...1)
                .colorScheme(theme.isDark ? .dark : .light)
                .accessibilityIdentifier("matrixIssue.slider.\(cell.pairing.foregroundToken)"
                                        + ".\(cell.pairing.backgroundToken)")
            HStack {
                Text(previewReads ? "Reads fine now" : "Still hard to see")
                    .font(Typography.caption)
                    .foregroundStyle(previewReads ? t.success : t.destructive)
                    .accessibilityIdentifier("matrixIssue.reading.\(cell.pairing.foregroundToken)"
                                            + ".\(cell.pairing.backgroundToken)")
                Spacer()
                ClipLink("Use this color", size: .small, theme: t) {
                    theme.setToken(cell.pairing.foregroundToken, hex: previewColor.hexString)
                }
                .accessibilityIdentifier("matrixIssue.accept.\(cell.pairing.foregroundToken)"
                                        + ".\(cell.pairing.backgroundToken)")
            }
        }
    }

    /// M33: shown instead of the slider when `reason` is `.noRoom` - see
    /// `isStuck`. The plain sentence already named this above
    /// (`ThemeDoctor.plainCollisionSentence`, the `.noRoom` case); this row
    /// is the one action that is actually true to offer: commit the
    /// closest this colour gets, honestly labelled as the closest rather
    /// than as fixed. `fraction` already sits at `1` by default (the
    /// nearest lightness this hue reaches), so `previewColor` here already
    /// is that nearest colour - the same value `m17_applyNudge` applies for
    /// a probe.
    private var closestColourRow: some View {
        HStack {
            Spacer()
            ClipLink("Use the closest color", size: .small, theme: t) {
                theme.setToken(cell.pairing.foregroundToken, hex: previewColor.hexString)
            }
            .accessibilityIdentifier("matrixIssue.acceptClosest.\(cell.pairing.foregroundToken)"
                                    + ".\(cell.pairing.backgroundToken)")
        }
    }
}
