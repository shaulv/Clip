import SwiftUI
import AppKit

/// A neutral, theme-independent backdrop so a translucent swatch's alpha
/// actually reads - the same idea a design tool's own color well uses.
/// Deliberately NOT a themed token: the point is a fixed, always-legible
/// reference square no theme (light OR dark) can make invisible.
struct CheckerboardBackground: View {
    var tile: CGFloat = 6
    var light: Color = Color(nsColor: .controlBackgroundColor)
    var dark: Color = Color(nsColor: .quaternaryLabelColor)

    var body: some View {
        Canvas { context, size in
            let cols = max(1, Int((size.width / tile).rounded(.up)))
            let rows = max(1, Int((size.height / tile).rounded(.up)))
            for row in 0..<rows {
                for col in 0..<cols {
                    let rect = CGRect(x: CGFloat(col) * tile, y: CGFloat(row) * tile,
                                      width: tile, height: tile)
                    let isLight = (row + col).isMultiple(of: 2)
                    context.fill(Path(rect), with: .color(isLight ? light : dark))
                }
            }
        }
    }
}

/// One token's row in the M17 theme builder: a large swatch on a
/// checkerboard (so alpha is visible), the role name, a one-line
/// description, the hex+alpha value, and - when this token is graded by
/// `ThemeRules.pairings` - a live contrast badge. Every group in the builder
/// is built entirely from rows of this one type; there is no other row shape.
///
/// Reads the draft theme from the shared `ThemeBuilderState` (an
/// `@EnvironmentObject`, already in scope for every view under
/// `ThemeBuilderView`) rather than taking it as a parameter, so a row deep
/// inside a group does not have to thread it through every intermediate
/// container by hand.
struct ColorTokenRow: View {
    let label: String
    /// The name this token is graded under in `ThemeRules.pairings`, or
    /// `nil` for a token the audit never grades on its own (M9's own rule:
    /// "no badge is honest here" for a field that only ever appears
    /// composited into something else).
    let token: String?
    let role: String
    @Binding var hex: String
    /// The token currently selected in the builder (row + contrast-matrix
    /// row/column highlight) - `nil` when nothing is selected.
    @Binding var selection: String?
    /// Whether this optional field is still deriving its value rather than
    /// pinning one of its own.
    var isAuto: Bool = false
    var onResetToAuto: (() -> Void)? = nil

    @EnvironmentObject private var builderState: ThemeBuilderState
    /// M19: whether THIS row is one of the tokens the last Inspect click
    /// selected - read, never written here (`ThemeInspectRegistry.
    /// selectHovered()` owns the 600ms clear).
    @ObservedObject private var inspect = ThemeInspectRegistry.shared
    @State private var showEditor = false

    private var liveTheme: AppTheme { builderState.theme.appTheme }
    private var isSelected: Bool { token != nil && selection == token }
    private var isFlashed: Bool { token != nil && inspect.flashedTokens.contains(token!) }

    /// Every pairing this token appears in (as either side), graded against
    /// a theme - a token can appear more than once (e.g. `destructive` is
    /// graded on the card, on hover and on selection), so this is the WORST
    /// of them, which is the one finding a single-line row can act on
    /// honestly without hiding a failure the others would show.
    ///
    /// Static and independent of view state (M34) so `QABridge` can ask the
    /// exact same question this row's own quiet dot answers - "does this
    /// token have a real failure right now" - instead of duplicating the
    /// logic or scraping the rendered view for a colour it can't reliably
    /// read back.
    static func worstFinding(for token: String, in theme: AppTheme) -> (ratio: Double, passes: Bool)? {
        let matches = ThemeRules.pairings.filter {
            $0.foregroundToken == token || $0.backgroundToken == token
        }
        guard !matches.isEmpty else { return nil }
        let graded = matches.map { pairing -> (Double, Bool) in
            let ratio = ThemeRules.ratio(pairing.foreground(theme), on: pairing.background(theme))
            return (ratio, ratio >= pairing.level.ratio)
        }
        let worst = graded.min { lhs, rhs in
            if lhs.1 != rhs.1 { return !lhs.1 }
            return lhs.0 < rhs.0
        }
        return worst.map { (ratio: $0.0, passes: $0.1) }
    }

    private var worstFinding: (ratio: Double, passes: Bool)? {
        guard let token else { return nil }
        return Self.worstFinding(for: token, in: liveTheme)
    }

    var body: some View {
        HStack(spacing: Spacing.tight) {
            swatch
            VStack(alignment: .leading, spacing: Spacing.inline) {
                Text(label).font(Typography.body)
                Text(role).font(Typography.caption)
                    .foregroundStyle(liveTheme.secondaryText(on: liveTheme.panelBackground))
            }
            Spacer(minLength: Spacing.tight)
            HStack(spacing: Spacing.inline) {
                if isAuto {
                    Text("Auto").font(Typography.caption)
                        .foregroundStyle(liveTheme.secondaryText(on: liveTheme.panelBackground))
                } else if onResetToAuto != nil {
                    ClipLink("Auto", size: .small, theme: liveTheme) { onResetToAuto?() }
                }
                Text(hex.uppercased())
                    .font(Typography.captionMono)
                    .foregroundStyle(liveTheme.secondaryText(on: liveTheme.panelBackground))
                // M34: this used to print the ratio itself ("1.2:1") right
                // here, in the most-used part of the builder - exactly the
                // jargon the guidance panel below exists to keep him from
                // ever having to read. The hex stays (it's the colour's
                // identity, not a score); a colour that's actually failing
                // gets a quiet dot instead, with no number on it, worded
                // with the same phrase the guidance panel's own header uses
                // ("may be hard to see") so the two never disagree. A
                // passing colour shows nothing extra at all.
                if let finding = worstFinding, !finding.passes {
                    Circle()
                        .fill(liveTheme.destructive)
                        .frame(width: 6, height: 6)
                        .accessibilityIdentifier("colorTokenRow.contrastFlag.\(token ?? label)")
                        .help("May be hard to see. See the guidance below.")
                }
            }
        }
        .padding(.vertical, Spacing.inline)
        .padding(.horizontal, Spacing.tight)
        // T3-M10: was `SettingsPalette.hover` (system-appearance bound via
        // `Color.primary`); `cardHoverBackground` is this theme's own token.
        .background((isSelected || isFlashed) ? liveTheme.cardHoverBackground : Color.clear,
                    in: RoundedRectangle(cornerRadius: liveTheme.radiusControl, style: .continuous))
        // M19: a flashed row also gets a brief accent ring, so "selected in
        // the token column" and "just flashed by an Inspect click" read as
        // two different things even where a theme's own hover wash and
        // accent happen to sit close together.
        .overlay(
            RoundedRectangle(cornerRadius: liveTheme.radiusControl, style: .continuous)
                .strokeBorder(isFlashed ? liveTheme.accent : .clear, lineWidth: 1.5)
        )
        .animation(.easeOut(duration: 0.2), value: isFlashed)
        .contentShape(Rectangle())
        .accessibilityIdentifier("colorTokenRow.\(token ?? label)")
        // M19: the id `ScrollViewReader.scrollTo` addresses from an Inspect
        // click - `token`, falling back to `label` for the handful of
        // optional fields with no graded token name, so `.id` is always
        // unique and stable across this row's own re-renders.
        .id(token ?? label)
    }

    private var swatch: some View {
        Button {
            selection = token
            showEditor = true
        } label: {
            ZStack {
                CheckerboardBackground()
                RoundedRectangle(cornerRadius: liveTheme.radiusControl, style: .continuous)
                    .fill(Color(nsColor: NSColor(hex: hex) ?? .textBackgroundColor))
            }
            .frame(width: 56, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: liveTheme.radiusControl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: liveTheme.radiusControl, style: .continuous)
                    .stroke(liveTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showEditor, arrowEdge: .trailing) {
            ColorEditor(hex: $hex, title: label, theme: liveTheme, onClose: { showEditor = false })
        }
        // The colour a person settled on, for the picker's Recent swatches.
        .onChange(of: showEditor) { _, open in
            if !open { ColorEditor.remember(hex) }
        }
    }
}
