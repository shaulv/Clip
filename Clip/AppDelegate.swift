import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

/// Menu-bar item, global hotkeys, and the paste pipeline.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The live instance.
    ///
    /// `NSApp.delegate` is *not* this object: `@NSApplicationDelegateAdaptor`
    /// installs a `SwiftUI.AppDelegate` that forwards to it, so every
    /// `NSApp.delegate as? AppDelegate` is nil and whatever it called was
    /// silently skipped. Anything outside this class reaches it through here.
    private(set) static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem?
    /// For the probe: whether a menu-bar item was created at all.
    var hasStatusItem: Bool { statusItem != nil }
    private var cancellables = Set<AnyCancellable>()
    /// The pulse count already drawn, so a redraw for some other reason does
    /// not replay the animation.
    private var lastPulseDrawn = 0


    /// The menu-bar image for a stored preference value.
    ///
    /// `statusIcon` holds an SF Symbol name for every choice but one: the app's
    /// own mark, which is vector art in the asset catalogue rather than a
    /// system symbol, and is stored under a sentinel that cannot collide with a
    /// symbol name. Template rendering either way, so the bar tints it to match
    /// the menu bar rather than painting it brand blue against a white bar.
    static func statusImage(for name: String) -> NSImage? {
        let image: NSImage?
        if name == Self.markIconName {
            image = NSImage(named: "MenuBarIcon")
        } else {
            image = NSImage(systemSymbolName: name, accessibilityDescription: "Clip")
                ?? NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "Clip")
        }
        image?.isTemplate = true
        return image
    }

    /// Not a symbol name, so it can never be mistaken for one.
    static let markIconName = "clip.mark"

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        // Before anything opens a file. Repairs the permissions of an existing
        // install as well as setting them on a new one: the database used to be
        // created world-readable, and it holds every password the user has ever
        // copied.
        AppPaths.secureStorage()
        // Version stamp, pre-upgrade backup, schema migrations, integrity,
        // and the data-directory audit - before anything else opens a file
        // that assumes today's schema and an intact database (M3.1).
        StartupHealth.run()
        // Must run before HistoryStore or PreferencesModel touch disk.
        Migration.runIfNeeded()
        // Every secret into the one Keychain item, before anything reads a key
        // (user, 03/09 night: one item, one authorisation, credentials once).
        KeychainStore.migrateLegacyItemsIfNeeded()

        let store = HistoryStore.shared

        // The AI key and the sync token repair themselves before anyone
        // notices, or say plainly why they could not - never wait for a
        // person to find the right-click menu. Only when something is
        // actually configured: an app nobody has connected anything to has
        // nothing to repair, and nothing to stay quiet about either.
        if !AIService.shared.providers.isEmpty || SyncManager.shared.space != nil {
            Task { await KeychainStore.selfRepair(reason: "launch") }
        }
        Task { await SyncManager.shared.checkTokenContinuityAtLaunch() }

        ClipboardMonitor.shared.start()
        setupStatusItem()

        // Sparkle: starts the updater (the automatic-check timer, not a
        // check itself) so both the background check and a user-initiated
        // "Check for Updates…" (status menu, Settings > General > Updates)
        // become possible. See Core/Updates/UpdateController.swift for why
        // this is a separate `start()` rather than happening at init.
        UpdateController.shared.start()
        UpdateController.shared.automaticallyChecksForUpdates = PreferencesModel.shared.checkForUpdatesAutomatically

        // Sync runs on its own from here: on a change, on a timer, and whenever
        // Clip becomes the active app. Before this the only thing that synced
        // was the Sync Now button.
        SyncManager.shared.startAutomaticSync()
        SettingsSync.shared.start()

        // After the store has loaded (so "empty" means something) and before
        // the ordinary automatic sync has had a chance to run - an empty
        // library that quietly filled itself back in a few seconds later
        // would look like nothing had ever been missing, when what actually
        // happened is exactly what M5 exists to make loud: an install this
        // Keychain remembers, offering to bring it back rather than assuming
        // that is what the user wanted.
        SyncManager.shared.offerRestoreIfNeeded()

        CopyConfirmation.shared.onChange = { [weak self] in self?.renderConfirmation() }

        PanelController.shared.anchorButton = { [weak self] in self?.statusItem?.button }

        // Global bindings come from the registry, so they stay user-editable.
        ShortcutManager.shared.onHotkey = { MainActor.assumeIsolated { PanelController.shared.toggle(from: .hotkey) } }
        ShortcutManager.shared.onSecondaryHotkey = {
            ClipboardMonitor.shared.isPaused.toggle()
        }

        // The paste actions, from any app, with no panel involved. This is the
        // path the whole feature exists for: the user is in their editor, and
        // what comes back lands there.
        ShortcutManager.shared.onNamedHotkey = { name in
            MainActor.assumeIsolated {
                guard let action = ShortcutAction(rawValue: name) else { return }
                switch action {
                case .pasteTranslated: PasteActionRunner.translateAndPaste(from: .clipboard)
                case .pasteWithActions: ActionPanelController.shared.toggle()
                default: break
                }
            }
        }

        ShortcutRegistry.shared.applyGlobals()

        // Every AI-dependent surface in one registry, so a probe can prove
        // none of them was missed rather than trusting a grep. Registered
        // once, here, rather than from each view's own body - a tab or sheet
        // that is not on screen never runs its body, and this has to know
        // about a surface whether or not it happens to be visible right now.
        AIGate.registerSurfaces()

        // Per-item hotkeys paste straight from anywhere, without opening the panel.
        ShortcutManager.shared.onItemHotkey = { id in
            MainActor.assumeIsolated {
                guard let item = HistoryStore.shared.items.first(where: { $0.id == id }) else {
                    PasteTrace.note("no-item:\(id.uuidString)")
                    ShortcutManager.shared.noteItemOutcome(id, "no item with that id")
                    return
                }
                PasteTrace.note("requesting")
                PanelController.shared.previousApp = NSWorkspace.shared.frontmostApplication

                // A prompt with `{{placeholders}}` cannot paste until they are
                // filled in, and the form that fills them in lives INSIDE the
                // panel. From a global hotkey the panel is shut, so
                // `requestPaste` set `fillingVariablesFor` on a view nobody
                // could see and returned: the key did nothing, every time,
                // for ever. This is the silent death that survived three
                // rounds of fixes, because the shortcut, the registration and
                // the permission were all correct.
                //
                // Opening the panel first gives the form somewhere to appear.
                // `previousApp` is captured above and deliberately re-applied
                // after, because `open` records the frontmost app itself and
                // by then the frontmost app is Clip.
                if PromptVariables.hasVariables(item.fullText),
                   HistoryStore.shared.fillingVariablesFor == nil {
                    let target = PanelController.shared.previousApp
                    if !PanelController.shared.isOpen {
                        PanelController.shared.open(from: .hotkey)
                    }
                    PanelController.shared.previousApp = target
                    // Measured 02/09: the form opened and the OTHER app stayed
                    // frontmost, so the user saw nothing change. Bring the
                    // panel forward explicitly, once the open has settled.
                    PanelController.shared.bringToFront()
                    ShortcutManager.shared.noteItemOutcome(id, "asking for the prompt's variables")
                }

                HistoryStore.shared.requestPaste(item)
                ShortcutManager.shared.noteItemOutcome(id, "paste requested: \(PasteTrace.lastStage)")
            }
        }
        ShortcutManager.shared.registerAllItems(from: store.items)

        // "Always check when we open the app that we have permissions, only if
        // we don't have then show the permissions popup." Checked once, here,
        // whether or not anything is bound - and silent when the grant is
        // already there, so a user who has granted it is never asked again.
        // `checkAtLaunch` returns immediately when trusted, and its alert is
        // already suppressed under test by `TestIsolation.sendsRealKeystrokes`.
        AccessibilityGate.checkAtLaunch(boundItems: 0)

        KeyRouter.install()
        observePasteRequests()
        QABridge.startIfEnabled()

        if QABridge.isEnabled {
            // `writeStateFromAmbientChange`, not `writeState` directly: a QA
            // command already schedules its own acknowledgement write, and
            // this debounce (60ms) fires before that one (120ms) - reading
            // `visibleItems` here too just pollutes the counters that write
            // is about to report. See its doc comment in QABridge.swift.
            store.objectWillChange
                .debounce(for: .milliseconds(60), scheduler: RunLoop.main)
                .sink { _ in QABridge.writeStateFromAmbientChange() }
                .store(in: &cancellables)
        }

        // Dock visibility is a preference, applied at launch and on change.
        applyDockVisibility()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyDockVisibility()
                self?.refreshStatusIcon()
            }
            .store(in: &cancellables)

        // NoticeCenter.badgeVisible/badgeMessage still track "is there
        // something to look at" - Diagnostics and the status menu's own
        // condition line read them - but nothing draws a red dot on the menu
        // bar icon for it any more (M8.1). A dot that lit for a database
        // that could not open and stayed lit, unexplained, for a stale
        // Google token told a person "something", never what, and the first
        // panel open now says the whole list at once instead (see
        // `SetupOverviewCoordinator`).

        // Data at risk, with no panel open to say so: the one alert an agent
        // app has. Once per launch; the badge and Diagnostics carry the rest.
        NoticeCenter.shared.onIntegrityWithoutPanel = { [weak self] notice in
            self?.presentIntegrityAlert(notice)
        }

        // A previous quit could not finish saving - see `applicationWillTerminate`
        // below. Surfaced once, here, rather than every launch until someone
        // acts on it.
        Self.checkForUnsavedSnapshot()

        // The first-run welcome: the shortcut, arrow-key navigation, and the
        // Accessibility permission explained before macOS's own prompt does.
        // Shown once, never blocking - see `OnboardingWindowController`.
        OnboardingWindowController.shared.presentIfFirstRun()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardMonitor.shared.stop()
        // A delete still inside its undo window has left the list but touched
        // nothing on disk. Quitting is not undoing, so it is finished here: the
        // alternative is a row that comes back on the next launch because the
        // window happened to be open when the app went away.
        HistoryStore.shared.commitPendingDelete()
        if PreferencesModel.shared.clearOnQuit {
            HistoryStore.shared.clearAll()
        } else {
            // A debounced save would be lost on quit. `saveNow` used to be
            // called and ignored: whatever the disk did with it, the app
            // quit regardless. If it failed here - the one moment there is
            // no next tick to retry on - the tail of the library that never
            // reached the database was simply gone, with nothing recorded
            // anywhere that it had happened.
            let ok = HistoryStore.shared.saveNow()
            if !ok {
                Self.writeEmergencySnapshot(HistoryStore.shared.items)
            }
        }
    }

    /// Writes everything currently in memory to a plain JSON file next to the
    /// database, and remembers that it did so, because `saveNow()` reported
    /// that the database write itself did not go through. Best-effort: quit
    /// is already underway and there is nowhere left to recover to but disk.
    static func writeEmergencySnapshot(_ items: [ClipboardItem]) {
        guard !items.isEmpty else { return }
        // The same shape `ExportPane` reads back on import, so the notice
        // this produces on the NEXT launch can hand the file straight to
        // that exact path rather than inventing a second one.
        let dicts = items.map(ExportPane.dictionary)
        let root: [String: Any] = [
            "application": "Clip",
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "clips": dicts
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        else { return }
        let ts = Int(Date().timeIntervalSince1970)
        let url = AppPaths.support.appendingPathComponent("unsaved-\(ts).json")
        do {
            try data.write(to: url)
            AppPaths.restrict(url, to: 0o600)
            Database.shared.setPreference("unsavedSnapshotPath", url.path)
        } catch {
            // Nothing more can be done at quit time; the items are still in
            // the in-memory list that is about to vanish, but there is no
            // second write attempt to make.
        }
    }

    /// Runs at launch. If the last quit left an emergency snapshot behind,
    /// says so once, with an action that puts the clips straight back rather
    /// than only pointing at the file.
    static func checkForUnsavedSnapshot() {
        guard let path = Database.shared.preference("unsavedSnapshotPath"), !path.isEmpty else { return }
        // Cleared immediately: this is a one-time surfacing, not a condition
        // that re-announces itself on every future launch once the person
        // has already seen it and been offered the recovery action.
        Database.shared.setPreference("unsavedSnapshotPath", "")
        NoticeCenter.shared.report(.unsavedAtQuit(path: path), action: NoticeCenter.Action(
            title: "Restore unsaved clips") {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    SettingsWindowController.shared.show(tab: .export)
                    return
                }
                let outcome = ExportPane.apply(root, into: HistoryStore.shared, importSettings: false)
                let recovered = outcome.added + outcome.updated
                NoticeCenter.shared.report(
                    "Recovered \(recovered) clip\(recovered == 1 ? "" : "s") from the last quit.",
                    kind: .transient)
            })
    }

    /// Shows or hides the Dock icon. `.accessory` is the agent-app default;
    /// `.regular` puts Clip in the Dock for people whose menu bar is crowded.
    private func applyDockVisibility() {
        let wanted: NSApplication.ActivationPolicy =
            PreferencesModel.shared.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != wanted {
            NSApp.setActivationPolicy(wanted)
        }
    }

    /// Briefly shows what was just copied beside the menu-bar icon.
    ///
    /// The confirmation people actually want is "did that copy land?", and the
    /// menu bar is where their eye already goes. It reverts on its own; a stuck
    /// title would eat the menu bar.

    /// Shows what was just copied, beside the menu bar icon.
    ///
    /// The decisions live in `CopyConfirmation`; this only draws them. The text
    /// sits on the **left** of the icon, which is what `imageTrailing` means
    /// here: title first, image after it.
    func showCopyConfirmation(_ text: String) {
        CopyConfirmation.shared.show(text)
    }

    /// Draws the current confirmation onto the status item.
    private func renderConfirmation() {
        guard let button = statusItem?.button else { return }
        let state = CopyConfirmation.shared
        button.title = state.title.isEmpty ? "" : state.title + " "
        button.font = .systemFont(ofSize: 11)
        // Both move together. Changing one without the other is how the icon ends
        // up parked on the wrong side for the rest of the session.
        button.imagePosition = state.iconTrailing ? .imageTrailing : .imageLeading

        if state.pulse != lastPulseDrawn {
            lastPulseDrawn = state.pulse
            pulseStatusIcon(button)
        }
    }

    /// A short bounce on the glyph when a copy lands.
    ///
    /// This is the whole message when there is no room for the preview text, so
    /// it has to be visible at a glance and over in well under a second - a
    /// menu-bar icon that keeps moving is an irritation, not a confirmation.
    ///
    /// Layer-based rather than a title change: it costs nothing, it cannot
    /// widen the item, and widening the item is precisely the problem the
    /// pulse exists to work around.
    private func pulseStatusIcon(_ button: NSStatusBarButton) {
        guard let layer = button.layer ?? {
            button.wantsLayer = true
            return button.layer
        }() else { return }

        layer.removeAnimation(forKey: "clip.pulse")
        // Anchored at the centre, or the scale drags the glyph towards the
        // bottom-left corner instead of growing in place.
        let bounds = layer.bounds
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: bounds.midX, y: bounds.midY)

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1.0, 1.28, 0.94, 1.0]
        scale.keyTimes = [0, 0.35, 0.7, 1]
        scale.duration = 0.34
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1.0, 0.45, 1.0]
        fade.keyTimes = [0, 0.35, 1]
        fade.duration = 0.34

        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.34
        layer.add(group, forKey: "clip.pulse")
    }

    /// Applies the user's chosen menu-bar glyph.
    func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        button.image = Self.statusImage(for: PreferencesModel.shared.statusIcon)
    }

    // MARK: - Menu-bar tooltip

    /// The one thing this menu-bar item's tooltip ever says now (M8.1).
    ///
    /// It used to embed whatever `NoticeCenter`'s badge was showing - a
    /// stale "sync connection was rejected" sentence sat here until the next
    /// failure overwrote it, and there was no way to tell from the tooltip
    /// alone whether it was still true. The first panel open after launch
    /// now says the whole list of open conditions at once (see
    /// `SetupOverviewCoordinator`), and Diagnostics has the rest; the
    /// tooltip just names the app.
    static let tooltipText = "Clip: clipboard manager"

    #if CLIP_TESTING
    /// What the menu-bar tooltip would say right now. The probe runs with
    /// `CLIP_HEADLESS=1`, where `setupStatusItem` never runs (see its guard
    /// above) and there is no real `NSStatusItem` whose `toolTip` could be
    /// read - so this is the same constant `setupStatusItem` assigns, kept
    /// under one name so a rename can never make the two disagree.
    static var currentSyncTooltipForTesting: String { tooltipText }
    /// How many integrity alerts would have been shown this launch.
    private(set) static var integrityAlertsForTesting = 0
    #endif

    /// The modal for an `.integrity` notice raised while the panel is shut.
    /// Suppressed under test and when headless (there is no screen to hold
    /// it), counted instead so a probe can assert it would have appeared.
    private func presentIntegrityAlert(_ notice: NoticeCenter.Notice) {
        #if CLIP_TESTING
        Self.integrityAlertsForTesting += 1
        #endif
        guard !TestIsolation.isActive, !QABridge.isHeadless else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = notice.message
        alert.informativeText = (notice.remedy ?? "") + "\n\nDetails are in Diagnostics, from Clip's menu-bar icon."
        alert.addButton(withTitle: "Open Diagnostics")
        if let action = notice.action { alert.addButton(withTitle: action.title) }
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: showDiagnostics()
        case .alertSecondButtonReturn: notice.action?.run()
        default: break
        }
    }

    /// Everything the app knows about its own health: storage, Keychain,
    /// sync, AI, the shortcut report, and the last 200 rows of the activity
    /// log - see `DiagnosticsView`, hosted inside Settings > Diagnostics
    /// since M8.8 rather than its own separate window. A person who has just
    /// been told three times that something is fixed needs one destination
    /// to check it from, not a window, an alert and a menu item that each
    /// showed a different slice of the same facts.
    @objc func showDiagnostics() {
        SettingsWindowController.shared.show(tab: .diagnostics)
    }

    #if CLIP_TESTING
    private static func _keepEndif() {}
    #endif

    // MARK: - Status item

    private func setupStatusItem() {
        // A test run should leave no trace on the menu bar of whoever is using
        // the machine.
        guard !QABridge.isHeadless else { return }
        // Variable, not square: a square item never widens for a title, so the
        // copy confirmation would be set and then have nowhere to render.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Named, because the preferred position the system remembers is keyed
        // on this. Without a name there is nothing to write a position against
        // and no way to ask for a different spot.
        item.autosaveName = StatusItemVisibility.autosaveName
        if let button = item.button {
            button.image = Self.statusImage(for: PreferencesModel.shared.statusIcon)
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = Self.tooltipText
        }
        statusItem = item
        watchForCrowding()
        // RT-1: a process launched directly (not via a Dock/Finder relaunch)
        // never receives `didActivateApplicationNotification` for itself, so
        // without this the flag sits at its Swift default (`false`, meaning
        // "not crowded") even when the bar genuinely is crowded at launch.
        // The confirmation then tries to render a preview with nowhere to
        // put it and the feature goes dark on the very first copy. Evaluate
        // the real layout now, before anything can ask `isCrowded` a
        // question.
        checkCrowding()
    }

    // MARK: - Staying visible

    /// Watches for the icon disappearing under another app's menus.
    ///
    /// Checked when the frontmost app changes, which is when the menu bar's
    /// contents actually change, and again briefly after - a newly activated
    /// app has not laid its menus out yet at the moment the notification
    /// arrives. No timer, no polling: an app that watches the menu bar
    /// continuously to keep one icon visible has its priorities wrong.
    private func watchForCrowding() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkCrowding()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    MainActor.assumeIsolated { self?.checkCrowding() }
                }
            }
        }
    }

    /// What the last crowding check saw, for diagnosis.
    static var lastCrowdingReport = "never checked"

    private func checkCrowding() {
        guard PreferencesModel.shared.keepStatusItemVisible else {
            CopyConfirmation.shared.isCrowded = false
            return
        }
        let hidden = StatusItemVisibility.isHidden(statusItem?.button)
        CopyConfirmation.shared.isCrowded = hidden
        let box = statusItem?.button?.window?.frame
        let where_ = box.map { "x=\(Int($0.minX)) w=\(Int($0.width))" } ?? "no window"
        Self.lastCrowdingReport = "\(where_) hidden=\(hidden)"

        guard hidden else {
            StatusItemVisibility.noteVisible()
            return
        }
        // Setting `isCrowded` above has already done the one thing that helps:
        // the preview is dropped, so the item is as narrow as it can be and the
        // pulse carries the confirmation instead.
        //
        // There is deliberately nothing else here. An earlier version wrote a
        // preferred position and rebuilt the item; that was measured to be
        // inert, because removing a status item makes the system write the real
        // position back over the request. Moving the icon is the user's to do,
        // with a Command-drag, and Settings says so.
        StatusItemVisibility.noteCrowded()
    }

    @objc private func statusItemClicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showStatusMenu()
        } else {
            // RT-1: re-evaluate on panel open too, not only on app-activation.
            // The bar's contents can change without any app activating at
            // all - another app's own icon appearing or leaving - so the
            // flag this click is about to rely on (via the next copy) must
            // never be older than the click itself.
            checkCrowding()
            PanelController.shared.toggle(from: .statusItem)
        }
    }

    /// The status menu's rows, in order, with `nil` marking a separator -
    /// built here, once, so `showStatusMenu()` and the QA bridge (which
    /// cannot right-click a real `NSStatusItem` under `CLIP_HEADLESS=1`,
    /// because `setupStatusItem` never creates one there) read the exact
    /// same list and can never disagree about what it says.
    ///
    /// M8.8: "make sure that anything that is not relevant for the user
    /// remove, example: we finished repair and I still see repair in the
    /// menu". Diagnostics, Shortcut Diagnostics and Repair AI Key Access
    /// used to sit here permanently, whether or not there was anything to
    /// diagnose or repair; they now live in Settings > Diagnostics, one
    /// destination instead of three, reachable through the Settings item
    /// already on this menu.
    private static func statusMenuRows() -> [String?] {
        var rows: [String?] = [
            "Open Clip", nil,
            ClipboardMonitor.shared.isPaused ? "Resume Capture" : "Pause Capture",
            // M15: above Settings…, the same "promote it" the user asked
            // for in onboarding and the panel's own setup overview.
            "Getting Started…",
            "Settings…"
        ]
        // An open condition is the first thing after that, in its own words,
        // with its action beside it - present only while one is pending, so
        // a resolved condition removes its line rather than leaving a menu
        // item that used to matter and no longer does.
        if let notice = NoticeCenter.shared.pending.first(where: { $0.kind.isCondition }) {
            rows.append(nil)
            rows.append(notice.message)
            if let action = notice.action { rows.append(action.title) }
        }
        rows.append(nil)
        rows.append("Quit Clip")
        return rows
    }

    #if CLIP_TESTING
    /// The menu's item titles only (no separators), for a probe to compare
    /// against the exact allowed set (section 137, V10).
    static func statusMenuTitlesForTesting() -> [String] {
        statusMenuRows().compactMap { $0 }
    }

    /// One dictionary per real row `buildStatusMenu()` would produce (the
    /// same construction `showStatusMenu()` uses, not a lookalike), so a
    /// probe can prove a row is genuinely clickable rather than merely
    /// present (section 137, M27).
    ///
    /// `menu.update()` runs the exact validation `autoenablesItems` runs
    /// right before a real click would show the menu - it forces
    /// `isEnabled` to reflect whether the item's target actually responds
    /// to its action, without ever presenting anything on screen.
    static func statusMenuDiagnosticsForTesting() -> [[String: Any]] {
        guard let delegate = shared else { return [] }
        let menu = delegate.buildStatusMenu()
        menu.update()
        return menu.items.map { item in
            let target = item.target as? NSObject
            let action = item.action
            let responds: Bool
            if let target, let action {
                responds = target.responds(to: action)
            } else if target == nil, let action {
                // Nil target: AppKit walks the responder chain, which always
                // ends at NSApp itself - this is the "leave it unset" form
                // of the fix, checked the same way autoenablesItems checks it.
                responds = NSApp.responds(to: action)
            } else {
                responds = false
            }
            return [
                "title": item.title,
                "isEnabled": item.isEnabled,
                "hasAction": action != nil,
                "targetIsNSApp": target === NSApp,
                "targetIsAppDelegate": target === delegate,
                "targetResponds": responds,
            ]
        }
    }

    /// Simulates an actual click on the named status-menu row through
    /// `NSApp.sendAction(_:to:from:)` - the same dispatch AppKit itself
    /// performs when a menu item is clicked, not a synthetic keystroke - so
    /// a one-off manual check can prove the row's action really fires
    /// rather than merely that `isEnabled` says it should. Used to verify
    /// the M27 Quit fix terminates the app for real; deliberately not
    /// wired into any full-suite section, because a row whose action is
    /// `terminate(_:)` ends the process this probe is driving.
    @discardableResult
    static func clickStatusMenuItemForTesting(title: String) -> Bool {
        guard let delegate = shared else { return false }
        let menu = delegate.buildStatusMenu()
        guard let item = menu.items.first(where: { $0.title == title }),
              let action = item.action else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
    }
    #endif

    /// Builds the real `NSMenu` `showStatusMenu()` presents - split out so a
    /// probe can validate it (via `menu.update()`) without ever calling
    /// `performClick`, which would actually pop the menu on screen.
    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        // Read once: `statusMenuRows()` already found this same notice, and
        // re-deriving it per row risked disagreeing with itself if the
        // pending list changed between two calls.
        let condition = NoticeCenter.shared.pending.first(where: { $0.kind.isCondition })

        for row in Self.statusMenuRows() {
            guard let title = row else { menu.addItem(.separator()); continue }
            let item: NSMenuItem
            if title == "Open Clip" {
                item = NSMenuItem(title: title, action: #selector(openPanel), keyEquivalent: "")
            } else if title == "Resume Capture" || title == "Pause Capture" {
                item = NSMenuItem(title: title, action: #selector(togglePause), keyEquivalent: "")
            } else if title == "Getting Started…" {
                item = NSMenuItem(title: title, action: #selector(openGettingStarted), keyEquivalent: "")
            } else if title == "Settings…" {
                item = NSMenuItem(title: title, action: #selector(openSettings), keyEquivalent: ",")
            } else if title == "Quit Clip" {
                item = NSMenuItem(title: title, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            } else if let condition, title == condition.action?.title {
                item = NSMenuItem(title: title, action: #selector(runCurrentNoticeAction), keyEquivalent: "")
            } else if let condition, title == condition.message {
                // The condition line itself: read-only, its action is the
                // row right after it.
                item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
            } else {
                item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            }
            // `terminate(_:)` lives on `NSApplication`, not on `AppDelegate` -
            // pointing it at `self` like every other row left it with a
            // target that never responds to its own action, and
            // `autoenablesItems` (on by default, and deliberately left on:
            // the condition row above depends on it not blanket-enabling
            // everything) then disables it. Target it at the live `NSApp`
            // explicitly instead of leaving it nil, because this is an
            // `LSUIElement` app that often has no key window when the
            // status item is right-clicked, and an explicit target says
            // outright which object is expected to handle it rather than
            // relying on responder-chain resolution to find its own way
            // there.
            item.target = (item.action == #selector(NSApplication.terminate(_:))) ? NSApp : self
            menu.addItem(item)
        }
        return menu
    }

    private func showStatusMenu() {
        let menu = buildStatusMenu()
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil      // restore click-to-toggle for the next left click
    }

    /// Runs the action beside the one open condition the menu names.
    @objc private func runCurrentNoticeAction() {
        NoticeCenter.shared.pending.first(where: { $0.kind.isCondition })?.action?.run()
    }

    /// Opens Settings on the Diagnostics tab - the same destination every
    /// notice action, alert button and menu item that used to open a
    /// separate Diagnostics window or a "Shortcut diagnostics" alert now
    /// reaches (M8.8). The `@objc` methods and their names stay, because
    /// they are still what a notice action's closure and `SettingsShortcutsPane`'s
    /// button call.
    @objc func showShortcutDiagnostics() {
        SettingsWindowController.shared.show(tab: .diagnostics)
    }

    /// Re-writes the stored AI keys under this build's signature.
    ///
    /// See `KeychainStore.repairAccess`. Driven from here because this is a
    /// real window with a real event loop: it is the one moment the Keychain
    /// is allowed to put a dialog on screen, because someone just asked for
    /// it and is looking at the screen when it appears - and because it is
    /// the one funnel every entry point (the notice action `repairAction()`
    /// runs, the button in `SettingsSyncPane`, and the one in Settings >
    /// Diagnostics) already goes through, gating all three at once behind
    /// `CredentialExplainer` (M8.7) rather than gating each call site
    /// separately.
    ///
    /// Not private: it is also the closure a "Repair now" notice action runs
    /// (`KeychainStore`'s `repairAction()`), and the button in Settings.
    @objc func repairKeychainAccess() {
        Task { @MainActor in await repairKeychainAccessAsync() }
    }

    /// The body of `repairKeychainAccess()`, as `async` so the QA bridge can
    /// `await` it directly instead of racing a fire-and-forget `Task` - the
    /// bridge's ack (and the state snapshot a probe reads right after)
    /// would otherwise be written before `CredentialExplainer.confirm` and
    /// `KeychainStore.repairAccess()` had actually run.
    @discardableResult
    @MainActor
    func repairKeychainAccessAsync() async -> Bool {
        guard await CredentialExplainer.confirm(reason: .keychainRepair) else { return false }
        let outcome = KeychainStore.repairAccess()
        #if CLIP_TESTING
        Self.lastRepairOutcomeForTesting = outcome
        #endif
        // A probe can now reach this real method (unlike before M8.7, when
        // only `directRepairAccess` called `KeychainStore.repairAccess()`
        // directly, specifically to avoid this alert) because
        // `CredentialExplainer.confirm` above already answers itself under
        // test. The outcome alert below still cannot: an un-suppressed
        // `runModal()` here would hang the harness with nobody to click it,
        // same as `presentIntegrityAlert`.
        guard TestIsolation.sendsRealKeystrokes, !QABridge.isHeadless else { return true }
        let alert = NSAlert()
        alert.messageText = outcome.repaired > 0 ? "AI key access repaired" : "Nothing to repair"
        alert.informativeText = outcome.message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        return true
    }

    #if CLIP_TESTING
    /// What the last `repairKeychainAccess()` call actually did, since its
    /// own outcome alert is suppressed under test (see above).
    private(set) static var lastRepairOutcomeForTesting: (repaired: Int, message: String)?

    static func resetRepairOutcomeForTesting() {
        lastRepairOutcomeForTesting = nil
    }
    #endif

    @objc private func openPanel() { PanelController.shared.open() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }

    @objc private func openGettingStarted() {
        SettingsWindowController.shared.show(tab: .gettingStarted)
    }
    @objc private func togglePause() { ClipboardMonitor.shared.isPaused.toggle() }

    // MARK: - Paste pipeline

    private func observePasteRequests() {
        HistoryStore.shared.$pasteTicket
            .compactMap { $0 }
            .sink { [weak self] _ in self?.performPaste() }
            .store(in: &cancellables)
    }

    /// Close the panel, give focus back to the app the user was in, then send ⌘V.
    ///
    /// Order matters: Clip is the active app while the panel is open, so
    /// synthesising ⌘V without re-activating the target would paste into Clip.
    private func performPaste() {
        PasteTrace.note("perform-enter")
        guard PreferencesModel.shared.pasteAutomatically else {
            PasteTrace.note("not-automatic")
            PanelController.shared.close()
            return
        }

        let target = PanelController.shared.previousApp
        PanelController.shared.close(restoreFocus: false)
        target?.activate()
        ClipboardMonitor.shared.suppressNextCapture()

        // Let the activation land before the keystroke, or the target app will
        // not yet be first responder and the paste is dropped.
        PasteTrace.note("perform-scheduled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            PasteTrace.note("perform-fired")
            PasteKeystroke.send()
        }
    }

}

extension Notification.Name {
    static let clipFocusSearch = Notification.Name("clip.focus.search")
}
