import AppKit
import SwiftUI

/// Settings live in a real window.
///
/// The previous build presented them with `.sheet(isPresented:)` from inside the
/// panel. A sheet cannot present from a non-key popover, which is why the gear
/// button appeared to do nothing.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private var logicallyOpen = false
    private var isHeadless: Bool { QABridge.isHeadless }

    var isKeyWindow: Bool { window?.isKeyWindow ?? false }
    var isOpen: Bool { isHeadless ? logicallyOpen : (window?.isVisible ?? false) }

    /// `page`, when given, deep-links straight into that sub-page (M14) -
    /// exactly what a notice's own action, or the QA bridge's
    /// `settingsPage <tab> <page>`, needs to reach one cluster of controls
    /// directly rather than making the caller land on the hub and tap
    /// through. Passing no `page` (the default, and every pre-M14 call
    /// site) keeps the old behaviour exactly: only the tab changes, and
    /// whatever sub-page that tab's own history was already showing stays
    /// showing - reopening Settings from the menu bar mid-drill-down does
    /// not silently rewind you to the hub.
    func show(tab: SettingsTab = .themes, page: String? = nil) {
        if let page {
            SettingsRouter.shared.deepLink(to: page, in: tab)
        } else {
            SettingsRouter.shared.tab = tab
        }
        // Opening Settings puts the panel behind a window it can no longer be
        // used from, so it closes - EXCEPT while the theme builder is editing,
        // where the panel IS the live preview and closing it removes the thing
        // being worked on.
        if PanelController.shared.layoutMode != .themeEditing {
            PanelController.shared.close(restoreFocus: false)
        }
        guard !isHeadless else { logicallyOpen = true; return }

        let window = self.window ?? make()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.center()
    }

    private func make() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Clip Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: SettingsShell()
                .environmentObject(HistoryStore.shared)
                .environmentObject(ThemeManager.shared)
                .environmentObject(SettingsRouter.shared)
        )
        return window
    }

    func close() {
        logicallyOpen = false
        // The window is kept alive for reuse (see windowWillClose below), so a
        // shortcut recorder inside it never deinits and orderOut alone does not
        // resign first responder. Without this, closing Settings mid-recording
        // leaves ShortcutRecording's process-wide counter stuck above zero,
        // which makes the Carbon dispatcher (ShortcutManager) silently drop
        // every global and per-item hotkey for the rest of the session.
        // makeFirstResponder(nil) forces AppKit to send resignFirstResponder()
        // to whatever currently holds it; RecorderView's override already
        // calls stopRecording() -> ShortcutRecording.end() there, so this
        // reuses that existing safety net instead of adding a new one.
        window?.makeFirstResponder(nil)
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Nothing to tear down; keep the window for reuse so state persists.
    }
}

#if CLIP_TESTING
extension SettingsWindowController {
    /// The Settings window's real content view, for `snapshotSettings` (M8.4,
    /// 02/09) - the same "render the actual layer to a bitmap" approach
    /// `snapshotPanel` already uses for the panel window, aimed at Settings
    /// instead. `nil` under `CLIP_HEADLESS=1`, where `show()` never builds a
    /// real window at all - the caller has to treat that as "cannot render
    /// here", not as an empty picture.
    var contentViewForTesting: NSView? { window?.contentView }
    var windowAppearanceNameForTesting: String { window?.effectiveAppearance.name.rawValue ?? "" }
    var windowNumberForTesting: Int { window?.windowNumber ?? 0 }
    /// QA: a taller window so a rendered check can see a whole long page.
    func resizeForTesting(height: CGFloat) {
        guard let window else { return }
        var frame = window.frame
        frame.origin.y -= (height - frame.height)
        frame.size.height = height
        window.setFrame(frame, display: true)
    }

    /// QA-only. Mounts a real `ShortcutRecorder.RecorderView` as the content
    /// of a real `NSWindow`, recording, and hands that window to `self.window`
    /// - so the very next call to this class's own (unmodified) `close()`
    /// runs the actual regression fix for real: `window?.makeFirstResponder(
    /// nil)` resigning a *live* responder, which is what
    /// `RecorderView.resignFirstResponder()` -> `stopRecording()` ->
    /// `ShortcutRecording.end()` depends on.
    ///
    /// `show()` never builds this under `CLIP_HEADLESS=1`, so without this
    /// entry point `close()` always runs against `window == nil` in headless
    /// tests and `makeFirstResponder(nil)` is a no-op - the regression's
    /// actual fix path is never exercised, only its source text.
    ///
    /// Chosen over forcing `show()` to build the real `SettingsShell`
    /// headless: that SwiftUI view graph is constructed lazily by the render
    /// loop, and finding the recorder inside `NSHostingView`'s private NSView
    /// tree by type would be fragile and still only indirect proof. This
    /// uses the same `RecorderView` class, the same `startRecording()` a
    /// click performs, and the same `close()` production code calls - none
    /// of the teardown is faked, only the surrounding chrome (the rest of
    /// the Settings UI) is skipped because this check has no use for it.
    @discardableResult
    func beginTestRecordingInRealWindow() -> Bool {
        let recorder = ShortcutRecorder.RecorderView(
            frame: NSRect(x: 0, y: 0, width: 150, height: 26))
        let testWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        testWindow.isReleasedWhenClosed = false
        testWindow.contentView = recorder
        recorder.setRecording(true)
        window = testWindow
        logicallyOpen = true
        return ShortcutRecording.isActive && testWindow.firstResponder === recorder
    }
}
#endif

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    // `gettingStarted` first: it is the checklist that points at every other
    // tab, so it is the first thing anyone opening Settings should see.
    case gettingStarted, sync, general, shortcuts, themes, tabs, menuBar, ai, pasteActions, privacy, export, diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gettingStarted: return "Getting Started"
        case .sync:      return "Sync"
        case .themes:    return "Themes"
        case .general:   return "General"
        case .tabs:      return "Tabs"
        case .shortcuts: return "Shortcuts"
        case .ai:        return "AI Connection"
        // Named for what it produces, not for the technology behind it. "AI
        // actions" would have put the same word on two panes in one sidebar.
        case .pasteActions: return "Paste Actions"
        case .privacy:   return "Privacy"
        case .menuBar:   return "Menu Bar"
        // The pane both exports and imports - settings, themes, shortcuts and
        // the design library. "Export Data" named half of what it does.
        case .export:    return "Backup"
        // M8.8: what used to be its own window, a "Shortcut diagnostics"
        // alert, and a "Repair AI Key Access…" menu item that stayed in the
        // menu whether or not there was anything left to repair.
        case .diagnostics: return "Diagnostics"
        }
    }

    var symbol: String {
        switch self {
        case .gettingStarted: return "checklist"
        case .sync:      return "arrow.triangle.2.circlepath"
        case .themes:    return "paintpalette"
        case .general:   return "gearshape"
        case .tabs:      return "rectangle.split.3x1"
        case .shortcuts: return "keyboard"
        case .ai:        return "sparkles"
        case .pasteActions: return "text.badge.plus"
        case .privacy:   return "hand.raised"
        case .menuBar:   return "menubar.rectangle"
        case .export:    return "arrow.up.arrow.down.square"
        case .diagnostics: return "stethoscope"
        }
    }

    var group: SettingsGroup {
        switch self {
        // Getting Started sits with Sync at the top of Behaviour: it is the
        // checklist that points at every other tab, so `allCases`' own
        // declaration order (gettingStarted first) puts it first in this
        // group's own row list, right under the pinned sync card.
        case .gettingStarted:             return .behaviour
        // Sync is the pinned card at the top of the sidebar, the way an account
        // row is. Listing it again under Data made the same destination appear
        // twice on one screen, which is a "which of these is the real one"
        // question nobody should have to answer.
        case .sync:                       return .behaviour
        case .themes, .tabs, .menuBar:    return .appearance
        case .general, .shortcuts:        return .behaviour
        case .ai, .pasteActions:          return .content
        case .privacy, .export, .diagnostics: return .data
        }
    }

    /// Individual setting names, so search finds a checkbox and not just a page.
    var keywords: [String] {
        switch self {
        // M15: "getting started" and "tutorial" moved here from `.general`
        // - the same "keywords follow their setting" rule `.general`'s own
        // comment below states, now that this tab is what those words mean.
        case .gettingStarted: return ["getting started", "setup", "setup guide", "checklist",
                                      "tutorial", "walkthrough", "what's left"]
        case .sync:      return ["sync token", "token", "connect", "disconnect", "another mac",
                                 "combine", "merge", "share", "lock", "delete sync data"]
        case .themes:    return ["color", "color", "dark", "light", "theme builder", "custom theme"]
        // Keywords follow their setting to the pane that now owns it, or search
        // sends people to a pane that no longer holds what they searched for.
        case .general:   return ["launch at login", "paste automatically", "history limit",
                                 "poll", "clear history", "clear everything",
                                 "clear unpinned", "delete history", "trash",
                                 "open on", "startup", "welcome guide", "onboarding",
                                 "accessibility permission"]
        case .menuBar:   return ["menu bar icon", "icon", "dock", "copy confirmation",
                                 "footer", "keyboard hint", "copy preview",
                                 "preview", "panel position",
                                 "move panel", "drag panel", "where the panel opens"]
        case .tabs:      return ["tab order", "visible tabs", "layout", "density", "gallery", "list"]
        case .shortcuts: return ["hotkey", "keyboard", "binding", "conflict"]
        case .ai:        return ["model", "api key", "provider", "anthropic", "openai", "nvidia",
                                 "gemini", "ollama", "connection", "enable ai", "skills",
                                 "content recognition"]
        case .pasteActions:
            return ["paste action", "translate", "translation", "language", "languages",
                    "rewrite", "style", "improve prompt", "action menu", "transform",
                    "shorten", "bullets", "grammar", "custom action", "redact"]
        case .privacy:   return ["ignored apps", "concealed", "password manager", "network"]
        case .export:    return ["json", "backup", "export", "export data", "import",
                                 "design library", "restore"]
        case .diagnostics: return ["diagnostics", "shortcut report", "repair", "repair ai key access",
                                   "reset accessibility", "activity log", "health", "keychain repair"]
        }
    }
}

/// A tab's own sub-page, so the sidebar's search (M14 Y5) and the hub/
/// sub-page router can work with one small, typed shape instead of a bare
/// string everywhere. Each hub-tab pane declares its own conforming enum
/// right beside the sections it now names (`SyncPage` in
/// `SettingsSyncPane.swift`, and so on) - the same place `SyncMethod`
/// already lives, so a reader finds a tab's whole navigation surface in
/// its own file rather than in a central switch nobody remembers to update.
protocol SettingsSubpageID: RawRepresentable, CaseIterable where RawValue == String {
    var title: String { get }
    var symbol: String { get }
}

extension SettingsTab {
    /// The panes actually shown, which is not all of them.
    ///
    /// With AI turned off its pane is *absent*, not disabled. A greyed-out pane
    /// that can never be opened from here is a question the reader has to answer
    /// every time they scan the sidebar.
    static var visible: [SettingsTab] {
        // The AI pane is always present now that it holds the master switch.
        // Hiding it when AI is off would put the only way to turn AI back on
        // inside the pane that being off removes.
        allCases
    }

    /// This tab's own sub-pages, for the sidebar's search and the M14 hub/
    /// sub-page framework - `nil` for a tab that stayed single-layer
    /// (General, Shortcuts, Tabs, Menu Bar: none of them exceed roughly two
    /// screens of content or mix more than three concerns, the M14 plan's
    /// own threshold for becoming a hub).
    var subpages: [(id: String, title: String, symbol: String)]? {
        func map<P: SettingsSubpageID>(_ type: P.Type) -> [(id: String, title: String, symbol: String)] {
            P.allCases.map { ($0.rawValue, $0.title, $0.symbol) }
        }
        switch self {
        case .themes:       return map(ThemesPage.self)
        case .menuBar:      return map(MenuBarPage.self)
        case .general:      return map(GeneralPage.self)
        case .pasteActions: return map(PasteActionsPage.self)
        case .privacy:      return map(PrivacyPage.self)
        case .export:       return map(ExportPage.self)
        case .diagnostics:  return map(DiagnosticsPage.self)
        // AI (user, 03/09 evening): one page - the switch, and below it,
        // only while the switch is on, the connections and which one is used.
        // Sync and Shortcuts (user, 03/09 night): flat again - every section
        // on the main tab, so there is no sub-page to route or search to.
        case .gettingStarted, .tabs, .ai, .sync, .shortcuts: return nil
        }
    }

    /// Whether this tab is a hub (hero + grouped chevron rows to sub-pages)
    /// rather than a single flat pane.
    var isHub: Bool { subpages != nil }
}

/// Lets callers open Settings on a specific pane.
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var tab: SettingsTab = .general
    /// Setting id to flash after a search jump.
    @Published var highlight: String?
    /// Pinned to `.all` and never auto-managed by `NavigationSplitView`
    /// itself (M8 bug fix, 02/09): with no explicit binding, SwiftUI owns
    /// this state privately and can collapse the sidebar column on its own
    /// when a detail view's content asks for more width than it expects -
    /// which `DiagnosticsView`'s old `.frame(minWidth: 660, minHeight: 560)`
    /// did the moment it stopped being a standalone window's content and
    /// became one pane among many. Binding it here makes the state
    /// observable (for the probe) and keeps this app's own choice in force
    /// rather than SwiftUI's private heuristic.
    @Published var sidebarVisibility: NavigationSplitViewVisibility = .all

    // MARK: - M14: per-tab sub-page navigation

    /// Each hub tab keeps its own browser-style history: `nil` means the hub
    /// itself, a non-nil string is a `SettingsSubpageID.rawValue`. Kept per
    /// tab (not one shared stack) so leaving Sync mid-drill-down to check
    /// something in AI and coming back to Sync leaves it exactly where it
    /// was - the same reason a browser's own tabs each keep their own
    /// history rather than sharing one.
    @Published private var pageHistory: [SettingsTab: [String?]] = [:]
    @Published private var pageIndex: [SettingsTab: Int] = [:]

    /// The sub-page currently shown for `tab` (the router's own `tab` by
    /// default), or `nil` for the hub itself.
    func page(for tab: SettingsTab? = nil) -> String? {
        let t = tab ?? self.tab
        let history = pageHistory[t] ?? [nil]
        let index = min(max(pageIndex[t, default: 0], 0), history.count - 1)
        return history[index]
    }

    /// Pushes `id` onto `tab`'s own history - exactly what tapping a hub
    /// row does. Drops any forward history past the current point first,
    /// the same rule a browser's back/forward stack follows: visiting
    /// somewhere new from the middle of your history discards what was
    /// ahead of you.
    func openSubpage(_ id: String, in tab: SettingsTab? = nil) {
        let t = tab ?? self.tab
        var history = pageHistory[t] ?? [nil]
        let index = min(max(pageIndex[t, default: 0], 0), history.count - 1)
        if index < history.count - 1 {
            history.removeLast(history.count - 1 - index)
        }
        history.append(id)
        pageHistory[t] = history
        pageIndex[t] = history.count - 1
    }

    func goBack(in tab: SettingsTab? = nil) {
        let t = tab ?? self.tab
        let index = pageIndex[t, default: 0]
        guard index > 0 else { return }
        pageIndex[t] = index - 1
    }

    func goForward(in tab: SettingsTab? = nil) {
        let t = tab ?? self.tab
        let history = pageHistory[t] ?? [nil]
        let index = pageIndex[t, default: 0]
        guard index < history.count - 1 else { return }
        pageIndex[t] = index + 1
    }

    func canGoBack(in tab: SettingsTab? = nil) -> Bool {
        pageIndex[tab ?? self.tab, default: 0] > 0
    }

    func canGoForward(in tab: SettingsTab? = nil) -> Bool {
        let t = tab ?? self.tab
        let history = pageHistory[t] ?? [nil]
        return pageIndex[t, default: 0] < history.count - 1
    }

    /// A fresh navigation from OUTSIDE the tab's own history - a notice's
    /// action, `SettingsWindowController.show(tab:page:)`, or the sidebar's
    /// own search jumping to a sub-page row. Unlike `openSubpage`, this
    /// discards whatever history the tab already had: it is not "go one
    /// step further from here", it is "start over, right there."
    func deepLink(to page: String?, in tab: SettingsTab) {
        self.tab = tab
        self.highlight = nil
        pageHistory[tab] = page.map { [nil, $0] } ?? [nil]
        pageIndex[tab] = pageHistory[tab]!.count - 1
    }

    private init() {}
}
