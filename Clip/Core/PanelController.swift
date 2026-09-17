import AppKit
import SwiftUI

/// A borderless, key-capable floating panel.
///
/// The app previously used an `NSPopover`. In an `LSUIElement` (agent) app the
/// popover's window never becomes key, so no `keyDown` ever reached the app:
/// Escape, arrow navigation, ⌘1–9, menus and sheets were all silently dead.
/// An `NSPanel` that returns `true` from `canBecomeKey` fixes all of that at once.
final class ClipPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// Escape must reach our key router rather than being swallowed as "cancel".
    override func cancelOperation(_ sender: Any?) { /* handled by KeyRouter */ }
}

/// Owns the panel's lifecycle: where it appears, when it closes, and which app
/// gets focus back when it does.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {

    static let shared = PanelController()

    private var panel: ClipPanel?
    /// When the panel last became visible, used to ignore spurious focus loss.
    private var openedAt = Date.distantPast
    /// Logical open state, used when running headless.
    private var logicallyOpen = false

    /// Under the test harness the panel is never shown, activated or made key.
    ///
    /// Every assertion the probe makes is about store state and key routing, not
    /// about AppKit's ability to order a window front — and a test run that
    /// repeatedly steals focus makes the machine unusable for whoever is sitting
    /// at it. `KeyRouter` gates on `isOpen`, which stays truthful either way.
    private var isHeadless: Bool { QABridge.isHeadless }
    private var hosting: NSHostingView<AnyView>?

    /// The app that was frontmost before we took focus. We must restore it
    /// before synthesising ⌘V, otherwise the paste lands in Clip itself.
    var previousApp: NSRunningApplication?

    var isOpen: Bool { isHeadless ? logicallyOpen : (panel?.isVisible ?? false) }

    /// Shipped in every build (the overlay is a product feature, not a test hook).
    /// The real panel window, for the theme builder's "Inspect" overlay
    /// (M19) to size and position itself against - `nil` headless, exactly
    /// like every other AppKit-only accessor on this object, since a
    /// headless run has no real window for an overlay to sit over.
    var panelWindowForInspect: NSWindow? { isHeadless ? nil : panel }

    /// Set by the delegate so the panel can be anchored under the menu bar icon.
    var anchorButton: () -> NSStatusBarButton? = { nil }

    static let size = NSSize(width: 820, height: 640)

    // MARK: - Build

    private func makePanel() -> ClipPanel {
        let panel = ClipPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // Drag it wherever you want it. Empty background areas move the panel;
        // controls still get their own clicks, which is what this flag means.
        // Deliberately false. Anywhere-drag made starting an item drag move
        // the whole window, because to AppKit a drag on non-control content is
        // a request to move the window and the two gestures are identical.
        // Repositioning is still available, from an explicit handle behind the
        // header controls - see `WindowDragHandle`.
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        // Remember where it was put, so the next open returns it there.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                // Ignore the offscreen parking spot the headless harness uses,
                // or a test run would save -20000 as the user's preference.
                guard !QABridge.isHeadless else { return }
                // A resize moves the origin too (the panel grows downward from
                // a held top, and a clamp or a recentre moves it outright).
                // Recording that as a drag pinned the panel to a position the
                // UI chose, which is exactly the movement the user should
                // never have to undo.
                guard !self.isMovingProgrammatically else { return }
                PreferencesModel.shared.rememberedPanelOrigin = panel.frame.origin
                // A drag replaces the anchor: the top the panel grows from is
                // wherever the user just put it, not where it was before.
                self.anchoredTop = nil
                // Dragging it somewhere IS the instruction. Leaving the setting
                // on a rule that overrides the drag would mean the panel jumped
                // back on the next open, which reads as the drag not working.
                if PreferencesModel.shared.panelPlacement != .remembered {
                    PreferencesModel.shared.panelPlacement = .remembered
                }
            }
        }
        // A display change (resolution, a monitor unplugged, the Dock moving)
        // changes the cap the height was computed against. Without this the
        // panel kept a height its new screen cannot hold, which is the exact
        // "it hangs off the bottom" the cap exists to prevent.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyHeight() }
        }
        // Watch for authorisation dialogs taking focus, whether or not the panel
        // has resigned key yet. This is what makes the grace period above able
        // to know a dialog was involved at all.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let bundle = app?.bundleIdentifier,
                      Self.systemDialogBundles.contains(bundle) else { return }
                self.systemDialogLastSeen = Date()
            }
        }

        panel.animationBehavior = .utilityWindow

        let root = AnyView(
            PanelRootView()
                .environmentObject(HistoryStore.shared)
                .environmentObject(ThemeManager.shared)
        )
        let view = NSHostingView(rootView: root)
        view.frame = NSRect(origin: .zero, size: Self.size)
        // Rounded glass edge. The visual material itself is painted in SwiftUI so
        // the theme controls it; this only clips the corners.
        view.wantsLayer = true
        view.layer?.cornerRadius = 18
        view.layer?.masksToBounds = true
        if #available(macOS 14.0, *) { view.layer?.cornerCurve = .continuous }

        panel.contentView = view
        hosting = view
        return panel
    }

    /// True while the panel is being shown purely to preview a theme.
    private(set) var isPreviewing = false

    /// M7: whether the panel and Settings are laid out as the paired
    /// editor-left, preview-right theme-editing view, or the ordinary single
    /// window each is the rest of the time.
    enum LayoutMode { case normal, themeEditing }
    private(set) var layoutMode: LayoutMode = .normal

    /// What `enterThemeEditing` found before it moved anything, so
    /// `exitThemeEditing` can put both windows back exactly where they were -
    /// including whether the panel was open at all.
    private var savedPanelFrame: NSRect?
    private var savedSettingsFrame: NSRect?
    private var wasOpenBeforeThemeEditing = false
    private weak var themeEditingSettingsWindow: NSWindow?

    /// Window numbers exempt from "focus left the panel" while a layout mode
    /// depends on them staying interactive beside it - the same reasoning as
    /// the `ActionPanelController.shared.isOpen` check in `handleFocusLoss`,
    /// scoped to exactly the window in play rather than to any window at all.
    private var focusLossAllowlist: Set<Int> = []

    /// Opens the panel beside Settings so a theme can be judged by using it.
    ///
    /// A swatch grid tells you nothing about whether a theme works. The panel
    /// stays fully interactive — you can search, arrow around and switch tabs —
    /// and it will not close on focus loss, because the user is deliberately
    /// working in the Settings window next to it.
    func openForPreview() {
        isPreviewing = true
        guard !isHeadless else { logicallyOpen = true; return }
        if !isOpen { open() }
        positionBesideSettings()
    }

    func closePreview() {
        isPreviewing = false
        close(restoreFocus: false)
    }

    /// Puts the panel to the side of the Settings window rather than over it.
    private func positionBesideSettings() {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        var origin = NSPoint(x: visible.maxX - Self.size.width - 24,
                             y: visible.midY - Self.size.height / 2)
        origin.x = max(origin.x, visible.minX + 8)
        origin.y = max(origin.y, visible.minY + 8)
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: true)
        panel.orderFrontRegardless()
    }

    // MARK: - Theme editing layout (M7, REVISED for M17's own window)

    /// The geometry for the composition, separated from the window itself
    /// for the same reason `origin(for:...)` is: it can be tested with a
    /// known screen and a known panel size, with no real `NSWindow` involved.
    ///
    /// M17 REPLACES M7's sheet-relative formula: the theme builder is no
    /// longer a sheet floating over Settings, it is its OWN resizable
    /// window, and the rule is now about that window and the panel beside
    /// it, full stop - Settings itself is not part of this layout any more
    /// (M17 plan, the user's own words: "i want him on his own window, fixed
    /// to the left in full height and also all the width that can be done
    /// with leaving the right panel in view on the screen so the rest of the
    /// space can be given to the width").
    struct ThemeEditingLayout: Equatable {
        /// The builder window's own frame: flush to the visible frame's left
        /// edge, full visible height, as wide as the screen allows once the
        /// panel and both gaps are reserved.
        let windowFrame: NSRect
        /// The panel, docked 12pt past the builder window's right edge,
        /// vertically centred on the visible frame.
        let panelFrame: NSRect
    }

    /// origin.x = visible.minX, height = visible.height, width =
    /// visible.width - panelWidth - 24 (a 12pt gap to the panel plus a 12pt
    /// right margin); the panel sits at windowFrame.maxX + 12, vertically
    /// centred - exactly the numbers in the M17 plan, so a probe reading
    /// this function's own output is reading the rule itself, not a
    /// paraphrase of it.
    static func themeEditingLayout(panelSize: NSSize, visible: NSRect) -> ThemeEditingLayout {
        let gap: CGFloat = 12
        let rightMargin: CGFloat = 12

        let windowWidth = max(0, visible.width - panelSize.width - (gap + rightMargin))
        let windowFrame = NSRect(x: visible.minX, y: visible.minY,
                                 width: windowWidth, height: visible.height)
        let panelOrigin = NSPoint(x: windowFrame.maxX + gap, y: visible.midY - panelSize.height / 2)

        return ThemeEditingLayout(
            windowFrame: windowFrame,
            panelFrame: NSRect(origin: panelOrigin, size: panelSize))
    }

    #if CLIP_TESTING
    /// Stands in for a screen too small to hold both windows, without
    /// needing one - T3 and T7 drive this rather than resizing a real display.
    static var visibleFrameOverrideForTesting: NSRect?
    #endif

    private func themeEditingVisibleFrame(on screen: NSScreen) -> NSRect {
        Self.visibleFrame(on: screen)
    }

    /// The space the panel is allowed to occupy on a screen.
    ///
    /// One accessor for every caller, so the test override reaches the
    /// ordinary height rule too - the screen-height cap was previously
    /// reachable only by attaching a small display.
    static func visibleFrame(on screen: NSScreen?) -> NSRect {
        #if CLIP_TESTING
        if let override = visibleFrameOverrideForTesting { return override }
        #endif
        return screen?.visibleFrame ?? .zero
    }

    /// Enters the paired builder-left, panel-right layout beside
    /// `builderWindow` - M17: this is now the theme builder's OWN window,
    /// never the Settings window (Settings is not repositioned or resized
    /// by this any more). Safe to call while already in it (re-lays-out
    /// rather than stomping the saved frames a second time), and a no-op
    /// headless or with no window to sit beside. Internal names below still
    /// say "settings" in a few places - kept rather than churned across the
    /// probe and this file for a rename with no behaviour change; the
    /// PARAMETER is the builder window now, is all that actually matters.
    func enterThemeEditing(beside builderWindow: NSWindow?) {
        guard let builderWindow, !isHeadless else { return }
        if layoutMode != .themeEditing {
            wasOpenBeforeThemeEditing = isOpen
            savedSettingsFrame = builderWindow.frame
            if !isOpen { open(from: .themePreview) }
            savedPanelFrame = panel?.frame
            themeEditingSettingsWindow = builderWindow
            focusLossAllowlist.insert(builderWindow.windowNumber)
            layoutMode = .themeEditing
        }
        applyThemeEditingLayout()
    }

    private func applyThemeEditingLayout() {
        guard layoutMode == .themeEditing,
              let builderWindow = themeEditingSettingsWindow,
              let panel,
              let screen = builderWindow.screen ?? Self.activeScreen
        else { return }

        let visible = themeEditingVisibleFrame(on: screen)
        let layout = Self.themeEditingLayout(
            panelSize: NSSize(width: Self.size.width, height: panel.frame.height),
            visible: visible)

        // Not `animate: true`: that variant is synchronous and pumps the run
        // loop for the length of the animation - see the same warning on
        // `applyHeight()` below, which is exactly the reentrancy this would
        // reintroduce for the QA bridge's own command timer.
        builderWindow.setFrame(layout.windowFrame, display: true)
        panel.setFrame(layout.panelFrame, display: true)
        // The panel sits in FRONT of the builder window by design (the M7
        // composition this inherits), and it must never take key from the
        // editor while doing it. The panel is `.floating` level already (see
        // `makePanel`), which already outranks the builder window's
        // ordinary level in AppKit's compositing - `orderFront` is enough.
        panel.orderFront(nil)
    }

    #if CLIP_TESTING
    /// Re-runs the layout against whatever override is current, so a probe
    /// can change the screen size mid-edit and see the layout react.
    func reapplyThemeEditingLayoutForTesting() { applyThemeEditingLayout() }
    #endif

    /// Leaves the paired layout, restoring both windows exactly as
    /// `enterThemeEditing` found them - including the panel's open/closed
    /// state, which `ThemeManager.endPreview` (called around the same time)
    /// does not track: it always closes the panel, whether or not it was
    /// open before the theme editor was.
    func exitThemeEditing() {
        guard layoutMode == .themeEditing else { return }
        layoutMode = .normal

        if let settingsWindow = themeEditingSettingsWindow {
            focusLossAllowlist.remove(settingsWindow.windowNumber)
            if let saved = savedSettingsFrame {
                settingsWindow.setFrame(saved, display: true)
            }
        }
        if wasOpenBeforeThemeEditing {
            if !isOpen { open(from: .themePreview) }
            if let panel, let saved = savedPanelFrame {
                panel.setFrame(saved, display: true)
            }
        } else if let panel, let saved = savedPanelFrame {
            // About to be closed by `closePreview`, but set the frame back
            // first anyway: closing does not always run in the same tick as
            // this (Cancel calls `endPreview()` directly, then `onDisappear`
            // calls this again), and a frame left mid-layout would be what a
            // developer NEXT saw if they ever open the panel without going
            // through a placement rule first.
            panel.setFrame(saved, display: true)
        }
        themeEditingSettingsWindow = nil
        savedSettingsFrame = nil
        savedPanelFrame = nil
    }

    #if CLIP_TESTING
    /// The Settings frame `enterThemeEditing` is positioning, for the probe -
    /// there is no other way to read a window this class does not itself own.
    var themeEditingSettingsFrameForProbe: [Double] {
        guard let f = themeEditingSettingsWindow?.frame else { return [] }
        return [f.origin.x, f.origin.y, f.width, f.height]
    }
    /// The sheet's own frame (falling back to Settings' frame with no sheet
    /// attached) - what the panel's left edge is actually measured from,
    /// distinct from the wider Settings window behind it.
    var themeEditingSheetFrameForProbe: [Double] {
        guard let w = themeEditingSettingsWindow else { return [] }
        let f = w.attachedSheet?.frame ?? w.frame
        return [f.origin.x, f.origin.y, f.width, f.height]
    }
    var panelWindowNumberForProbe: Int { panel?.windowNumber ?? -1 }
    /// Whether the panel itself currently holds the keyboard. A sheet
    /// presented over Settings becomes key in Settings' place (the parent
    /// window's own `isKeyWindow` goes false while its sheet is up), so the
    /// meaningful check while editing a theme is "not the panel" rather than
    /// "Settings, specifically".
    var panelIsKeyForProbe: Bool { panel?.isKeyWindow ?? false }
    /// Whether the settings window's number is in the focus-loss allowlist
    /// right now - the direct, removable-in-isolation proof for T5, apart
    /// from `isPreviewing`'s own, broader, pre-existing guard.
    var themeEditingAllowlistContainsSettingsForProbe: Bool {
        guard let n = themeEditingSettingsWindow?.windowNumber else { return false }
        return focusLossAllowlist.contains(n)
    }
    /// Whether the panel is genuinely behind Settings in on-screen z-order.
    /// REVISED 02/09 20:40: the panel is always in FRONT of Settings now (it
    /// overlaps the right part of it by design), so T7 asserts this is
    /// false - kept under its original name since it is still exactly the
    /// z-order ground truth the assertion needs, just negated.
    ///
    /// Reads the window server's own list rather than `NSApp.orderedWindows`:
    /// the latter did not reliably include a borderless `NSPanel` alongside a
    /// titled window with an attached sheet in testing, where `CGWindowList`
    /// - the same ground truth Mission Control and Exposé use - did.
    var panelIsBehindSettingsForProbe: Bool {
        guard let panel, let settingsWindow = themeEditingSettingsWindow,
              let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]]
        else { return false }
        let panelNumber = panel.windowNumber
        // "The editor" is the sheet when one is attached - see the same
        // reasoning in applyThemeEditingLayout.
        let editorNumber = settingsWindow.attachedSheet?.windowNumber ?? settingsWindow.windowNumber
        var panelIndex: Int?
        var settingsIndex: Int?
        // Front-to-back, so a later index is further back on screen.
        for (i, entry) in info.enumerated() {
            guard let number = entry[kCGWindowNumber as String] as? Int else { continue }
            if number == panelNumber { panelIndex = i }
            if number == editorNumber { settingsIndex = i }
        }
        guard let p = panelIndex, let s = settingsIndex else { return false }
        return p > s
    }
    #endif

    // MARK: - Show / hide

    /// Where the request to open came from, which decides where the panel lands.
    ///
    /// Clicking the menu-bar icon should drop the panel under the icon, because
    /// that is where the click happened. A global hotkey has no such anchor: it
    /// is pressed while looking at the middle of the screen, so the panel opens
    /// there rather than in a corner the eye has to hunt for.
    enum OpenSource {
        case hotkey
        case statusItem
        /// M7: opening as part of `enterThemeEditing`. `origin(for:...)`
        /// bypasses the placement setting for this source - the paired
        /// layout computes its own position immediately afterward, and
        /// honouring a remembered or pointer-relative spot first would just
        /// be a frame that layout then has to undo.
        case themePreview
    }

    /// What positioned the panel last, for the probe to read.
    private(set) var lastOpenSource: OpenSource = .statusItem

    /// Polls for the end of a drag that began while the panel was open.
    private var dragWatcher: Timer?
    private var systemDialogWatcher: Timer?
    /// When a system authorisation dialog was last in front of us.
    ///
    /// Checking whether one is frontmost RIGHT NOW is not enough, and this is
    /// the half that was missing. `windowDidResignKey` does not always arrive
    /// while the dialog is up: SecurityAgent can take and give back focus
    /// faster than the notification reaches us, so the panel asks "is a dialog
    /// in front of me?", is told no because the dialog has already gone, and
    /// closes - which is exactly the "it vanishes after I submit" symptom.
    /// A remembered timestamp closes that window.
    private var systemDialogLastSeen: Date?
    /// How long after a dialog goes away a focus loss is still attributed to it.
    private static let systemDialogGrace: TimeInterval = 2.5


    func toggle(from source: OpenSource = .statusItem) {
        isOpen ? close() : open(from: source)
    }

    func open(from source: OpenSource = .statusItem) {
        // Measures the real show latency: entry to this function to the
        // panel actually being on screen and (when not headless) key. A
        // figure of 307.9 ms measured from the QA bridge's own command loop
        // included that loop's 30 ms polling floor on every sample, which is
        // noise from the harness, not the panel - this pair is timed INSIDE
        // the open path itself, the same reason `perfTheme` and the M10
        // tab-render metric are timed in-process rather than from the probe.
        let openStart = CFAbsoluteTimeGetCurrent()
        lastOpenSource = source
        let store = HistoryStore.shared

        // Remember who had focus so paste can go back to them.
        previousApp = NSWorkspace.shared.frontmostApplication

        store.query = ""
        store.beginSession()
        openedAt = Date()
        // Evaluated on every open rather than once at launch: AI can be turned
        // on in Settings while the panel is shut, and the invitation has to be
        // gone by the time it is next seen.
        NoticeCenter.shared.refreshInvitation()

        // M8.1: the first open after launch with anything standing gets the
        // full overview; every open after that (and every one before the
        // first condition exists) does not.
        NoticeCenter.shared.recheck()
        SetupOverviewCoordinator.shared.presentIfNeeded()

        // Headless: the panel still renders, but far offscreen and without ever
        // taking focus. A truly windowless mode would mean SwiftUI never runs a
        // body, and then no test could tell "the model changed" apart from "the
        // interface updated" — which is the bug class this exists to catch.
        guard !isHeadless else {
            logicallyOpen = true
            let panel = self.panel ?? makePanel()
            self.panel = panel
            panel.setFrame(NSRect(x: -20_000, y: -20_000,
                                  width: Self.size.width, height: Self.size.height),
                           display: false)
            panel.orderFrontRegardless()
            Perf.record("panelShow", ms: (CFAbsoluteTimeGetCurrent() - openStart) * 1000)
            // After `logicallyOpen = true`, not before: an `.integrity`
            // report made while `isOpen` still read false would count as
            // "raised with no panel open" and consume this launch's one
            // silent alert slot for a condition that is, in fact, about to
            // be shown right here in the panel it thinks is shut.
            checkAccessibilityAtOpen()
            return
        }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel, source: source)

        // An agent app must activate for its panel to accept keyboard input.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
        // The panel is genuinely on screen and key at this point - the
        // moment "show latency" actually means. Recorded here, not after
        // `checkAccessibilityAtOpen()` below: that call can post a notice
        // and touch other published state, which is cost the panel's own
        // appearance should not be charged for.
        Perf.record("panelShow", ms: (CFAbsoluteTimeGetCurrent() - openStart) * 1000)
        // Same ordering reason as the headless branch above: `isOpen` now
        // reads true, so this cannot double up with the integrity-alert path.
        checkAccessibilityAtOpen()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .clipFocusSearch, object: nil)
        }
    }

    /// M8.6: the red permissions row. Reported as `.integrity`, not
    /// `.persistent` like the other Accessibility notices in
    /// `AccessibilityGate` (a hotkey that fired and was blocked, or the
    /// launch-time check): those exist to be *noticed*, this one exists to
    /// be *impossible to miss or dismiss* the moment there is something on
    /// this Mac that cannot work without the grant, which is exactly what
    /// `.integrity` already means everywhere else in this app - it always
    /// wins the one visible slot, and `NoticeBar` never draws a close button
    /// for it. Both share `AccessibilityGate.noticeKey`, so whichever last
    /// reported wins until `resolve` clears it, and a real paste succeeding
    /// (`PasteTransform`) or trust being detected here both do.
    private func checkAccessibilityAtOpen() {
        let relevant = PreferencesModel.shared.pasteAutomatically
            || HistoryStore.shared.items.contains { !($0.shortcut ?? "").isEmpty }
        guard relevant, !AccessibilityGate.isTrusted else {
            NoticeCenter.shared.resolve(AccessibilityGate.noticeKey)
            return
        }
        NoticeCenter.shared.report(
            AccessibilityGate.message, remedy: AccessibilityGate.remedy,
            kind: .integrity, key: AccessibilityGate.noticeKey,
            action: AccessibilityGate.resetAction,
            secondaryAction: AccessibilityGate.openSettingsAction,
            stillNeeded: { !AccessibilityGate.isTrusted })
        // Proactive: reset the stale entry and let macOS ask, once per launch,
        // before anyone has to press the button above.
        AccessibilityGate.autoRepairOnce()
    }

    /// Makes the panel the key window in front of every other app.
    ///
    /// `open` already activates, but a hotkey fired from another application
    /// can land while that app is still finishing its own activation, and the
    /// panel then opens behind it. Re-asserting on the next run-loop turn is
    /// what makes the placeholder form actually visible.
    func bringToFront() {
        guard !isHeadless, let panel else { return }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Pins the panel where it is now, from Settings.
    ///
    /// The same thing dragging it does, for anyone who would rather press a
    /// button than find a corner - and it is the only way to say "here" when
    /// the panel is being previewed beside the Settings window.
    func rememberCurrentPosition() {
        guard let panel, panel.isVisible else { return }
        PreferencesModel.shared.rememberedPanelOrigin = panel.frame.origin
        PreferencesModel.shared.panelPlacement = .remembered
    }

    /// Closes the panel and hands focus back to whatever the user was using.
    /// `restoreFocus: false` is used on the paste path, where the caller
    /// re-activates the target app itself and then sends the keystroke.
    func close(restoreFocus: Bool = true) {
        // M8.1: the first-run overview is shown for one session, not
        // forever once armed. Without this, closing the panel WITHOUT
        // pressing its own Dismiss (just hitting the hotkey again, or
        // clicking away) left `isVisible` stuck true, and the next open
        // showed the full overview a second time even though
        // `hasShownThisLaunch` already says it should not.
        SetupOverviewCoordinator.shared.dismiss()
        // M19: the panel can close while the theme builder is open and
        // Inspect is on (the global hotkey, or clicking away, both reach
        // this method - only `ThemeBuilderWindowController.close` used to
        // turn Inspect off). Left on, the overlay window kept intercepting
        // clicks over a frame that no longer had a real panel under it, and
        // the builder's toggle still read "on" for a mode that could no
        // longer do anything - the user's report. Inspect belongs to a
        // VISIBLE panel, full stop; turning it off here is the missing half
        // of the same rule `ThemeBuilderWindowController.close` already
        // enforces on the builder-closes side.
        if ThemeInspectController.shared.isOn {
            ThemeInspectController.shared.setOn(false)
        }
        if isHeadless {
            logicallyOpen = false
            panel?.orderOut(nil)
            HistoryStore.shared.endSession()
            return
        }
        guard let panel else { return }
        panel.orderOut(nil)
        HistoryStore.shared.endSession()
        if restoreFocus {
            previousApp?.activate()
        }
    }

    // MARK: - Height

    /// True while a resize is in flight, so one cannot start another.
    private var isResizing = false
    /// The top edge to grow from and shrink back to, while the panel is taller
    /// than its base height. Nil whenever the panel is at base height, so the
    /// next growth re-reads wherever the user has since put it.
    private var anchoredTop: CGFloat?
    /// True from a programmatic frame change until the move notifications it
    /// causes have been delivered. `isResizing` cannot do this job: it is
    /// cleared synchronously after `setFrame`, and `didMoveNotification`
    /// arrives on a later main-queue turn, by which time it reads false.
    private var isMovingProgrammatically = false

    /// Resizes to the height the metrics ask for, keeping the top edge still
    /// and the whole panel on screen.
    ///
    /// Two promises, in this order:
    ///
    /// 1. **The top edge does not move.** The panel grows and shrinks from the
    ///    bottom, so a banner appearing above the content cannot move the
    ///    search field. Written as "hold the anchored top" rather than "set a
    ///    frame", because a frame set from the origin is exactly what moved
    ///    everything before.
    /// 2. **Growth never costs visibility.** The height is capped to the
    ///    visible frame, and the frame is clamped back inside it - so a panel
    ///    parked at the bottom edge slides up rather than growing off-screen,
    ///    and nothing the UI does asks the user to move the window.
    func applyHeight(animated: Bool = true) {
        // Reentrancy is not theoretical here. The first version called
        // `setFrame(display:animate:)`, which BLOCKS and pumps the run loop for
        // the length of the animation - during which the QA command timer
        // fired, ran another command, and called back into this. The panel
        // stopped accepting commands entirely: state kept updating, because a
        // Combine sink writes it, so it looked like the app was fine and the
        // bridge was broken. Neither was true.
        guard !isResizing else { return }
        // In theme-editing mode the layout owns the frame (full screen
        // height beside the builder). Recomputing the ordinary
        // base-plus-banners height here shrank the panel the moment a notice
        // appeared, and the content jumped with it (user report, 03/09). The
        // full-height panel already has room for every banner.
        guard layoutMode != .themeEditing else { return }
        guard let panel, panel.isVisible, !isHeadless else { return }
        let screen = panel.screen ?? Self.activeScreen
        let visibleFrame = Self.visibleFrame(on: screen)
        let wanted = PanelMetrics.shared.height(within: visibleFrame)
        let current = panel.frame

        guard abs(current.height - wanted) > 0.5 else { return }

        // The top edge the panel is growing from. Captured once, the first
        // time it grows above its base height, so shrinking back puts the top
        // exactly where it was rather than wherever the last clamp left it.
        // Without this the panel walked up the screen: hold-maxY on the way
        // out, slid-up maxY on the way back, and the position the user chose
        // was gone after two searches.
        if wanted > PanelMetrics.baseHeight, anchoredTop == nil {
            anchoredTop = current.maxY
        }
        let top = anchoredTop ?? current.maxY
        var frame = NSRect(x: current.minX, y: top - wanted,
                           width: current.width, height: wanted)
        if wanted <= PanelMetrics.baseHeight { anchoredTop = nil }

        // The height is already capped to the visible frame minus its inset,
        // so there are only two cases: it fits under the anchored top (keep
        // the top still, which is what makes typing into the search field
        // safe), or it does not, and the panel is centred vertically instead
        // of being slid off an edge or clipped. Centring is the one placement
        // that guarantees both edges are in view whatever grew.
        if visibleFrame.height > 0 {
            let visible = visibleFrame
            let inset = PanelMetrics.screenInset
            let lowest = visible.minY + inset
            let highest = visible.maxY - inset - frame.height
            if highest >= lowest {
                frame.origin.y = min(max(frame.origin.y, lowest), highest)
            } else {
                frame.size.height = min(frame.height, visible.height)
                frame.origin.y = visible.minY + (visible.height - frame.height) / 2
            }
            // The same promise horizontally, for a panel dragged half off the
            // side: a resize is not the moment to leave it there.
            let leftmost = visible.minX + inset
            let rightmost = visible.maxX - inset - frame.width
            if rightmost >= leftmost {
                frame.origin.x = min(max(frame.origin.x, leftmost), rightmost)
            }
        }
        isResizing = true
        // Never `animate: true`. That variant is synchronous and pumps the run
        // loop; the visible smoothness is not worth an app that stops
        // responding while it plays. The SwiftUI content animates its own
        // layout inside the new frame, which is the part anybody notices.
        isMovingProgrammatically = true
        panel.setFrame(frame, display: true)
        isResizing = false
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.isMovingProgrammatically = false
                self?.centreIfOffscreen()
            }
        }
    }

    /// Last line of defence: centre a panel that ended up outside the screen.
    ///
    /// The window has a floor of its own - `NSHostingView` holds `minSize` at
    /// the height its content refuses to go below - and `setFrame` obeys it,
    /// clamping the height while keeping the TOP-LEFT, which is how a capped
    /// panel ended up hanging below the screen. Reading the height back
    /// synchronously does not catch it (AppKit reports the requested size and
    /// clamps during layout) and forcing `minSize` ratchets the content's
    /// ideal height upward, so the check runs one turn later and only moves
    /// the panel, never resizes it.
    private func centreIfOffscreen() {
        guard !isResizing, let panel, panel.isVisible, !isHeadless else { return }
        let visible = Self.visibleFrame(on: panel.screen ?? Self.activeScreen)
        guard visible.height > 0 else { return }
        let frame = panel.frame
        guard frame.minY < visible.minY - 0.5 || frame.maxY > visible.maxY + 0.5
        else { return }
        let centred = visible.minY + (visible.height - frame.height) / 2
        guard abs(centred - frame.minY) > 0.5 else { return }
        isMovingProgrammatically = true
        panel.setFrame(NSRect(x: frame.minX, y: centred,
                              width: frame.width, height: frame.height),
                       display: true)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.isMovingProgrammatically = false }
        }
    }

    /// Positions the panel: under the status item when the icon opened it,
    /// centred on the active screen when the hotkey did. Clamped either way.
    private func position(_ panel: NSPanel, source: OpenSource = .statusItem) {
        guard let screen = Self.activeScreen else { return }
        var anchor: NSRect?
        if let button = anchorButton(), let window = button.window {
            anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        // Opening always starts from the base height. A panel that reopened at
        // whatever height the last search left it would be a different size
        // every time, for reasons invisible to the person opening it.
        PanelMetrics.shared.isSearching = false
        anchoredTop = nil
        let size = NSSize(width: Self.size.width,
                          height: PanelMetrics.shared.height(within: Self.visibleFrame(on: screen)))
        let origin = Self.origin(for: source, size: size,
                                 visible: screen.visibleFrame, anchor: anchor,
                                 remembered: PreferencesModel.shared.rememberedPanelOrigin,
                                 placement: PreferencesModel.shared.panelPlacement,
                                 pointer: NSEvent.mouseLocation)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    /// The maths, separated from the window.
    ///
    /// Under the test harness the panel is parked far offscreen and never
    /// positioned at all, so a check that reads the window frame can only ever
    /// confirm the offscreen parking spot. Pulling the decision out means the
    /// rule itself can be driven with a known screen and a known anchor, and
    /// the centring can actually be proved.
    /// Where the panel goes, given how it was opened and what the user asked
    /// for.
    ///
    /// Every branch ends at the same clamp, so no setting can put the panel
    /// off-screen - including a remembered position on a monitor that has since
    /// been unplugged.
    static func origin(for source: OpenSource, size: NSSize,
                       visible: NSRect, anchor: NSRect?,
                       remembered: NSPoint? = nil,
                       placement: PanelPlacement = .automatic,
                       pointer: NSPoint? = nil) -> NSPoint {
        var origin: NSPoint

        func clamped(_ point: NSPoint) -> NSPoint {
            var p = point
            p.x = min(max(p.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
            p.y = min(max(p.y, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8))
            return p
        }

        // M7: theme editing computes and applies its own paired layout right
        // after this open() returns, so honouring a remembered/pointer/corner
        // placement here would only be a frame that gets undone immediately.
        if source != .themePreview {
            switch placement {
            case .remembered:
                // A position the user chose outranks any rule we would apply.
                if let remembered { return clamped(remembered) }
            case .pointer:
                if let pointer {
                    // Under the pointer, not on it: a panel whose top-left corner
                    // is exactly at the cursor covers what was just clicked.
                    return clamped(NSPoint(x: pointer.x - 40,
                                           y: pointer.y - size.height + 20))
                }
            case .centre:
                return clamped(NSPoint(x: visible.midX - size.width / 2,
                                       y: visible.midY - size.height / 2))
            case .topLeft, .topRight, .bottomLeft, .bottomRight:
                if let corner = placement.corner {
                    return clamped(NSPoint(
                        x: visible.minX + (visible.width - size.width) * corner.x,
                        y: visible.minY + (visible.height - size.height) * corner.y))
                }
            case .automatic:
                // A dragged position still wins under Automatic, because dragging
                // the panel somewhere is an instruction whatever the setting says.
                if let remembered { return clamped(remembered) }
            }
        }

        if source == .statusItem, let anchor {
            origin = NSPoint(x: anchor.midX - size.width / 2,
                             y: anchor.minY - size.height - 6)
        } else {
            // Centred on both axes, which is where the eye already is when a
            // hotkey is what opened the panel.
            origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.midY - size.height / 2)
        }
        // Keep it fully on screen. A screen too small to hold it centred gets
        // it clamped rather than clipped.
        origin.x = min(max(origin.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
        origin.y = min(max(origin.y, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8))
        return origin
    }

    /// Where the panel actually is, as `[x, y, width, height]`.
    ///
    /// Read from the window, never from what `position` intended: the whole
    /// point is to catch a frame that was computed correctly and then not
    /// applied.
    /// Whether the frame above is the frame of a panel anyone can see.
    ///
    /// `frameForProbe` keeps reporting the last frame after the panel closes,
    /// so a resize check with no visibility check reads a stale rectangle as a
    /// live one and blames the resize code for a dismissal.
    var isVisibleForProbe: Bool { panel?.isVisible ?? false }

    var frameForProbe: [Double] {
        guard let f = panel?.frame else { return [] }
        return [f.origin.x, f.origin.y, f.width, f.height]
    }

    /// The visible frame the panel is being positioned within.
    static var probeScreenFrame: [Double] {
        let v = visibleFrame(on: activeScreen)
        guard v.height > 0 else { return [] }
        return [v.origin.x, v.origin.y, v.width, v.height]
    }

    /// The screen the user is actually on.
    ///
    /// `NSScreen.main` is the screen with the key window, which for an agent app
    /// with nothing open is whichever screen macOS last decided on - so on two
    /// monitors the panel could open on the one you are not looking at. The
    /// mouse is the better witness.
    static var activeScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    // MARK: - NSWindowDelegate

    /// Clicking anywhere outside the panel resigns key, which closes it.
    /// This is the "click outside to dismiss" behaviour.
    func windowDidResignKey(_ notification: Notification) {
        // Under the test harness, dismissal is driven explicitly by the
        // `clickOutside` command. Ambient desktop focus changes would otherwise
        // close the panel mid-test and make every keyboard assertion flaky —
        // testing the desktop's mood rather than Clip's behaviour.
        guard !QABridge.isHeadless else { return }
        // M23: and the same exemption for a REAL-input sequence, which runs in
        // a visible window and therefore cannot use the headless one. See the
        // `real_hold` command: a sequence of real keystrokes takes longer than
        // the desktop leaves Clip frontmost, so without this the overlay under
        // test disappears part way through and the keyboard code gets the
        // blame. `false` in the shipped app, where the harness does not exist.
        guard !QABridge.realInputHoldsPanel else { return }
        handleFocusLoss()
    }

    /// Exercises the real click-outside path without a synthetic mouse event.
    func simulateResignKey() { handleFocusLoss(force: true) }

    /// The unforced path: exactly what `windowDidResignKey` does.
    ///
    /// Needed because the two are no longer the same decision. A forced
    /// dismissal is "the user left, I am sure"; an unforced one is "focus went
    /// somewhere, work out whether that means anything".
    func simulateFocusLoss() { handleFocusLoss(force: false) }

    /// Whether the panel is presenting a sheet. Test-facing.
    var hasAttachedSheet: Bool { panel?.attachedSheet != nil }

    /// Focus loss in the first moments after opening is almost never a real
    /// click: activation races with whatever app was frontmost, and acting on it
    /// makes the panel flicker open and shut. A real click cannot arrive that
    /// fast, so ignoring that window costs the user nothing.
    /// The window that just took key, by number, for the M7 allowlist. Kept
    /// out of `handleFocusLoss` itself so the "only a sheet of THIS panel
    /// counts" rule stays provable: the handler never reasons about the key
    /// window in general, only about the exact numbers a layout mode listed.
    private var keyWindowNumberForAllowlist: Int? { NSApp.keyWindow?.windowNumber }

    private func handleFocusLoss(force: Bool = false) {
        // While previewing a theme the user is working in Settings by design.
        guard !isPreviewing else { return }

        // Clicking Settings dismisses the panel, like clicking anywhere else.
        // The one exception is a theme preview, which exists precisely so the
        // panel can be seen while its colors are being changed - that returns
        // above, before any of this runs.

        // A held mouse button at the moment focus is lost is a DRAG starting,
        // not someone clicking away. This is what made drag-and-drop from
        // Finder impossible: pressing a file to pick it up made Finder key,
        // the panel dismissed itself, and the drop target the user was aiming
        // at no longer existed by the time the drag began.
        if !force, NSEvent.pressedMouseButtons != 0 {
            waitForDragToFinish()
            return
        }
        // A sheet the panel itself put up is not a click outside either.
        //
        // `.sheet` on macOS is a separate window. It opens while the panel is
        // still key, so nothing happens at first - and then the first click
        // into it moves key to the sheet, the panel treats that as the user
        // leaving, and closes. The sheet goes with it. So the AI review sheet
        // could be read but not touched: clicking a proposal to see its diff
        // dismissed the whole thing.
        //
        // Only a sheet OF THIS PANEL counts. Settings is a separate window
        // rather than a sheet and still dismisses the panel, which is
        // deliberate and unchanged.
        if let panel, panel.attachedSheet != nil { return }

        // The action panel is Clip's own window, and raising it is not leaving.
        // Without this, opening it from inside the panel closed the panel - and
        // the user asked for these two to be independent in as many words.
        if ActionPanelController.shared.isOpen { return }

        // M7: a window a layout mode depends on staying interactive beside
        // the panel is not the user leaving either - the same reasoning as
        // the check just above, scoped to exactly the window in play rather
        // than to any window Clip happens to own. `isPreviewing` above
        // already covers every theme-editing window today (it is the only
        // caller of `openForPreview`), so this is the narrower mechanism the
        // plan calls for and the one a probe can prove in isolation; it does
        // not need `isPreviewing` to be true to do its own job correctly.
        if let number = keyWindowNumberForAllowlist, focusLossAllowlist.contains(number) {
            return
        }

        // A system authorisation dialog is not a click outside.
        //
        // Approving something with the password sheet or Touch ID hands focus
        // to SecurityAgent, the panel resigned key, and it dismissed itself -
        // so by the time the approval was granted the thing it was granted for
        // had gone. The user did not click away; the system took focus and
        // will give it straight back.
        //
        // Applies to `force` as well. Forcing exists to stand in for a real
        // click outside, and this is definitively not one.
        // A dialog up right now is never a click outside, forced or not.
        if isSystemDialogFrontmost {
            waitForSystemDialogToFinish()
            return
        }

        // One that has only just gone is the harder case: SecurityAgent can
        // take and give back focus faster than the resign-key notification
        // arrives, so by the time the panel is told it lost focus the dialog is
        // already history. The grace period attributes that loss to the dialog.
        //
        // Deliberately NOT applied to a forced dismissal. `force` means the
        // caller has already established that the user left - an explicit
        // dismissal, or a drag that ended somewhere else - and a grace period
        // that swallows those turns "it vanishes after I submit" into "it will
        // not close when I ask it to", which is the same bug facing the other
        // way.
        if !force, justFinishedSystemDialog {
            waitForSystemDialogToFinish()
            return
        }

        if !force, Date().timeIntervalSince(openedAt) < 0.4 {
            DispatchQueue.main.async { [weak self] in
                guard let panel = self?.panel, panel.isVisible else { return }
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
            }
            return
        }
        close(restoreFocus: false)
    }

    /// Processes that put a window in front of everything and then go away.
    ///
    /// Deliberately a short list of system agents rather than "anything that is
    /// not us". Another ordinary app becoming frontmost IS a click outside and
    /// must still dismiss the panel; these are the ones that take focus without
    /// the user having chosen to leave.
    private static let systemDialogBundles: Set<String> = [
        "com.apple.SecurityAgent",           // password and Touch ID approval
        "com.apple.loginwindow",
        "com.apple.CoreServicesUIAgent",     // Gatekeeper's "are you sure"
        "com.apple.UserNotificationCenter",  // system alerts
        "com.apple.ScreenSaver.Engine"
    ]

    #if CLIP_TESTING
    /// Why a focus loss was ignored, if it was. Names the branch rather than
    /// leaving a test to guess which of six early returns fired.
    var focusLossVerdictForTesting: String {
        if isPreviewing { return "previewing" }
        if panel?.attachedSheet != nil { return "sheet" }
        if isSystemDialogFrontmost {
            return "systemDialog:" + (NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")
        }
        if justFinishedSystemDialog { return "graceperiod" }
        return "dismisses"
    }

    /// Stands in for a corner drag, which a test cannot perform.
    ///
    /// Goes through the same two writes the real drag does, so the "dragging it
    /// pins it" rule is exercised rather than restated.
    func setOriginForTesting(_ origin: NSPoint) {
        PreferencesModel.shared.rememberedPanelOrigin = origin
        if PreferencesModel.shared.panelPlacement != .remembered {
            PreferencesModel.shared.panelPlacement = .remembered
        }
    }

    /// The panel's root view, so a test can render it to an image.
    var panelContentViewForTesting: NSView? { panel?.contentView }

    /// Stamps the grace period as though a dialog had just taken focus.
    func markSystemDialogSeenForTesting() { systemDialogLastSeen = Date() }

    /// Stands in for the frontmost application, so the DECISION can be tested.
    ///
    /// A real authorisation dialog cannot be raised from a test, and the part
    /// worth testing is not the dialog - it is what the panel does when one is
    /// in front of it. Compiled out of the shipped build entirely.
    static var frontmostBundleForTesting: String?
    #endif

    /// Makes a sheet this panel put up the key window, and activates the app.
    ///
    /// The panel is a NONACTIVATING panel, so a sheet it presents can be on
    /// screen and fully drawn while the keyboard still belongs to whatever app
    /// was in front. SwiftUI focus inside the sheet cannot help with that: the
    /// key events are not arriving at this process at all. Called when a sheet
    /// appears, so its first keystroke lands where the user is looking.
    func makeSheetKey() {
        guard let sheet = panel?.attachedSheet else { return }
        NSApp.activate(ignoringOtherApps: true)
        sheet.makeKeyAndOrderFront(nil)
    }

    /// True for a short while after an authorisation dialog was last seen.
    private var justFinishedSystemDialog: Bool {
        guard let seen = systemDialogLastSeen else { return false }
        return Date().timeIntervalSince(seen) < Self.systemDialogGrace
    }

    private var isSystemDialogFrontmost: Bool {
        #if CLIP_TESTING
        if let injected = Self.frontmostBundleForTesting {
            return Self.systemDialogBundles.contains(injected)
        }
        #endif
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        else { return false }
        return Self.systemDialogBundles.contains(front)
    }

    /// Holds the panel open until the system dialog goes away, then gives it
    /// the focus back.
    ///
    /// Handing focus back matters as much as staying open: a panel that is
    /// visible but not key swallows the next keystroke, so returning from an
    /// approval to a panel you cannot type into would be its own bug.
    private func waitForSystemDialogToFinish() {
        guard systemDialogWatcher == nil else { return }
        let watcher = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                guard let panel = self.panel, panel.isVisible else {
                    timer.invalidate(); self.systemDialogWatcher = nil; return
                }
                guard !self.isSystemDialogFrontmost else { return }
                timer.invalidate()
                self.systemDialogWatcher = nil
                // Back to us, ready to be typed into.
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
                // Spend the grace period. Once focus is back with the panel the
                // next loss is a real click outside, and a stale timestamp
                // would swallow it.
                self.systemDialogLastSeen = nil
            }
        }
        systemDialogWatcher = watcher
        RunLoop.main.add(watcher, forMode: .common)
    }

    /// Keeps the panel up while a drag is under way, and re-checks once the
    /// button comes back up.
    ///
    /// If the drag ended somewhere else entirely - the user was dragging a file
    /// between two Finder windows and never came near Clip - the panel dismisses
    /// then, so staying open costs nothing but the length of the drag.
    private func waitForDragToFinish() {
        guard dragWatcher == nil else { return }
        dragWatcher = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons == 0 else { return }
                timer.invalidate()
                self?.dragWatcher = nil
                guard let self, let panel = self.panel, panel.isVisible else { return }
                // Back where we started: no button held, so the ordinary rule
                // applies again. A drop onto the panel makes it key, and a key
                // panel is not a panel that has lost focus.
                if !panel.isKeyWindow { self.handleFocusLoss(force: true) }
            }
        }
        if let dragWatcher { RunLoop.main.add(dragWatcher, forMode: .common) }
    }
}

extension NSPoint {
    /// For the probe, which reads JSON rather than structs.
    var asArray: [Double] { [x, y] }
}
