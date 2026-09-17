import SwiftUI

/// Settings, laid out like System Settings: a source list on the left with the
/// account pinned at the top and a search field above it, and the selected pane
/// on the right.
struct SettingsShell: View {
    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var router: SettingsRouter
    @StateObject private var sync = SyncManager.shared
    @ObservedObject private var googleAuth = GoogleAuth.shared
    @ObservedObject private var checklist = SetupChecklist.shared

    @State private var search = ""

    var body: some View {
        NavigationSplitView(columnVisibility: $router.sidebarVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 215, ideal: 232, max: 300)
        } detail: {
            detail
        }
        // AAA tint for every native control in Settings: link-style buttons,
        // toggles, pickers and focus rings paint `SettingsPalette.link`
        // (7:1 on both grounds) instead of systemBlue (5.6:1).
        .tint(SettingsPalette.link)
        // Settings now paints the chosen theme's surfaces, so it has to resolve
        // native colours in the theme's mode rather than the system's. Without
        // this, Ivory viewed while macOS is in Dark Mode drew every row label
        // white on its own white card - the labels were simply gone - because
        // `.primary`, `SettingsPalette.note`, dividers and native controls all
        // read `NSAppearance`, not the theme. One line rather than a token per
        // label, and the same fix T3-M10 applied to the theme builder's own
        // native chrome.
        .preferredColorScheme(theme.settingsTheme.isDark ? .dark : .light)
        // Every shared control in this window draws with the SETTINGS
        // theme from here, rather than each call site having to pass it:
        // see `clipChromeTheme`.
        .environment(\.clipChromeTheme, theme.settingsTheme)
        .frame(minWidth: 900, minHeight: 620)
        // Defensive, not merely observational: some pane's content can
        // still ask for more width than the window offers (a monospace
        // report block, say), and without this SwiftUI is free to answer
        // that by collapsing the sidebar instead of just scrolling the
        // pane - which is exactly the bug Diagnostics hit. Re-asserted on
        // every pane change, so a future pane with the same mistake self
        // corrects the next time it is opened rather than staying collapsed
        // until Settings is closed and reopened.
        .onChange(of: router.tab) { _, _ in router.sidebarVisibility = .all }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
            List(selection: Binding(
                get: { router.tab },
                set: { if let t = $0 { router.tab = t; router.highlight = nil } }
            )) {
                Section {
                    syncRow
                }
                ForEach(SettingsGroup.allCases.filter { !panes(in: $0).isEmpty }) { group in
                    Section(group.title) {
                        ForEach(panes(in: group)) { pane in
                            row(pane)
                        }
                    }
                }
                // M14 Y5: search also reaches into a hub tab's own
                // sub-pages, not just tab titles/keywords - Apple's own
                // search does the same (typing "About" surfaces General's
                // own sub-page, not just "General"). Tapping one deep-links
                // straight in, discarding that tab's prior history - the
                // same jump `SettingsWindowController.show(tab:page:)` and
                // a notice's own action make.
                if !subpageMatches.isEmpty {
                    Section("Settings") {
                        ForEach(subpageMatches, id: \.id) { hit in
                            subpageRow(hit)
                        }
                    }
                }
                if !search.isEmpty && matches.isEmpty && subpageMatches.isEmpty {
                    Text("No settings match “\(search)”")
                        .font(.caption).foregroundStyle(SettingsPalette.note)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SettingsPalette.note).font(.system(size: 12))
            TextField("Search settings", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(SettingsPalette.note)
                }
                .buttonStyle(.plain)
                // M8.4: an icon-only `.plain` button, same reasoning as
                // ThemeCard - no native chrome to fall back on.
                .settingsHover(cornerRadius: 6)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
    }

    @ViewBuilder
    private var syncIdentityGlyph: some View {
        #if CLIP_TESTING
        let _ = {
            switch sync.connection {
            case .google:
                if let pic = googleAuth.account?.picture, !pic.isEmpty,
                   let url = URL(string: pic), url.scheme?.lowercased() == "https", url.host != nil {
                    SettingsProbe.settingsSyncGlyphKind = "googleAvatar"
                } else {
                    SettingsProbe.settingsSyncGlyphKind = "initials"
                }
            case .token:
                SettingsProbe.settingsSyncGlyphKind = "tokenIcon"
            case .none:
                SettingsProbe.settingsSyncGlyphKind = "disconnectedIcon"
            }
        }()
        #endif

        switch sync.connection {
        case .google(let email):
            let account = googleAuth.account
            let name = (account?.name.isEmpty == false) ? account!.name : email
            AccountAvatarView(name: name, picture: account?.picture, size: 34)
                .accessibilityLabel("Google account avatar for \(name)")
        case .token:
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.18)).frame(width: 34, height: 34)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 15)).foregroundStyle(Color.accentColor)
            }
            .accessibilityLabel("Sync token connection")
        case .none:
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.18)).frame(width: 34, height: 34)
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 15)).foregroundStyle(Color.accentColor)
            }
            .accessibilityLabel("Disconnected from sync")
        }
    }

    private var syncRow: some View {
        Button {
            router.tab = .sync
        } label: {
            HStack(spacing: 10) {
                syncIdentityGlyph
                VStack(alignment: .leading, spacing: 1) {
                    Text(sync.isConnected ? "Sync is on" : "Sync")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(SettingsPalette.note)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.vertical, 3)
            // No extra leading inset on the content: `row(_:)`'s native
            // `Label` draws its icon straight at the List's own row-content
            // origin, and this Button needs to land at that same x for its
            // icon to align with every other sidebar row's icon (user, 06/09).
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // M8.4: the one row in this sidebar that is NOT a native List row -
        // `row(_:)` below is a plain `Label(...).tag()` and gets its hover
        // for free from `.listStyle(.sidebar)`; this is a custom `.plain`
        // Button sharing the same List, and opts out of that for free.
        //
        // 06/09 morning: lit only as wide as its own text (16pt short on both
        // sides), fixed by stretching the row with `.frame(maxWidth: .infinity)`
        // above - that alone already matches this List's own row slot, the
        // same slot `row(_:)`'s native selection highlight (see Themes) is
        // drawn into.
        //
        // 06/09 evening: an added negative-padding stretch (borrowed from the
        // Form rows below, whose grouped Form re-applies its own 16pt gutter
        // outside the row slot) pushed the wash 20px/10pt at 2x PAST the
        // Themes highlight on both sides - this List has no such gutter to
        // compensate for.
        //
        // 06/09 night: `leading`/`trailing`: 0 (no stretch at all) undershot
        // instead - measured 13px/6.5pt at 2x SHORT of the Themes highlight
        // on both sides, real window captures, `.frame(maxWidth: .infinity)`
        // fills this custom row's own content width, but a plain `.sidebar`
        // List still wraps that content in its own small leading/trailing
        // inset that a native `Label` row does not carry (Label draws its
        // icon straight at the row's true edge; an arbitrary custom view
        // gets the List's default padding around it instead). 6.5pt of
        // negative padding cancels exactly that, landing the wash back on
        // the Themes highlight's own bounds - re-measured after this change,
        // not assumed.
        .settingsRowHover(cornerRadius: 8, leading: 6.5, trailing: 6.5, vertical: 0)
    }

    private var subtitle: String {
        guard let space = sync.space else { return "Not connected to a token" }
        if space.deletionRequestedAt != nil { return "Deletion pending" }
        switch sync.syncState {
        case .syncing:           return "Syncing…"
        case .synced:            return space.deviceSummary
        case .failed:            return "Sync failed"
        case .idle:              return space.deviceSummary
        }
    }

    // M8.4: allowlisted, not wrapped - a plain `Label(...).tag()` inside a
    // `List` styled `.sidebar` gets AppKit's own sidebar row hover for
    // free; `.settingsHover()` exists for content that opts OUT of that
    // native list-row chrome (see `syncRow` above, in the same List).
    //
    // The trailing badge (M15) does not change that: it is still a plain
    // row with no button/plain style of its own, so the same native
    // sidebar hover and selection chrome paints behind the whole row.
    private func row(_ pane: SettingsTab) -> some View {
        HStack {
            Label(pane.title, systemImage: pane.symbol)
            Spacer(minLength: 0)
            if pane == .gettingStarted, checklist.remainingCount > 0 {
                remainingBadge(checklist.remainingCount)
            }
        }
        .tag(pane)
    }

    /// The Getting Started row's own remaining-step count - no other tab
    /// carries a badge, so there is no existing `Badge` component or
    /// notice-count style to reuse (section 4's "Badge count" is otherwise
    /// unclaimed in this codebase). Styled quietly (the accent, not
    /// destructive red): a step left to finish is information, not an
    /// alert like Apple's own "Software Update Available."
    private func remainingBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.accentColor, in: Capsule())
    }

    // MARK: - Search

    /// Panes whose title or whose individual settings match the query, so
    /// searching finds a checkbox and not just a page.
    private var matches: [SettingsTab] {
        guard !search.isEmpty else { return SettingsTab.visible }
        let q = search.lowercased()
        return SettingsTab.visible.filter { pane in
            pane.title.lowercased().contains(q)
                || pane.keywords.contains { $0.lowercased().contains(q) }
        }
    }

    private func panes(in group: SettingsGroup) -> [SettingsTab] {
        matches.filter { $0.group == group }
    }

    /// Every hub tab's own sub-page whose title matches the search text -
    /// M14 Y5. A row here identifies both what it is AND where it lives
    /// ("in Sync"), since two different tabs can each have a page called,
    /// say, "Storage" (Privacy and Diagnostics both do).
    private struct SubpageHit { let tab: SettingsTab; let id: String; let title: String; let symbol: String }
    private var subpageMatches: [SubpageHit] {
        guard !search.isEmpty else { return [] }
        let q = search.lowercased()
        return SettingsTab.visible.flatMap { tab -> [SubpageHit] in
            (tab.subpages ?? [])
                .filter { $0.title.lowercased().contains(q) }
                .map { SubpageHit(tab: tab, id: $0.id, title: $0.title, symbol: $0.symbol) }
        }
    }

    private func subpageRow(_ hit: SubpageHit) -> some View {
        Button {
            router.deepLink(to: hit.id, in: hit.tab)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: hit.symbol).frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(hit.title)
                    Text("in \(hit.tab.title)")
                        .font(.caption2).foregroundStyle(SettingsPalette.note)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .settingsHover(cornerRadius: 6)
    }

    // MARK: - Detail

    /// Each pane scrolls itself.
    ///
    /// Wrapping them in a shared `ScrollView` made `TabsPane` disappear entirely:
    /// a `List` inside a `ScrollView` has no definite height and collapses to
    /// nothing. `Form` and `List` both scroll on their own, so the shell must not.
    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Every main tab opens with the shared hero (`SettingsHero`,
            // 03/09 evening) - hubs through `SettingsHub`, Getting Started
            // and Tabs on their own - so the shell draws no generic
            // icon+title bar above any of them; a sub-page carries its own
            // title in `SettingsSubpage`.
            pane
                .environment(\.settingsHighlight, router.highlight)
                // ONE inset for every page, applied here rather than in each
                // pane. Measured before this line, the right edge of the first
                // card differed by up to 51pt between pages - a Form page
                // ended at 1821, Getting Started and Shortcuts ran to the
                // window edge at 1877, Tabs sat at 1844 (user, 06/09: "the
                // same left/right/top padding from the edges of the page ...
                // I asked it before and you didn't do it").
                .padding(.horizontal, SettingsAppleMetrics.contentInset)
                .padding(.top, SettingsAppleMetrics.contentInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch router.tab {
        case .gettingStarted: SettingsGettingStartedPane()
        case .sync:      SyncPane()
        case .themes:    ThemePane()
        case .general:   GeneralPane()
        case .tabs:      TabsPane()
        case .shortcuts: ShortcutsPane()
        case .ai:        AIPane()
        case .pasteActions: PasteActionsPane()
        case .privacy:   PrivacyPane()
        case .menuBar:   MenuBarPane()
        case .export:    ExportPane()
        case .diagnostics: SettingsDiagnosticsPane()
        }
    }
}

/// Sidebar grouping, matching how System Settings organises itself.
enum SettingsGroup: String, CaseIterable, Identifiable {
    // Order matters: this is the order the sidebar draws. The things people
    // change most often come first, right under the account row.
    case behaviour, appearance, content, data
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .behaviour:  return "Behavior"
        case .content:    return "AI"
        case .data:       return "Data"
        }
    }
}

/// A section whose explanatory note sits **directly under the title**.
///
/// Notes used to sit in `footer`, at the bottom of the section, which is the
/// wrong place: the reader needs the instruction *before* scanning the rows, not
/// as an afterthought once they have already guessed.
struct ExplainedSection<Content: View>: View {
    let title: String
    let note: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, note: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.note = note
        self.content = content
    }

    /// Collapses any run of whitespace to a single space, so a note reads as
    /// the sentence it is rather than as the shape of its source literal.
    static func prose(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    var body: some View {
        Section {
            if let note, !note.isEmpty {
                // `Self.prose` is not cosmetic. Four notes carried literal runs
                // of up to 17 spaces mid-sentence, left behind when a `\`
                // line-continuation was edited out of the multi-line literal,
                // and they rendered exactly as written: "…next to        the
                // menu-bar icon". Normalising here means a note is prose no
                // matter how the literal was wrapped in source.
                HStack(spacing: 0) {
                    Text(Self.prose(note))
                        .font(.caption)
                        .foregroundStyle(SettingsPalette.note)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .listRowSeparator(.hidden)
            }
            content()
        } header: {
            Text(title)
        }
    }
}

private struct SettingsHighlightKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// Setting id to flash after a search jump.
    var settingsHighlight: String? {
        get { self[SettingsHighlightKey.self] }
        set { self[SettingsHighlightKey.self] = newValue }
    }
}
