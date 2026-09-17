import SwiftUI

/// Root of the clipboard panel: header, tabs, content, footer, detail overlay.
struct PanelRootView: View {
    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager
    @ObservedObject private var prefs = PreferencesModel.shared
    /// `store.activeTab` reads through to `TabConfiguration`, so this view has to
    /// observe it as well as the store. Without this the footer's grid/list
    /// toggle wrote the change and persisted it, but nothing re-rendered — the
    /// panel only ever showed whatever Settings had been set to.
    @ObservedObject private var tabs = TabConfiguration.shared
    @ObservedObject private var setupOverview = SetupOverviewCoordinator.shared
    @ObservedObject private var checklist = SetupChecklist.shared

    private var t: AppTheme { theme.theme }

    var body: some View {
        panel
            // Last, so it draws over every row, chip and tab. A tooltip that
            // can be painted over by the next row is not a tooltip.
            .drawsActionTooltips(theme: t)
            // M19: rooted here so every `.themeTokens(...)` frame anywhere
            // under this ZStack is measured against exactly what
            // `PanelController`'s `NSHostingView` mounts - the same view
            // the Inspect overlay window sizes itself to, in coordinates
            // that already agree with a flipped `NSView`'s own, with no
            // axis flip needed on either side. See `ThemeInspectRegistry`'s
            // own doc comment on `coordinateSpaceName`.
            .coordinateSpace(name: ThemeInspectRegistry.coordinateSpaceName)
    }

    private var panel: some View {
        ZStack {
            GlassBackground(theme: t)
                // M19: the one background every other themed view in the
                // panel sits on top of - tagged here rather than left
                // undiscoverable, so hovering any gap between smaller
                // tagged elements still reports something rather than
                // nothing. Smallest-area-wins hit testing means this frame
                // (the whole panel) only ever "wins" where nothing smaller
                // is tagged underneath the pointer.
                .themeTokens(["panelBackground"])

            VStack(spacing: 0) {
                // The "Set up Clip" promo (M8.1, reshaped 03/09) sits above
                // even NoticeBar: once per launch, while a Getting Started
                // step remains. Finishing the last step while it is up
                // takes it down - there is nothing left to sell.
                if setupOverview.isVisible, checklist.remainingCount > 0 {
                    SetupOverview(onDismiss: { setupOverview.dismiss() })
                        .padding(.horizontal, Spacing.comfortable)
                        .padding(.top, Spacing.comfortable)
                        // Measured, not assumed: this promo is several times
                        // taller than a notice row, and before it reserved
                        // anything it took its space out of the items list
                        // without the panel growing at all.
                        .reservesPanelHeight(PanelMetrics.setupBanner)
                }

                // At the very top, above everything, because a notice about the
                // app itself is not about the tab you happen to be on. The row
                // that used to sit under the tabs was the opposite: it scanned
                // the visible items, so it moved and changed as you navigated.
                NoticeBar()
                    .reservesPanelHeight(PanelMetrics.noticeBanner)

                HeaderView()
                    .padding(.horizontal, Spacing.comfortable)
                    .padding(.top, Spacing.comfortable)
                    .padding(.bottom, Spacing.related)

                TabsView()
                    .padding(.horizontal, Spacing.comfortable)

                FilterChips()
                    .padding(.horizontal, Spacing.comfortable)
                    .padding(.top, Spacing.related)

                content
                    // Records what was actually rendered, so a test can tell a
                    // persisted setting apart from a view that redrew. Without
                    // this the assertions passed even when the panel ignored the
                    // change entirely.
                    .onAppear { RenderProbe.layout = renderedLayout }
                    .onChange(of: renderedLayout) { _, new in RenderProbe.layout = new }
                    .padding(.horizontal, Spacing.comfortable)
                    .padding(.top, Spacing.related)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if prefs.showFooter {
                    FooterView()
                        .padding(.horizontal, Spacing.comfortable)
                        .padding(.vertical, Spacing.related)
                }
            }

            if store.movingItemID != nil {
                MovePicker()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            if store.openingItemID != nil {
                OpenWithPicker()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            // What the last drop did used to be its own toast here, with its
            // own timer and its own layout. It is now a `.transient` notice
            // through `NoticeBar`, at the top of the panel with everything
            // else the app has to say - one channel, not two.

            if let prompt = store.fillingVariablesFor {
                VariableFillSheet(item: prompt)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            if store.isDetailOpen, store.selectedItem != nil {
                DetailOverlay()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            // Last in the stack, so a corner drag is never stolen by whatever
            // is drawn under it - and only in the corners, so nothing in the
            // content area can move the window by accident.
            PanelDragCorners(theme: t)
        }
        .animation(.easeOut(duration: 0.16), value: store.movingItemID)
        .animation(.easeOut(duration: 0.16), value: store.openingItemID)
        .animation(.easeOut(duration: 0.16), value: store.isDetailOpen)
        .animation(.easeOut(duration: 0.16), value: tabs.tabs)
        // M10b: no longer `.animation(value: store.activeTabID)` here. That
        // blanket modifier put every switch - mouse, Tab key, or the QA
        // bridge - inside an active animation transaction covering this
        // WHOLE ZStack (header, notices, footer count, the content subtree),
        // which is exactly the ambient context that let a plain tab switch
        // animate the insertion of up to 200 rows. The tab indicator keeps
        // its own explicit animation in `TabsView`; the content cross-fade
        // below is its own explicit `withAnimation`, scoped to two opacity
        // values, not a value-keyed modifier over this whole subtree.
        // The panel resizes from the bottom as these change, so the search
        // field stays exactly where it is.
        .onChange(of: store.query) { _, query in
            PanelMetrics.shared.isSearching = !query.isEmpty
            PanelController.shared.applyHeight()
        }
    }

    /// A tab chooses its own layout, so the same category can be a gallery in
    /// one tab and a list in another.
    /// The layout this view will draw right now.
    private var renderedLayout: String {
        (tabs.spec(for: store.activeTabID) ?? store.activeTab).layout.rawValue
    }

    /// The tab body (M10b): always `LibraryContentView`, never a
    /// hand-rolled cross-fade.
    ///
    /// An earlier version of this kept the outgoing tab's `LibraryContentView`
    /// alive for ~120 ms in a `ZStack`, cross-fading opacity, on the theory
    /// that adding a keyed sibling would be cheaper than replacing the sole
    /// occupant of this slot. Measured back to back on the same process it
    /// was the opposite: wrapping the switch in `withAnimation` made SwiftUI
    /// lay the incoming 200-row content out eagerly to have something to
    /// interpolate, costing MORE than before M10b (p95 ~154-193 ms) rather
    /// than less. Dropping the animation and the second live copy - keeping
    /// only the type unification below - measured p95 well under the old
    /// 45-65 ms floor (see `LibraryContentView`'s doc comment for why a
    /// stable type here is what actually moved the number).
    private var content: some View {
        LibraryContentView(tabID: store.activeTabID)
    }
}

/// The frosted-glass substrate. A real `NSVisualEffectView` behind the theme's
/// own translucent wash, so the panel picks up what is behind it the way
/// Apple's own surfaces do.
struct GlassBackground: View {
    let theme: AppTheme

    var body: some View {
        ZStack {
            VisualEffectView(material: theme.isDark ? .hudWindow : .popover,
                             blending: .behindWindow)
            // The wash is a theme value now. At the 0.55/0.45 this was fixed
            // at, a bright desktop behind a dark theme lifted the panel until
            // white text on it fell under 2:1 - and no audit could see it,
            // because the audit graded the authored color, not this one.
            theme.panelBackground.opacity(1 - theme.translucency)

            if theme.usesGradientHeader {
                theme.accentGradient
                    .opacity(theme.isDark ? 0.30 : 0.16)
                    .blur(radius: 70)
                    .offset(y: -190)
            }
        }
        .ignoresSafeArea()
        .overlay(
            // Was fixed at 18 regardless of theme: Mono (a 6pt theme) still
            // drew an 18pt-rounded panel edge. `radiusContainer` is the
            // theme's own cornerRadius, so the edge now rounds the way the
            // theme that owns it says it should.
            RoundedRectangle(cornerRadius: theme.radiusContainer, style: .continuous)
                .strokeBorder(theme.isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08),
                              lineWidth: 1)
        )
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}


/// A one-value window into what the panel last drew.
///
/// Deliberately tiny and write-only from the view's side: it exists so a test
/// can assert that the interface *re-rendered*, which no amount of reading the
/// model can prove.
enum RenderProbe {
    nonisolated(unsafe) static var layout: String = ""

    /// Which kind-filter chip ids `FilterChips` actually drew as selected on
    /// its last render pass. Reading `store.activeFilters` proves the MODEL
    /// switched; it says nothing about whether the row redrew. This is
    /// stamped from inside the same `body` evaluation that feeds each chip's
    /// `active` flag, so a chip whose visual ring is stuck on an old
    /// selection - the model already moved on, the view did not - shows up
    /// here as a stale id no probe reading `activeFilters` could ever catch.
    nonisolated(unsafe) static var activeChipIDs: Set<String> = []

    /// Which chip ids currently hold real SwiftUI keyboard focus, per
    /// `ChipButton`'s own `@FocusState`. Tracked separately from
    /// `activeChipIDs` because the two are meant to be independent - a mouse
    /// click should select a chip without also leaving it looking "focused",
    /// and the two states must never be visually indistinguishable.
    nonisolated(unsafe) private static var chipFocus: [String: Bool] = [:]

    nonisolated(unsafe) static var focusedChipIDs: Set<String> {
        Set(chipFocus.filter { $0.value }.keys)
    }

    static func setChipFocus(_ id: String, _ focused: Bool) {
        chipFocus[id] = focused
    }
}


/// The shell both pickers share: scrim, card, title, hints.
///
/// Two overlays that look almost the same are two things to keep in step, and
/// they would not stay in step. One shell, two lists.
struct PickerShell<Content: View>: View {
    let title: String
    let onCancel: () -> Void
    @ViewBuilder let content: () -> Content

    @EnvironmentObject var theme: ThemeManager
    private var t: AppTheme { theme.theme }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: Spacing.related) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(t.textPrimary)
                    .lineLimit(2)

                VStack(spacing: Spacing.inline) { content() }

                HStack(spacing: Spacing.tight) {
                    Text("↑↓ choose").font(.system(size: 10)).foregroundStyle(t.textTertiary)
                    Text("↩ confirm").font(.system(size: 10)).foregroundStyle(t.textTertiary)
                    Text("⎋ cancel").font(.system(size: 10)).foregroundStyle(t.textTertiary)
                    Spacer()
                }
            }
            .padding(Spacing.comfortable)
            .frame(width: 340)
            .background(t.cardBackground, in: RoundedRectangle(cornerRadius: t.radiusContainer, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: t.radiusContainer, style: .continuous)
                .strokeBorder(t.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
            .themeTokens(["cardBackground", "border", "textPrimary", "textTertiary"])
        }
    }
}

/// One row in a picker.
struct PickerRow<Leading: View>: View {
    let label: String
    let detail: String?
    let highlighted: Bool
    let action: () -> Void
    @ViewBuilder let leading: () -> Leading

    @EnvironmentObject var theme: ThemeManager
    private var t: AppTheme { theme.theme }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.tight) {
                leading().frame(width: 20, height: 20)
                Text(label)
                    .font(.system(size: 12, weight: highlighted ? .semibold : .regular))
                    .foregroundStyle(highlighted ? t.onAccent : t.textPrimary)
                    .lineLimit(1)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.system(size: 9))
                        // Not `onAccent.opacity(0.8)`: fading the one color chosen for
                        // being readable on the accent gives back the contrast it
                        // was picked for. Weight and size carry the hierarchy.
                        .foregroundStyle(highlighted ? t.onAccent : t.tertiaryText(on: t.panelBackground))
                }
            }
            .padding(.horizontal, Spacing.related).padding(.vertical, Spacing.tight)
            .background(highlighted ? AnyShapeStyle(t.accent) : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Which app opens this link.
struct OpenWithPicker: View {
    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        PickerShell(title: title, onCancel: { store.cancelOpenWith() }) {
            ForEach(Array(store.openTargets.enumerated()), id: \.element.id) { index, target in
                PickerRow(label: target.name,
                          detail: target.isDefault ? "default" : (target.isNative ? "app" : nil),
                          highlighted: store.openChoice == index,
                          action: { store.commitOpenWith(target) }) {
                    Image(nsImage: target.icon).resizable()
                }
            }
        }
    }

    private var title: String {
        guard let item = store.selectedItem else { return "Open with" }
        return "Open \(item.host ?? "this link") with"
    }
}

/// Choosing where an item goes, from the keyboard.
///
/// The pointer gets a menu straight off the Move button; this is the same list
/// for anyone who never touches the mouse. Up/Down choose, Return moves, Escape
/// cancels — and the current home is marked so the choice is never a guess.
struct MovePicker: View {
    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager

    private var t: AppTheme { theme.theme }

    var body: some View {
        PickerShell(title: title, onCancel: { store.cancelMove() }) {
            ForEach(Array(store.moveDestinations.enumerated()), id: \.element.id) { index, role in
                PickerRow(label: role.title,
                          detail: store.selectedItem?.role == role ? "current" : nil,
                          highlighted: store.moveChoice == index,
                          action: { store.commitMove(to: role) }) {
                    Image(systemName: role.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(store.moveChoice == index ? t.onAccent : t.accent)
                }
            }
        }
    }

    private var title: String {
        guard let item = store.selectedItem else { return "Move to" }
        return "Move “\(item.displayTitle)” to"
    }
}


/// Asks for a prompt's placeholders, then pastes it filled in.
///
/// The last value for each name is offered again, because the second use of a
/// prompt is usually the same client, the same tone, the same product - and
/// retyping it is the friction that makes people edit the prompt instead.
struct VariableFillSheet: View {
    let item: ClipboardItem

    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager
    @State private var values: [String: String] = [:]
    @FocusState private var focused: String?

    private var t: AppTheme { theme.theme }
    private var names: [String] { PromptVariables.names(in: item.fullText) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { store.fillingVariablesFor = nil }

            VStack(alignment: .leading, spacing: Spacing.related) {
                Text(item.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(t.textPrimary)
                Text(PanelController.shared.previousApp?.localizedName.map {
                        "Fill these in, then press Return to paste into \($0)."
                     } ?? "Fill these in and it pastes complete.")
                    .font(.system(size: 11))
                    .foregroundStyle(t.textTertiary)

                ForEach(names, id: \.self) { name in
                    VStack(alignment: .leading, spacing: Spacing.inline) {
                        Text(name)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(t.textTertiary)
                        TextField("", text: Binding(
                            get: { values[name] ?? "" },
                            set: { values[name] = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, Spacing.tight).padding(.vertical, Spacing.inline)
                        .background(t.surfaceBackground, in: RoundedRectangle(cornerRadius: t.radiusControl))
                        .focused($focused, equals: name)
                        .onSubmit { paste() }
                    }
                }

                HStack {
                    SecondaryButton("Cancel", theme: t) { store.fillingVariablesFor = nil }
                    Spacer()
                    PrimaryButton("Paste", theme: t) { paste() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(Spacing.comfortable)
            .frame(width: 340)
            .background(t.cardBackground, in: RoundedRectangle(cornerRadius: t.radiusContainer, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: t.radiusContainer, style: .continuous)
                .strokeBorder(t.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
            .themeTokens(["cardBackground", "surfaceBackground", "border", "textPrimary", "textTertiary"])
        }
        .onAppear {
            let remembered = PromptVariables.remembered
            for name in names { values[name] = remembered[name] ?? "" }
            focused = names.first
        }
    }

    private func paste() { store.pasteFilled(item, values: values) }
}
