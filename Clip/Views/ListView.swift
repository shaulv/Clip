import SwiftUI

/// The dense, keyboard-first view — closest to Maccy, but still typed and visual.
struct ListView: View {
    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager

    private var t: AppTheme { theme.theme }

    /// Same rule as everywhere else: only on the default sort with no search.
    private var canReorder: Bool {
        store.query.isEmpty && store.sortOrder == .newest
    }

    var body: some View {
        Group {
            if store.visibleItems.isEmpty {
                EmptyStateView(query: store.query, filtered: !store.activeFilters.isEmpty)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // Bumped from 3pt: the smallest scale step still
                        // reads as a dense, keyboard-first list.
                        LazyVStack(spacing: Spacing.inline) {
                            // Iterates the memoised array directly - no
                            // `Array(...enumerated())` allocation on every
                            // body evaluation - and looks the row's index up
                            // from the dictionary `visibleItems` builds once
                            // per derivation, not once per render.
                            ForEach(store.visibleItems) { item in
                                ListRow(item: item, index: store.visibleIndex(of: item.id), theme: t,
                                        selected: store.selectedID == item.id,
                                        pinned: store.isPinned(item.id),
                                        onActivate: {
                                            store.activatePrimary(item, presentation: .historyList)
                                        })
                                    // Lets SwiftUI skip a row whose inputs did
                                    // not change, instead of re-diffing every
                                    // row on every store publish.
                                    .equatable()
                                    .id(item.id)
                                    .reorderable(item, in: store.visibleItems,
                                                 enabled: canReorder)
                            }
                            ReorderTailTarget(collection: store.visibleItems, enabled: canReorder)
                        }
                        // M10b: a tab switch replaces this whole array with a
                        // disjoint one. A mouse-click tab switch wraps
                        // `store.setTab` in its own `withAnimation` spring
                        // (`TabsView.tab(_:)`, for the tab-indicator's
                        // `matchedGeometryEffect`) - without this, that ambient
                        // animation would implicitly animate every row's
                        // insertion/removal too, up to 200 of them, instead of
                        // being scoped to the indicator it was meant for. A
                        // row's own local `.animation(value:)` (the reorder
                        // drop-target highlight) still applies: this only
                        // overrides the ambient default, not an explicit one
                        // set closer in.
                        .transaction { $0.animation = nil }
                        .padding(.bottom, Spacing.tight)
                    }
                    // One row per step in the list.
                    .onAppear { store.selectionStride = 1 }
                    .onChange(of: store.selectedID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
    }
}

struct ListRow: View, Equatable {
    let item: ClipboardItem
    let index: Int
    /// Handed in rather than read from the environment, so that `==` below can
    /// actually see them. A value a view reads but does not store cannot be
    /// compared, and an Equatable blind to an appearance-driving input is
    /// worse than no Equatable at all.
    let theme: AppTheme
    let selected: Bool
    let pinned: Bool
    /// What a tap does - selecting and pasting this item. A closure rather
    /// than `@EnvironmentObject var store: HistoryStore`, which this row used
    /// to hold for exactly this one call: an `@EnvironmentObject` subscribes
    /// the row to every one of the store's 24 published properties, so it
    /// re-rendered on every store publish regardless of `.equatable()` above
    /// it - the wrapper only skips a body call when the PARENT re-diffs this
    /// view's value, and a live `@EnvironmentObject` subscription invalidates
    /// the view directly, bypassing that entirely. `onActivate` is excluded
    /// from `==` below like every other closure would be, since it never
    /// changes what the row draws.
    let onActivate: () -> Void

    @State private var hovering = false

    private var t: AppTheme { theme }
    /// What this row is actually painted on.
    ///
    /// Every color below is resolved against it rather than against the card,
    /// because the selected row is a different background entirely. Painting the
    /// authored accent on it is what made the shortcut badge disappear at
    /// 1.37:1 on Graphite's selection blue.
    private var surface: Color {
        if selected { return t.selectedBackground }
        return hovering ? t.cardHoverBackground : t.cardBackground
    }
    private var tint: Color { t.tint(for: item.kind, on: surface) }
    private var accentText: Color { t.accentText(on: surface) }

    var body: some View {
        HStack(spacing: Spacing.related) {
            leading

            VStack(alignment: .leading, spacing: Spacing.inline) {
                Text(item.displayTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(t.text(on: surface))
                    .lineLimit(1)
                HStack(spacing: Spacing.inline) {
                    Text(item.typeLabel)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                    // The address is the title now, so this line carries what the
                    // page calls itself instead - the part that tells one Figma
                    // file from another.
                    if item.kind == .url {
                        if let page = item.pageTitle, !page.isEmpty {
                            Text("· \(page)")
                                .font(.system(size: 9))
                                .foregroundStyle(t.tertiaryText(on: surface))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    } else if let description = item.documentDescription {
                        // For any document the name alone does not say whether you
                        // want it; the document's own description does.
                        Text("· \(description)")
                            .font(.system(size: 9))
                            .foregroundStyle(t.tertiaryText(on: surface))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if let app = item.sourceAppName {
                        Text("· \(app)").font(.system(size: 9)).foregroundStyle(t.tertiaryText(on: surface))
                    }
                    Text("· \(item.timeShort)").font(.system(size: 9)).foregroundStyle(t.tertiaryText(on: surface))
                    Text("· \(item.dateLabel)")
                        .font(.system(size: 9))
                        .foregroundStyle(t.tertiaryText(on: surface))
                        .lineLimit(1)
                    if item.useCount > 0 {
                        Text("· used \(item.useCount) time\(item.useCount == 1 ? "" : "s")").font(.system(size: 9)).foregroundStyle(t.tertiaryText(on: surface))
                    }
                }
            }

            Spacer(minLength: Spacing.tight)

            // Always present so the row cannot change height; revealed by
            // hover or by being the selected row.
            ItemActionCluster(item: item, theme: t,
                              hovering: hovering, selected: selected, compact: true)
                .reportItemFrame(.actions, of: item.id)

            // M19: each of these is its own answer to "what paints this" - the
            // pin and the shortcut are the accent, the quick-paste badge is
            // tertiary text. Tagged individually because a 9pt glyph the
            // pointer can land on must resolve to its own token, not to the
            // row it sits in.
            if pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(accentText)
                    .themeTokens(["accentOnCard"])
            }
            if let s = item.shortcut, !s.isEmpty {
                Text(Shortcut.display(s))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(accentText)
                    .themeTokens(["accentOnCard"])
            }
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(t.tertiaryText(on: surface))
                    .accessibilityIdentifier("card.quickPasteBadge")
                    .reportItemFrame(.badge, of: item.id)
                    .themeTokens(["textTertiary"])
            }
        }
        .padding(.horizontal, Spacing.related)
        .frame(height: 44)
        .rowChrome(t, hovering: hovering, selected: selected)
        .contentShape(Rectangle())
        // M19: background states first (`rowChrome`'s own fill/ring
        // tokens), then the foreground pieces this row paints - title,
        // secondary/tertiary text, and its own kind tint/chip.
        .themeTokens(["cardBackground", "cardHoverBackground", "selectedBackground",
                      "selectionStroke", "hoverStroke", "border",
                      "textPrimary", "textTertiary", "typeTint.\(item.kind.rawValue)"])
        .onTapGesture { onActivate() }
        .onHover { hovering = $0 }
        .contextMenu { ItemContextMenu(item: item) }
    }

    /// Every field the row's appearance depends on:
    /// - `item` (title, type, page title, description, source app, times, use
    ///   count, shortcut, colour, thumbnail) - the whole struct, because a
    ///   partial compare is how stale rendering starts;
    /// - `index` draws the command-number badge;
    /// - `theme` supplies every colour, including the surface the text
    ///   contrast is resolved against;
    /// - `selected` changes the fill, the ring AND that surface;
    /// - `pinned` draws the pin.
    ///
    /// `hovering` is `@State` and invalidates this view directly. The action
    /// cluster is a separate view with its own store subscription, so its
    /// focus ring keeps updating even when the row around it is skipped.
    static func == (lhs: ListRow, rhs: ListRow) -> Bool {
        lhs.item == rhs.item
            && lhs.index == rhs.index
            && lhs.theme == rhs.theme
            && lhs.selected == rhs.selected
            && lhs.pinned == rhs.pinned
    }

    private var leading: some View {
        ItemAvatar(item: item, theme: t, surface: surface)
    }
}

/// The 30pt square at the head of a row: a thumbnail, a colour swatch, an
/// emoji, or the kind glyph on its own chip.
///
/// Its own struct, not an inline `@ViewBuilder` inside `ListRow`, for one
/// reason: Inspect can only report what carries a `.themeTokens` tag, and the
/// convention is one tag per themed STRUCT. Inline, the smallest thing the
/// pointer could resolve to was the whole row - a click on the avatar answered
/// with the row's background tokens, which is not what the avatar is painted
/// with (the user's report: "help inspect even the smallest element like the
/// item card left avatar").
struct ItemAvatar: View {
    let item: ClipboardItem
    let theme: AppTheme
    /// What the avatar sits on, so the kind chip resolves its contrast against
    /// the row's real background rather than the card's.
    let surface: Color

    private var t: AppTheme { theme }

    var body: some View {
        content.themeTokens(tokens)
    }

    /// A thumbnail, a saved colour and an emoji are painted by the ITEM, not by
    /// the theme - saying so is the honest answer, and it is a different answer
    /// from "nothing is tagged here".
    private var tokens: [String] {
        switch item.kind {
        case .image, .video, .color, .emoji:
            return [ThemeInspectRegistry.notThemed]
        default:
            return ["typeTint.\(item.kind.rawValue)"]
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .image, .video:
            MediaPreview(item: item, theme: t, maxWidth: 40, maxHeight: 30,
                         cornerRadius: t.radiusControl)
                .frame(width: 40, height: 30, alignment: .leading)
        case .color:
            RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous)
                .fill(item.hexColor.flatMap { Color(nsColor: NSColor(hex: $0) ?? .gray) } ?? .gray)
                .frame(width: 30, height: 30)
        case .emoji:
            Text(item.fullText).font(.system(size: 20)).frame(width: 30, height: 30)
        default:
            let chip = t.chipColors(for: item.kind, on: surface)
            Image(systemName: item.kind.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(chip.foreground)
                .frame(width: 30, height: 30)
                .background(chip.fill, in: RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous))
        }
    }
}
