import SwiftUI
import AppKit

/// M17: the theme builder's own top-level window.
///
/// It used to be a sheet presented over Settings (M7/M9). The user's own
/// words moving it out: "i want him on his own window, fixed to the left in
/// full height and also all the width that can be done with leaving the
/// right panel in view on the screen so the rest of the space can be given
/// to the width." Settings itself is no longer part of this layout at all -
/// "New theme" / "Edit…" / "Generate" now open this window directly, and it
/// positions itself and the real clipboard panel beside it, reusing the
/// exact M7 machinery (`PanelController.enterThemeEditing`/`exitThemeEditing`)
/// with a new placement rule (`PanelController.themeEditingLayout`).
@MainActor
final class ThemeBuilderWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ThemeBuilderWindowController()

    /// Shared with `ThemeBuilderView` (an `@EnvironmentObject`) so the window
    /// controller (AppKit, no SwiftUI state of its own) and the view tree
    /// (every row, the assistant, the matrix) agree on one draft without
    /// either reaching into the other's private state - the same split
    /// `ThemeEditorBridge`'s open/close counters already use, applied here
    /// to the draft itself.
    let state = ThemeBuilderState()

    private weak var themeManager: ThemeManager?
    private(set) var isOpen = false
    /// Whether the real SwiftUI content has been installed yet. `NSWindow`
    /// always starts with a non-nil DEFAULT content view of its own (an
    /// empty `NSView`, created by `NSWindow.init` itself) - checking
    /// `window?.contentView == nil` to decide "has the real content been
    /// installed" is never true, which silently left every open of this
    /// window showing that empty default view forever, real content never
    /// installed. Measured directly: every model-level probe (reading
    /// `state.theme` straight from the shared `ThemeBuilderState`) passed
    /// regardless, because those never touch the view tree at all - only
    /// anything that needed the ACTUAL rendered window (a snapshot PNG, a
    /// registry a SwiftUI `onAppear` populates) came back empty.
    private var hasBuiltContent = false

    /// M9: the same seam `SettingsWindowController.contentViewForTesting`
    /// already exposes, aimed at this window instead - the builder opened
    /// but had no snapshot path of its own, so its visual design (the token
    /// list, the contrast matrix, the live preview) had never actually been
    /// looked at, only ever asserted against via `state.theme` and the
    /// counters above.
    var contentViewForTesting: NSView? { window?.contentView }

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Theme Builder"
        // NOT 720pt wide: the M17 window-frame FORMULA is the authority on
        // width at open time (visibleFrame.width - panelWidth - 24), and on
        // a real 13"/14" MacBook screen (logical visible width well under
        // 1564pt, the point at which the formula alone clears 720 with the
        // panel's fixed 820pt width) that formula legitimately computes
        // LESS than 720 - measured directly: `setFrame` respects
        // `NSWindow.minSize` even for a purely programmatic call, so a
        // 720pt floor here silently overrode the formula's own real answer
        // on exactly the screens most people actually use. 400pt is a floor
        // against a pathological/negative width only, never a fight with
        // the placement rule; a person dragging the window's own resize
        // handle still cannot shrink it into uselessness.
        window.minSize = NSSize(width: 400, height: 480)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        self.init(window: window)
        window.delegate = self
    }

    /// Opens (or re-focuses) the builder on `draft`, previewing it live on
    /// the real panel exactly as the old sheet did.
    func open(_ draft: CustomTheme, themeManager: ThemeManager,
             onSave: @escaping (CustomTheme) -> Void, onCancel: @escaping () -> Void) {
        self.themeManager = themeManager
        state.theme = draft
        state.selectedToken = nil
        // M30: the contrast matrix's "Show the full check" disclosure -
        // collapsed on every fresh open, the same "never remembered open"
        // rule `assistantExpanded` states for its own section, now actually
        // enforced here rather than only on the one-time-ever view init
        // (the content view itself is built once and reused - see
        // `hasBuiltContent` below - so this reset has to live in the state
        // object, not a plain `@State` the view would only initialize once).
        state.matrixFullAuditOpen = false
        state.onSave = onSave
        state.onCancel = onCancel

        if !hasBuiltContent {
            let hosting = NSHostingView(rootView: AnyView(
                ThemeBuilderView()
                    .environmentObject(state)
                    .environmentObject(themeManager)
            ))
            // KNOWN LIMITATION, measured directly rather than assumed:
            // `NSHostingView` still enforces a content-driven minimum width
            // on this window - roughly the contrast matrix's fixed 340pt
            // column plus ~295pt for the token column's own shortest
            // readable layout, about 634pt total - regardless of
            // `sizingOptions` (tried `[]`) or forcing springs-and-struts
            // autoresizing on the hosting view itself (tried that too):
            // neither stopped it, so the M17 width FORMULA is only exact
            // down to a visible width of about 1478pt (634 + panelWidth 820
            // + the 24pt of gaps); below that, the window holds at ~634pt
            // rather than the formula's smaller number. This is real,
            // narrow-screen behaviour, not a test artifact - `run_m7_
            // theme_editing_layout`'s own T2/T3 exercise the formula on
            // widths comfortably above this floor for exactly that reason,
            // and T3 is why this floor is written down here rather than
            // rediscovered blind next time.
            window?.contentView = hosting
            hasBuiltContent = true
        }
        isOpen = true
        themeManager.beginPreview(draft)

        // First pass: opens the panel (if needed) and enters the paired
        // layout against THIS window. Second pass, deferred a run-loop turn:
        // the same reasoning the old sheet's `onAppear` documented - AppKit
        // coalesces the reposition/reorder calls within one turn, so the
        // layout is reapplied once more after the window has actually
        // settled, which is what the probe's own `wait_for_layout_mode`
        // polls for.
        PanelController.shared.enterThemeEditing(beside: window)
        // Clip is an LSUIElement (agent) app - without activating it first, a
        // freshly-created window can order front without ever truly taking
        // key/main status, which is what `SettingsWindowController.show`
        // already does before its own `makeKeyAndOrderFront`. Missing this
        // left the builder's own SwiftUI subviews unable to resolve a real
        // `.window` on first open, which is what every registry-based probe
        // (`MiniPreviewTestRegistry`, `MarkdownPromptTestRegistry`) polls for.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isOpen else { return }
            PanelController.shared.enterThemeEditing(beside: self.window)
        }
    }

    /// Closes without saving (the caller decides what "without saving" means
    /// - Cancel calls `state.onCancel` itself before this; a window-manager
    /// close (the red button) is handled by `windowWillClose` below, which
    /// calls it for you).
    override func close() {
        guard isOpen else { return }
        isOpen = false
        // M19: an Inspect overlay left open over a panel the builder no
        // longer sits beside would swallow every click into a window that
        // is not even visible any more - Inspect mode belongs to an open
        // builder, full stop.
        ThemeInspectController.shared.setOn(false)
        themeManager?.endPreview()
        PanelController.shared.exitThemeEditing()
        window?.orderOut(nil)
        themeManager = nil
    }

    /// The red close button/⌘W is Cancel, not a silent discard - the draft's
    /// preview is torn down and the caller's `onCancel` runs exactly as if
    /// the footer's own Cancel button had been clicked.
    func windowWillClose(_ notification: Notification) {
        guard isOpen else { return }
        let cancel = state.onCancel
        close()
        cancel?()
    }
}
