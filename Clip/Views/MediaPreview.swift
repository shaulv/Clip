import SwiftUI
import AppKit

/// Thumbnail for image and video items.
///
/// The layout rule that matters: the picture must never influence the size of
/// the thing containing it. A `resizable()` Image still reports an ideal size,
/// and inside a `LazyVGrid` with flexible columns that ideal width leaks out and
/// stretches the whole column — which is why one wide screenshot was three times
/// the width of its neighbours.
///
/// The fix is to hang the image off a container with *no* intrinsic size
/// (`Color.clear`), so sizing flows strictly parent → child, never back up.
struct MediaPreview: View {
    let item: ClipboardItem
    let theme: AppTheme
    /// Longest edge the thumbnail may occupy. Height follows the real ratio.
    var maxWidth: CGFloat = .infinity
    var maxHeight: CGFloat = .infinity
    var cornerRadius: CGFloat = 8
    /// `fill` crops to the box (grid cards); `fit` shows the whole frame (detail).
    var contentMode: ContentMode = .fill

    @State private var image: NSImage?
    /// Set once `load()` has confirmed the file is genuinely unavailable (as
    /// opposed to still decoding) - distinguishes the ordinary brief moment
    /// between mount and decode from an actual missing or too-large file, so
    /// the placeholder text does not flash on every normal render.
    @State private var missingReason: String?

    /// Real aspect ratio when we recorded it, else a sane 4:3.
    private var ratio: CGFloat {
        guard let w = item.pixelWidth, let h = item.pixelHeight, w > 0, h > 0 else { return 4.0 / 3.0 }
        return CGFloat(w) / CGFloat(h)
    }

    var body: some View {
        Color.clear
            .aspectRatio(ratio, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else {
                    placeholder
                }
            }
            .overlay {
                if item.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(radius: 4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .frame(maxWidth: maxWidth, maxHeight: maxHeight)
            .task(id: item.id) { await load() }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(theme.surfaceBackground)
            .overlay {
                if let missingReason {
                    // A hole where the picture should be is indistinguishable
                    // from nothing having happened (M4 row 19) - so a
                    // confirmed-missing file gets the reason in words, not
                    // just the generic kind icon every other placeholder uses.
                    VStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.textTertiary)
                        Text(missingReason)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)
                    }
                } else {
                    Image(systemName: item.kind.symbol).foregroundStyle(theme.textTertiary)
                }
            }
    }

    /// Decoding happens off the main thread; `MediaStore` caches the result.
    ///
    /// Image, video, file and folder items are local-only (M5 REVISED): the
    /// file either exists on this Mac's disk or it does not, and there is
    /// nowhere else to ask - a missing file was never pushed anywhere, so
    /// there is no server copy to fetch it back from.
    private func load() async {
        guard let file = item.imageFile else { return }

        if let cg = await Self.decode(file) {
            await MainActor.run {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                missingReason = nil
            }
            return
        }

        await MainActor.run {
            missingReason = "This image is no longer on disk"
            NoticeCenter.shared.report(StorageFailure.mediaMissing(file: file))
        }
    }

    private static func decode(_ file: String) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            MediaStore.shared.cgImage(for: file, maxDimension: 500)
        }.value
    }
}

/// The action cluster shared by every item surface.
///
/// Move used to be a SwiftUI `Menu` so the pointer got a dropdown directly. It
/// looked right and behaved wrong: a `Menu` swallows hover tracking on macOS, so
/// `.onHover` never fired and that one button stayed dead while its neighbours
/// lit up. It is now an ordinary button that opens the same destination picker
/// the keyboard uses — one code path, and the hover state comes for free.
///
/// Three rules learned the hard way:
/// 1. **It never changes layout.** The cluster is always in the view tree and
///    only its opacity changes, so a row cannot grow or jump when hovered.
/// 2. **Selection reveals it too.** Arrowing onto a row shows exactly what
///    hovering shows, so the keyboard is not a second-class citizen.
/// 3. **Its buttons are individually focusable.** Right arrow steps into them.
struct ItemActionCluster: View {
    let item: ClipboardItem
    let theme: AppTheme
    /// True when the pointer is over the row.
    var hovering: Bool = false
    /// True when this row is the selected one.
    var selected: Bool = false
    var compact: Bool = false

    @EnvironmentObject var store: HistoryStore

    /// 26pt: the previous 20pt target was too small to hit comfortably.
    private var side: CGFloat { compact ? 24 : 26 }

    private var actions: [ItemAction] {
        ItemAction.available(for: item, isPinned: store.isPinned(item.id))
    }

    private var isVisible: Bool { hovering || selected }

    /// True only for the pin button on an item that is not already pinned,
    /// once the global cap is reached - the one button that would otherwise
    /// mint a fifth pin. An already-pinned item's own pin control is never
    /// touched by this, so unpinning stays available at the cap.
    private var pinAtCap: Bool {
        !store.isPinned(item.id) && store.pinnedIDs.count >= HistoryStore.maxPinnedItems
    }

    var body: some View {
        HStack(spacing: Spacing.inline) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                button(action, index: index)
            }
        }
        // Both settle on the same step: the app's smallest real gap has no
        // room for a second, tighter tier below it.
        .padding(Spacing.inline)
        // Always laid out; only visibility changes. This is what stops the jump.
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(.easeOut(duration: 0.12), value: isVisible)
    }

    private func button(_ action: ItemAction, index: Int) -> some View {
        let focused = selected && store.focusedActionIndex == index
        let disabled = action == .pin && pinAtCap
        return ActionButton(action: action, focused: focused, theme: theme,
                            side: side, compact: compact,
                            isPinned: store.isPinned(item.id),
                            isPrompt: item.role == .prompt,
                            disabled: disabled) {
            store.select(item.id)
            store.perform(action, on: item)
        }
    }
}

/// The one icon-button chrome, in three weights.
///
/// Three surfaces were drawing the same idea three times: the round action
/// button in a row, the round pill in the header toolbar, and the little X that
/// dismisses a notice. Same shape, same disc, same ring - three separate
/// implementations that had already drifted (the panel's X had no background
/// and no hover at all). This is the item variant, the most configured of the
/// three, generalised: the other two are lighter settings of it, not new
/// components.
///
/// The weights carry meaning and so all four survive:
/// - `.item` is loud because it appears on hover inside a row and has to be
///   found quickly among content.
/// - `.toolbar` is always visible, so it rests quietly and only reacts to a
///   press.
/// - `.dismiss` is deliberately the quietest: it is never the thing you came
///   for, but it must still answer the pointer.
/// - `.cardAction` is `.item`'s own row-of-buttons sibling, split out rather
///   than folded into `.item` (M-cardAction, user 06/09): `.item` draws on
///   `.ultraThinMaterial`, a system material with no measurable color, which
///   is exactly what made the row's copy/open/edit/pin/move/delete buttons
///   unreadable on a light selected card - a dark grey button, a darker grey
///   glyph, a muted red delete glyph, none of it graded by anything. This
///   variant draws on `theme.cardActionFill` instead (a real, audited
///   token - see `AppTheme`), with its own icon colors tuned against that
///   fill, and keeps a resting hairline edge so it reads as its own chip even
///   where the fill sits close in tone to the card under it.
enum IconButtonVariant {
    case item
    case toolbar
    case dismiss
    case cardAction
}

/// Chrome only. Each call site keeps its own container (a `Button`, a
/// `ButtonStyle`, a `Menu` label), because those differ for real reasons; what
/// they share is what it looks like, and that now lives here once.
struct IconButtonChrome: ViewModifier {
    let theme: AppTheme
    var variant: IconButtonVariant = .item
    /// Fixed square side for the sized variants. `nil` means "hug the glyph
    /// and pad", which is what the dismiss X does.
    var side: CGFloat?
    /// Pointer hover OR keyboard focus. The two render identically on purpose,
    /// so reaching a control by keyboard is not a second-class experience.
    var highlighted: Bool = false
    /// Keyboard focus specifically, which only picks the ring colour.
    var focused: Bool = false
    var pressed: Bool = false
    /// Tints the disc, never the ring. See `ActionButton`.
    var destructive: Bool = false
    /// Design rule (user, 03/09): a disabled control never draws hover.
    @Environment(\.isEnabled) private var isEnabled
    private var lit: Bool { highlighted && isEnabled }

    /// The ring weight shared by every icon button, regardless of colour or
    /// variant. One number, so it cannot drift per call site the way a
    /// repeated literal could.
    static let ringWidth: CGFloat = 2

    private var padding: CGFloat {
        if side != nil { return 0 }
        return variant == .toolbar ? Spacing.related : Spacing.inline
    }

    private var restingFill: AnyShapeStyle {
        switch variant {
        case .item:       return AnyShapeStyle(.ultraThinMaterial)
        case .toolbar:    return AnyShapeStyle(pressed ? theme.cardHoverBackground : theme.surfaceBackground)
        case .dismiss:    return AnyShapeStyle(Color.clear)
        case .cardAction: return AnyShapeStyle(theme.cardActionFill)
        }
    }

    private var highlightFill: Color? {
        guard lit else { return nil }
        if destructive { return theme.destructive.opacity(0.18) }
        return theme.actionHoverFill
    }

    /// The toolbar pill and the card-action chip are both outlined at rest,
    /// for two different reasons: the toolbar pill always shows its own
    /// border, and the card-action chip needs a visible edge because its
    /// fill is deliberately quiet (`ThemeRules.Level.chipFill`, 1.1:1 - real,
    /// but short of an indicator ring) - "clearly distinguishable, or a
    /// visible edge" is answered by the fill and this edge together. `.item`
    /// and `.dismiss` draw a ring only while pointed at or focused.
    private var strokeColor: Color {
        if lit { return focused ? theme.focusRing : theme.hoverStroke }
        switch variant {
        case .toolbar, .cardAction: return theme.border
        case .item, .dismiss:       return .clear
        }
    }

    private var strokeWidth: CGFloat {
        if lit { return variant == .item || variant == .cardAction ? Self.ringWidth : 1 }
        switch variant {
        case .toolbar, .cardAction: return 1
        case .item, .dismiss:       return 0
        }
    }

    private var scale: CGFloat {
        switch variant {
        case .item, .cardAction: return lit ? 1.12 : 1
        case .toolbar:           return pressed ? 0.94 : 1
        case .dismiss:           return lit ? 1.08 : 1
        }
    }

    /// M19: every token this one chrome can paint with, across its four
    /// variants - every icon-only button in the app (the header's sort/
    /// settings pills, a row's hover actions, a notice's dismiss X) renders
    /// through this one modifier, so tagging it here covers all of them.
    private var tagTokens: [String] {
        var tokens: [String] = ["hoverStroke", "focusRing"]
        switch variant {
        case .item:       tokens.append(contentsOf: ["actionHoverFill"])
        case .toolbar:    tokens.append(contentsOf: ["surfaceBackground", "cardHoverBackground", "border"])
        case .dismiss:    break
        case .cardAction: tokens.append(contentsOf: ["cardActionFill", "border", "actionHoverFill",
                                                     destructive ? "cardActionDestructiveIcon" : "cardActionIcon"])
        }
        if destructive { tokens.append("destructive") }
        return tokens
    }

    func body(content: Content) -> some View {
        // `scale` is the "lift" feedback (grows the `.item`/`.dismiss` glyph
        // on hover, shrinks the `.toolbar` pill on press) and it must land on
        // the GLYPH only. It used to sit after `.background`/`.overlay`,
        // which scaled the disc and ring too - a Circle drawn exactly at
        // `side` then rendered ~12% larger than `side`, so the highlight
        // visibly spilled past the control's own frame on hover (M18, user
        // screenshot). The disc/ring below are drawn once, at the fixed
        // `side` size, and are never touched by `scale` - so what a pointer
        // sees light up can never be bigger than the button it is lighting.
        // A sized control is a circle; a toolbar control with no fixed side
        // (text beside a glyph, like the time filter) is the same chrome as a
        // capsule, so "Any time" is the settings button stretched for a word.
        let shape = AnyShape(side == nil && variant == .toolbar ? AnyShape(Capsule()) : AnyShape(Circle()))
        content
            .scaleEffect(scale)
            .padding(padding)
            .frame(width: side, height: side ?? (variant == .toolbar ? 32 : nil))
            .background {
                shape.fill(restingFill)
                if let highlightFill {
                    shape.fill(highlightFill)
                }
            }
            .overlay {
                if side == nil && variant == .toolbar {
                    Capsule().strokeBorder(strokeColor, lineWidth: strokeWidth)
                } else {
                    Circle().strokeBorder(strokeColor, lineWidth: strokeWidth)
                }
            }
            // Belt and suspenders: even though nothing after this point is
            // scaled any more, clip to the same shape so any future
            // modifier added here (a shadow, another overlay) can never
            // paint outside the control's own frame either.
            .clipShape(shape)
            .contentShape(shape)
            .themeTokens(tagTokens)
    }
}

extension View {
    /// Applies the shared icon-button chrome.
    func iconButtonChrome(_ theme: AppTheme,
                          variant: IconButtonVariant = .item,
                          side: CGFloat? = nil,
                          highlighted: Bool = false,
                          focused: Bool = false,
                          pressed: Bool = false,
                          destructive: Bool = false) -> some View {
        modifier(IconButtonChrome(theme: theme, variant: variant, side: side,
                                  highlighted: highlighted, focused: focused,
                                  pressed: pressed, destructive: destructive))
    }
}

/// One action button.
///
/// Pointer hover and keyboard focus render **identically** — the same ring and
/// the same lift — so the two ways of reaching an action feel like one feature
/// rather than two. Every button in the cluster shares this ONE ring, full
/// stop: same shape, same `ringWidth`, and now the same colour tokens
/// (`hoverStroke` / `focusRing`) too, delete included - a row of otherwise
/// identical buttons must not speak two hover languages. The destructive
/// colour still marks the icon and the hover disc's fill below; only the ring
/// itself was asked to match, and now does.
private struct ActionButton: View {
    let action: ItemAction
    let focused: Bool
    let theme: AppTheme
    let side: CGFloat
    let compact: Bool
    let isPinned: Bool
    let isPrompt: Bool
    /// True only for the pin button once the global cap is reached and this
    /// item is not already pinned. The control stays in the layout and
    /// reachable by mouse and keyboard alike - only its tap and its "looks
    /// clickable" cues are turned off - so hover or focus can still surface
    /// the explanation below.
    var disabled: Bool = false
    let run: () -> Void

    @State private var hovering = false
    /// "Copied" tooltip after the copy action: 4 s, then gone at once.
    @State private var copiedUntil: Date?
    private var showingCopied: Bool { (copiedUntil ?? .distantPast) > Date() }

    /// The ring/lift weight shared by every button in the cluster, regardless
    /// of colour. One number, read by every button, so it cannot drift per
    /// button the way a repeated literal could.
    private var highlighted: Bool { focused || hovering }
    /// The hover/focus disc, ring and lift all imply "this is clickable", so
    /// none of them draw while the control is disabled - only the tooltip
    /// (below) still does, which is the one thing a disabled control still
    /// owes the person hovering or tabbing onto it.
    private var highlightedVisual: Bool { highlighted && !disabled }

    var body: some View {
        Button(action: {
            run()
            if action == .copy {
                copiedUntil = Date().addingTimeInterval(4)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_050_000_000)
                    if let until = copiedUntil, until <= Date() { copiedUntil = nil }
                }
            }
        }) {
            Image(systemName: action.symbol(isPinned: isPinned, isPrompt: isPrompt))
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                // `cardActionIcon`/`cardActionDestructiveIcon` (M-cardAction,
                // user 06/09): tuned against `cardActionFill` itself, not
                // `textPrimary`/`textSecondary`/`destructive`, which were only
                // ever measured against `cardBackground`/`cardHoverBackground`/
                // `selectedBackground` - a different, uncontrolled surface
                // (`.ultraThinMaterial`) sat between them and the eye, which is
                // exactly what read as a low-contrast grey button and a muted
                // red delete glyph on a light selected card. One color serves
                // both idle and highlighted here (unlike the old textSecondary/
                // textPrimary split) because it is already tuned to clear
                // 4.5:1 against the fill AND against the fill with the hover
                // wash composited on top - see `AppTheme.cardActionIcon`.
                .foregroundStyle(disabled
                                 ? theme.tertiaryText(on: theme.cardActionFill)
                                 : (action.isDestructive
                                    ? theme.cardActionDestructiveIcon
                                    : theme.cardActionIcon))
                // Same shape, same ring width and the same colour tokens as
                // every other icon button in the app, delete included - the
                // ring itself was asked to match its neighbours, not just its
                // geometry. `theme.destructive` still tints the hover disc's
                // fill (via `destructive:`); it no longer reaches the ring.
                .iconButtonChrome(theme, variant: .cardAction, side: side,
                                  highlighted: highlightedVisual,
                                  focused: focused,
                                  destructive: action.isDestructive)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        // Kept as well: `.help` is what VoiceOver reads and what the system
        // shows on a long hover. It just cannot do the other two things -
        // appear for KEYBOARD focus, and be placed where we want it.
        .help(label)
        // Published, not drawn. A list row is 44pt, so a label drawn here has
        // nowhere to go that is not covered by the row above or below; the
        // panel draws it instead. See `ActionTooltip`. Driven by `highlighted`
        // (not `highlightedVisual`) so a disabled pin button still explains
        // itself on hover or keyboard focus - hover-only would leave it
        // unreachable without a mouse.
        .actionTooltip(showingCopied ? "Copied" : label, showing: highlighted || showingCopied)
        .animation(.easeOut(duration: 0.12), value: highlightedVisual)
    }

    private var label: String {
        if disabled { return HistoryStore.pinCapExplanation }
        return action.label(isPinned: isPinned, isPrompt: isPrompt)
    }
}


/// The card treatment every row shares: fill, hover, selection ring.
///
/// The two list surfaces had drifted apart. A row in the All tab was transparent
/// until touched and drew a faint accent hairline when selected, while a row in
/// Prompts was a filled card with a two-point ring. Same interaction, two
/// different answers, so selecting an item looked like a different feature
/// depending on which tab you were standing in. One modifier now decides it, and
/// neither surface can wander off again.
struct RowChrome: ViewModifier {
    let theme: AppTheme
    let hovering: Bool
    let selected: Bool
    /// A gathered card stays ringed in the accent even when the cursor is
    /// elsewhere, or a gathered set becomes invisible the moment you arrow
    /// away from it. Rows do not offer gathering, so they leave this off.
    var marked: Bool = false
    /// Gallery cards float above the grid; list rows sit flat in it. This is
    /// the one thing the card treatment had that rows genuinely do not want.
    var shadow: Bool = false

    /// The one card radius. Gallery cards used the full
    /// `theme.cornerRadius` while rows used this; there was never a reason for
    /// two, and a grid and a list of the same items should not round
    /// differently. Now named on `AppTheme` itself as `radiusCard`, so every
    /// other content surface can share this exact rule instead of picking its
    /// own nearby number.
    private var radius: CGFloat { theme.radiusCard }

    /// Exposed so a card can clip its own hit area to the same shape.
    static func radius(_ theme: AppTheme) -> CGFloat { theme.radiusCard }

    /// Selected rows use the theme's own selection color.
    ///
    /// Matching Prompts exactly would have meant selection was carried by the
    /// ring alone, which left `selectedBackground` rendering nowhere at all
    /// while the theme builder still offered it as an editable color. A token
    /// the interface never draws is a lie in the settings pane, and a ring on
    /// its own is a weak signal at a glance.
    private var fill: Color {
        if selected { return theme.selectedBackground }
        return hovering ? theme.cardHoverBackground : theme.cardBackground
    }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                    // Zeroed rather than branched: a shadow of radius 0 in a
                    // clear colour draws nothing, so rows pay no cost for a
                    // parameter only the grid uses.
                    .shadow(color: .black.opacity(shadow ? (selected ? 0.28 : 0.12) : 0),
                            radius: shadow ? (selected ? 10 : 4) : 0,
                            y: shadow ? (selected ? 4 : 2) : 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    // Selection and hover are separate tokens: a row you are
                    // pointing at and a row that is chosen are two different
                    // statements, and a theme can now say them differently.
                    // Marked outranks both: it is the only one of the three
                    // that has to survive losing the cursor AND the cursor
                    // moving to another item.
                    .strokeBorder(marked ? theme.accent
                                  : (selected ? theme.selectionStroke
                                     : (hovering ? theme.hoverStroke : theme.border)),
                                  lineWidth: (selected || marked) ? 2 : 1)
            )
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.12), value: selected)
            .animation(.easeOut(duration: 0.12), value: marked)
    }
}

extension View {
    /// Applies the shared row treatment.
    func rowChrome(_ theme: AppTheme, hovering: Bool, selected: Bool,
                   marked: Bool = false, shadow: Bool = false) -> some View {
        modifier(RowChrome(theme: theme, hovering: hovering, selected: selected,
                           marked: marked, shadow: shadow))
    }
}
