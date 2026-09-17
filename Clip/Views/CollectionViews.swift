import SwiftUI
import AppKit

/// Notes, Skills and Prompts are the same shape: a curated collection of items
/// with a name, a body and tags. One view serves all three so they stay
/// consistent, with only the wording and the "new" affordance differing.
struct RoleCollectionView: View {
    let role: ItemRole
    let layout: TabLayout
    let density: GalleryDensity

    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager

    private var t: AppTheme { theme.theme }
    private var items: [ClipboardItem] { store.items(withRole: role) }

    var body: some View {
        VStack(spacing: Spacing.tight) {
            toolbar
            if items.isEmpty {
                emptyState
                    .onAppear {
                        if store.focusedEmptyAction == nil { store.focusedEmptyAction = 0 }
                    }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: Spacing.tight) {
                            if !store.allTags.isEmpty { TagRail() }
                            if layout == .gallery { grid } else { list }
                        }
                        .padding(.bottom, Spacing.tight)
                    }
                    // Arrow keys move a whole row, so the stride follows the
                    // layout exactly as it does on any other tab.
                    .onAppear { store.selectionStride = stride }
                    .onChange(of: stride) { _, n in store.selectionStride = n }
                    .onChange(of: store.selectedID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
    }

    private var stride: Int { layout == .gallery ? density.columns : 1 }

    /// Whether dragging a card would mean anything right now.
    ///
    /// An arrangement is only honoured on the default sort with no search - any
    /// other view is the user asking a different question - so offering the
    /// gesture there would be offering one that silently does nothing.
    private var canReorder: Bool {
        store.query.isEmpty && store.sortOrder == .newest
    }

    /// `items` builds a fresh array on every access (it is its own filter and
    /// sort, not behind `visibleItems`' `DerivationKey` cache), so an index
    /// table for it lives exactly as long as one read of `items` does - built
    /// once here, not once per row via `Array(items.enumerated())`.
    private func indexByID(_ items: [ClipboardItem]) -> [UUID: Int] {
        var table: [UUID: Int] = [:]
        table.reserveCapacity(items.count)
        for (index, item) in items.enumerated() { table[item.id] = index }
        return table
    }

    private var list: some View {
        let rows = items
        let index = indexByID(rows)
        return LazyVStack(spacing: Spacing.tight) {
            ForEach(rows) { item in
                CuratedRow(item: item, index: index[item.id] ?? 0, theme: t,
                           selected: store.selectedID == item.id,
                           onActivate: {
                               store.activatePrimary(item, presentation: .curatedList)
                           })
                    .equatable()
                    .id(item.id)
                    .reorderable(item, in: rows, enabled: canReorder)
            }
            ReorderTailTarget(collection: rows, enabled: canReorder)
        }
        // M10b: see the matching comment in ListView.swift - a tab switch
        // must not let whatever ambient animation is active implicitly
        // animate every row's insertion/removal.
        .transaction { $0.animation = nil }
    }

    private var grid: some View {
        let rows = items
        let index = indexByID(rows)
        return VStack(spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: density.spacing),
                                     count: density.columns),
                      spacing: density.spacing) {
                ForEach(rows) { item in
                    GalleryCard(item: item, index: index[item.id] ?? 0, density: density,
                                theme: t,
                                selected: store.selectedID == item.id,
                                marked: store.markedIDs.contains(item.id),
                                pinned: store.isPinned(item.id),
                                onTap: { gather in
                                    if gather {
                                        store.select(item.id)
                                        store.toggleMark(item.id)
                                    } else {
                                        store.activatePrimary(item, presentation: .curatedGallery)
                                    }
                                })
                        .equatable()
                        .id(item.id)
                        .reorderable(item, in: rows, enabled: canReorder)
                }
            }
            // M10b: see the matching comment in ListView.swift - a tab
            // switch must not let whatever ambient animation is active
            // implicitly animate every card's insertion/removal.
            .transaction { $0.animation = nil }
            ReorderTailTarget(collection: rows, enabled: canReorder)
        }
    }

    private var toolbar: some View {
        HStack {
            toolbarButton(.create)
            toolbarButton(.pasteInto)
            Spacer()
            // Only once there is an arrangement to undo. A hand-arranged
            // collection has no other way back to the automatic order, and
            // "drag everything into date order by hand" is not one.
            if items.contains(where: { $0.manualOrder != nil }) {
                ClipLink("Reset order", size: .small) { store.clearManualOrder(in: items) }
                    .help("Go back to newest first. Your items are untouched.")
            }
            Text("\(items.count)")
                .font(.system(size: 11)).foregroundStyle(t.textTertiary)
        }
    }

    /// Focus is shown here as well as in the action clusters, so arrowing on an
    /// empty tab moves something the user can actually see.
    private func toolbarButton(_ action: HistoryStore.EmptyAction) -> some View {
        let focused = store.isEmptyTabFocusable
            && store.focusedEmptyAction == action.rawValue
        // "Create" is this tab's one CTA; "paste into" is the lesser of the
        // two, so it is the ghost. `forcedState: .focused` reuses the SAME
        // focus ring every other component draws, for keyboard navigation
        // between the two empty-state actions.
        return Group {
            if action == .create {
                PrimaryButton(action.title(role), systemImage: action.symbol, size: .small,
                              forcedState: focused ? .focused : nil, theme: t) {
                    store.performEmpty(action, role: role)
                }
            } else {
                GhostButton(action.title(role), systemImage: action.symbol, size: .small,
                            forcedState: focused ? .focused : nil, theme: t) {
                    store.performEmpty(action, role: role)
                }
            }
        }
    }

    /// True when the collection has content but the current search hides it.
    private var hiddenBySearch: Bool {
        items.isEmpty && store.count(ofRole: role) > 0
    }

    /// The shared empty state, told what this tab's version of it says.
    ///
    /// The base shape (icon, title, subtitle, centred) is `EmptyStateView`, the
    /// same one the history tabs use. What is genuinely different here - a
    /// "Clear search" way out, and copy that counts what the search is hiding -
    /// is passed to it, not re-implemented beside it.
    private var emptyState: some View {
        EmptyStateView(
            symbol: hiddenBySearch ? "magnifyingglass" : role.symbol,
            title: hiddenBySearch
                ? "No \(role.title.lowercased())s match \u{201C}\(store.query)\u{201D}"
                : "No \(role.title.lowercased())s yet",
            subtitle: hiddenBySearch
                ? "\(store.count(ofRole: role)) \(role.title.lowercased())s are hidden by the search."
                : hint,
            actionTitle: hiddenBySearch ? "Clear search" : nil,
            action: clearSearch
        )
    }

    /// Spelled out rather than written inline: a closure inside a ternary is
    /// the kind of expression the type checker gives up on.
    private var clearSearch: (() -> Void)? {
        guard hiddenBySearch else { return nil }
        let store = self.store
        return { store.query = "" }
    }

    private var hint: String {
        switch role {
        case .prompt: return "Right-click anything in Gallery or List and choose “Save as Prompt”, or start one here. Prompts survive history trimming and can each get a global shortcut."
        case .note:   return "Write a note, or paste something straight into one. Notes are never trimmed."
        case .skill:  return "A skill is a markdown document. Create one and the editor opens full screen with a live preview."
        case .design: return "A design document is a DESIGN.md file: tokens and the prose that explains them. Drop one here, or import a folder of them from Settings."
        case .clip:   return ""
        }
    }
}

/// Tag filter rail shared by the curated tabs.
struct TagRail: View {
    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager
    private var t: AppTheme { theme.theme }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.tight) {
                ForEach(store.allTags, id: \.self) { tag in
                    let active = store.query == "#\(tag)"
                    Button { store.query = active ? "" : "#\(tag)" } label: {
                        TagChip(theme: t, tag: tag, active: active)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: 24)
    }
}

/// One `#tag` pill.
///
/// The rail's filter chip and the tag list on a row were the same pill written
/// twice, with different padding, radius and type size for no stated reason -
/// so the same tag looked like two different objects depending on where you
/// read it. The rail's version was the more configured of the two (it has an
/// active state), so it is the one that survived; the row simply never turns
/// `active` on, because a tag printed on a row is not a control.
struct TagChip: View {
    let theme: AppTheme
    let tag: String
    var active: Bool = false

    var body: some View {
        Text("#\(tag)")
            .font(.system(size: 10, weight: active ? .bold : .medium))
            .foregroundStyle(active ? theme.onAccent : theme.textSecondary)
            .padding(.horizontal, Spacing.tight).padding(.vertical, Spacing.inline)
            .background(active ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.surfaceBackground),
                        in: Capsule())
    }
}

/// One row in a curated collection.
struct CuratedRow: View, Equatable {
    let item: ClipboardItem
    let index: Int
    /// Handed in for the same reason as in `ListRow`: `==` can only compare
    /// what the view stores.
    let theme: AppTheme
    let selected: Bool
    /// What a tap does, decided by role at the call site (a note or skill
    /// opens; a prompt pastes). A closure rather than
    /// `@EnvironmentObject var store: HistoryStore`, which this row used to
    /// hold for exactly this one call: an `@EnvironmentObject` subscribes the
    /// row to every one of the store's 24 published properties, so it
    /// re-rendered on every store publish regardless of `.equatable()` below
    /// - the wrapper only skips a body call when the PARENT re-diffs this
    /// view's value, and a live `@EnvironmentObject` subscription invalidates
    /// the view directly, bypassing that entirely. `onActivate` is excluded
    /// from `==` below like every other closure would be.
    let onActivate: () -> Void

    @State private var hovering = false

    private var t: AppTheme { theme }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.tight) {
                Image(systemName: item.role.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(t.accentOnPanel)

                // Bumped from the original 1pt: a title and its date were
                // touching, not stacked.
                VStack(alignment: .leading, spacing: Spacing.inline) {
                    Text(item.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(t.textPrimary)
                        .lineLimit(1)
                    Text(item.dateLabel)
                        .font(.system(size: 9))
                        .foregroundStyle(t.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: Spacing.tight)

                ItemActionCluster(item: item, theme: t,
                                  hovering: hovering, selected: selected, compact: true)

                if item.useCount > 0 {
                    Text("used \(item.useCount) time\(item.useCount == 1 ? "" : "s")")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(t.textTertiary)
                }
                if let s = item.shortcut, !s.isEmpty {
                    Text(Shortcut.display(s))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(t.accentOnPanel)
                        .padding(.horizontal, Spacing.tight).padding(.vertical, Spacing.inline)
                        .background(t.accent.opacity(0.14), in: Capsule())
                }
                if index < 9 {
                    Text("⌘\(index + 1)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(t.textTertiary)
                }
            }

            if item.kind == .image || item.kind == .video {
                MediaPreview(item: item, theme: t, maxWidth: 220, maxHeight: 120,
                             cornerRadius: t.radiusCard, contentMode: .fit)
            } else {
                // A document that describes itself shows the description, not its
                // opening bytes. Three lines of `--- version: alpha name: …` is
                // the front matter, which is the one part of the file that says
                // nothing about what the document is.
                let preview = item.documentDescription ?? item.fullText
                Text(preview.isEmpty ? "Nothing here yet, click to add something." : preview)
                    .font(.system(size: 11,
                                  design: item.documentDescription == nil && item.role.hasFrontMatter
                                      ? .monospaced : .default))
                    .foregroundStyle(preview.isEmpty ? t.textTertiary : t.textSecondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !item.tags.isEmpty {
                HStack(spacing: Spacing.inline) {
                    ForEach(item.tags, id: \.self) { tag in
                        TagChip(theme: t, tag: tag)
                    }
                }
            }
        }
        .padding(Spacing.related)
        .frame(maxWidth: .infinity)
        .rowChrome(t, hovering: hovering, selected: selected)
        .contentShape(Rectangle())
        .onTapGesture { onActivate() }
        .onHover { hovering = $0 }
        .contextMenu { ItemContextMenu(item: item) }
    }

    /// Every field the row's appearance depends on:
    /// - `item` (title, description, tags, shortcut, use count, kind) - the
    ///   whole struct, because a partial compare is how stale rendering
    ///   starts;
    /// - `index` draws the command-number badge;
    /// - `theme` supplies every colour;
    /// - `selected` changes the fill and the ring.
    ///
    /// `hovering` is `@State` and invalidates this view directly. The action
    /// cluster is a separate view with its own store subscription, so its
    /// focus ring keeps updating even when the row around it is skipped.
    static func == (lhs: CuratedRow, rhs: CuratedRow) -> Bool {
        lhs.item == rhs.item
            && lhs.index == rhs.index
            && lhs.theme == rhs.theme
            && lhs.selected == rhs.selected
    }
}
