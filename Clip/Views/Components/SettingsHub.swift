import SwiftUI

/// Apple-measured geometry this file draws to, that has no equivalent on
/// Clip's own `Spacing`/`Typography` scales (SETTINGS-DESIGN.md's own "Known
/// Gaps": the hero title and the Apple card radius are both explicitly
/// larger than anything already named, and are a deliberate difference from
/// Clip's Graphite tokens to KEEP, not to fix - section 2/9 of that doc).
/// Named here, once, rather than left as bare literals scattered through the
/// two M14 components, so a reviewer reads "this is the hero icon tile" at
/// the call site instead of reverse-engineering a 52 from context - the same
/// reasoning `Spacing`/`Typography` themselves give for existing as enums.
enum SettingsAppleMetrics {
    /// `layout.heroIconTile` - 52x52pt, screenshot17.png.
    static let heroIconTile: CGFloat = 52
    /// The hero tile's own glyph size - not independently measured, chosen
    /// to visually fill the 52pt tile the way screenshot17.png's gear does.
    static let heroGlyphSize: CGFloat = 24
    /// `radius.appleCard` - ~14pt, visually continuous, measured across
    /// every grouped card in the 31-screenshot source set.
    static let cardRadius: CGFloat = 14
    /// A row's own icon tile - smaller than the hero tile, not independently
    /// measured (no single hub row was pixel-isolated the way the hero and
    /// the row TEXT inset were); sized to sit comfortably inside a
    /// `cardRowInset`-11pt row without crowding the title.
    static let rowIconTile: CGFloat = 28
    static let rowGlyphSize: CGFloat = 13
    /// `spacing.cardRowInset` - 11pt, re-measured screenshot18.png/26.png.
    static let rowInset: CGFloat = 11
    /// The inset every Settings page keeps between its CONTENT and the window
    /// - hub and drilled-down page alike. The title row is deliberately not
    /// covered: it carries the back control and sits on its own rhythm.
    ///
    /// One constant because there were two: a hub padded itself 24pt while an
    /// inner page inherited the grouped `Form`'s own 20pt, so drilling into a
    /// page shifted every card 4pt left (user, 05/09).
    static let contentInset: CGFloat = Spacing.group
    static let chevronGlyphSize: CGFloat = 10
}

/// One chevron row inside a `SettingsHub` grouped card - icon tile, title,
/// an optional trailing summary value read from live state, and a chevron
/// (SETTINGS-DESIGN.md section 4, "Value + chevron row" / "Chevron row").
/// Tapping it asks the hub's own `onSelectRow` to push `id` as a sub-page.
struct SettingsHubRow: Identifiable {
    let id: String
    let symbol: String
    let title: String
    var summary: String? = nil
    /// The icon tile's own tint. Defaults to the accent colour; a row that
    /// leads to something destructive (Sync's "Danger zone") passes
    /// `SettingsPalette.danger` instead, matching section 5's rule that
    /// danger is a colour role, not a button fill.
    var tint: Color = .accentColor

    init(id: String, symbol: String, title: String, summary: String? = nil,
         tint: Color = .accentColor) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.summary = summary
        self.tint = tint
    }
}

/// A named (or anonymous) group of rows, drawn as one rounded card with a
/// hairline divider between rows - "grouping is the whole layout system"
/// (section 1).
struct SettingsHubGroup: Identifiable {
    let id: String
    var title: String? = nil
    var rows: [SettingsHubRow]

    init(id: String, title: String? = nil, rows: [SettingsHubRow]) {
        self.id = id
        self.title = title
        self.rows = rows
    }
}

/// The landing page of a "hub" tab: a hero card (icon, title, one sentence
/// of purpose) then grouped cards of chevron rows, each opening a
/// `SettingsSubpage` (SETTINGS-DESIGN.md section 4 "Hero card", section 7
/// "a hero card exists only at the top of a landing pane, never on a
/// drilled-down sub-page").
///
/// `heroExtra`, when supplied, draws hero-like inline content directly on
/// the hub, below the purpose sentence and above the grouped rows - the two
/// named exceptions the M14 plan carves out of "a hub shows only chevron
/// rows": Diagnostics' own Insights list, and Themes' own theme grid. Both
/// are the tab's primary, most-used control, and Apple-style progressive
/// disclosure would otherwise hide it behind a chevron the user has to open
/// on every single visit.
struct SettingsHub<HeroExtra: View>: View {
    let icon: String
    let title: String
    let purpose: String
    var groups: [SettingsHubGroup]
    /// Greys out every grouped row while a master switch in `heroExtra` is
    /// off, without disabling the switch itself. A `.disabled` on the whole
    /// hub cannot do that: SwiftUI lets the outer view win, so the switch
    /// that turns things back on would be dead too (user, 03/09: "I turned
    /// off the AI and then it stuck").
    var rowsDisabled: Bool = false
    var onSelectRow: (String) -> Void
    @ViewBuilder var heroExtra: () -> HeroExtra
    /// Settings surfaces come from the chosen theme, not the system: see
    /// `SettingsHero`'s own note.
    @EnvironmentObject private var theme: ThemeManager
    private var t: AppTheme { theme.settingsTheme }

    init(icon: String, title: String, purpose: String, groups: [SettingsHubGroup],
         rowsDisabled: Bool = false,
         onSelectRow: @escaping (String) -> Void,
         @ViewBuilder heroExtra: @escaping () -> HeroExtra = { EmptyView() }) {
        self.icon = icon
        self.title = title
        self.purpose = purpose
        self.groups = groups
        self.rowsDisabled = rowsDisabled
        self.onSelectRow = onSelectRow
        self.heroExtra = heroExtra
    }

    // A `List`, not a raw `ScrollView` - discovered empirically while
    // building section 141's own rendered check (Y7): a bare `ScrollView`
    // embedded in this window renders perfectly on the real screen but
    // comes back BLANK from every offscreen capture technique this codebase
    // has (`layer.render(in:)`, and `cacheDisplay(in:to:)` tried as a
    // fix) - a real, narrow AppKit/SwiftUI limitation with `NSScrollView`
    // content specifically, confirmed by comparing a real `screencapture`
    // (perfect) against both offscreen paths (blank, byte-identical
    // regardless of tab, history, or settle time). `List` is proven to
    // capture correctly by every existing screenshot in this whole
    // codebase - the sidebar is one. Every default List chrome (row
    // insets, separators, background) is stripped below so this draws
    // pixel-identically to the `ScrollView` it replaces.
    var body: some View {
        List {
            // `Spacing.section` between each block, by hand: a `List` row
            // has no automatic gap the way the `VStack(spacing:)` this
            // replaced did, once separators/insets are stripped to zero.
            hero
                .padding(.bottom, Spacing.section)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            // Skipped entirely (no row, no padding-only gap) when this hub
            // carries no hero-like inline content - `HeroExtra` resolves to
            // `EmptyView` at every call site that omits `heroExtra:`.
            if HeroExtra.self != EmptyView.self {
                heroExtra()
                    .padding(.bottom, Spacing.section)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            ForEach(groups) { group in
                groupCard(group)
                    .disabled(rowsDisabled)
                    .opacity(rowsDisabled ? 0.5 : 1)
                    .padding(.bottom, Spacing.section)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        // The shell insets every page; a second inset here would double it.
        .padding(.bottom, SettingsAppleMetrics.contentInset)
    }

    // MARK: - Hero

    private var hero: some View { SettingsHero(icon: icon, title: title, purpose: purpose) }

    // MARK: - Grouped cards

    private func groupCard(_ group: SettingsHubGroup) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if let title = group.title {
                Text(title)
                    .font(Typography.subheading)
                    .padding(.horizontal, Spacing.inline)
            }
            VStack(spacing: 0) {
                ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider().padding(.leading, SettingsAppleMetrics.rowInset * 2
                                          + SettingsAppleMetrics.rowIconTile)
                    }
                    hubRow(row)
                }
            }
            .background(t.cardBackground,
                        in: RoundedRectangle(cornerRadius: SettingsAppleMetrics.cardRadius, style: .continuous))
            // Settings surfaces are themed now, so Inspect can report what
            // paints them, same as every themed struct in the panel.
            .themeTokens(["cardBackground"])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hubRow(_ row: SettingsHubRow) -> some View {
        Button {
            onSelectRow(row.id)
        } label: {
            HStack(spacing: Spacing.related) {
                RoundedRectangle(cornerRadius: SettingsAppleMetrics.rowIconTile * 0.27, style: .continuous)
                    .fill(row.tint.opacity(0.18))
                    .frame(width: SettingsAppleMetrics.rowIconTile, height: SettingsAppleMetrics.rowIconTile)
                    .overlay(
                        Image(systemName: row.symbol)
                            .font(.system(size: SettingsAppleMetrics.rowGlyphSize))
                            .foregroundStyle(row.tint)
                    )
                Text(row.title).font(Typography.body).foregroundStyle(.primary)
                Spacer(minLength: Spacing.tight)
                if let summary = row.summary {
                    Text(summary)
                        .font(Typography.body)
                        .foregroundStyle(SettingsPalette.note)
                        .lineLimit(1)
                }
                // No trailing chevron (user, 03/09): the row's hover and
                // the summary already say it opens; the arrow was noise.
            }
            // `spacing.cardRowInset` - 11pt, SETTINGS-DESIGN.md section 8.
            .padding(.horizontal, SettingsAppleMetrics.rowInset)
            .padding(.vertical, Spacing.tight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // M8.4 hover treatment, reused rather than reinvented - see
        // `SettingsHoverModifier`'s own doc comment for why a `.plain`
        // composite row needs this and a native control does not.
        .settingsHover(cornerRadius: SettingsAppleMetrics.rowIconTile * 0.27)
        .accessibilityLabel(row.summary.map { "\(row.title), \($0)" } ?? row.title)
        .accessibilityAddTraits(.isButton)
    }
}

/// The opening every main tab shares (user, 03/09 evening: "a consistent
/// template opening - avatar, title, sub text - the same component with
/// different content"): a glyph tile, the tab's title, one sentence on what
/// the tab is for. Hubs draw it through `SettingsHub`; single-page tabs
/// (Getting Started, Tabs) place it themselves.
struct SettingsHero: View {
    let icon: String
    let title: String
    let purpose: String
    /// Settings draws on the chosen theme's surfaces, not the system's own
    /// (user, 07/09: "use dark blue surfaces in the settings and not gray").
    /// Measured before the change: every card here was `#1E1E1E`, macOS's
    /// neutral `controlBackgroundColor`, whatever theme was chosen - the blue
    /// on the page in the report was the desktop showing through a translucent
    /// window, not a colour this app had picked. Text comes from the theme too,
    /// because a system-appearance label on a themed surface is the exact
    /// defect T3-M9 fixed in the theme builder: a light theme viewed in Dark
    /// Mode painted near-white text on its own near-white card.
    @EnvironmentObject private var theme: ThemeManager
    private var t: AppTheme { theme.settingsTheme }

    var body: some View {
        VStack(spacing: Spacing.tight) {
            RoundedRectangle(cornerRadius: SettingsAppleMetrics.rowIconTile * 0.27, style: .continuous)
                .fill(t.surfaceBackground)
                .frame(width: SettingsAppleMetrics.heroIconTile, height: SettingsAppleMetrics.heroIconTile)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: SettingsAppleMetrics.heroGlyphSize))
                        .foregroundStyle(t.textPrimary)
                )
            // Apple's own hero title measures noticeably larger than
            // title2/title3 (SETTINGS-DESIGN.md heroTitle) - `.title` is
            // SwiftUI's own dynamic-type role one step above `.title2`.
            Text(title).font(.title.weight(.semibold))
                .foregroundStyle(t.textPrimary)
            Text(purpose)
                .font(Typography.body)
                .foregroundStyle(t.secondaryText(on: t.cardBackground))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.group)
        .padding(.horizontal, Spacing.section)
        .background(t.cardBackground,
                    in: RoundedRectangle(cornerRadius: SettingsAppleMetrics.cardRadius, style: .continuous))
        .themeTokens(["cardBackground", "surfaceBackground", "textPrimary", "textSecondary"])
    }
}
