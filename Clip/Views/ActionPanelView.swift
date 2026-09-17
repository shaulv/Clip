import SwiftUI

/// The action panel's interface: source, actions, and what came back.
///
/// One window, three states, and the same frame throughout - a panel that
/// resizes as it thinks makes the pointer's target move under it. The source
/// text stays visible in the result state on purpose: the question a transform
/// raises is "is this better than what I had", and that cannot be answered
/// against something you can no longer see.
struct ActionPanelView: View {
    @EnvironmentObject var model: ActionPanelModel
    @EnvironmentObject var theme: ThemeManager
    @ObservedObject private var actions = PasteActionStore.shared

    @FocusState private var keyboardFocused: Bool
    /// The close button had no hover state at all - see `closeButton`.
    @State private var hoveringClose = false
    @FocusState private var closeFocused: Bool

    /// The three result-footer buttons (Close/discard, Copy, Paste) had their
    /// tooltip hardcoded to `showing: true` - always on, regardless of the
    /// pointer or keyboard focus. Each gets its own hover flag and its own
    /// `@FocusState`, matching `ActionButton.highlighted` in `MediaPreview.swift`:
    /// hover and keyboard focus render the same tooltip, never two languages.
    @State private var hoveringDiscard = false
    @FocusState private var discardFocused: Bool
    @State private var hoveringCopy = false
    @FocusState private var copyFocused: Bool
    @State private var hoveringPaste = false
    @FocusState private var pasteFocused: Bool

    /// Pure pointer signal. Never moves keyboard focus on its own. The
    /// keyboard-driven counterparts, `focusedRowID` and `expandedParentID`,
    /// live on `ActionPanelModel` now - see the comment there.
    @State private var hoveredRowID: String?

    /// Convenience alias for the model's row type, so the row-rendering code
    /// below reads exactly as it did before the move.
    private typealias ActionRow = ActionPanelModel.ActionRow

    private var t: AppTheme { theme.theme }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(t.border)
            content
        }
        .background(t.panelBackground)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(t.border, lineWidth: 1))
        // M19: one aggregate tag for the whole action panel - it is a
        // separate satellite window from the clipboard panel Inspect
        // overlays, so it declares its own `.coordinateSpace` below (see
        // `ThemeInspectRegistry.coordinateSpaceName`'s own doc comment);
        // its frames resolve correctly only while THIS window is the one
        // being inspected.
        .themeTokens(["panelBackground", "border", "surfaceBackground", "textPrimary",
                      "textTertiary", "accentOnPanel", "destructive"])
        .coordinateSpace(name: ThemeInspectRegistry.coordinateSpaceName)
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocused)
        .onKeyPress(.downArrow) {
            guard model.phase == .choosing else { return .ignored }
            model.moveFocus(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard model.phase == .choosing else { return .ignored }
            model.moveFocus(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard model.phase == .choosing else { return .ignored }
            return model.expandFocusedIfPossible() ? .handled : .ignored
        }
        .onKeyPress(.leftArrow) {
            guard model.phase == .choosing else { return .ignored }
            return model.collapseFocusedIfPossible() ? .handled : .ignored
        }
        .onKeyPress(.return) {
            guard model.phase == .choosing else { return .ignored }
            model.activateFocusedRow()
            return .handled
        }
        .onKeyPress(.escape) {
            // Escape steps out of an open submenu first, and only closes the
            // whole panel once there is nothing left to step out of - the
            // same one-level-at-a-time rule the left arrow follows.
            if model.phase == .choosing, model.collapseFocusedIfPossible() { return .handled }
            close()
            return .handled
        }
        .onAppear {
            DispatchQueue.main.async { keyboardFocused = true }
            resetChoosingFocus()
        }
        // The panel view is reused across opens (the window is hidden, not
        // torn down), so `.onAppear` alone would leave a stale highlight or
        // an open submenu from the previous run. `openToken` bumps on every
        // fresh `begin()` and catches that case; the phase check below catches
        // every other way the panel lands back on `.choosing` (cancel, or
        // switching the source).
        .onChange(of: model.openToken) { _, _ in resetChoosingFocus() }
        .onChange(of: model.phase) { _, newPhase in
            if newPhase == .choosing { resetChoosingFocus() }
        }
        .drawsActionTooltips(theme: t)
        #if CLIP_TESTING
        // Mirrors the real published tooltip payload onto the controller so
        // the probe can assert against it directly - see
        // `ActionPanelController.tooltipTextForProbe`.
        .onPreferenceChange(ActionTooltipKey.self) { payload in
            ActionPanelController.shared.tooltipTextForProbe = payload?.text
        }
        #endif
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(t.accentOnPanel)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(t.textPrimary)
                Spacer()
                closeButton
            }
            // While choosing, the source is one line of metadata here - the
            // dropdown has no room for a preview card and does not need one
            // (user, 03/09 night: "smaller and more compact").
            if model.phase == .choosing {
                HStack(spacing: 8) {
                    fromPicker(on: t.panelBackground)
                    Spacer()
                    Text("\(model.sourceText.count) characters")
                        .font(.system(size: 9))
                        .foregroundStyle(t.textTertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// This X was the odd one out: no background, no ring and no `.onHover` at
    /// all, so the one control that throws away a whole run was also the only
    /// one in the app that did not acknowledge the pointer. It is now the
    /// dismiss weight of the same icon-button chrome the notice bar's X uses.
    private var closeButton: some View {
        Button { close() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hoveringClose ? t.textPrimary : t.textTertiary)
                .iconButtonChrome(t, variant: .dismiss, highlighted: hoveringClose)
        }
        .buttonStyle(.plain)
        .onHover { hoveringClose = $0 }
        .focused($closeFocused)
        .actionTooltip("Close without keeping anything", showing: hoveringClose || closeFocused)
    }

    private var title: String {
        switch model.phase {
        case .choosing:            return "Paste action"
        case .working(let label):  return label
        case .result:              return model.lastRun?.action.title ?? "Result"
        case .failed:              return "That didn't work"
        }
    }

    // MARK: - Source

    /// Which clip the action runs on, and what is in it.
    ///
    /// The clipboard is the default because nine times in ten it is what was
    /// just copied. The picker exists for the tenth: the thing you want to
    /// translate is two copies back, and re-copying it to use it here would be
    /// a silly thing to have to do.
    private var source: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                fromPicker(on: t.panelBackground)
                Spacer()
                Text("\(model.sourceText.count) characters")
                    .font(.system(size: 9))
                    .foregroundStyle(t.textTertiary)
            }

            ScrollView {
                Text(model.sourceText.isEmpty ? "Nothing copied yet." : model.sourceText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(model.sourceText.isEmpty ? t.textTertiary : t.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 54)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    /// "From" and the clip picker beside it.
    ///
    /// The stacked source strip and the floating preview card had this block
    /// byte for byte identical bar one thing - the background each sits on,
    /// which is why it takes `ground` and resolves its own text against it
    /// rather than guessing. Two places to change the wording, the chevron or
    /// the accent is how they end up different; this is the part that never
    /// does.
    @ViewBuilder
    private func fromPicker(on ground: Color) -> some View {
        Text("From")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(t.tertiaryText(on: ground))
        Menu {
            Button {
                model.useClipboard()
            } label: {
                Label("Clipboard", systemImage: "doc.on.clipboard")
            }
            Divider()
            ForEach(model.candidates) { item in
                Button { model.use(item) } label: {
                    Text(item.displayTitle).lineLimit(1)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(sourceLabel).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(t.accentText(on: ground))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var sourceLabel: String {
        guard let id = model.sourceItemID,
              let item = HistoryStore.shared.items.first(where: { $0.id == id })
        else { return "Clipboard" }
        return item.displayTitle
    }

    // MARK: - States

    /// What sits below the header, per phase.
    ///
    /// Only the choosing phase floats the source over a full-bleed list - it
    /// is the one phase where picking the source and picking the action are
    /// both live decisions, and the actions are the thing to focus on.
    /// Working, result and failure all concern one thing (the run under way,
    /// or its outcome), so they keep the panel's older stacked shape: the
    /// source as a strip on top, for reference, and the phase body below it.
    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .choosing:
            choosingLayout
        case .working(let label):
            stacked(working(label))
        case .result:
            stacked(result)
        case .failed(let m, let remedy):
            stacked(failure(m, remedy))
        }
    }

    /// The panel's older stacked shape: the source as a reference strip on
    /// top, the phase body filling what is left below it. Kept, unchanged,
    /// for every phase except choosing.
    private func stacked<Body: View>(_ phaseBody: Body) -> some View {
        VStack(spacing: 0) {
            source
            Divider().overlay(t.border)
            phaseBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The actions list is the hero and fills the whole area edge to edge;
    /// the source preview floats above it, inset and shadowed, so the two
    /// read as two different surfaces even though they share one window. The
    /// list reserves its own top gutter (see `actionList`) so the card never
    /// covers a row - it sits on top of the list visually, not on top of it
    /// in the hit-test sense.
    /// The dropdown: rows only, edge to edge, no preview card - the source
    /// line lives in the header. Scrolls only past ~13 rows.
    private var choosingLayout: some View {
        actionList
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Every enabled action, generously spaced, with the one open submenu's
    /// choices spliced in right after their parent - see `flattenedRows`.
    /// Scrolling is expected and fine: opening the panel up (rather than
    /// keeping native-menu density) means a full action set no longer fits
    /// without it, the same trade every "trendy" app dropdown makes.
    private var actionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Owner asked for a hairline gap so hover and selected row
                // backgrounds never visually touch when stacked.
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.flattenedRows, id: \.id) { row in
                        rowView(row).id(row.id)
                    }

                    if actions.enabled.isEmpty {
                        Text("No actions are switched on. Settings > Paste Actions.")
                            .font(.system(size: 11))
                            .foregroundStyle(t.textTertiary)
                            .padding(.vertical, 20)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .onChange(of: model.focusedRowID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t.panelBackground)
    }

    // MARK: - Keyboard-navigable rows
    //
    // The row type, the flattened list, and every decision about moving,
    // expanding or collapsing the keyboard highlight now live on
    // `ActionPanelModel` (see `Core/ActionPanel.swift`) - not here. The view
    // only renders `model.flattenedRows` and forwards key presses to the
    // model's methods, which is what lets `QABridge`'s `actionPanelKey`
    // command drive the identical decision a real keystroke does.

    /// Run on every fresh open and every return to the choosing phase, so a
    /// closed submenu or a stale highlight never survives from a previous
    /// run of the panel - see the `openToken` comment on `body`. Resets the
    /// view's own pointer-hover state here; the keyboard state it hands off
    /// to `model.resetChoosingFocus()`.
    private func resetChoosingFocus() {
        hoveredRowID = nil
        model.resetChoosingFocus()
    }

    /// The background a row is actually painted on right now, matching
    /// `RowChrome`'s own fill exactly - text and icon contrast are computed
    /// against this, not against a guess, on every one of its three states.
    private func rowGround(isFocused: Bool, isHovered: Bool) -> Color {
        if isFocused { return t.selectedBackground }
        if isHovered { return t.cardHoverBackground }
        return t.cardBackground
    }

    @ViewBuilder
    private func rowView(_ row: ActionRow) -> some View {
        switch row {
        case .action(let action):       actionRow(action)
        case .child(let parent, let c):  childRow(parent: parent, choice: c)
        }
    }

    /// A top-level action: an accent-tinted icon in its own chip, a generous
    /// label, and - for a parent like Translate or Rewrite in a style - a
    /// chevron that rotates open. Hover and keyboard focus share the app's
    /// one row treatment (`rowChrome`) but are never the same state: focus
    /// takes the stronger, two-point selection ring, hover the lighter one,
    /// so a glance tells them apart without reading color alone.
    private func actionRow(_ action: PasteAction) -> some View {
        let id = ActionRow.action(action).id
        let isFocused = model.focusedRowID == id
        let isHovered = hoveredRowID == id
        let isExpanded = model.expandedParentID == action.id
        let ground = rowGround(isFocused: isFocused, isHovered: isHovered)
        let chip = AppTheme.chipColors(t.accent, on: ground)

        return Button {
            model.focusedRowID = id
            if action.kind.hasSubmenu {
                isExpanded ? (model.expandedParentID = nil) : model.expand(action)
            } else {
                model.run(action)
            }
        } label: {
            // Apple-menu density: a 16pt symbol in the accent, the label,
            // a small chevron for a submenu. No icon chip, 30pt rows.
            HStack(spacing: 10) {
                Image(systemName: action.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(chip.foreground)
                    .frame(width: 18)
                Text(action.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(t.text(on: ground))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if action.kind.hasSubmenu {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(t.tertiaryText(on: ground))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: ActionPanelController.menuRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowChrome(t, hovering: isHovered, selected: isFocused)
        .onHover { entered in
            hoveredRowID = entered ? id : (hoveredRowID == id ? nil : hoveredRowID)
        }
        .animation(.easeOut(duration: 0.12), value: isExpanded)
    }

    /// One choice inside an open submenu (a language, a style): indented
    /// under its parent rather than iconed, so proximity alone says it
    /// belongs there, with the same focus/hover chrome as every other row.
    private func childRow(parent: PasteAction, choice: String) -> some View {
        let id = ActionRow.child(parent: parent, choice: choice).id
        let isFocused = model.focusedRowID == id
        let isHovered = hoveredRowID == id
        let ground = rowGround(isFocused: isFocused, isHovered: isHovered)

        return Button {
            model.focusedRowID = id
            model.run(parent, argument: choice)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(t.tertiaryText(on: ground))
                    .frame(width: 5, height: 5)
                Text(choice)
                    .font(.system(size: 12.5))
                    .foregroundStyle(t.text(on: ground))
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.leading, 30)
            .padding(.trailing, 10)
            .frame(height: ActionPanelController.menuRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowChrome(t, hovering: isHovered, selected: isFocused)
        .onHover { entered in
            hoveredRowID = entered ? id : (hoveredRowID == id ? nil : hoveredRowID)
        }
    }

    /// The spinner lives here, in the panel, where the action was raised. A menu
    /// could not hold one, which is why a request looked like nothing happening.
    private func working(_ label: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView().controlSize(.small)
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(t.textPrimary)
            Text("Nothing is written until you accept the result.")
                .font(.system(size: 10))
                .foregroundStyle(t.textTertiary)
            Button("Cancel") { model.cancel() }
                .buttonStyle(.link)
                .font(.system(size: 11))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// The result, editable, next to what it replaced.
    private var result: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Before")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(t.textTertiary)
                    ScrollView {
                        Text(model.original)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(t.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().overlay(t.border)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("After")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(t.accentOnPanel)
                        Text("editable")
                            .font(.system(size: 9))
                            .foregroundStyle(t.textTertiary)
                        Spacer()
                    }
                    // A markdown editor, because the answer is a draft. What
                    // gets stored is what is in this box when Paste or Copy is
                    // pressed, not what the model happened to say.
                    MarkdownPromptEditor(text: $model.draft,
                                         placeholder: "",
                                         theme: t,
                                         minHeight: 120, maxHeight: .infinity,
                                         showsPreview: true, showsAI: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider().overlay(t.border)

            HStack(spacing: 8) {
                Button("Close") { close() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(t.textTertiary)
                    .onHover { hoveringDiscard = $0 }
                    .focused($discardFocused)
                    .actionTooltip("Throw this away. Nothing has been stored yet.",
                                   showing: hoveringDiscard || discardFocused)
                Spacer()
                Button("Copy to Clipboard") { model.copyToClipboard() }
                    .onHover { hoveringCopy = $0 }
                    .focused($copyFocused)
                    .actionTooltip("Keeps it in Clip and on the clipboard",
                                   showing: hoveringCopy || copyFocused)
                Button("Paste") { model.paste() }
                    .keyboardShortcut(.defaultAction)
                    .onHover { hoveringPaste = $0 }
                    .focused($pasteFocused)
                    .actionTooltip("Keeps it in Clip and pastes it where you were",
                                   showing: hoveringPaste || pasteFocused)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func failure(_ message: String, _ remedy: String?) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(t.destructive)
            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(t.textPrimary)
                .multilineTextAlignment(.center)
            if let remedy {
                Text(remedy)
                    .font(.system(size: 10))
                    .foregroundStyle(t.textTertiary)
                    .multilineTextAlignment(.center)
            }
            Text("Nothing was changed or stored.")
                .font(.system(size: 10))
                .foregroundStyle(t.textTertiary)
            HStack(spacing: 10) {
                Button("Close") { close() }
                Button("Try Again") { model.retry() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    private func close() { ActionPanelController.shared.close() }
}
