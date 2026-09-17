import SwiftUI
import AppKit

// MARK: - M9: badge/action-row frame probe

/// Reports the rendered frame of the quick-paste badge and the hover action
/// row, per item, into the shared `themeInspect` coordinate space
/// (`ThemeInspectRegistry.coordinateSpaceName`, already applied at
/// `PanelRootView`'s root - see that file's own doc comment) - the same
/// GeometryReader-in-the-background shape `ThemeTokenTagging.swift` already
/// uses for the theme builder's Inspect mode, reused here so this needs no
/// new coordinate space of its own.
///
/// This is the seam `m9_itemFrames` (`QABridge.swift`) reads to prove the
/// badge and the action row never share a pixel, in both the grid card
/// (`GalleryCard`) and the list row (`ListRow`) - requirement 1's own probe.
/// Recording is unconditional (not gated on hover/selection) on purpose: the
/// action row is "always laid out, only its opacity changes" by design
/// (`ItemActionCluster`'s own doc comment), so its LAYOUT frame is what
/// actually reserves pixels, regardless of whether it happens to be visible
/// at the instant a probe reads it.
@MainActor
final class ItemFrameProbe: ObservableObject {
    enum Slot: String { case badge, actions }
    static let shared = ItemFrameProbe()
    private init() {}

    private var frames: [UUID: [Slot: CGRect]] = [:]

    func set(_ slot: Slot, _ rect: CGRect, for id: UUID) {
        frames[id, default: [:]][slot] = rect
    }
    func clear(_ slot: Slot, for id: UUID) {
        frames[id]?[slot] = nil
    }
    func frame(_ slot: Slot, for id: UUID) -> CGRect? { frames[id]?[slot] }

    /// The self-test's own throwaway ids (`m9_frameProbeSelfTest`) call
    /// `clear` directly and explicitly, right after reading their result -
    /// that is safe because nothing else reports under those ids. A real
    /// card/row's `.reportItemFrame` never clears on disappear (see that
    /// modifier's own doc comment for why): switching gallery/list layout
    /// removes the old view and mounts the new one for the SAME item id in
    /// one transaction, and an unclear ordering between the old view's
    /// teardown and the new view's own `onAppear` let a stale clear wipe out
    /// a frame the new view had just reported a moment before - measured
    /// directly, reproducing 100% of the time on a gallery-to-list switch.
    /// A handful of stale `CGRect`s for QA-only, sandboxed test items is a
    /// non-issue; a flaky "no intersection" result would not be.

    /// `nil` when either frame has never been reported (nothing to compare -
    /// distinct from `false`, which means both exist and do not intersect).
    func intersects(for id: UUID) -> Bool? {
        guard let badge = frame(.badge, for: id), let actions = frame(.actions, for: id) else { return nil }
        return badge.intersects(actions)
    }
}

private struct ItemFrameReportModifier: ViewModifier {
    let slot: ItemFrameProbe.Slot
    let itemID: UUID
    @ObservedObject private var probe = ItemFrameProbe.shared

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                let rect = proxy.frame(in: .named(ThemeInspectRegistry.coordinateSpaceName))
                // No `.onDisappear { probe.clear(...) }` here on purpose -
                // see `ItemFrameProbe.clear`'s own doc comment: switching
                // gallery/list layout tears down the old view and mounts
                // the new one for the SAME item id in one transaction, and
                // a disappearing old view's clear could run after the new
                // view's own `onAppear` had just set the real frame,
                // wiping it. `set` always overwrites with the latest real
                // layout, so a genuinely removed item's stale entry is
                // simply never read again (nothing asks for its id).
                Color.clear
                    .onAppear { probe.set(slot, rect, for: itemID) }
                    .onChange(of: rect) { _, new in probe.set(slot, new, for: itemID) }
            }
        )
    }
}

extension View {
    /// Declares this view as the quick-paste badge or the hover action row
    /// for `id`, so `ItemFrameProbe` can answer whether the two ever
    /// overlap. See `ItemFrameProbe`'s own doc comment.
    func reportItemFrame(_ slot: ItemFrameProbe.Slot, of id: UUID) -> some View {
        modifier(ItemFrameReportModifier(slot: slot, itemID: id))
    }
}

/// One gallery card. The chrome (frame, selection ring, badges, hover actions)
/// is shared; only the middle preview changes per type, so a wall of very
/// different content still reads as one grid.
struct GalleryCard: View, Equatable {
    let item: ClipboardItem
    let index: Int
    let density: GalleryDensity
    /// Everything below is handed in rather than read out of the environment,
    /// and the reason is `==` below: a value the view reads but does not store
    /// cannot be compared, and an Equatable that cannot see an
    /// appearance-driving input renders stale. The grid already holds all
    /// four, so passing them costs nothing.
    let theme: AppTheme
    let selected: Bool
    let marked: Bool
    let pinned: Bool
    /// What a tap does - `true` for a command-click (gather: select and
    /// toggle-mark), `false` for a plain click (select and paste). A closure
    /// rather than `@EnvironmentObject var store: HistoryStore`, which this
    /// card used to hold for exactly this one call: an `@EnvironmentObject`
    /// subscribes the card to every one of the store's 24 published
    /// properties, so it re-rendered on every store publish regardless of
    /// `.equatable()` above it - the wrapper only skips a body call when the
    /// PARENT re-diffs this view's value, and a live `@EnvironmentObject`
    /// subscription invalidates the view directly, bypassing that entirely.
    /// `onTap` is excluded from `==` below like every other closure would be,
    /// since it never changes what the card draws.
    let onTap: (_ gather: Bool) -> Void

    @State private var hovering = false

    private var t: AppTheme { theme }
    /// What this card is actually painted on.
    ///
    /// Selection now paints `selectedBackground` here exactly as it does in the
    /// list (it arrives with the shared `RowChrome`), so the colours that must
    /// stay readable are resolved against that rather than against the resting
    /// card - the same trap the list row had already stepped out of.
    private var surface: Color {
        if selected { return t.selectedBackground }
        return hovering ? t.cardHoverBackground : t.cardBackground
    }
    private var tint: Color { t.tint(for: item.kind, on: surface) }
    private var accentText: Color { t.accentText(on: surface) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isCurated, let title = item.title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(t.textPrimary)
                    .lineLimit(1)
                    .padding(.bottom, Spacing.inline)
            }
            KindPreview(item: item, density: density)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            footer
        }
        .padding(Spacing.related)
        .frame(maxWidth: .infinity)
        .frame(height: density.cardHeight)
        // The card used to hand-roll its own fill, ring and shadow beside the
        // identical treatment the two list surfaces already shared. It now
        // wears that one treatment, with the two things a card genuinely needs
        // and a row does not - `marked` and `shadow` - as parameters on it.
        // This is also what finally gives a gallery card a hover ring: the
        // hand-rolled version handled marked, selected and resting only, so
        // pointing at a card said nothing while pointing at a row said
        // something.
        .rowChrome(t, hovering: hovering, selected: selected,
                   marked: marked, shadow: true)
        .contentShape(RoundedRectangle(cornerRadius: RowChrome.radius(t), style: .continuous))
        // M19: background states first (`rowChrome`'s own fill/ring
        // tokens), then the foreground pieces this card paints - title,
        // secondary/tertiary text, and its own kind tint/chip.
        .themeTokens(["cardBackground", "cardHoverBackground", "selectedBackground",
                      "selectionStroke", "hoverStroke", "border", "accent",
                      "textPrimary", "textTertiary", "typeTint.\(item.kind.rawValue)"])
        .overlay(alignment: .topTrailing) { hoverActions }
        // Command-click gathers instead of pasting. The plain click still does
        // the fastest thing - paste - because that is what the panel is for.
        .onTapGesture {
            onTap(NSEvent.modifierFlags.contains(.command))
        }
        .onHover { hovering = $0 }
        .contextMenu { ItemContextMenu(item: item) }
        .help(item.previewText)
    }

    /// Compared so SwiftUI can skip re-diffing a card whose appearance cannot
    /// have changed. Every field the body reads is here:
    /// - `item` drives all of the content, including title, tags, shortcut,
    ///   use count and timestamps. The whole struct, not a few fields: a
    ///   partial compare is exactly how stale rendering starts;
    /// - `index` draws the command-number badge;
    /// - `density` sets the height and the preview line count;
    /// - `theme` supplies every colour;
    /// - `selected`, `marked` and `pinned` are the three store-derived states
    ///   the card paints.
    ///
    /// `hovering` is deliberately absent: it is `@State`, owned by this view,
    /// and its changes invalidate this view directly rather than through a
    /// parent's comparison. The action cluster is likewise absent because it
    /// is its own view with its own store subscription, so keyboard focus
    /// inside it still updates while the card around it is skipped.
    static func == (lhs: GalleryCard, rhs: GalleryCard) -> Bool {
        lhs.item == rhs.item
            && lhs.index == rhs.index
            && lhs.density == rhs.density
            && lhs.theme == rhs.theme
            && lhs.selected == rhs.selected
            && lhs.marked == rhs.marked
            && lhs.pinned == rhs.pinned
    }

    // MARK: Chrome

    /// Curated items lead with what they are; plain clips lead with their type.
    private var isCurated: Bool { item.role.isCurated }
    private var headerSymbol: String { isCurated ? item.role.symbol : item.kind.symbol }
    private var headerLabel: String {
        if isCurated { return item.role.title.uppercased() }
        return item.typeLabel
    }
    private var headerTint: Color { isCurated ? accentText : tint }

    private var header: some View {
        HStack(spacing: Spacing.tight) {
            // M19: the kind glyph and its label are the card's smallest
            // painted parts - tagged so Inspect answers for THEM, not for the
            // card behind them.
            Image(systemName: headerSymbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(headerTint)
                .themeTokens([isCurated ? "accentOnCard" : "typeTint.\(item.kind.rawValue)"])

            Text(headerLabel)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(headerTint)
                .themeTokens([isCurated ? "accentOnCard" : "typeTint.\(item.kind.rawValue)"])

            Spacer(minLength: Spacing.inline)

            if pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9)).foregroundStyle(accentText)
            }
        }
        .padding(.bottom, Spacing.tight)
    }

    // M9: the quick-paste badge used to live in the header, sharing the
    // card's top-right corner with `hoverActions` (an `.overlay(alignment:
    // .topTrailing)` pinned to that exact corner) - a hovered or selected
    // card with an assigned number drew the badge and the trash icon on
    // the same pixels, and both became unreadable. The overlay floats
    // independently of the header's own HStack layout, so nothing in that
    // row ever reserved room for it.
    //
    // The footer is a different region of the card: the action cluster is
    // sized to its own content (one row of ~26pt buttons) and pinned to the
    // top of the card, well clear of the footer at every fixed card height
    // (118pt at the smallest, `.compact`). Moving the badge here puts it in
    // an ordinary HStack row that lays out simultaneously with the
    // shortcut text - the two can never occupy the same pixels, and
    // neither one is ever hidden on hover, so it stays reachable by
    // keyboard exactly as before.
    private var footer: some View {
        HStack(spacing: Spacing.inline) {
            if let app = item.sourceAppName {
                Text(app).font(.system(size: 9)).foregroundStyle(t.tertiaryText(on: surface)).lineLimit(1)
                Text("\u{00B7}").foregroundStyle(t.tertiaryText(on: surface)).font(.system(size: 9))
            }
            Text(item.dateLabel)
                .font(.system(size: 9))
                .foregroundStyle(t.tertiaryText(on: surface))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let s = item.shortcut, !s.isEmpty {
                Text(Shortcut.display(s))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(accentText)
            }
            if index < 9 {
                Text("\u{2318}\(index + 1)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(t.tertiaryText(on: surface))
                    .accessibilityIdentifier("card.quickPasteBadge")
                    .reportItemFrame(.badge, of: item.id)
            }
        }
        .padding(.top, Spacing.tight)
    }

    private var hoverActions: some View {
        ItemActionCluster(item: item, theme: t,
                          hovering: hovering, selected: selected)
            .reportItemFrame(.actions, of: item.id)
    }

}

// MARK: - The per-type preview

/// Chooses how one item's content is shown. This is where "many copies, still
/// visual" is won or lost.
struct KindPreview: View {
    let item: ClipboardItem
    let density: GalleryDensity
    @EnvironmentObject var theme: ThemeManager
    private var t: AppTheme { theme.theme }

    var body: some View {
        switch item.kind {
        case .image, .video:
            HStack {
                MediaPreview(item: item, theme: t, maxHeight: .infinity, cornerRadius: t.radiusCard)
                Spacer(minLength: 0)
            }
        case .code:          CodePreview(item: item, density: density, theme: t)
        case .emoji:         EmojiPreview(item: item)
        case .color:         ColorPreview(item: item, theme: t)
        case _ where item.role.hasFrontMatter:
                             SkillPreview(item: item, theme: t)
        case .url:           LinkPreview(item: item, theme: t)
        case .file:          FilePreview(item: item, theme: t)
        default:             TextPreview(item: item, density: density, theme: t)
        }
    }
}

struct TextPreview: View {
    let item: ClipboardItem
    let density: GalleryDensity
    let theme: AppTheme

    var body: some View {
        Text(item.fullText)
            .font(.system(size: 12))
            .foregroundStyle(theme.textSecondary)
            .lineLimit(density.previewLines)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .themeTokens(["textSecondary"])
    }
}

/// Code keeps its shape: monospace, real line breaks, a tinted gutter.
struct CodePreview: View {
    let item: ClipboardItem
    let density: GalleryDensity
    let theme: AppTheme

    private var lines: [String] {
        item.fullText.components(separatedBy: .newlines).prefix(density.previewLines).map { $0 }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.tight) {
            Rectangle()
                .fill(theme.tint(for: .code))
                .frame(width: 2)
                .clipShape(Capsule())

            // Not on the spacing scale on purpose: this is code-line leading,
            // not a gap between UI elements, and the whole point is that it
            // reads as one contiguous block the way a real code line does.
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if item.lineCount > density.previewLines {
                    Text("+\(item.lineCount - density.previewLines) more")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .themeTokens(["typeTint.code", "textSecondary", "textTertiary"])
    }
}

struct EmojiPreview: View {
    let item: ClipboardItem
    var body: some View {
        Text(item.fullText)
            .font(.system(size: 44))
            .minimumScaleFactor(0.4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themeTokens([ThemeInspectRegistry.notThemed])
    }
}

/// Kept as a thin alias so existing call sites read naturally; all the sizing
/// rules live in `MediaPreview`.
struct ImagePreview: View {
    let item: ClipboardItem
    let theme: AppTheme
    var body: some View { MediaPreview(item: item, theme: theme) }
}

struct ColorPreview: View {
    let item: ClipboardItem
    let theme: AppTheme

    var body: some View {
        let color = item.hexColor.flatMap { Color(nsColor: NSColor(hex: $0) ?? .gray) } ?? .gray
        RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous)
            .fill(color)
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            )
            .overlay(alignment: .bottomLeading) {
                Text(item.hexColor?.uppercased() ?? "")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(Spacing.inline)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: theme.radiusControl))
                    .padding(Spacing.tight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themeTokens([ThemeInspectRegistry.notThemed])
    }
}

struct LinkPreview: View {
    let item: ClipboardItem
    let theme: AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.inline) {
            // The address leads. The host alone made every link from the same
            // service look identical, which is exactly the case a clipboard
            // history has a lot of.
            HStack(spacing: Spacing.tight) {
                Image(systemName: item.platform?.symbol ?? "globe")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.tint(for: .url))
                Text(item.shortURL.isEmpty ? (item.host ?? "link") : item.shortURL)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            // Underneath: what it is, and what the page calls itself.
            HStack(spacing: Spacing.inline) {
                Text(item.typeLabel)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.tint(for: .url))
                if let page = item.pageTitle, !page.isEmpty {
                    Text("· \(page)")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .themeTokens(["typeTint.url", "textPrimary", "textTertiary"])
    }
}

/// A skill card that says what the skill is for.
///
/// Skills render as a wall of markdown otherwise - starting with the front
/// matter, which is the least readable part of the document. A shelf of them
/// then shows twenty titles and no way to tell which one you want without
/// opening each. The document already answers that in its own `description`.
struct SkillPreview: View {
    let item: ClipboardItem
    let theme: AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if let description = item.skillDescription, !description.isEmpty {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // No description in the document: show its opening rather than
                // an empty card.
                Text(item.previewText)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(4)
            }

            if let usage = item.skillUsage, !usage.isEmpty {
                HStack(alignment: .top, spacing: Spacing.inline) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.accentOnCard)
                        // A baseline nudge, not a gap: aligns the glyph with
                        // the first line of text beside it, so off the scale.
                        .padding(.top, 2)
                    Text(usage)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("\(item.wordCount) word\(item.wordCount == 1 ? "" : "s")")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .themeTokens(["textSecondary", "accentOnCard", "textTertiary"])
    }
}

struct FilePreview: View {
    let item: ClipboardItem
    let theme: AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.inline) {
            ForEach(Array(item.filePaths.prefix(3).enumerated()), id: \.offset) { _, path in
                HStack(spacing: Spacing.tight) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable().frame(width: 16, height: 16)
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            if item.filePaths.count > 3 {
                Text("+\(item.filePaths.count - 3) more")
                    .font(.system(size: 9)).foregroundStyle(theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .themeTokens(["textSecondary", "textTertiary"])
    }
}

// MARK: - Shared context menu

struct ItemContextMenu: View {
    let item: ClipboardItem
    @EnvironmentObject var store: HistoryStore

    var body: some View {
        Button("Paste") { store.requestPaste(item) }
        Button("Paste as Plain Text") { store.requestPaste(item, plain: true) }
        Button("Copy Without Pasting") { store.copyOnly(item) }
        Divider()
        Button("Duplicate") { store.duplicate(item.id) }
        if item.kind == .url {
            let targets = LinkOpener.targets(for: item)
            if targets.count > 1 {
                Menu("Open With") {
                    ForEach(targets) { target in
                        Button(target.isDefault ? "\(target.name) (default)" : target.name) {
                            LinkOpener.open(item, with: target)
                        }
                    }
                }
            } else {
                Button("Open Link") { LinkOpener.open(item, with: targets.first) }
            }
            Divider()
        }
        if item.kind.isOnDisk {
            Button("Show in Finder") { store.revealInFinder(item) }
            Divider()
        }
        Button(store.isPinned(item.id) ? "Unpin" : "Pin") { store.togglePin(item.id) }
        Menu("Save as") {
            ForEach(ItemRole.allCases) { role in
                Button(role == item.role ? "\(role.title) ✓" : role.title) {
                    store.setRole(item.id, to: role)
                }
            }
        }
        Button("Edit…") { store.select(item.id); store.isDetailOpen = true }
        Divider()
        Button("Delete", role: .destructive) { store.deleteKeepingSelection(item.id) }
    }
}
