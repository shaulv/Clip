import SwiftUI

/// Top bar: search field, search-mode picker, sort menu, settings.
struct HeaderView: View {
    /// M21: hover on every header control. Menus cannot see hover through a
    /// ButtonStyle, so the state is tracked here and handed to the chrome.
    @State private var hoveringMode = false
    @State private var hoveringSort = false
    @State private var hoveringGear = false
    @State private var hoveringSearch = false
    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager
    @FocusState private var searchFocused: Bool

    private var t: AppTheme { theme.theme }

    var body: some View {
        HStack(spacing: 10) {
            searchField
            // Above the tabs on purpose: the window on time is one setting for
            // the whole panel, not a per-tab chip. In the filter row it sat
            // among controls that reset as you move between tabs, which read as
            // though it belonged to whichever tab you were on.
            TimeFilterButton()
            sortMenu
            settingsButton
        }
        // Behind the controls, so a click on one reaches it and a drag on the
        // space between them moves the panel. This is the only place the panel
        // can be dragged from; content never moves it.
        .background(WindowDragHandle())
        .onAppear { searchFocused = true }
        .onChange(of: searchFocused) { _, focused in store.searchIsFocused = focused }
        .onReceive(NotificationCenter.default.publisher(for: .clipFocusSearch)) { _ in
            searchFocused = true
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(t.textTertiary)
                .font(.system(size: 13, weight: .medium))

            // M21: was `TextField(searchPlaceholder, text:)`, whose empty-
            // field placeholder is painted by AppKit's own system
            // placeholder color, never a theme token - measured 3.84:1 from
            // rendered pixels (M18 audit) regardless of which theme was
            // active, because no theme color reached it at all. `prompt:`
            // lets the placeholder's own `Text` carry a real style, so it is
            // now the same `textTertiary` the magnifying-glass glyph beside
            // it already uses - the exact pairing ("Tertiary text on
            // surface") the AAA pass already tuned to clear 7:1 against
            // `surfaceBackground` on all 14 themes, not a new literal.
            TextField("", text: $store.query,
                      prompt: Text(searchPlaceholder).foregroundStyle(t.textTertiary))
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .foregroundStyle(t.textPrimary)
                .font(.system(size: 13))
                .accessibilityLabel(Text(searchPlaceholder))
                // Arrow keys must drive the grid even while the field has focus,
                // otherwise the caret eats them and navigation feels broken.
                .onKeyPress(.upArrow)   { store.moveSelection(by: -store.selectionStride); return .handled }
                .onKeyPress(.downArrow) { store.moveSelection(by:  store.selectionStride); return .handled }

            if !store.query.isEmpty {
                Button { store.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(t.textTertiary)
                }
                .buttonStyle(.plain)
            }

            searchModeMenu
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // The same hover the settings icon button draws (user, 03/09): a
        // wash and the hover stroke, so the field reads as something to
        // click, not a strip of text.
        .background(hoveringSearch ? t.actionHoverFill : t.surfaceBackground, in: Capsule())
        .overlay(Capsule().strokeBorder(hoveringSearch ? t.hoverStroke : t.border, lineWidth: 1))
        .onHover { hoveringSearch = $0 }
        // M19: background, then the two foreground pieces this field paints
        // (the magnifier/clear glyph, the typed text).
        .themeTokens(["surfaceBackground", "border", "textTertiary", "textPrimary"])
    }

    private var searchPlaceholder: String {
        switch store.searchMode {
        case .exact: return "Search clipboard"
        case .fuzzy: return "Fuzzy search"
        case .regex: return "Regular expression"
        }
    }

    private var searchModeMenu: some View {
        Menu {
            Picker("Search mode", selection: $store.searchMode) {
                ForEach(SearchMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(store.searchMode.title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(hoveringMode ? t.textSecondary : t.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(hoveringMode ? t.actionHoverFill : t.cardBackground, in: Capsule())
                .overlay(Capsule().strokeBorder(hoveringMode ? t.hoverStroke : .clear, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hoveringMode = $0 }
        .help("Search mode")
    }

    // MARK: - Sort

    // Matches TimeFilterButton exactly: same capsule, same icon size (9pt
    // semibold), same active/inactive fill and border, same hover. The two
    // used to read as different families - this one was a plain circular
    // icon button (PillButtonStyle) while time-filter was a labelled capsule
    // pill - even though they sit side by side and do the same job (narrow
    // the same list). Sort has no "default" state the way time-filter has
    // "any time", so it is never painted active; it always reads as the
    // quieter member of the pair, which is the one unambiguous reading here.
    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $store.sortOrder) {
                ForEach(SortOrder.allCases) { order in
                    Label(order.title, systemImage: order.symbol).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: store.sortOrder.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hoveringSort ? t.text(on: t.surfaceBackground) : t.secondaryText(on: t.surfaceBackground))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // See the time filter: the pull-down's label follows the system
        // appearance, not foregroundStyle, unless the scheme is pinned.
        .environment(\.colorScheme, t.isDark ? .dark : .light)
        .fixedSize()
        // Chrome and hover on the CONTAINER, not the label: a real-pointer
        // capture (03/09 evening) showed the label-mounted chrome never
        // drew - the gear had its pill, this and the time filter sat bare -
        // and the label never saw the pointer either. The Menu itself does.
        .iconButtonChrome(t, variant: .toolbar, side: 32, highlighted: hoveringSort)
        .onHover { hoveringSort = $0 }
        .help("Sort: \(store.sortOrder.title)")
    }

    private var settingsButton: some View {
        Button {
            SettingsWindowController.shared.show()
        } label: {
            Image(systemName: "gearshape")
        }
        .buttonStyle(PillButtonStyle(theme: t, hovering: hoveringGear))
        .onHover { hoveringGear = $0 }
        .help("Settings (⌘,)")
    }
}

/// Type filter as a row of chips.
///
/// Chips beat a hidden menu here: the whole point of the app is seeing what kind
/// of things you copied. Only categories the user actually has appear, so the
/// row stays short and a Figma chip only shows up once a Figma link exists.
struct FilterChips: View {
    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager
    private var t: AppTheme { theme.theme }

    /// The chips to offer, and the count behind each - worked out once by the
    /// store and cached there, rather than re-derived on every body
    /// evaluation. See `HistoryStore.filterChips` for what that was costing.
    private var chips: HistoryStore.FilterChipSet { store.filterChips }

    /// Which chip ids this render pass will actually draw as selected - the
    /// exact same booleans handed to each `ChipButton` below, collected once
    /// so a probe can be told what really got rendered rather than only what
    /// the model says. See `RenderProbe.activeChipIDs`.
    private func renderedActiveIDs(categories: [ItemCategory]) -> Set<String> {
        var ids: Set<String> = store.activeFilters.isEmpty ? [ItemCategory.all.id] : []
        for category in categories where store.activeFilters.contains(category) {
            ids.insert(category.id)
        }
        return ids
    }

    var body: some View {
        let set = chips
        let categories = set.categories
        if categories.count > 1 {
            let activeIDs = renderedActiveIDs(categories: categories)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    // "All" is not a chip you add - it is the way to clear the
                    // rest, and it lights up only when nothing else is on.
                    ChipButton(theme: t, category: .all,
                               active: store.activeFilters.isEmpty, empty: false, count: 0) {
                        store.clearFilters()
                    }
                    ForEach(categories) { category in
                        ChipButton(theme: t, category: category,
                                   active: store.activeFilters.contains(category),
                                   empty: set.count(category) == 0,
                                   count: set.count(category)) {
                            // Each click adds or removes its own chip and leaves
                            // the others alone, so several types can be asked
                            // for at once.
                            store.toggleFilter(category)
                        }
                    }
                }
                .padding(.vertical, 1)
                // The keyboard-focus halo is drawn a few points outside each
                // pill's own bounds (see `FilterPill`). Without this margin the
                // ring on the first or last chip would be sliced off by the
                // scroll view's edge the moment Tab reaches it.
                .padding(.horizontal, 3)
            }
            .frame(height: 26)
            // Records what this render pass actually fed each chip, so a test
            // can tell "the model changed" apart from "the row redrew" -
            // reading `activeFilters` alone cannot catch a chip whose ring
            // sticks after the selection has moved on.
            .onAppear { RenderProbe.activeChipIDs = activeIDs }
            .onChange(of: activeIDs) { _, new in RenderProbe.activeChipIDs = new }
        }
    }
}

/// One chip: hover and keyboard focus.
///
/// Split out of `FilterChips` because each of those two needs its own state
/// tied to exactly one chip - a `@State`/`@FocusState` declared inside a
/// function that just returns a view has nowhere of its own to live, it would
/// end up shared across every chip in the row instead of belonging to one.
private struct ChipButton: View {
    let theme: AppTheme
    let category: ItemCategory
    let active: Bool
    let empty: Bool
    /// How many items match. Not used for `.all`, which speaks for the whole
    /// library rather than a count of its own.
    let count: Int
    let action: () -> Void

    @State private var hovering = false
    @FocusState private var keyboardFocused: Bool

    var body: some View {
        Button {
            // A mouse click also hands this button real keyboard focus (macOS
            // gives a clicked `.focusable()` control first responder along
            // with the click) - and `FilterPill` drew that focus in the same
            // ring geometry as selection, at the pill's own edge, in
            // `theme.focusRing`. Once this chip's `active` goes false again
            // (another chip is picked, or the row clears) that lingering
            // focus took over the border, so a chip a pointer had merely
            // clicked kept a persistent accent ring long after the model
            // moved on - reading exactly like it was still selected. The
            // ring itself is meant for someone tabbing through the row with
            // a keyboard; a pointer click is done with this chip the moment
            // its action runs, so the click resigns the focus it was just
            // handed.
            action()
            keyboardFocused = false
        } label: {
            FilterPill(theme: theme, symbol: category.symbol, title: category.title,
                       active: active, activeFill: category.tint(theme),
                       dimmed: empty && !active,
                       hovering: hovering, keyboardFocused: keyboardFocused)
        }
        .buttonStyle(.plain)
        // The system's own focus ring is drawn as a plain rounded rectangle
        // regardless of the button's real shape, which would give this one
        // chip a focus look none of its neighbours' states share. `FilterPill`
        // draws its own ring instead, in the same language as its hover and
        // active states, so all three read as one family.
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocused)
        // A chip's own rendered focus state, per id, so a probe can tell a
        // mouse click that also grabbed keyboard focus (and therefore paints
        // the same-looking ring as selection) apart from real Tab navigation.
        // See `RenderProbe.focusedChipIDs`.
        .onAppear { RenderProbe.setChipFocus(category.id, keyboardFocused) }
        .onChange(of: keyboardFocused) { _, focused in
            RenderProbe.setChipFocus(category.id, focused)
        }
        .onHover { hovering = $0 }
        .help(helpText)
    }

    /// Says what a click will do and how many items are behind it, because a
    /// tooltip that just repeats the visible label earns nothing a sighted
    /// user did not already read on the chip itself.
    private var helpText: String {
        if case .all = category { return "Show everything" }
        if empty { return "\(category.title): no items copied yet" }
        let noun = count == 1 ? "item" : "items"
        return active ? "\(count) \(noun), remove \(category.title) from the filter"
                      : "\(count) \(noun), add \(category.title) to the filter"
    }
}

/// The one filter pill.
///
/// The type chips and the time-window button were a single visual contract
/// typed out twice - same icon size, same type size, same padding, same
/// capsule, same "active fills, inactive outlines" rule - in two files that
/// could drift apart independently, and one of them wrapped a `Button` while
/// the other wrapped a `Menu` label. The container is the part that genuinely
/// differs, so that stays at each call site; the look is this.
struct FilterPill: View {
    let theme: AppTheme
    let symbol: String
    let title: String
    var active: Bool = false
    /// What an active pill fills with. A type chip uses its own category tint,
    /// so a Figma chip lights up Figma-coloured; the time window has no type of
    /// its own and uses the accent.
    var activeFill: Color
    /// A chip that is offered but currently matches nothing. Dimmed rather than
    /// hidden, so the row does not shuffle as history changes.
    var dimmed: Bool = false
    /// The pointer is over this pill right now. Rendered as a translucent
    /// "state layer" wash (Material's term for it) over the resting fill,
    /// never as the same solid fill `active` uses - a hovered chip and an
    /// active one must never be mistaken for each other.
    var hovering: Bool = false
    /// This pill holds keyboard focus, independent of the pointer. Drawn as a
    /// ring sitting just OUTSIDE the pill's own edge rather than any change to
    /// the fill or the inner border, so it cannot be confused with hovering's
    /// fill wash even where a theme happens to use the same colour for both
    /// tokens - the two are different shapes, not just different colours.
    var keyboardFocused: Bool = false
    /// A gentle fill for the pill's resting state, in place of the plain
    /// outline. Left `nil` for pills that should keep the outline at rest
    /// (the type chips); the time filter passes its secondary-button token
    /// so themes and the AI theme maker control the tint.
    var idleFill: Color? = nil

    /// A dimmed chip that is being pointed at or tabbed to stops looking
    /// switched off, matching the same hover/focus wash and ring every
    /// other pill state already draws - a chip a user is actively
    /// interacting with should never look inert.
    private var showsDimmed: Bool { dimmed && !hovering && !keyboardFocused }

    private var fill: AnyShapeStyle {
        // Selected reads like every other selection in the app (a card, a
        // tab): the card fill with the ring in the chip's own tint, never a
        // solid flood (user, 03/09).
        if active { return AnyShapeStyle(theme.cardBackground) }
        if hovering { return AnyShapeStyle(theme.actionHoverFill) }
        return AnyShapeStyle(idleFill ?? theme.surfaceBackground)
    }

    private var borderColor: Color {
        if active { return theme.selectionStroke }
        // Focus wears the same ring geometry as selection, in the focus
        // colour: the old ring floated 3pt outside the pill and read as a
        // stray stroke (user, 04/09). The fill still tells them apart.
        if keyboardFocused { return theme.focusRing }
        if hovering { return theme.hoverStroke }
        if idleFill != nil { return .clear }
        return theme.border
    }

    /// Selected and keyboard-focused-but-unselected drew the identical solid
    /// 2pt ring, telling the two apart by colour alone - a click hands a
    /// chip real keyboard focus along with selecting it (see `ChipButton`),
    /// and any focus a click leaves behind (a stray tab-order jump, a theme
    /// whose focus and tint colours read close together) could no longer be
    /// told apart from selection at a glance. Selection keeps the solid
    /// ring every other selected control in the app uses; focus-only draws
    /// dashed, a shape difference no colour choice can erase.
    private var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: (active || keyboardFocused) ? 2 : 1,
                    dash: (keyboardFocused && !active) ? [3, 2] : [])
    }

    /// The ground this pill's label is actually read against at rest -
    /// `foregroundColor` grades against the same surface `fill` paints
    /// with when `showsDimmed` is true (never `idleFill` and
    /// `theme.surfaceBackground` both at once).
    private var restingGround: Color { idleFill ?? theme.surfaceBackground }

    /// The label's resting color. Was `theme.textSecondary` faded by
    /// `.opacity(0.45)` when dimmed - measured 2.5:1 (M21 audit), because
    /// opacity multiplies a color's own contrast down with whatever sits
    /// behind it, the exact anti-pattern `controlDisabledText` already
    /// avoids. This chip is not disabled (a click still calls `toggleFilter`
    /// no matter how many items are behind it), so dimming keeps the same
    /// 7:1 body-text floor via `ThemeRules.dimmedChipLabel`, which is a real,
    /// measurable color rather than a transparency trick over one.
    private var foregroundColor: Color {
        if active { return theme.textPrimary }
        if showsDimmed { return ThemeRules.dimmedChipLabel(theme, on: restingGround) }
        return theme.textSecondary
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(title).font(.system(size: 11, weight: active ? .semibold : .medium))
                .lineLimit(1)
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(fill, in: Capsule())
        // One ring, on the pill's own edge, for both selection and focus - a
        // second ring outside it was clipped by the row (03/09) and then read
        // as a detached stroke (04/09). Dashed vs solid keeps "focused" and
        // "selected" apart by shape, not only by colour (see `strokeStyle`).
        .overlay(Capsule().strokeBorder(borderColor, style: strokeStyle))
        .contentShape(Capsule())
        // M19: every token this one pill can paint with, across its states
        // (idle/active/hover/focus) - a type chip, the time-window pill.
        .themeTokens(["surfaceBackground", "accent", "border", "hoverStroke",
                      "selectionStroke", "focusRing", "onAccent", "textSecondary"])
    }
}

/// Compact toolbar button style.
///
/// The toolbar weight of the one icon-button chrome. It stays a `ButtonStyle`
/// rather than becoming a view, because the sort control is a `Menu` and a
/// style is the only way to dress one of those; what it draws is now the same
/// primitive the action buttons and the dismiss X use.
struct PillButtonStyle: ButtonStyle {
    let theme: AppTheme
    var destructive: Bool = false
    /// M21: a style cannot observe hover on its own; the owning view tracks
    /// it with `.onHover` and passes it in, so the toolbar pills light up
    /// like every other icon button.
    var hovering: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(destructive ? theme.destructive : (hovering ? theme.textPrimary : theme.textSecondary))
            .iconButtonChrome(theme, variant: .toolbar, side: 32,
                              highlighted: hovering,
                              pressed: configuration.isPressed,
                              destructive: destructive)
    }
}


/// "Any time" until you narrow it, then the window you chose.
struct TimeFilterButton: View {
    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager
    private var t: AppTheme { theme.theme }

    @State private var hovering = false
    @State private var showingCustom = false
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var to = Date()

    private var active: Bool { store.timeFilter != .any }

    var body: some View {
        Menu {
            ForEach(Array(TimeFilter.presets.enumerated()), id: \.offset) { _, option in
                Button {
                    apply(option)
                } label: {
                    Label(option.title,
                          systemImage: store.timeFilter == option ? "checkmark" : option.symbol)
                }
            }
            Divider()
            Button {
                if case .range(let f, let t) = store.timeFilter { from = f; to = t }
                showingCustom = true
            } label: {
                Label(store.timeFilter.isCustom ? "Change range…" : "Custom range…",
                      systemImage: "calendar")
            }
        } label: {
            // Looks like the settings icon button (toolbar pill: surface
            // fill, border, hover wash + stroke), stretched for its text.
            ToolbarTextPill(theme: t, symbol: store.timeFilter.symbol,
                            title: store.timeFilter.shortTitle,
                            active: active, hovering: hovering)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // The borderless pull-down repaints its label in the system
        // appearance's control text colour, ignoring foregroundStyle: a
        // light theme under dark appearance drew "Any time" white on its pale
        // capsule (user, 03/09 night) while the gear, a plain Button, was
        // fine. Pinning the scheme to the theme's side keeps the label on
        // the readable side. Same on `sortMenu`.
        .environment(\.colorScheme, t.isDark ? .dark : .light)
        .fixedSize()
        // Same reason as `sortMenu`: the container is what the pointer
        // reaches and what the chrome must be drawn on.
        .iconButtonChrome(t, variant: .toolbar, side: nil, highlighted: hovering || active)
        .onHover { hovering = $0 }
        .help("Filter by when it was copied")
        .popover(isPresented: $showingCustom, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Copied between").font(.system(size: 12, weight: .semibold))
                DatePicker("From", selection: $from, displayedComponents: .date)
                DatePicker("To", selection: $to, displayedComponents: .date)
                HStack {
                    GhostButton("Clear", theme: t) { apply(.any); showingCustom = false }
                    Spacer()
                    PrimaryButton("Apply", theme: t) {
                        apply(.range(from: from, to: to))
                        showingCustom = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 260)
        }
    }

    /// A filter change reshapes the list, so the cursor moves with it - the same
    /// rule the type chips follow.
    private func apply(_ filter: TimeFilter) {
        store.timeFilter = filter
        store.select(store.visibleItems.first?.id)
    }
}


/// The "Name N" button that used to sit beside the search field lived here.
///
/// It is gone, and so is the row that replaced it. Naming and tagging the
/// library was housekeeping: it made the app tidier and produced nothing the
/// user could take anywhere. The AI in Clip now acts on the way out - at the
/// moment of paste - so its product lands in the app being typed into rather
/// than in Clip's own metadata.


/// The toolbar pill with text: the same resting look and the same hover as
/// the icon-only toolbar buttons (`IconButtonChrome`, `.toolbar`), drawn as a
/// capsule so it can hold a label. Active = the accent fill, like a chip.
struct ToolbarTextPill: View {
    let theme: AppTheme
    let symbol: String
    let title: String
    var active: Bool = false
    var hovering: Bool = false

    var body: some View {
        HStack(spacing: Spacing.inline) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            Text(title).font(.system(size: 13, weight: .medium))
        }
        // Derived from the ground the pill actually paints (its own
        // surface fill), never the panel's text tokens: a light theme whose
        // panel text is light left "Any time" white on a pale capsule
        // (user, 03/09 evening). `secondaryText(on:)`/`text(on:)` pick the
        // readable side for that fill; the active accent is contrast-checked
        // the same way.
        .foregroundStyle(active ? theme.accentText(on: theme.surfaceBackground)
                                : (hovering ? theme.text(on: theme.surfaceBackground)
                                            : theme.secondaryText(on: theme.surfaceBackground)))
        // Chrome is drawn by the Menu container that hosts this label (see
        // the time filter): a label inside a macOS Menu drops its own.
        .padding(.horizontal, Spacing.tight)
    }
}
