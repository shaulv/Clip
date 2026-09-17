import AppKit
import ApplicationServices
import SwiftUI
import Combine

/// The action surface: pick a clip, pick an action, read what came back, then
/// decide what happens to it.
///
/// It replaced an `NSMenu`, and the reason is what a menu cannot do. A menu can
/// raise an action and nothing else - no spinner while the model thinks, no way
/// to show the answer, and no way to let someone read it before it lands in
/// their document. The old shape pasted the result the instant it arrived, which
/// means the first time you ever see a transform is in the middle of whatever
/// you were writing.
///
/// **The rule this is built on: nothing is written, stored or pasted until Paste
/// or Copy is pressed.** The result lives here. Close throws it away, and the
/// history never hears about it. That is what makes running an action on a whim
/// safe, and it is why the editor is editable - the answer is a draft until the
/// user accepts it.
///
/// Independent of the clipboard panel by design. Opening this, using it, or
/// closing it changes nothing about the panel, the menu-bar icon, or what is
/// selected there.
@MainActor
final class ActionPanelController: NSObject, NSWindowDelegate {

    static let shared = ActionPanelController()

    let model = ActionPanelModel()

    private var panel: NSPanel?
    /// The app to give focus back to, and to paste into.
    private(set) var previousApp: NSRunningApplication?

    /// Two shapes (user, 03/09 night: "smaller and more compact like a
    /// dropdown of Apple"): a narrow menu while choosing, a working pane
    /// once an action runs. `size` is whatever the current phase needs.
    static let menuWidth: CGFloat = 300
    static let paneSize = NSSize(width: 520, height: 380)
    static let menuRowHeight: CGFloat = 30
    static let menuHeaderHeight: CGFloat = 58
    var size: NSSize { Self.size(for: model.phase, rows: model.flattenedRows.count) }

    static func size(for phase: ActionPanelModel.Phase, rows: Int) -> NSSize {
        guard phase == .choosing else { return paneSize }
        let height = menuHeaderHeight + CGFloat(max(rows, 1)) * menuRowHeight + 12
        return NSSize(width: menuWidth, height: min(max(height, 120), 460))
    }
    private var phaseObserver: AnyCancellable?

    var isOpen: Bool {
        #if CLIP_TESTING
        if QABridge.isHeadless { return logicallyOpen }
        #endif
        return panel?.isVisible == true
    }

    /// Headless runs never show a window, so "open" has to be a fact of its own.
    private var logicallyOpen = false

    #if CLIP_TESTING
    /// Where the action panel actually is, as `[x, y, width, height]` - read
    /// from the window itself, the same idiom `PanelController.frameForProbe`
    /// uses for the main panel. Empty under `CLIP_HEADLESS=1`: `open()` never
    /// builds a window in that mode (see the guard below), so there is
    /// nothing to report a frame for.
    var frameForProbe: [Double] {
        guard let f = panel?.frame else { return [] }
        return [f.origin.x, f.origin.y, f.width, f.height]
    }

    /// Whatever `ActionTooltipKey` currently publishes inside the action
    /// panel, or `nil` when nothing is showing. `ActionPanelView` writes this
    /// on every `.onPreferenceChange(ActionTooltipKey.self)`, so the probe
    /// can assert on the real published state - the same signal that drives
    /// what actually renders - rather than inferring it from `@State` it has
    /// no access to.
    var tooltipTextForProbe: String?
    #endif

    private override init() { super.init() }

    // MARK: - Opening

    func toggle() { isOpen ? close() : open() }

    func open() {
        // Before anything can take focus, and before the model reads the
        // clipboard: on the global path this is the app the user is typing in.
        previousApp = NSWorkspace.shared.frontmostApplication
        model.begin()

        #if CLIP_TESTING
        if QABridge.isHeadless {
            logicallyOpen = true
            return
        }
        #endif

        let panel = self.panel ?? makePanel()
        self.panel = panel
        resize(panel, to: size, anchorTopLeft: false)
        position(panel)
        // Deliberately no `NSApp.activate`: activating the app brings every
        // other visible window (Settings, the clipboard panel) forward with
        // it. This non-activating panel can become key on its own, so the
        // menu is the only thing that appears (user, 03/09 night).
        panel.makeKeyAndOrderFront(nil)
        if phaseObserver == nil {
            // `objectWillChange` fires BEFORE the phase changes, so the fit
            // is deferred one turn of the run loop to read the new value.
            phaseObserver = model.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in DispatchQueue.main.async { self?.fitToPhase() } }
        }
    }

    /// Re-fits the window to the current phase: the menu grows and shrinks
    /// with its rows (an opened submenu), and switching to a result swaps
    /// the menu for the working pane. The top-left corner stays put, so the
    /// menu never jumps away from the field it was opened under.
    private func fitToPhase() {
        guard let panel, panel.isVisible else { return }
        let wanted = size
        guard abs(panel.frame.width - wanted.width) > 0.5 || abs(panel.frame.height - wanted.height) > 0.5 else { return }
        resize(panel, to: wanted, anchorTopLeft: true)
        clampOnScreen(panel)
    }

    private func resize(_ panel: NSPanel, to size: NSSize, anchorTopLeft: Bool) {
        var frame = panel.frame
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        frame.size = size
        if anchorTopLeft { frame.origin = NSPoint(x: topLeft.x, y: topLeft.y - size.height) }
        panel.setFrame(frame, display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
    }

    /// Closes and discards. Nothing here has been stored, so there is nothing
    /// to undo.
    func close(restoreFocus: Bool = true) {
        model.cancel()
        model.reset()
        logicallyOpen = false
        panel?.orderOut(nil)
        if restoreFocus { previousApp?.activate() }
    }

    private func makePanel() -> NSPanel {
        let panel = ClipPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.animationBehavior = .utilityWindow

        let root = AnyView(
            ActionPanelView()
                .environmentObject(model)
                .environmentObject(ThemeManager.shared)
        )
        let view = NSHostingView(rootView: root)
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
        panel.contentView = view
        return panel
    }

    /// Under the text field that has focus in the app the person is typing
    /// in, so the menu appears where the paste will land; with no focused
    /// element (or no Accessibility), top-centre of the screen instead
    /// (user, 03/09 night). Never at the pointer.
    private func position(_ panel: NSPanel) {
        let size = panel.frame.size
        if let field = focusedElementFrame() {
            // AX frames are top-left based; Cocoa's are bottom-left based on
            // the primary screen.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let below = primaryHeight - field.maxY - 6 - size.height
            panel.setFrameOrigin(NSPoint(x: field.minX, y: below))
        } else {
            let screen = NSScreen.main ?? NSScreen.screens.first
            guard let visible = screen?.visibleFrame else { return }
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                         y: visible.maxY - 60 - size.height))
        }
        clampOnScreen(panel)
    }

    private func clampOnScreen(_ panel: NSPanel) {
        let frame = panel.frame
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var origin = frame.origin
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - frame.height - 8)
        panel.setFrameOrigin(origin)
    }

    /// The frame (top-left screen coordinates) of the focused UI element in
    /// the app that was frontmost when the menu was asked for, or nil when
    /// there is none this process is allowed to read.
    private func focusedElementFrame() -> CGRect? {
        guard let app = previousApp, app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        let element = focused as! AXUIElement
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef, let sizeValue = sizeRef else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &extent),
              extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    // MARK: - Focus

    func windowDidResignKey(_ notification: Notification) {
        #if CLIP_TESTING
        if QABridge.isHeadless { return }
        #endif
        // A result on screen is unsaved work. Clicking away must not throw away
        // an answer the user is still reading - the same rule the item editor
        // follows. Only Escape and the three buttons end a result.
        if model.hasUnsavedResult { return }
        // Nothing to lose: close, and do not steal focus back from whatever the
        // user just clicked.
        close(restoreFocus: false)
    }
}


/// Everything the action panel is doing, in one observable place.
@MainActor
final class ActionPanelModel: ObservableObject {

    enum Phase: Equatable {
        case choosing
        case working(String)
        case result
        case failed(String, String?)
    }

    @Published var phase: Phase = .choosing
    /// Bumped on every fresh `begin()`. The action panel's view is reused
    /// across opens (the window is hidden, not torn down), so this is what
    /// lets it tell "a fresh open" apart from "still the same open session,"
    /// and reset its own keyboard-only state (highlighted row, an open
    /// submenu) that would otherwise leak from one run of the panel to the
    /// next.
    @Published private(set) var openToken = 0
    /// The text the action runs on.
    @Published var sourceText = ""
    /// Which clip that came from, when it came from one rather than the
    /// clipboard itself.
    @Published var sourceItemID: UUID?
    /// What came back, editable. What is stored is what is in here.
    @Published var draft = ""
    /// What it was, kept for comparison.
    @Published var original = ""
    /// The action that produced the draft, for the title and for Retry.
    @Published var lastRun: (action: PasteAction, argument: String?)?

    /// The keyboard-navigable row currently highlighted. Deliberately its own
    /// piece of state, independent of pointer hover, so the two can render
    /// differently and a user driving the list by keyboard while the mouse
    /// happens to rest elsewhere always sees where Return will land.
    ///
    /// Lives here, not on `ActionPanelView`, because the view is torn down
    /// and rebuilt around the window's lifecycle while the model is not -
    /// and because a `CLIP_TESTING` bridge command needs a keyboard-driven
    /// decision to land somewhere it can reach without a live view instance.
    /// See `moveFocus(by:)`, `activateFocusedRow()`, `expand(_:)`,
    /// `expandFocusedIfPossible()` and `collapseFocusedIfPossible()` below -
    /// the same methods both `ActionPanelView`'s `.onKeyPress` handlers and
    /// `QABridge`'s `actionPanelKey` command call, so a test drives the exact
    /// decision a real keystroke does rather than a parallel copy of it.
    @Published var focusedRowID: String?
    /// The one submenu open at a time, spliced inline into the row list so
    /// arrow keys can walk straight into it and back out.
    @Published var expandedParentID: PasteAction.ID?

    /// True while there is an answer nobody has accepted or discarded.
    var hasUnsavedResult: Bool {
        if case .result = phase { return true }
        return false
    }

    private var task: Task<Void, Never>?

    /// The clips offered in the source picker.
    var candidates: [ClipboardItem] {
        Array(HistoryStore.shared.items
            .filter { !$0.fullText.isEmpty }
            .prefix(12))
    }

    /// Sets up for a fresh open: the clipboard is the default source, because
    /// nine times in ten it is what the user just copied.
    func begin() {
        openToken += 1
        reset()
        sourceText = TestIsolation.board.string(forType: .string) ?? ""
        if sourceText.isEmpty, let first = candidates.first {
            sourceText = first.fullText
            sourceItemID = first.id
        }
    }

    func reset() {
        phase = .choosing
        draft = ""
        original = ""
        lastRun = nil
        sourceItemID = nil
    }

    func use(_ item: ClipboardItem) {
        sourceItemID = item.id
        sourceText = item.fullText
        // A different source invalidates an answer about the old one.
        if phase != .choosing { phase = .choosing }
    }

    func useClipboard() {
        sourceItemID = nil
        sourceText = TestIsolation.board.string(forType: .string) ?? ""
        if phase != .choosing { phase = .choosing }
    }

    // MARK: - Running

    func run(_ action: PasteAction, argument: String? = nil) {
        guard AIService.shared.isAvailable else {
            phase = .failed("Connect a model to use paste actions.", AIGate.sentence)
            return
        }
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            phase = .failed("There is no text to work with.",
                            "Copy something, or pick a clip above.")
            return
        }

        let store = PasteActionStore.shared
        let instruction = store.instruction(for: action, argument: argument)
        lastRun = (action, argument)
        original = sourceText
        phase = .working(action.title)

        task?.cancel()
        task = Task { [weak self] in
            do {
                let suggestion = try await AIService.shared
                    .transformForPaste(text, instruction: instruction)
                let output = PasteTransform.cleaned(suggestion.body)
                guard !Task.isCancelled else { return }
                guard !output.isEmpty else {
                    throw AIError.malformed("The model replied with nothing at all.")
                }
                self?.draft = output
                self?.phase = .result
            } catch is CancellationError {
                self?.phase = .choosing
            } catch {
                guard !Task.isCancelled else { return }
                let reading = AIDiagnosis.read(error)
                self?.phase = .failed(reading.message, reading.remedy)
            }
        }
    }

    func retry() {
        guard let last = lastRun else { phase = .choosing; return }
        run(last.action, argument: last.argument)
    }

    func cancel() {
        task?.cancel()
        task = nil
        if case .working = phase { phase = .choosing }
    }

    // MARK: - Keyboard-navigable rows

    /// One row of the actions dropdown: a top-level action, or one choice
    /// inside the submenu currently open. Flattening both into a single list
    /// is what lets arrow keys walk straight from an action into its open
    /// submenu and back out, instead of two separate keyboard worlds - a
    /// plain `Menu` submenu cannot join a custom roving highlight this way,
    /// which is why this list drives every row itself.
    enum ActionRow: Equatable {
        case action(PasteAction)
        case child(parent: PasteAction, choice: String)

        var id: String {
            switch self {
            case .action(let a):            return a.id.uuidString
            case .child(let parent, let c):  return "\(parent.id.uuidString)#\(c)"
            }
        }
    }

    /// The list as it is actually shown right now.
    var flattenedRows: [ActionRow] {
        var rows: [ActionRow] = []
        let store = PasteActionStore.shared
        for action in store.enabled {
            rows.append(.action(action))
            if action.kind.hasSubmenu, expandedParentID == action.id {
                for choice in store.submenu(for: action) {
                    rows.append(.child(parent: action, choice: choice))
                }
            }
        }
        return rows
    }

    func moveFocus(by delta: Int) {
        let rows = flattenedRows
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == focusedRowID } ?? -1
        let next = min(max(current + delta, 0), rows.count - 1)
        focusedRowID = rows[next].id
    }

    /// Return: runs a leaf, opens a parent's submenu, or runs a submenu
    /// choice - whichever the focused row actually is.
    func activateFocusedRow() {
        let rows = flattenedRows
        guard let current = rows.firstIndex(where: { $0.id == focusedRowID })
            ?? (rows.isEmpty ? nil : 0) else { return }
        switch rows[current] {
        case .action(let action):
            if action.kind.hasSubmenu {
                expand(action)
            } else {
                run(action)
            }
        case .child(let parent, let choice):
            run(parent, argument: choice)
        }
    }

    /// Opens `action`'s submenu inline and moves focus onto its first
    /// choice - the same thing the right arrow does to it.
    func expand(_ action: PasteAction) {
        expandedParentID = action.id
        if let first = PasteActionStore.shared.submenu(for: action).first {
            focusedRowID = ActionRow.child(parent: action, choice: first).id
        }
    }

    @discardableResult
    func expandFocusedIfPossible() -> Bool {
        let rows = flattenedRows
        guard let current = rows.firstIndex(where: { $0.id == focusedRowID }),
              case .action(let action) = rows[current],
              action.kind.hasSubmenu, expandedParentID != action.id
        else { return false }
        expand(action)
        return true
    }

    /// Left arrow or Escape: step out of an open submenu one level at a
    /// time, rather than jumping straight to closing the whole panel while a
    /// choice is still open.
    @discardableResult
    func collapseFocusedIfPossible() -> Bool {
        let rows = flattenedRows
        guard let current = rows.firstIndex(where: { $0.id == focusedRowID }) else {
            guard expandedParentID != nil else { return false }
            expandedParentID = nil
            return true
        }
        switch rows[current] {
        case .child(let parent, _):
            expandedParentID = nil
            focusedRowID = ActionRow.action(parent).id
            return true
        case .action(let action):
            guard expandedParentID == action.id else { return false }
            expandedParentID = nil
            return true
        }
    }

    /// Run on every fresh open and every return to the choosing phase, so a
    /// closed submenu or a stale highlight never survives from a previous
    /// run of the panel - see the `openToken` comment above.
    func resetChoosingFocus() {
        expandedParentID = nil
        focusedRowID = flattenedRows.first?.id
    }

    // MARK: - Accepting

    /// Stores the draft, puts it on the clipboard, and pastes it into the app
    /// the user came from.
    func paste() {
        guard let stored = accept() else { return }
        let target = ActionPanelController.shared.previousApp
        ActionPanelController.shared.close(restoreFocus: false)
        _ = stored
        guard PreferencesModel.shared.pasteAutomatically else {
            CopyConfirmation.shared.show("Ready. Press ⌘V.")
            return
        }
        if TestIsolation.sendsRealKeystrokes { target?.activate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            PasteKeystroke.send()
        }
    }

    /// Stores the draft and puts it on the clipboard, without pasting.
    func copyToClipboard() {
        guard accept() != nil else { return }
        CopyConfirmation.shared.show("Copied")
        ActionPanelController.shared.close()
    }

    /// The one place a result becomes real: the clipboard and the history, in
    /// that order, with exactly the text on screen.
    ///
    /// Returns the stored item, or nil when there was nothing to store - which
    /// is not a silent failure but the honest answer for an empty draft.
    @discardableResult
    private func accept() -> ClipboardItem? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let board = TestIsolation.board
        board.clearContents()
        board.setString(draft, forType: .string)

        // The monitor would pick this up on its next poll and file it as an
        // ordinary copy. Suppressing that and adding it here instead is what
        // lets the item carry a title saying where it came from.
        ClipboardMonitor.shared.suppressNextCapture()
        let item = ClipboardItem(kind: .text, text: draft,
                                 title: storedTitle,
                                 role: .clip)
        HistoryStore.shared.add(item)
        lastStored = item
        return item
    }

    /// The last item stored by Paste or Copy. Test-facing.
    @Published private(set) var lastStored: ClipboardItem?

    private var storedTitle: String? {
        guard let last = lastRun else { return nil }
        let store = PasteActionStore.shared
        return "\(last.action.title) · \(store.label(for: last.action, argument: last.argument))"
    }
}
