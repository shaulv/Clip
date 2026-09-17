import SwiftUI

/// The visual card grid — the view users land on.
struct GalleryView: View {
    /// Density comes from the tab, so a screenshots tab can be roomy while a
    /// colors tab is dense.
    let density: GalleryDensity

    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager

    private var t: AppTheme { theme.theme }
    private var columnCount: Int { density.columns }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: density.spacing), count: columnCount)
    }

    /// Same rule as the curated tabs: an arrangement is only honoured on the
    /// default sort with no search, so the gesture is only offered there.
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
                        LazyVGrid(columns: columns, spacing: density.spacing) {
                            // Iterates the memoised array directly - no
                            // `Array(...enumerated())` allocation on every
                            // body evaluation - and looks the card's index up
                            // from the dictionary `visibleItems` builds once
                            // per derivation, not once per render.
                            ForEach(store.visibleItems) { item in
                                GalleryCard(item: item, index: store.visibleIndex(of: item.id), density: density,
                                            theme: t,
                                            selected: store.selectedID == item.id,
                                            marked: store.markedIDs.contains(item.id),
                                            pinned: store.isPinned(item.id),
                                            onTap: { gather in
                                                if gather {
                                                    store.select(item.id)
                                                    store.toggleMark(item.id)
                                                } else {
                                                    store.activatePrimary(item, presentation: .historyGallery)
                                                }
                                            })
                                    // Lets SwiftUI skip a card whose inputs
                                    // did not change rather than re-diffing
                                    // the whole grid on every store publish.
                                    .equatable()
                                    .id(item.id)
                                    .reorderable(item, in: store.visibleItems,
                                                 enabled: canReorder)
                            }
                        }
                        // M10b: see the matching comment in ListView.swift -
                        // a tab switch must not let whatever ambient
                        // animation is active implicitly animate all 200
                        // cards' insertion/removal.
                        .transaction { $0.animation = nil }
                        ReorderTailTarget(collection: store.visibleItems, enabled: canReorder)
                        Spacer().frame(height: 8)
                    }
                    // Arrow keys move by a whole row, so the stride must match
                    // the column count the grid is actually rendering.
                    .onAppear { store.selectionStride = columnCount }
                    .onChange(of: columnCount) { _, n in store.selectionStride = n }
                    .onChange(of: store.selectedID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }
}

/// The one empty state.
///
/// Two of these had grown up separately - the history one here and the curated
/// one in `CollectionViews` - sharing a shape (icon, 14pt semibold title,
/// 12pt tertiary subtitle, centred) and differing only in an icon size nobody
/// had a reason for. The shape now lives here once, at this file's size, and
/// the two things the curated version genuinely has and this one does not - a
/// way out of a search, and copy that counts what the search is hiding - are
/// parameters rather than a second component.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let subtitle: String
    /// An optional way forward, drawn between the title and the subtitle.
    /// Only the curated tabs have one: "Clear search" is a real remedy, and an
    /// empty history has no equivalent.
    var actionTitle: String?
    var action: (() -> Void)?

    @EnvironmentObject var theme: ThemeManager
    private var t: AppTheme { theme.theme }

    init(symbol: String, title: String, subtitle: String,
         actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.action = action
    }

    /// The history flavour: what it says is derived from the search and the
    /// type filter, so the two call sites do not each have to spell it out.
    init(query: String, filtered: Bool) {
        let searching = !query.isEmpty
        self.init(symbol: searching || filtered ? "magnifyingglass" : "square.on.square.dashed",
                  title: searching ? "No matches"
                       : (filtered ? "Nothing of this type" : "Nothing copied yet"),
                  subtitle: searching ? "Try a different search, or switch the search mode."
                          : (filtered ? "Clear the type filter to see everything."
                             : "Copy text, code, an image, a file, a link or a color and it lands here."))
    }

    var body: some View {
        VStack(spacing: Spacing.related) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(t.textTertiary)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(t.textSecondary)
            if let actionTitle, let action {
                ClipLink(actionTitle) { action() }
            }
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(t.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themeTokens(["textTertiary", "textSecondary"])
    }
}
