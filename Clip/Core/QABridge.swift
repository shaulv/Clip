import AppKit
import SwiftUI
import CoreGraphics
import ApplicationServices
import Carbon.HIToolbox

#if CLIP_TESTING

/// A file-driven test harness, active only when `CLIP_QA=1` is in the
/// environment. It exists so behaviour can be *proved* rather than eyeballed:
/// a probe writes a command, the app performs it on the main thread exactly as
/// a real event would, then the app writes its observable state back out.
///
/// It is inert in a normal launch — no timer, no files, no cost.
///
/// # TWO INPUT PATHS. KNOW WHICH ONE A COMMAND USES.
///
/// Almost every command here drives the app **in process**: it calls the same
/// handler a real event would eventually reach, directly. `key` is the clearest
/// example - it builds an `NSEvent` and hands it straight to
/// `KeyRouter.handleForTesting`. That proves the *decision logic* is right. It
/// cannot prove the keystroke ever ARRIVES at that logic, because it skips
/// every stage in front of it: the window server, `NSApplication.sendEvent`,
/// the local event monitor `KeyRouter.install()` actually registers, the key
/// window, the first responder and SwiftUI's `@FocusState`.
///
/// That gap has cost real time. An audit reported the arrows, Option+arrow and
/// Tab as dead while the suite passed every one of those sections, because the
/// suite was testing the handler and the audit was pressing a key. Neither was
/// lying; they were measuring different things.
///
/// So there is a second family, every command prefixed **`real_`**, that
/// delivers input the way the system does and does not touch a handler at all:
///
/// | prefix   | route                                   | proves                                    |
/// |----------|-----------------------------------------|-------------------------------------------|
/// | `key`    | `KeyRouter.handleForTesting(event)`     | the routing DECISION for that key          |
/// | `real_*` | window server / `NSApp` event queue     | the key or click REACHES that decision     |
///
/// A `real_` command therefore fails for reasons an in-process command cannot:
/// the app is not active, the panel is not key, focus is somewhere else, the
/// element is not where its layout says, the process lacks Accessibility. Each
/// records *which* of those happened in the `realInput` state dictionary
/// (`lastDelivery`, `lastDetail`), so "the app never got the event" is never
/// confused with "the app got it and did nothing" - the two failures that look
/// identical from the outside and mean opposite things.
///
/// What `real_` still cannot prove: anything about a *physical* device. These
/// are synthesized events, indistinguishable from a real one once they are past
/// the tap they are posted to, but nothing here exercises the keyboard driver,
/// key-repeat timing, or an input method. See `real_keyHID` for the one
/// precondition that is not in this process's control (Accessibility).
@MainActor
enum QABridge {

    /// The command/state bridge is available.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["CLIP_QA"] == "1"
    }

    /// No window, no menu-bar icon, no focus stealing.
    ///
    /// Separate from `isEnabled` on purpose: a scripted run that the user is
    /// watching wants the real UI, while an unattended run must not touch their
    /// screen. Conflating the two forced a choice between the two.
    /// What the pasteboard held before `systemCopy` overwrote it.
    static var stashedPasteboard: String?

    // Fixture tracking for file/folder reference testing
    static var lastCreatedFixtureFileID: String?
    static var lastCreatedFixtureFolderID: String?
    static var lastCreatedFixtureFilePath: String?
    static var lastCreatedFixtureFolderPath: String?
    static var lastPrimaryActivationOutcome: String?

    /// The origin the rule produces for a known 1600x1000 screen with the
    /// status item near its top right.
    @MainActor
    private static func originProbe(_ source: PanelController.OpenSource) -> [Double] {
        PanelController.origin(for: source, size: PanelController.size,
                               visible: NSRect(x: 0, y: 0, width: 1600, height: 1000),
                               anchor: NSRect(x: 700, y: 975, width: 24, height: 24)).asArray
    }

    /// The Settings window's REAL sidebar row count, read from the actual
    /// `NSOutlineView` a SwiftUI `List(selection:).listStyle(.sidebar)`
    /// renders as - not the SwiftUI model array (`SettingsTab.visible`),
    /// which stays exactly the same size whether or not the sidebar COLUMN
    /// is visible. That distinction is the whole of the M8 bug this exists
    /// to catch: "when clicking diagnosis all the tabs vanish" was
    /// `NavigationSplitView` collapsing its sidebar column while the model
    /// array behind it never changed, so any assertion reading the model
    /// would have stayed green through the regression. Only meaningful in a
    /// real, non-headless window - `-1` otherwise.
    @MainActor
    private static var settingsSidebarRowCount: Int {
        guard !isHeadless,
              let window = NSApp.windows.first(where: { $0.title == "Clip Settings" }),
              let content = window.contentView,
              let outline = firstSidebarOutlineView(in: content)
        else { return -1 }
        return outline.numberOfRows
    }

    /// M14: a hub tab's own content is now ALSO a SwiftUI `List`
    /// (`SettingsHub`, `.listStyle(.plain)`) - which, like the sidebar's own
    /// `.listStyle(.sidebar)` List, compiles to an `NSOutlineView` on macOS.
    /// A plain first-match walk would silently start finding the DETAIL
    /// pane's outline instead of the sidebar's the moment a hub tab is
    /// selected, which is exactly the kind of thing this whole check exists
    /// to catch (see the doc comment above) - so this specifically looks
    /// for `.sourceList` style, the one `.listStyle(.sidebar)` sets and no
    /// other list style does.
    private static func firstSidebarOutlineView(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView, outline.style == .sourceList { return outline }
        for sub in view.subviews {
            if let found = firstSidebarOutlineView(in: sub) { return found }
        }
        return nil
    }

    /// What the last theme export or import said went wrong - empty when it
    /// worked, so a probe can tell a refusal from a silent no-op.
    @MainActor static var lastThemeFileError = ""

    /// The Settings window's id for `screencapture -l` - see the command.
    @MainActor static var settingsWindowNumber = 0

    /// What the last design-library import reported, for the probe to compare
    /// against what the database actually holds.
    /// Which of the two exclusive sync modes is live, as a word.
    @MainActor
    static var connectionLabel: String {
        switch SyncManager.shared.connection {
        case .none:   return "none"
        case .google: return "google"
        case .token:  return "token"
        }
    }

    static var lastImportSummary = ""
    /// Whether the last `importDesignLibrary` reported a real problem -
    /// see `ExportPane.designImportMessage`, which is what now produces
    /// `lastImportSummary` for this command.
    static var lastImportFailed = false
    /// M4 row 15/16: the outcome of the last `importFixture`/`exportWriteFixture`.
    static var lastExportImportOutcome = ""
    static var lastExportImportUnreadable = -1
    /// M4 row 4: whether the last `captureImageNow` actually produced an item.
    static var lastImageCaptureSucceeded = false
    /// M4 row 13: whether the last `deleteMediaFileOf` actually removed the file.
    static var lastMediaDeleteSucceeded = false
    static var lastPaletteAudit = ""
    static var lastDerivationAudit = ""
    static var lastVisibleOrder = ""
    static var lastPayloadResult = ""
    static var lastKeyedReply = ""
    static var lastBatchTokens = ""
    static var lastPayloadTypes = ""
    static var lastManualOrders = ""
    static var lastHexReading = ""
    static var lastSignIn = ""
    static var lastSettingsRoundTrip = ""
    static var lastSettingsDiagnostic = ""

    // M29: settings sync and backup.
    static var lastSettingsValue = ""
    static var lastSettingsPayload = ""
    static var lastSettingsStamps = ""
    static var lastBackupError = ""
    static var lastBackupSections: [String] = []
    static var lastBackupCounts: [String: Int] = [:]
    static var lastBackupDropSummary = ""
    static var lastRestoreSummary = ""
    static var lastSafetyCopy = ""
    static var lastMergeResult = ""
    /// M2: what `repairKeychain` last found, for K3-K5's assertions.
    static var lastRepairResult = KeychainStore.RepairResult()

    /// How long the last simulated typing run took, in milliseconds.
    static var lastSearchMilliseconds: Double = 0

    /// The theme built from a design document, for the probe.
    static var lastThemeFromDesign = ""
    static var lastComposeCount = 0
    static var lastThemeFromDesignPasses = false
    static var lastThemeFromDesignFailures: [[String: Any]] = []
    // ---- M9: theme builder as a design system
    private static var lastPanelLuminance: Double?
    // ---- M17: contrast matrix - a ratio computed fresh, on demand, so a
    // probe can prove the matrix's cached number and a brand-new call into
    // the SAME `ThemeRules.ratio` agree, rather than one silently drifting.
    private static var lastRatioProbe: Double?
    // ---- M30: the SAME explanation `ContrastMatrixView.stuckExplanation`
    // shows beside a still-red cell, read back for a probe rather than
    // parsed off a screenshot. `["reason": "collidesWith"|"noRoom"|
    // "unresolved", "pairing": <name or "">, "sharedToken": <token or "">]`.
    private static var lastStuckExplanation: [String: String]?
    // ---- M30 redesign: the plain-language copy `IssueCard` shows for one
    // pairing right now - `["problem": <sentence>, "collision": <sentence
    // or "">]`.
    private static var lastIssueCopy: [String: String]?
    // ---- M9: badge/action-row frame probe self-test (requirement 5) -
    // proves `ItemFrameProbe.intersects(for:)` can answer both true and
    // false, so a real `false` from the selected item is evidence rather
    // than a check that cannot fail.
    static var lastFrameProbeSelfTestOverlap: Bool?
    static var lastFrameProbeSelfTestDisjoint: Bool?
    /// M9: requirement 4 (diagnostics discoverability) - length of the last
    /// `DiagnosticsReport.full()` string put on the pasteboard by
    /// `diagnosticsCopyFullReport`, so a probe can prove it is not empty.
    static var lastDiagnosticsFullReportLength = 0

    /// The action panel's phase as one word, so a test can wait on it.
    static var actionPanelPhase: String {
        switch ActionPanelController.shared.model.phase {
        case .choosing:  return "choosing"
        case .working:   return "working"
        case .result:    return "result"
        case .failed:    return "failed"
        }
    }

    /// The message and remedy behind a `.failed` phase - e.g. the "connect a
    /// model" refusal when AI is off - so a test can read what the panel
    /// actually says rather than only that it failed.
    static var actionPanelFailureMessage: String {
        if case .failed(let message, _) = ActionPanelController.shared.model.phase { return message }
        return ""
    }
    static var actionPanelFailureRemedy: String {
        if case .failed(_, let remedy) = ActionPanelController.shared.model.phase { return remedy ?? "" }
        return ""
    }

    static var isHeadless: Bool {
        ProcessInfo.processInfo.environment["CLIP_HEADLESS"] == "1"
    }

    /// Outcome of the last `fireGlobalHotkey` command, kept apart from
    /// whether the hotkey's effect showed up. Posting to the HID event tap
    /// requires Accessibility permission and fails *silently* without it, so
    /// "the hotkey did not fire" and "this process was never allowed to send
    /// one" would otherwise look identical to a probe. `.notAttempted` is the
    /// state before the command has ever run.
    private enum HotkeyPostOutcome: String {
        case notAttempted = "not_attempted"
        case invalidCombo = "invalid_combo"
        case noPermission = "no_permission"
        case posted = "posted"
    }
    private static var lastHotkeyOutcome: HotkeyPostOutcome = .notAttempted
    /// When the last hotkey was posted, so the round trip can be measured.
    private static var lastHotkeyPostAt: Date?

    /// What the last paste-action command produced, so the probe can read it
    /// back. Each is the empty string when the operation was accepted, which is
    /// how "it refused, and said why" is told apart from "it worked".
    private static var lastCustomProblem = ""
    private static var lastResyncSummary = ""
    private static var lastResyncAgrees = false
    private static var lastMediaFile = ""
    private static var lastMediaItemID = ""
    private static var lastTombstoneCount = 0
    private static var lastHasTombstone = false
    private static var lastMediaFileExists = false
    private static var lastLanguageProblem = ""
    private static var lastInstruction = ""

    /// M1 - N3: whether the action closure on a QA-reported notice has run.
    static var noticeActionRanForTesting = false

    // ---- M3: startup health, backups, migrations, the audit ----
    static var lastHealthFindingsCount = 0
    static var lastBackupPath = ""
    static var lastRestoreSucceeded = false
    static var lastAuditOrphanCount = 0
    static var lastAuditOrphans: [[String: Any]] = []
    static var lastReclaimPath = ""
    static var lastEmptyReclaimedCount = 0
    static var lastDiagnosticsReportText = ""
    /// Computed on demand (`diagnosticsInsights` command), not on every
    /// state write: `DiagnosticsInsights.all()` runs a filesystem audit
    /// scan (`AppPaths.audit()`) among other things, and this dictionary is
    /// rebuilt after EVERY command in the whole suite - the same reasoning
    /// as `lastDiagnosticsReportText` just above it.
    static var lastInsightLines: [String] = []

    private static var timer: Timer?
    private static var lastCommandID = ""
    /// The id of the last command whose effects are reflected in the state file.
    private static var acknowledged = ""

    // `realSandboxSupport`, not `support`: the bridge's own command/state
    // files must never move just because a test is simulating the APP
    // failing to create ITS folder - see the doc comment on
    // `AppPaths.realSandboxSupport` for the hang this caused when it did.
    private static var dir: URL { AppPaths.realSandboxSupport }
    private static var commandURL: URL { dir.appendingPathComponent("qa-command.txt") }
    private static var stateURL: URL { dir.appendingPathComponent("qa-state.json") }

    @MainActor
    static func startIfEnabled() {
        guard isEnabled else { return }
        try? FileManager.default.removeItem(at: commandURL)
        let t = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // A paste recorded asynchronously changes nothing the poll loop
        // watches, so it has to say so itself. See TestIsolation.onPasteRecorded.
        TestIsolation.onPasteRecorded = {
            MainActor.assumeIsolated { writeState() }
        }
        writeState()
    }

    // MARK: - Command loop

    @MainActor
    private static func poll() {
        guard let raw = try? String(contentsOf: commandURL, encoding: .utf8) else { return }
        // Each command is "<id> <verb> [argument]" so a repeated verb still runs.
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, parts[0] != lastCommandID else { return }
        lastCommandID = parts[0]

        let verb = parts[1]
        // A command is one line, so a multi-line argument arrives escaped. Without
        // turning it back, a document passed as text was a single line containing
        // the characters `\` and `n` - and a front-matter test that "passed"
        // against it was really testing one long line, not front matter.
        let arg = (parts.count > 2 ? parts[2] : "")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
        // A command is about to mutate `@Published` state, which fires
        // `objectWillChange` and would otherwise wake the ambient debounced
        // sink in `AppDelegate` (below) at ~60ms - BEFORE this command's own
        // acknowledgement write at 120ms. That ambient call reads
        // `store.visibleItems` for its own state snapshot exactly like this
        // one does, and `writeState`'s "snapshot the counters before reading
        // the list" guard only protects a write against ITS OWN read - it
        // does nothing about a write that ran a moment earlier. Measured: 10
        // keystrokes via `perfType` reported 11-13 pipeline runs instead of
        // 10, because the ambient write's read bumped the shared `Perf`
        // counters, and by the time THIS command's snapshot was taken those
        // extra runs were already baked in. Set before `perform`, so nothing
        // this command does can slip an ambient write in ahead of it.
        commandWritePending = true
        let synchronous = perform(verb, arg)

        // Async commands (anything that calls a model) acknowledge themselves
        // once the work is really done. Acknowledging here as well would let the
        // probe read the state before the answer arrived.
        guard synchronous else { return }

        // Publish the state only after SwiftUI has applied the change, stamped
        // with the command id so the probe waits for this command specifically.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            // Cleared AFTER `writeState()`, not before: the ambient sink is a
            // separate scheduler (Combine's `RunLoop.main` vs this `DispatchQueue`
            // timer), and clearing the flag first left a window - both ready on
            // the same run-loop turn - where the ambient read could still land
            // between "pending cleared" and "snapshot taken", some runs and not
            // others. Held through the whole call, there is no such window.
            acknowledged = lastCommandID
            writeState()
            commandWritePending = false
        }
    }

    /// True from the moment a command starts until its own acknowledgement
    /// write has run. See the comment in `poll()` above for the race this
    /// closes: a command in flight already has a write coming, so the
    /// ambient sink skipping its own redundant one costs nothing and stops
    /// it from padding the very report the command is about to return.
    private static var commandWritePending = false

    /// The entry point for `AppDelegate`'s ambient `objectWillChange` sink -
    /// state changes with no QA command driving them (an async paste landing,
    /// a background fetch) still need to reach the state file, but one that
    /// arrives while a command's own write is already pending would only be
    /// measuring the same settle a moment early, at the cost of the counter
    /// pollution described above.
    @MainActor
    static func writeStateFromAmbientChange() {
        guard !commandWritePending else { return }
        writeState()
    }

    /// Returns true when the command completed synchronously.
    @discardableResult
    @MainActor
    private static func perform(_ verb: String, _ arg: String) -> Bool {
        let store = HistoryStore.shared

        switch verb {
        case "open":     PanelController.shared.open(from: arg == "hotkey" ? .hotkey : .statusItem)
        case "close":    PanelController.shared.close()
        case "toggle":   PanelController.shared.toggle(from: arg == "hotkey" ? .hotkey : .statusItem)

        // Simulates a real click outside the panel.
        case "clickOutside":
            PanelController.shared.simulateResignKey()

        case "key":      sendKey(arg)

        // Posts a REAL key event at the HID event tap - see `fireGlobalHotkey`
        // below for why `sendKey` cannot stand in for this.
        case "fireGlobalHotkey": fireGlobalHotkey(arg)
        case "tab":
            // Render-side timing: the model switch is instant (perf-probe
            // measures 0.07 ms); what a person feels is the layout commit
            // that follows. The next main run-loop turn happens after that
            // commit, so its delay is the render cost of the switch.
            let t0 = CFAbsoluteTimeGetCurrent()
            store.setTab(arg.isEmpty ? "all" : arg)
            DispatchQueue.main.async {
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                lastTabRenderMS = ms
                tabRenderSamples.append(ms)
                if tabRenderSamples.count > 50 { tabRenderSamples.removeFirst() }
            }
        case "sort":     store.sortOrder = SortOrder(rawValue: arg) ?? .newest
        case "search":   store.query = arg
        case "searchMode": store.searchMode = SearchMode(rawValue: arg) ?? .exact
        case "filter":
            // A space-separated list, so the probe can drive more than one.
            if arg.isEmpty { store.activeFilters = [] }
            else { store.activeFilters = Set(arg.split(separator: " ").compactMap { ItemCategory(id: String($0)) }) }
        // `appearance light|dark|system` - forces the app's appearance so an
        // eye pass can capture Settings in both (the AAA palette, 03/09).
        case "appearance":
            switch arg {
            case "light":  NSApp.appearance = NSAppearance(named: .aqua)
            case "dark":   NSApp.appearance = NSAppearance(named: .darkAqua)
            default:       NSApp.appearance = nil
            }
        case "settings":
            SettingsWindowController.shared.show()
            if let tab = SettingsTab(rawValue: arg) { SettingsRouter.shared.tab = tab }
        case "closeSettings": SettingsWindowController.shared.close()
        case "m23_settingsHeight": SettingsWindowController.shared.resizeForTesting(height: CGFloat(Double(arg) ?? 900))

        // ---- M14: two-layer settings (hub + sub-pages) ----
        // `settingsPage <tab> <page>` deep-links straight into a sub-page -
        // exactly `SettingsWindowController.show(tab:page:)`, the same call
        // a notice's own action would make.
        case "settingsPage":
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if bits.count == 2, let tab = SettingsTab(rawValue: bits[0]) {
                SettingsWindowController.shared.show(tab: tab, page: bits[1])
            }
        // `m14_openSubpage <tab> <page>` - exactly what a hub row's own tap
        // does (`SettingsRouter.openSubpage`), without discarding the tab's
        // forward history the way a deep link does.
        case "m14_openSubpage":
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if bits.count == 2, let tab = SettingsTab(rawValue: bits[0]) {
                SettingsRouter.shared.tab = tab
                SettingsRouter.shared.openSubpage(bits[1], in: tab)
            }
        case "m14_back":    SettingsRouter.shared.goBack()
        case "m14_forward": SettingsRouter.shared.goForward()

        // ---- M8.3/M8b: EditableLabel (Settings > Privacy's search-as-label,
        // and any future label that doubles as a filter), driven by testID
        // rather than a synthesized click - see EditableLabelTestRegistry.
        case "m8b_editableLabelBegin":
            EditableLabelTestRegistry.shared.handle(arg)?.begin()
        case "m8b_editableLabelType":
            // "<id> <text>", where an empty text (clearing the draft) is a
            // real case to prove, not just a non-empty one - so the split
            // keeps an empty trailing piece rather than dropping it.
            let bits = arg.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if let id = bits.first {
                EditableLabelTestRegistry.shared.handle(id)?.type(bits.count > 1 ? bits[1] : "")
            }
        case "m8b_editableLabelCommit":
            EditableLabelTestRegistry.shared.handle(arg)?.commit()
        case "m8b_editableLabelRevert":
            EditableLabelTestRegistry.shared.handle(arg)?.revert()

        // ---- Onboarding
        case "resetOnboarding":
            // Leaves no stale window behind for the next `onboardingPresent`.
            OnboardingWindowController.shared.close()
            PreferencesModel.shared.hasSeenOnboarding = false

        // Calls `show()` directly rather than `presentIfFirstRun()`, which is
        // the one entry point AppDelegate calls at launch and which refuses
        // outright under `CLIP_HEADLESS=1` - by design, so an unattended run
        // never has a real window steal focus. `show()` itself carries no
        // such guard (Settings > "Show the Welcome Guide" already calls it
        // unconditionally for anyone who skipped the first run), so this is
        // the real production entry point, not a bypass of one.
        case "onboardingPresent":
            OnboardingWindowController.shared.show()

        // The route the window's own red close button takes: `performClose`
        // asks `windowShouldClose` (undeclared here, so it proceeds) and only
        // then fires `windowWillClose`, which is the one place the flag is
        // set on this route rather than through `onDone()`. Found by title
        // rather than held as a reference, because the controller's window
        // property is private and that privacy is exactly the kind of thing
        // this bridge must not punch a hole in for two buttons' sake alone.
        case "onboardingWindowClose":
            NSApp.windows.first { $0.title == "Welcome to Clip" }?.performClose(nil)

        // Drives exactly what the "Not Now" button does: `OnboardingView`'s
        // shared `dismiss(onDone:)`, passed the same closure production wires
        // it to. No system prompt is anywhere on this path.
        case "onboardingNotNow":
            OnboardingView.dismiss(onDone: { OnboardingWindowController.shared.close() })

        // Drives Continue's dismissal outcome (flag set, window closed)
        // WITHOUT ever calling `OnboardingView.acceptAndDismiss(onDone:)` -
        // that is the one path that raises the real
        // `AXIsProcessTrustedWithOptions` system dialog, and a test must
        // never trigger it. See the comment on `OnboardingView`'s Actions
        // section for why `dismiss(onDone:)` is the right seam for this.
        case "onboardingContinueDismiss":
            OnboardingView.dismiss(onDone: { OnboardingWindowController.shared.close() })

        // Mounts a real ShortcutRecorder.RecorderView, in a real NSWindow,
        // recording - so the very next `closeSettings` exercises the actual
        // regression fix (`window?.makeFirstResponder(nil)` resigning a live
        // responder) even under CLIP_HEADLESS=1, where `show()` never builds
        // the production Settings window. See SettingsWindowController for
        // why this is a QA-only entry point rather than a headless `show()`.
        case "beginRecordingRealWindow":
            _ = SettingsWindowController.shared.beginTestRecordingInRealWindow()

        case "selectIndex":
            if let i = Int(arg), let item = store.item(atVisibleIndex: i) { store.select(item.id) }

        case "pinSelected":
            if let item = store.selectedItem { store.togglePin(item.id) }

        case "promptSelected":
            if let item = store.selectedItem { store.togglePrompt(item.id) }

        case "detail":   store.isDetailOpen = (arg != "false")

        case "assignShortcut":
            // "assignShortcut <index> <combo>"
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if bits.count == 2, let i = Int(bits[0]), let item = store.item(atVisibleIndex: i) {
                lastShortcutError = store.setShortcut(bits[1], for: item.id) ?? ""
            }

        // M8.5/V7e: frees one item's CARBON registration only, through
        // `ShortcutManager` directly rather than `HistoryStore.setShortcut`
        // - which also means `item.shortcut` is left exactly as it was.
        // Exists to stage the real scenario `ShortcutManager.
        // registerAllItems`'s own doc comment describes: a combination that
        // worked when it was assigned can start losing to something else by
        // the next launch, and the STORED shortcut must survive that even
        // though the live registration does not.
        case "m8b_unregisterItemCarbon":
            if let i = Int(arg), let item = store.item(atVisibleIndex: i) {
                ShortcutManager.shared.unregisterItem(item.id)
            }

        // M8.5/V7e: re-runs the exact call `AppDelegate.
        // applicationDidFinishLaunching` makes once at every real launch,
        // without relaunching the process - so a probe can simulate "the
        // next launch found this combination already taken" and read the
        // resulting itemDiagnostics through `m8b_itemShortcutRows`.
        case "m8b_reregisterAllItems":
            _ = ShortcutManager.shared.registerAllItems(from: store.items)

        case "editSelected":
            if let item = store.selectedItem {
                store.update(item.id) { $0.text = arg }
            }

        case "editDraft":
            // Simulates typing in the editor without committing — used to prove
            // Cancel discards and Save commits.
            pendingDraft = arg

        case "saveDraft":
            // Goes through the exact method the editor's Save button calls
            // (`commitDetailEdit`), not a lookalike - so a test of this
            // exercises the real close-on-save behaviour, and would go red
            // if that method stopped calling closeDetail() on success.
            if let item = store.selectedItem, let draft = pendingDraft {
                lastShortcutError = store.commitDetailEdit(
                    item.id,
                    text: draft,
                    title: item.title ?? "",
                    tags: item.tags.joined(separator: ", "),
                    shortcut: item.shortcut ?? "",
                    previousShortcut: item.shortcut
                ) ?? ""
                pendingDraft = nil
            }

        // M20/S1: Save pressed with nothing typed. Not a lookalike - the same
        // `commitDetailEdit` the Save button calls, fed the item's OWN current
        // values, which is exactly what the editor hands back when the user
        // opens it and saves without touching anything.
        case "m20_saveUnchanged":
            if let item = store.selectedItem {
                lastShortcutError = store.commitDetailEdit(
                    item.id,
                    text: item.text,
                    title: item.title ?? "",
                    tags: item.tags.joined(separator: ", "),
                    shortcut: item.shortcut ?? "",
                    previousShortcut: item.shortcut
                ) ?? ""
            }

        // M20/S5: does this media file still exist on disk? The reference check
        // is invisible from the item list - the surviving row keeps pointing at
        // the same name whether the bytes are there or not.
        case "m20_mediaFileExists":
            lastMediaFileExists = MediaStore.shared.url(for: arg) != nil

        // The `imageFile` of the item at a visible index, so the probe can name
        // the file two rows share.
        case "m20_mediaFileAt":
            lastMediaFile = store.item(atVisibleIndex: Int(arg) ?? 0)?.imageFile ?? ""

        case "cancelDraft":
            pendingDraft = nil

        case "restoreVersion":
            // "restoreVersion <index-from-oldest>"
            if let item = store.selectedItem, let i = Int(arg) {
                let all = store.versions(for: item.id).reversed().map { $0 }
                if all.indices.contains(i) { store.restore(all[i], for: item.id) }
            }

        case "bindAction":
            // "bindAction <action> <combo>"
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if bits.count == 2, let action = ShortcutAction(rawValue: bits[0]) {
                if let c = ShortcutRegistry.shared.assign(bits[1], to: action) {
                    lastConflict = c.message
                    lastConflictOwner = c.owner.describe
                } else {
                    lastConflict = ""
                    lastConflictOwner = ""
                }
            }

        case "resetShortcuts": ShortcutRegistry.shared.resetAll()

        // ---- Accessibility gate (per-item hotkey -> paste keystroke)
        //
        // `AccessibilityGate.isTrusted` cannot be driven false on a machine
        // that has actually granted the permission, and cannot be driven true
        // on CI, which never grants it - so both branches need a forced
        // value rather than depending on the real TCC state.
        case "forceAccessibilityTrust":
            // "forceAccessibilityTrust true|false|nil"
            switch arg {
            case "true":  AccessibilityGate.forcedTrust = true
            case "false": AccessibilityGate.forcedTrust = false
            default:      AccessibilityGate.forcedTrust = nil
            }

        case "resetAccessibilityGate":
            AccessibilityGate.resetForTesting()
            StartupHealth.installStampOverrideForTesting = nil

        // T1-M1: drives LinkMetadata.title(for:) exactly the way a copied
        // link does, so security-probe.py can prove the SSRF/byte-cap guard
        // from outside rather than reading the source and trusting it.
        case "m_t1m1_linkTestHost":
            // "m_t1m1_linkTestHost <host>" allows exactly that host past the
            // private-range guard for this run, or clears the allowance when
            // arg is empty. Only ever reaches Swift under CLIP_TESTING.
            LinkMetadata.testAllowedHost = arg.isEmpty ? nil : arg

        case "m_t1m1_linkFetch":
            // "m_t1m1_linkFetch <url>" - fetch, then report result, actual
            // bytes read, and how many requests the guard let through.
            let id = lastCommandID
            let requestedURL = arg
            LinkMetadata.requestsAttemptedForTesting = 0
            LinkMetadata.lastBytesReadForTesting = 0
            Task { @MainActor in
                linkFetchResult = nil
                if let url = URL(string: requestedURL) {
                    linkFetchResult = await LinkMetadata.title(for: url) ?? ""
                }
                linkFetchDone = true
                acknowledged = id
                writeState()
            }
            return false

        case "aiStub":
            // Installs / removes an offline model so AI features can be tested
            // without a key or a network.
            StubAIClient.scriptedReply = nil
            AIService.shared.clientOverride = (arg == "off") ? nil : StubAIClient()

        // "aiScript <reply>" makes the stub answer with exactly this, so a test
        // can present the shapes a real model actually returns.
        case "aiScript":
            StubAIClient.scriptedReply = arg.isEmpty ? nil : arg
            AIService.shared.clientOverride = StubAIClient()

        // A model that answers with nothing at all. Distinct from `aiScript ""`,
        // which clears the script: the empty reply is a case that happens, and
        // it needs to be scriptable rather than unreachable.
        case "aiEmptyReply":
            StubAIClient.scriptedReply = ""
            AIService.shared.clientOverride = StubAIClient()

        case "aiConfigureNth":
            // "aiConfigureNth <keyIndex>|<name>|<role>|<keyFile>|<kind>|<model>|<endpoint>"
            configureNth(arg)
            return false

        case "aiConfigure":
            // "aiConfigure <keyFilePath>|<kind>|<model>|<endpoint>"
            //
            // The key is read from the file and handed straight to the Keychain.
            // It is never written into the command file, never logged and never
            // included in the state report.
            configureProvider(arg)
            return false        // acknowledged after validation completes

        case "aiFeature":
            // "aiFeature <name>|<text>"
            let bits = arg.split(separator: "|", maxSplits: 1).map(String.init)
            guard bits.count == 2 else { break }
            runFeature(named: bits[0], text: bits[1])
            return false        // acknowledged when the model answers

        case "aiImprove":
            let id = lastCommandID
            Task { @MainActor in
                lastAISuggestion = (try? await AIService.shared.improvePrompt(arg)).map(\.body) ?? ""
                acknowledged = id
                writeState()
            }
            return false

        case "aiTheme":
            let id = lastCommandID
            Task { @MainActor in
                // The error is recorded rather than swallowed: "no theme came
                // back" and "a theme came back that was wrong" are different
                // failures, and a `try?` here made them look identical.
                lastAISuggestion = ""
                lastAIError = ""
                do {
                    let theme = try await AIService.shared.generateTheme(from: arg)
                    CustomThemeStore.shared.save(theme)
                    lastAISuggestion = theme.name
                } catch {
                    lastAIError = error.localizedDescription
                }
                acknowledged = id
                writeState()
            }
            return false

        case "aiRefineTheme":
            // "aiRefineTheme <instruction>"
            let id = lastCommandID
            Task { @MainActor in
                let base = CustomThemeStore.shared.themes.last
                    ?? CustomTheme.from(AppTheme.presets[0], name: "Base")
                do {
                    let refined = try await AIService.shared.refineTheme(base, instruction: arg)
                    CustomThemeStore.shared.save(refined)
                    lastAISuggestion = refined.name + "|" + refined.accent
                    finish(id, error: nil)
                } catch {
                    finish(id, error: error.localizedDescription)
                }
            }
            return false

        case "prefs":
            // "prefs <key> <value>"
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if bits.count == 2 { applyPreference(bits[0], bits[1]) }

        case "focusAction":
            // "focusAction next|prev|run"
            switch arg {
            case "next": _ = store.focusNextAction()
            case "prev": _ = store.focusPreviousAction()
            case "run":  _ = store.runFocusedAction()
            default: break
            }

        case "systemCopy":
            // Writes to the REAL pasteboard so the monitor's own poll picks it
            // up. The confirmation bug was invisible to every check that called
            // the app's code directly: the wiring was right, the caller was not.
            QABridge.stashedPasteboard = TestIsolation.board.string(forType: .string)
            let pb = TestIsolation.board
            pb.clearContents()
            pb.setString(arg, forType: .string)

        case "restorePasteboard":
            if let previous = QABridge.stashedPasteboard {
                let pb = TestIsolation.board
                pb.clearContents()
                pb.setString(previous, forType: .string)
                QABridge.stashedPasteboard = nil
            }

        case "addSkillText":
            // Runs the real detector over pasted text.
            store.add(ItemClassifier.item(fromText: arg, sourceAppName: "Probe"))

        case "importDesignLibrary":
            // The probe drives the real importer over a real folder; the count
            // it reports is checked against the database, not against itself.
            // Routed through the same `ExportPane.designImportMessage` the
            // real "Choose folder…" button calls, so the empty/unreadable/
            // no-candidates distinction (M4 row 17) is exercised here too,
            // not only in the SwiftUI action.
            let (failed, message) = ExportPane.designImportMessage(
                folder: URL(fileURLWithPath: arg), store: store)
            QABridge.lastImportSummary = message
            QABridge.lastImportFailed = failed

        case "dropFile":
            // "dropFile <role|-> <path>" - the real drop handler, not a stand-in.
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if bits.count == 2 {
                store.acceptDroppedFile(URL(fileURLWithPath: bits[1]),
                                        preferredRole: ItemRole(rawValue: bits[0]))
            }

        case "dropText":
            // "dropText <role|-> <text>"
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if bits.count == 2 {
                store.acceptDroppedText(bits[1], preferredRole: ItemRole(rawValue: bits[0]))
            }

        case "duplicateTheme":
            // "duplicateTheme <themeID>" - built-in id or "custom:<uuid>".
            let source: CustomTheme?
            if arg.hasPrefix("custom:") {
                source = CustomThemeStore.shared.theme(withID: arg)
            } else if let preset = AppTheme.presets.first(where: { $0.id == arg }) {
                source = CustomTheme.from(preset, name: preset.name)
            } else { source = nil }
            if let source {
                let copy = source.duplicated(
                    named: CustomTheme.copyName(for: source.name,
                                                existing: CustomThemeStore.shared.themes.map(\.name)))
                CustomThemeStore.shared.save(copy)
                ThemeManager.shared.themeID = "custom:\(copy.id)"
            }

        // ---- M7: theme editor beside the panel, editor left / preview right
        case "m7_openThemeEditor":
            // Opens Settings on Themes AND requests the sheet in the same
            // command, but the sheet's onAppear (which does the real work -
            // enterThemeEditing included) only runs once SwiftUI has actually
            // mounted ThemePane, which needs a run-loop turn or two after
            // `show(tab:)`. Not `return false` + a Task: the two waits below
            // give both events a turn on the run loop before the built-in
            // 0.12s post-command delay captures state.
            SettingsWindowController.shared.show(tab: .themes)
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    ThemeEditorBridge.shared.openRequested += 1
                }
            }

        case "m7_closeThemeEditor":
            ThemeEditorBridge.shared.closeRequested += 1

        case "m7_setVisibleFrameOverride":
            // "m7_setVisibleFrameOverride <width> <height>"
            let bits = arg.split(separator: " ").compactMap { Double($0) }
            if bits.count == 2 {
                PanelController.visibleFrameOverrideForTesting =
                    NSRect(x: 0, y: 0, width: bits[0], height: bits[1])
                PanelController.shared.reapplyThemeEditingLayoutForTesting()
                // The same thing a real display change does, so the override
                // exercises the ordinary height cap and not just the paired
                // theme-editing layout.
                PanelController.shared.applyHeight()
            }

        case "m7_clearVisibleFrameOverride":
            PanelController.visibleFrameOverrideForTesting = nil
            PanelController.shared.reapplyThemeEditingLayoutForTesting()
            PanelController.shared.applyHeight()

        case "m7_setPreviewAccent":
            // "m7_setPreviewAccent <hex>" - the same downstream call a colour
            // well's onChange(of: theme) makes inside ThemeBuilder, without
            // reaching into that view's own private @State.
            if let current = ThemeManager.shared.previewTheme {
                var custom = CustomTheme.from(current, name: "QA preview")
                custom.accent = arg
                ThemeManager.shared.updatePreview(custom)
            }

        // ---- M9: theme builder as a design system, 9.1-9.4
        //
        // "m9_setThemeDark true|false" - the same downstream call the
        // "Dark theme" switch's own setter makes (`CustomTheme.rederive
        // Surfaces(dark:)`), without reaching into ThemeBuilder's private
        // @State - mirrors m7_setPreviewAccent just above.
        case "m9_setThemeDark":
            if let current = ThemeManager.shared.previewTheme {
                var custom = CustomTheme.from(current, name: current.name)
                custom.rederiveSurfaces(dark: arg == "true")
                ThemeManager.shared.updatePreview(custom)
            }

        // Renders the REAL panel - the same view snapshotPanel captures -
        // and reports its mean relative luminance (0...1), so 9.1's "a light
        // theme whose panel stays dark is a defect" can be measured rather
        // than eyeballed. `arg`, if non-empty, is also written as a PNG (the
        // same renderLayerToPNG technique) for a human to look at.
        case "m9_renderPanelLuminance":
            if let view = PanelController.shared.panelContentViewForTesting {
                lastPanelLuminance = meanLuminance(of: view)
                if !arg.isEmpty { renderLayerToPNG(view, to: arg) }
            } else {
                lastPanelLuminance = nil
            }

        // "m9_setDraftAccent <hex>" - changes ThemeBuilder's own DRAFT
        // (theme.accent, the local @State the mini-preview reads), NOT the
        // live panel's preview m7_setPreviewAccent already reaches. W5i
        // needs exactly this distinction.
        case "m9_setDraftAccent":
            ThemeDraftTestBridge.shared.setAccent(arg)

        // Expands the "Theme assistant" disclosure - its content (the
        // MarkdownPromptEditor W4 drives) is not mounted while collapsed.
        case "m9_expandAssistant":
            ThemeDraftTestBridge.shared.expandAssistant()

        // Renders the theme builder's mini-preview - registered by
        // MiniPreviewProbe (SettingsThemePane.swift) since it lives inside a
        // sheet, not the Settings window's own content view that
        // m8b_snapshotSettings reaches. `arg` is the output path.
        case "m9_snapshotMiniPreview":
            if let view = MiniPreviewTestRegistry.shared.current() {
                renderLayerToPNG(view, to: arg)
            }

        // ---- M11: one component set with full interaction states -------
        //
        // "m11_renderComponent <name> <state> <path>" - name is one of
        // "primary"/"secondary"/"ghost"/"link", state one of "idle"/
        // "hover"/"pressed"/"focused". Forces exactly ONE of the mini-
        // preview's live component swatches (`M11ComponentTestBridge`) into
        // that state and renders the WHOLE mini-preview, the SAME technique
        // and the SAME view `m9_snapshotMiniPreview` already uses - a diff
        // between two calls with different states attributes its entire
        // delta to the one component that changed, since nothing else in
        // the preview reads this bridge. "idle" (or any state not one of
        // the three real cases) clears the override.
        case "m11_renderComponent":
            let bits = arg.split(separator: " ", maxSplits: 2).map(String.init)
            if bits.count == 3 {
                // M17: the live component row moved INTO "Buttons and
                // links" (the user's own words: "place the button preview
                // where it's relevant ... not where it is now"), which is
                // not always scrolled into view in a long token column -
                // `layoutSubtreeIfNeeded`/`displayIfNeeded` inside
                // `renderLayerToPNG` below force this scroll request AND
                // the forced-state change to actually apply before the
                // capture, the same way they already force `setForced`'s
                // own pending SwiftUI update to apply.
                ComponentPreviewScrollBridge.shared.requestScroll()
                M11ComponentTestBridge.shared.setForced(name: bits[0], state: bits[1])
                if let view = MiniPreviewTestRegistry.shared.current() {
                    renderLayerToPNG(view, to: bits[2])
                }
            }

        // "m11_clearComponentForce" - releases every forced swatch, so a
        // probe run leaves the mini-preview in its normal, unforced state.
        case "m11_clearComponentForce":
            M11ComponentTestBridge.shared.clear()

        // "m11_setDraftButtonToken <key> <hex>" - the same downstream call a
        // button/link swatch's own ColorPicker makes on the DRAFT theme
        // (`ThemeBuilder`'s local @State), without reaching into that
        // view's private state - mirrors `m9_setDraftAccent`. This is the
        // "prove red" lever: setting a state's token to equal its idle
        // counterpart's current hex must collapse the rendered pixel delta
        // between those two states to (near) zero.
        case "m11_setDraftButtonToken":
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if bits.count == 2 {
                ThemeDraftTestBridge.shared.setButtonToken(bits[0], bits[1])
            }

        // ---- M18: hover fill stays inside the button's own frame --------
        //
        // "m18_renderIconButton <state> <path>" - renders ONE `iconButtonChrome`
        // button (the `.item` weight the row action buttons use) alone, on a
        // KNOWN, fixed 48x48 canvas with the button's real 32x32 frame
        // centered inside it - not a live control living somewhere inside a
        // bigger sheet, whose on-screen position could drift between runs.
        // `state` is "idle" or "hover". Built with no window and no SwiftUI
        // tree to mount into - the same `renderLayerToPNG` every other
        // snapshot command already uses, aimed at an `NSHostingView` nobody
        // navigated to, because nothing here needs a real window: the chrome
        // reads `theme`/`highlighted` from its own arguments, not from
        // anything a window would supply. The 8pt margin on every side is
        // what section 145 diffs against - those pixels are OUTSIDE the
        // button's own frame, so a highlight that reaches them has leaked
        // (M18, user screenshot of a chevron button's hover disc spilling
        // past its own frame).
        case "m18_renderIconButton":
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if bits.count == 2 {
                let hovering = bits[0] == "hover"
                let theme = ThemeManager.shared.theme
                let probe = Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hovering ? theme.textPrimary : theme.textSecondary)
                    .iconButtonChrome(theme, variant: .item, side: 32, highlighted: hovering)
                    .frame(width: 48, height: 48)
                    .background(Color(nsColor: .windowBackgroundColor))
                let hosting = NSHostingView(rootView: probe)
                hosting.frame = CGRect(x: 0, y: 0, width: 48, height: 48)
                hosting.layoutSubtreeIfNeeded()
                renderLayerToPNG(hosting, to: bits[1])
            }

        // "m9_promptSetText <id> <text>" - sets a MarkdownPromptEditor's real
        // bound text through the same path typing does, for W4's 10 KB
        // paste-and-read-back proof. Mirrors m8b_editableLabelType.
        case "m9_promptSetText":
            let bits = arg.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                .map(String.init)
            if let id = bits.first {
                MarkdownPromptTestRegistry.shared.handle(id)?.setText(bits.count > 1 ? bits[1] : "")
            }

        // ---- M17: the theme builder as its own window, with a contrast matrix
        //
        // Opens/closes the SAME window "New theme"/Cancel do - routed through
        // the identical `ThemeEditorBridge` counters `m7_openThemeEditor`/
        // `m7_closeThemeEditor` already use (M17 keeps that bridge working by
        // pointing it at the window instead of the old sheet), given its own
        // name so a probe reading section 144 does not have to know it shares
        // machinery with section 136.
        case "m17_openBuilder":
            ThemeEditorBridge.shared.openRequested += 1

        case "m17_closeBuilder":
            ThemeEditorBridge.shared.closeRequested += 1

        // "m17_save" - the exact call the footer's "Save theme" button
        // makes (`state.onSave?(theme)` then close), for a probe to prove
        // Save actually persists without needing to synthesize a real click.
        case "m17_save":
            let controller = ThemeBuilderWindowController.shared
            let saved = controller.state.theme
            controller.state.onSave?(saved)
            controller.close()

        // "m17_cancel" - the exact call the footer's "Cancel" button makes,
        // distinct from `m17_closeBuilder` (which is the window-manager /
        // QA-bridge open/close path `ThemeEditorBridge` already drove for
        // M7): this one also fires `state.onCancel`.
        case "m17_cancel":
            let controller = ThemeBuilderWindowController.shared
            let cancel = controller.state.onCancel
            controller.close()
            cancel?()

        // "m17_setTokenHex <token> <RRGGBBAA-or-RRGGBB>" - the same downstream
        // call a `ColorTokenRow`'s own hex field makes on the draft, without
        // reaching into that view's private state.
        case "m17_setTokenHex":
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if bits.count == 2 {
                var hex = bits[1]
                if !hex.hasPrefix("#") { hex = "#" + hex }
                ThemeBuilderWindowController.shared.state.theme.setToken(bits[0], hex: hex)
            }

        // "m17_applyNudge <foregroundToken> <backgroundToken>" - applies the
        // SAME nearest-passing-colour nudge the matrix's own "Apply" link
        // computes, for the one pairing named.
        case "m17_applyNudge":
            let bits = arg.split(separator: " ").map(String.init)
            if bits.count == 2, let pairing = ThemeRules.pairings.first(where: {
                $0.foregroundToken == bits[0] && $0.backgroundToken == bits[1]
            }) {
                let controller = ThemeBuilderWindowController.shared
                let nudged = ThemeRules.nudgedForeground(for: pairing, in: controller.state.theme.appTheme)
                controller.state.theme.setToken(pairing.foregroundToken, hex: nudged.hexString)
            }

        // "m17_fixAll" - the same repair "Fix all failing" calls, `ThemeDoctor
        // .repaired`, so this can never suggest something the save gate would
        // not also accept.
        case "m17_fixAll":
            let controller = ThemeBuilderWindowController.shared
            controller.state.theme = ThemeDoctor.repaired(controller.state.theme)

        // "m9_frameProbeSelfTest" - proves `ItemFrameProbe.intersects(for:)`
        // itself can answer both ways, the same "prove it" shape section
        // 142f's Z6a uses (a same-picture self-comparison): a synthetic
        // overlapping pair and a synthetic disjoint pair, under a throwaway
        // id nothing else uses, read back with `m9_frameProbeSelfTestResult`.
        // Without this, `m9_selectedBadgeActionsIntersect` reading `false`
        // could mean either "genuinely fixed" or "this check cannot fail" -
        // there is no third render this bridge can put on screen to
        // distinguish them.
        case "m9_frameProbeSelfTest":
            let overlapID = UUID()
            ItemFrameProbe.shared.set(.badge, CGRect(x: 0, y: 0, width: 20, height: 20), for: overlapID)
            ItemFrameProbe.shared.set(.actions, CGRect(x: 10, y: 10, width: 20, height: 20), for: overlapID)
            lastFrameProbeSelfTestOverlap = ItemFrameProbe.shared.intersects(for: overlapID)
            ItemFrameProbe.shared.clear(.badge, for: overlapID)
            ItemFrameProbe.shared.clear(.actions, for: overlapID)

            let disjointID = UUID()
            ItemFrameProbe.shared.set(.badge, CGRect(x: 0, y: 0, width: 20, height: 20), for: disjointID)
            ItemFrameProbe.shared.set(.actions, CGRect(x: 100, y: 100, width: 20, height: 20), for: disjointID)
            lastFrameProbeSelfTestDisjoint = ItemFrameProbe.shared.intersects(for: disjointID)
            ItemFrameProbe.shared.clear(.badge, for: disjointID)
            ItemFrameProbe.shared.clear(.actions, for: disjointID)

        // M9: "m17_snapshotBuilder <png>" - the builder window opens
        // (`m17_openBuilder`) but until now had no way to actually LOOK at
        // it, only ever the model-level reads above (`m17_draftTokens`,
        // `m17_matrixCells`...). Its token list and contrast matrix both
        // sit inside their own `ScrollView`s (`ThemeTokenTagging.swift`,
        // `ContrastMatrixView.swift`) - the same shape that made
        // `m8b_snapshotSettings`'s `renderLayerToPNG` come back blank for
        // `SettingsHub`, which is why this uses the `m14_snapshotSettings`
        // technique (`cacheDisplay`, the real AppKit draw path) rather than
        // that one.
        case "m17_snapshotBuilder":
            if let view = ThemeBuilderWindowController.shared.contentViewForTesting {
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: arg))
                    }
                }
            }

        // "m17_ratioFor <foregroundToken> <backgroundToken>" - computes
        // `ThemeRules.ratio` fresh, via a SEPARATE call from the one
        // `m17_matrixCells` made to build its own cached list, so a probe
        // can prove the two never disagree rather than trusting one stale
        // number reused twice.
        // "m17_ratioFor <pairing name, verbatim>" - the pairing's own unique
        // `name` (see `m17_matrixCells`' own doc comment on why text+surface
        // alone is not always unique), taking the whole remaining argument
        // rather than splitting on spaces, since a pairing's name is itself
        // a sentence ("Accent as text on card").
        case "m17_ratioFor":
            if let pairing = ThemeRules.pairings.first(where: { $0.name == arg }) {
                let t = ThemeBuilderWindowController.shared.state.theme.appTheme
                lastRatioProbe = ThemeRules.ratio(pairing.foreground(t), on: pairing.background(t))
            } else {
                lastRatioProbe = nil
            }

        // "m17_stuckExplanation <pairing name, verbatim>" - the SAME
        // `ThemeDoctor.explainStuck` call `ContrastMatrixView`'s own
        // still-red-cell message makes, for the theme currently in the
        // builder. Read back via `m17_lastStuckExplanation`.
        case "m17_stuckExplanation":
            let theme = ThemeBuilderWindowController.shared.state.theme
            switch ThemeDoctor.explainStuck(arg, in: theme) {
            case .collidesWith(let pairing, let sharedToken):
                lastStuckExplanation = ["reason": "collidesWith", "pairing": pairing, "sharedToken": sharedToken]
            case .noRoom:
                lastStuckExplanation = ["reason": "noRoom", "pairing": "", "sharedToken": ""]
            case .unresolved:
                lastStuckExplanation = ["reason": "unresolved", "pairing": "", "sharedToken": ""]
            }

        // M30/M33: "m17_issueCopy <pairing name, verbatim>" - the EXACT
        // plain-language sentences `IssueCard` shows for that pairing right
        // now (`ContrastMatrixView.swift`), read via `m17_lastIssueCopy` -
        // `title` (M33: the card's own location title), `problem` (the
        // short verdict under it), `collision` (empty when there is none),
        // and `stuck` ("true"/"false", M33: whether `IssueCard` is showing
        // `closestColourRow` instead of the slider for this pairing right
        // now) - so a probe checks the real committed copy and the real
        // committed control instead of a proxy for either.
        case "m17_issueCopy":
            guard let pairing = ThemeRules.pairings.first(where: { $0.name == arg }) else {
                lastIssueCopy = ["title": "", "problem": "", "collision": "", "stuck": "false"]
                break
            }
            let theme = ThemeBuilderWindowController.shared.state.theme
            let reason = ThemeDoctor.explainStuck(arg, in: theme)
            lastIssueCopy = ["title": ThemeDoctor.plainLocationTitle(for: pairing),
                              "problem": ThemeDoctor.plainProblem(for: pairing),
                              "collision": ThemeDoctor.plainCollisionSentence(for: reason) ?? "",
                              "stuck": reason == .noRoom ? "true" : "false"]

        // M30: "m17_setFullAuditOpen true|false" - the SAME shared state
        // toggle the hand-rolled "Show the full check" row flips
        // (`ThemeBuilderState.matrixFullAuditOpen`, never a
        // `DisclosureGroup` - section 144a's own gate). Live on shared
        // state rather than a plain `@State`, so this can drive it at any
        // point in the session, not only before the view's very first
        // appearance.
        case "m17_setFullAuditOpen":
            ThemeBuilderWindowController.shared.state.matrixFullAuditOpen = (arg == "true")

        case "timeFilter":
            // "timeFilter any|day|week|month" or "timeFilter range <days-ago> <days-ago>"
            let bits = arg.split(separator: " ").map(String.init)
            switch bits.first {
            case "any":   store.timeFilter = .any
            case "day":   store.timeFilter = .lastDay
            case "week":  store.timeFilter = .lastWeek
            case "month": store.timeFilter = .lastMonth
            case "range":
                if bits.count == 3, let a = Double(bits[1]), let b = Double(bits[2]) {
                    store.timeFilter = .range(from: Date().addingTimeInterval(-a * 86_400),
                                              to: Date().addingTimeInterval(-b * 86_400))
                }
            default: break
            }

        case "ageItem":
            // "ageItem <index> <days-ago>" - backdates an item so the window
            // filters can be driven against real timestamps.
            let bits = arg.split(separator: " ").map(String.init)
            if bits.count == 2, let index = Int(bits[0]), let days = Double(bits[1]),
               index < store.visibleItems.count {
                let id = store.visibleItems[index].id
                store.update(id) { $0.timestamp = Date().addingTimeInterval(-days * 86_400) }
            }

        case "timeSearch":
            // Types the argument one character at a time, the way a person
            // does, and reports the total. A single search on the finished
            // string would miss the cost that actually hurts.
            let started = Date()
            var typed = ""
            for ch in arg {
                typed.append(ch)
                store.query = typed
                _ = store.visibleItems.count
            }
            QABridge.lastSearchMilliseconds = Date().timeIntervalSince(started) * 1000
            store.query = ""

        case "themeFromDesign":
            // "themeFromDesign <index>" - builds a theme from a design document
            // in the visible list, repairs it, and selects it.
            if let index = Int(arg), index < store.visibleItems.count {
                let item = store.visibleItems[index]
                if let draft = DesignDocTheme.theme(from: item.fullText,
                                                   named: item.displayTitle) {
                    let repaired = ThemeDoctor.repaired(draft)
                    CustomThemeStore.shared.save(repaired)
                    ThemeManager.shared.themeID = "custom:\(repaired.id)"
                    // Report the AUDIT result, not just that a theme was made.
                    // A theme that exists and fails is not a feature.
                    let report = ThemeRules.audit(repaired.appTheme)
                    QABridge.lastThemeFromDesign = repaired.name
                    QABridge.lastThemeFromDesignPasses = report.passes
                    QABridge.lastThemeFromDesignFailures = report.failures.map {
                        ["pairing": $0.pairing, "ratio": $0.ratio, "required": $0.required]
                    }
                } else {
                    QABridge.lastThemeFromDesign = ""
                }
            }

        case "paste":
            if let item = store.selectedItem { store.requestPaste(item) }

        case "signInGoogle":
            // The real path, not a stand-in: this is the same call the button
            // makes. A sign-in test that skips the browser proves the parts
            // that were never in doubt.
            Task { @MainActor in
                let ok = await SyncManager.shared.signInWithGoogle(merge: arg != "replace")
                QABridge.lastSignIn = ok
                    ? "ok:\(GoogleAuth.shared.account?.email ?? "")"
                    : "failed:\(SyncManager.shared.lastError ?? GoogleAuth.shared.lastError ?? "?")"
            }

        case "signOutGoogle":
            Task { @MainActor in
                await SyncManager.shared.signOutOfGoogle(unlinkAccount: arg == "unlink")
                QABridge.lastSignIn = ""
            }

        case "hexProbe":
            // Runs the real recogniser, nothing else. A color that only the
            // probe can see is a color the app cannot.
            QABridge.lastHexReading = HexColor.normalised(arg) ?? ""

        case "settingsCadence":
            SettingsSync.shared.cadence = SettingsSyncCadence(rawValue: arg) ?? .fifteenMinutes

        case "settingsRoundTrip":
            // Take a snapshot, change something, apply the snapshot back, and
            // report what the setting is now. This is the only check that
            // proves apply() actually writes rather than silently skipping a
            // type it did not recognise.
            //
            // `SettingsSnapshot.current()` reads each synced key with
            // `defaults.object(forKey:)`, which is nil until the FIRST
            // explicit write - `@AppStorage`'s own default (200 here) is
            // never registered with `UserDefaults`, only known to the
            // property wrapper in memory. On a sandbox that has never once
            // written `historyLimit`, `current()` silently omits it from
            // `before.preferences`, so `before.apply()` below has nothing to
            // restore it FROM and leaves it at the value this diagnostic is
            // about to change it to - not a bug this diagnostic exists to
            // catch, but a gap in what it assumes going in. Writing the
            // value back to itself first (a no-op behaviourally) guarantees
            // an explicit UserDefaults entry exists before the snapshot is
            // taken, exactly as it would on any Mac that has ever opened
            // Settings.
            PreferencesModel.shared.historyLimit = PreferencesModel.shared.historyLimit
            let before = SettingsSnapshot.current()
            let original = PreferencesModel.shared.historyLimit
            PreferencesModel.shared.historyLimit = original == 321 ? 654 : 321
            let changed = PreferencesModel.shared.historyLimit
            before.apply()
            QABridge.lastSettingsRoundTrip =
                "\(original)|\(changed)|\(PreferencesModel.shared.historyLimit)"
            QABridge.lastSettingsDiagnostic = [
                "captured=\(before.preferences["historyLimit"] ?? "MISSING")",
                "inKeys=\(SettingsSnapshot.syncedKeys.contains("historyLimit"))",
                "rawAfter=\(String(describing: AppPaths.defaults.object(forKey: "historyLimit")))",
                "typeAfter=\(String(describing: type(of: AppPaths.defaults.object(forKey: "historyLimit") as Any)))"
            ].joined(separator: " ")

        // MARK: - M29: settings sync and backup

        case "settingsPut":
            // "settingsPut key=value" - writes one setting the way a Settings
            // control would, so a section can change a named key without
            // driving the pane that owns it.
            let bits = arg.split(separator: "=", maxSplits: 1).map(String.init)
            if bits.count == 2 {
                let key = bits[0], value = bits[1]
                let store = SettingsRegistry.store(for: key)
                    ?? SettingsRegistry.machineLocal.first { $0.key == key }?.store
                switch store {
                case .defaults(let kind):
                    switch kind {
                    case .bool: AppPaths.defaults.set(value == "1" || value == "true", forKey: key)
                    case .int:  if let n = Int(value) { AppPaths.defaults.set(n, forKey: key) }
                    case .string: AppPaths.defaults.set(value, forKey: key)
                    }
                    PreferencesModel.shared.reloadFromDefaults()
                    if key == "themeID" { ThemeManager.shared.themeID = value }
                    if key == "initialTabID" { ThemeManager.shared.initialTabID = value }
                    if let d = GalleryDensity(rawValue: value), key == "density" {
                        ThemeManager.shared.density = d
                    }
                    HistoryStore.shared.reloadViewPreferences()
                case .database, .pinnedOrder:
                    Database.shared.setPreference(key, value)
                default:
                    break
                }
                SettingsSync.shared.markDirty()
            }

        case "settingsGet":
            // Reads back through the same path the document reads, so a check
            // cannot pass by looking somewhere the sync never touches.
            let live = SettingsDocument.liveValues()
            QABridge.lastSettingsValue = live[arg]
                ?? AppPaths.defaults.object(forKey: arg).map(SettingsDocument.text(from:))
                ?? Database.shared.preference(arg)
                ?? ""

        case "settingsPayload":
            // The exact bytes that would go on the wire. This is what the
            // never-list assertion reads, so it is testing the real payload
            // rather than a re-derivation of it.
            QABridge.lastSettingsPayload = SettingsDocument.current().payloadJSON() ?? ""

        case "settingsStamps":
            // "key:stamp key:stamp ..." so a section can prove two keys carry
            // DIFFERENT timestamps, which is the whole basis of the merge.
            let doc = SettingsDocument.current()
            QABridge.lastSettingsStamps = doc.entries
                .map { "\($0.key):\(Int($0.value.t))" }
                .sorted().joined(separator: " ")

        case "settingsForgetLocal":
            // Makes this Mac a Mac that has never held these settings: the
            // per-key stamps and the record of what was last pushed both go.
            //
            // This is what lets one process stand in for a SECOND Mac. Both
            // halves of a rotated device id share one preferences store, so a
            // value "arriving" cannot be seen while the local side already has
            // its own stamp for that key - the merge correctly keeps whichever
            // is newer, and on one store that is always the local one. Forgetting
            // the record reproduces the case that actually matters: a new Mac,
            // signed in, holding no opinion of its own yet.
            Database.shared.setPreference(SettingsDocument.recordKey, "")
            Database.shared.setPreference("settings.lastSentDoc", "")
            SettingsSync.shared.forgetLastSentForTesting()

        case "settingsMergeProbe":
            // The conflict rule, exercised through the real `merge`.
            //
            // Two live Macs cannot be simulated by rotating the device id -
            // both halves share one preferences store - so the arrival of a
            // setting is proved over the real wire below, and the RULE for
            // deciding a conflict is proved here, on the function that decides
            // it. Stamps are literals rather than clock reads so the expected
            // answer comes from the case, not from re-running the comparison.
            var local = SettingsDocument()
            local.device = "m29-local"
            local.entries = [
                // Changed here, and later than the remote's copy: must survive.
                "statusIcon": SettingsEntry(v: "local-icon", t: 300),
                // Untouched here: the remote's newer value must land.
                "showFooter": SettingsEntry(v: "1", t: 100)
            ]
            var remote = SettingsDocument()
            remote.device = "m29-remote"
            remote.entries = [
                "statusIcon": SettingsEntry(v: "remote-icon", t: 200),
                "showFooter": SettingsEntry(v: "0", t: 400),
                // A key the local side has never seen: must arrive.
                "copyConfirmationSeconds": SettingsEntry(v: "9", t: 400),
                // Machine-local, and stamped far in the future: must be refused
                // anyway, because newer is not the same as allowed.
                "historyLimit": SettingsEntry(v: "5", t: 999),
                // A secret: must be refused.
                "sync.tokenService": SettingsEntry(v: "leaked", t: 999)
            ]
            let changedKeys = local.merge(remote).sorted()
            QABridge.lastMergeResult = [
                "statusIcon=\(local.entries["statusIcon"]?.v ?? "ABSENT")",
                "showFooter=\(local.entries["showFooter"]?.v ?? "ABSENT")",
                "copyConfirmationSeconds=\(local.entries["copyConfirmationSeconds"]?.v ?? "ABSENT")",
                "historyLimit=\(local.entries["historyLimit"]?.v ?? "ABSENT")",
                "tokenService=\(local.entries["sync.tokenService"]?.v ?? "ABSENT")",
                "changed=\(changedKeys.joined(separator: ","))"
            ].joined(separator: " ")

        case "backupInjectUnencodableTheme":
            // A theme with a non-finite Double fails `JSONEncoder`, which is
            // exactly the failure `BackupArchive.write` used to swallow via a
            // silent `compactMap`. This is the smallest real trigger for it -
            // no mock, the actual encoder actually throwing. `cornerRadius`,
            // not `translucency`: the latter is read into `writeState`'s
            // "customThemes" entry on every poll, and `NSJSONSerialization`
            // raises an uncatchable Objective-C exception on a NaN payload -
            // it crashed the whole harness the first time this was tried.
            let bad = CustomTheme(name: arg, accent: "#000000", accentSecondary: "#000000",
                                   panelBackground: "#000000", cardBackground: "#000000",
                                   cardHoverBackground: "#000000", selectedBackground: "#000000",
                                   surfaceBackground: "#000000", textPrimary: "#000000",
                                   textSecondary: "#000000", textTertiary: "#000000",
                                   border: "#000000", isDark: true, cornerRadius: Double.nan)
            CustomThemeStore.shared.save(bad)

        case "backupWrite":
            do {
                let manifest = try BackupArchive.write(to: URL(fileURLWithPath: arg), store: store)
                QABridge.lastBackupError = ""
                QABridge.lastBackupSections = manifest.sections.sorted()
                QABridge.lastBackupCounts = manifest.counts
                QABridge.lastBackupDropSummary = manifest.dropSummary ?? ""
            } catch {
                QABridge.lastBackupDropSummary = ""
                QABridge.lastBackupError = error.localizedDescription
                QABridge.lastBackupSections = []
                QABridge.lastBackupCounts = [:]
            }

        case "backupInspect":
            do {
                let manifest = try BackupArchive.inspect(URL(fileURLWithPath: arg))
                QABridge.lastBackupError = ""
                QABridge.lastBackupSections = manifest.sections.sorted()
                QABridge.lastBackupCounts = manifest.counts
            } catch {
                QABridge.lastBackupError = error.localizedDescription
                QABridge.lastBackupSections = []
                QABridge.lastBackupCounts = [:]
            }

        case "backupRestore":
            // "backupRestore /path" or "backupRestore /path all" - "all" opts
            // the machine-local settings in too, which the real sheet defaults
            // to Skip.
            //
            // Matched as a SUFFIX rather than by splitting on the first space:
            // the sandbox lives under "~/Library/Application Support/...", so
            // splitting cut every path at "Application" and every restore
            // failed with "that file is not a Clip backup" - a path bug wearing
            // a corruption bug's error message.
            let wantsLocal = arg.hasSuffix(" all")
            let path = wantsLocal ? String(arg.dropLast(4)) : arg
            do {
                let manifest = try BackupArchive.inspect(URL(fileURLWithPath: path))
                var modes: [BackupArchive.Section: BackupArchive.RestoreMode] = [:]
                for section in BackupArchive.Section.allCases where manifest.has(section) {
                    modes[section] = section == .settingsLocal && !wantsLocal
                        ? .skip : (section.defaultMode == .skip ? .skip : .merge)
                    if section == .settingsLocal && wantsLocal { modes[section] = .merge }
                }
                let summary = try BackupArchive.restore(
                    URL(fileURLWithPath: path), modes: modes, store: store,
                    takeSafetyCopy: true)
                QABridge.lastBackupError = ""
                QABridge.lastRestoreSummary = summary.text
                QABridge.lastSafetyCopy = summary.safetyCopy?.path ?? ""
            } catch {
                QABridge.lastBackupError = error.localizedDescription
                QABridge.lastRestoreSummary = ""
            }

        case "mark":
            if let index = Int(arg), index < store.visibleItems.count {
                store.toggleMark(store.visibleItems[index].id)
            }

        case "composePaste":
            QABridge.lastComposeCount = store.composePaste()

        case "fillVariables":
            // "fillVariables name=value name=value"
            if let item = store.fillingVariablesFor {
                var values: [String: String] = [:]
                for pair in arg.split(separator: " ") {
                    let bits = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    if bits.count == 2 { values[bits[0]] = bits[1] }
                }
                store.pasteFilled(item, values: values)
            }

        case "setRoleAt":
            // "setRoleAt <index> <role>" - the Move option, driven directly.
            // Deliberately NOT "setRole": that verb already exists and acts on
            // the selection, and a second case with the same name silently
            // shadowed it, which read as two unrelated role tests breaking.
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if bits.count == 2, let index = Int(bits[0]),
               let role = ItemRole(rawValue: bits[1]),
               index < store.visibleItems.count {
                store.setRole(store.visibleItems[index].id, to: role)
            }

        case "providerRole":
            // "providerRole <index> <primary|backup|unused>"
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if bits.count == 2, let i = Int(bits[0]),
               AIService.shared.providers.indices.contains(i),
               let role = ProviderRole(rawValue: bits[1]) {
                AIService.shared.setRole(role, for: AIService.shared.providers[i].id)
            }

        // Switches the live theme, so a theme can be looked at rather than only
        // measured. A ratio says a color is readable; it does not say the
        // interface looks like anything.
        case "useTheme":
            ThemeManager.shared.themeID = arg

        // "forceSystemAppearance light|dark" - stands in for flipping the OS
        // appearance, which a headless run cannot trigger itself. Drives the
        // same published property the live `NSApp.effectiveAppearance` KVO
        // observer writes, so a system-following theme's live repaint is
        // exercised through the real path rather than restated.
        case "forceSystemAppearance":
            ThemeManager.shared.forceSystemAppearanceForTesting(dark: arg == "dark")
        // `seedGoogleAccount name|email|picture` (empty arg = forget) - the
        // remembered account behind Settings > Sync's card, without a real
        // sign-in; the sandbox DB holds it.
        case "seedGoogleAccount":
            if arg.isEmpty { GoogleAuth.shared.forget() } else {
                let bits = arg.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                GoogleAuth.shared.remember(email: bits.count > 1 ? bits[1] : "", name: bits[0],
                                           picture: bits.count > 2 ? bits[2] : nil)
            }

        case "auditThemes":
            // Grades every preset against ThemeRules and reports the failures.
            var out: [[String: Any]] = []
            for preset in AppTheme.presets {
                let report = ThemeRules.audit(preset)
                out.append([
                    "name": preset.name,
                    "id": preset.id,
                    "passes": report.passes,
                    "failures": report.failures.map {
                        ["pairing": $0.pairing,
                         "ratio": (round($0.ratio * 100) / 100),
                         "required": $0.required]
                    }
                ])
            }
            // A control: a theme that is obviously unreadable must be reported
            // as such. Without it a green run proves only that the audit ran,
            // not that it can fail - which is exactly how twelve presets passed
            // an audit that was measuring the wrong colors.
            let unreadable = AppTheme(
                id: "qa-unreadable", name: "Unreadable", symbol: "xmark",
                accent: Color(hex: "#111111"), accentSecondary: Color(hex: "#111111"),
                panelBackground: Color(hex: "#101010"), cardBackground: Color(hex: "#111111"),
                cardHoverBackground: Color(hex: "#111111"), selectedBackground: Color(hex: "#111111"),
                surfaceBackground: Color(hex: "#101010"), textPrimary: Color(hex: "#141414"),
                textSecondary: Color(hex: "#131313"), textTertiary: Color(hex: "#121212"),
                border: Color(hex: "#111111"), cornerRadius: 10, usesGradientHeader: false,
                defaultLayout: .list, defaultDensity: .comfortable, isDark: true)
            let control = ThemeRules.audit(unreadable)
            out.append(["name": "QA control (must fail)", "id": "qa-unreadable",
                        "passes": control.passes,
                        "failures": control.failures.map {
                            ["pairing": $0.pairing,
                             "ratio": (round($0.ratio * 100) / 100),
                             "required": $0.required]
                        }])
            themeAudit = out
            themePairings = ThemeRules.pairings.count

        // "auditThemesRepaired" - runs the SAME repair "Fix all failing" and
        // the design-import path call (`ThemeDoctor.repaired`) over every
        // built-in preset, off the theme builder window entirely, so the
        // presets themselves can be corrected without a UI round trip.
        // Reports only the tokens that actually moved (a preset ThemeDoctor
        // cannot improve comes back unchanged, per its own guard) and the
        // post-repair audit, so the smallest passing move is visible before
        // anyone hand-edits `AppTheme.presets`.
        case "auditThemesRepaired":
            var out: [[String: Any]] = []
            for preset in AppTheme.presets {
                let draft = CustomTheme.from(preset, name: preset.name)
                let fixed = ThemeDoctor.repaired(draft)
                let tokens: [(String, String, String)] = [
                    ("textPrimary", draft.textPrimary, fixed.textPrimary),
                    ("textSecondary", draft.textSecondary, fixed.textSecondary),
                    ("textTertiary", draft.textTertiary, fixed.textTertiary),
                    ("border", draft.border, fixed.border),
                    ("cardBackground", draft.cardBackground, fixed.cardBackground),
                    ("cardHoverBackground", draft.cardHoverBackground, fixed.cardHoverBackground),
                    ("selectedBackground", draft.selectedBackground, fixed.selectedBackground),
                    ("surfaceBackground", draft.surfaceBackground, fixed.surfaceBackground),
                    ("accent", draft.accent, fixed.accent),
                    ("accentSecondary", draft.accentSecondary, fixed.accentSecondary)
                ]
                let changes = tokens.filter { $0.1.caseInsensitiveCompare($0.2) != .orderedSame }
                let before = ThemeRules.audit(preset)
                let after = ThemeRules.audit(fixed.appTheme)
                out.append([
                    "id": preset.id, "name": preset.name,
                    "changes": changes.map { ["token": $0.0, "from": $0.1, "to": $0.2] },
                    "failuresBefore": before.failures.count,
                    "failuresAfter": after.failures.count,
                    "passesAfter": after.passes,
                    "remainingFailures": after.failures.map {
                        ["pairing": $0.pairing, "ratio": (round($0.ratio * 100) / 100),
                         "required": $0.required]
                    }
                ])
            }
            presetRepairReport = out

        case "createToken":
            let id = lastCommandID
            Task { @MainActor in
                lastToken = await SyncManager.shared.createToken() ?? ""
                finish(id, error: SyncManager.shared.lastError)
            }
            return false

        case "connectToken":
            // "connectToken <token> <merge|replace>"
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            let id = lastCommandID
            Task { @MainActor in
                _ = await SyncManager.shared.connect(token: bits.first ?? "",
                                                     merge: bits.count < 2 || bits[1] != "replace")
                finish(id, error: SyncManager.shared.lastError)
            }
            return false

        case "syncNow":
            let id = lastCommandID
            Task { @MainActor in
                await SyncManager.shared.syncNow()
                finish(id, error: nil)
            }
            return false

        // "syncSimulateFailure auth|lostToken|generic" - drives noteSyncFailure
        // with a real error of the named shape, so the noise threshold in
        // diagnose()/noteSyncFailure can be proved without breaking a real
        // network three times in a row. See hasVisibleFailure/
        // visibleFailureMessage in the state report for the result.
        case "syncSimulateFailure":
            SyncManager.shared.simulateSyncFailureForTesting(kind: arg)

        // The same call a real sync makes on success - clears the streak and
        // the badge, whatever put them up.
        case "syncSimulateSuccess":
            SyncManager.shared.simulateSyncSuccessForTesting()

        case "setSharing":
            let id = lastCommandID
            Task { @MainActor in
                await SyncManager.shared.setSharing(arg != "false")
                finish(id, error: SyncManager.shared.lastError)
            }
            return false

        case "disconnectToken":
            let id = lastCommandID
            Task { @MainActor in
                await SyncManager.shared.disconnect()
                finish(id, error: nil)
            }
            return false

        // Impersonates a second Mac against the same service, which is the only
        // way to test that two devices actually converge.
        case "newDeviceID":
            let id = arg.isEmpty ? UUID().uuidString : arg
            Database.shared.setPreference("sync.deviceID", id)
            // The id is derived from the hardware now, so the preference alone
            // no longer changes what this process calls itself.
            SyncManager.deviceIDOverrideForTesting = id

        // "addImage <pixelSide>" - a real, decodable PNG (a solid-colour
        // square), saved through the real MediaStore and added as a real
        // item, so sha256 comparisons and MediaPreview's decode path are
        // exercised against actual image bytes rather than a stand-in.
        case "m5AddImage":
            let side = max(1, Int(arg) ?? 8)
            if let data = QABridge.makeSolidPNG(side: side),
               let name = MediaStore.shared.save(data, ext: "png") {
                var item = ClipboardItem(kind: .image, imageFile: name,
                                         sourceAppName: "Probe")
                item.pixelWidth = side
                item.pixelHeight = side
                store.add(item)
                lastMediaFile = name
                lastMediaItemID = store.items.first(where: { $0.imageFile == name })?.id.uuidString ?? ""
            }

        // Simulates the file having been evicted from THIS Mac's disk while
        // the item still exists - a moved/renamed file, a volume that is not
        // mounted, or (M5 REVISED) the exact shape `StartupHealth.run()`'s
        // dangling-image audit finds and removes at the next launch.
        case "m5DeleteMediaFileLocally":
            if let url = MediaStore.shared.url(for: arg) {
                try? FileManager.default.removeItem(at: url)
            }

        // Simulates the launch-time check `AppDelegate` runs once for real -
        // useful here because the probe's instance already finished
        // launching before it can set up the "empty library, readable
        // token" state this checks for.
        case "m5RestoreCheck":
            SyncManager.shared.offerRestoreIfNeeded()

        // Runs whatever action button the current notice carries - the same
        // closure a real click on "Restore" or "Repair now" would run.
        case "m5RunNoticeAction":
            NoticeCenter.shared.current?.action?.run()

        // "applySettingsPinnedOrder id1,id2,..." - drives the EXACT path a
        // settings row from another Mac takes (`SettingsSnapshot.apply()`),
        // without needing a second device, so pin ORDER specifically - not
        // just which items are pinned, which the item channel already
        // covers on its own - is proven to travel this field.
        case "m5ApplySettingsPinnedOrder":
            var snapshot = SettingsSnapshot.current()
            snapshot.pinnedIDs = arg
            snapshot.apply()

        case "duplicateSelected":
            if let item = store.selectedItem { store.duplicate(item.id) }

        // The setup kit and the settings file, driven the way the buttons do.
        // "serverConfig <field>=<value>;<field>=<value>" - the Server form.
        case "serverConfig":
            var config = ServerConfig.load()
            for pair in arg.split(separator: ";") {
                // Keep empty values: "address=" means "clear it", and dropping
                // it silently made a field impossible to blank.
                let bits = pair.split(separator: "=", maxSplits: 1,
                                      omittingEmptySubsequences: false).map(String.init)
                guard bits.count == 2 else { continue }
                switch bits[0] {
                case "address":  config.address = bits[1]
                case "host":     config.databaseHost = bits[1]
                case "name":     config.databaseName = bits[1]
                case "user":     config.databaseUser = bits[1]
                case "password": config.databasePassword = bits[1]
                case "https":    config.requireHTTPS = bits[1] == "true"
                case "pageSize": config.pageSize = Int(bits[1]) ?? config.pageSize
                default: break
                }
            }
            config.save()

        case "writeKit":
            lastKitPath = (try? ServerKit.writeKit(to: URL(fileURLWithPath: arg)))?.path ?? ""

        case "exportSyncSettings":
            if let data = ServerKit.exportSettings() {
                try? data.write(to: URL(fileURLWithPath: arg))
                lastKitPath = arg
            }

        case "importSyncSettings":
            if let data = try? Data(contentsOf: URL(fileURLWithPath: arg)) {
                switch ServerKit.importSettings(from: data) {
                case .applied(let service): lastKitPath = service
                case .notClipSettings:      lastKitPath = "not-clip-settings"
                case .noService:            lastKitPath = "no-service"
                }
            }

        case "testServer":
            let id = lastCommandID
            Task { @MainActor in
                switch await SyncClient.shared.testConnection() {
                case .success(let message): lastKitPath = "ok: " + message
                case .failure(let error):   lastKitPath = "fail: " + error.localizedDescription
                }
                finish(id, error: nil)
            }
            return false

        case "setSyncURL":
            Database.shared.setPreference("syncBaseURL", arg)

        case "clickAction":
            // Runs an action the way the button's own handler does.
            if let item = store.selectedItem, let action = ItemAction(rawValue: arg) {
                store.perform(action, on: item)
            }

        case "beginOpenWith":
            if let item = store.selectedItem { store.beginOpenWith(item.id) }

        case "cancelOpenWith": store.cancelOpenWith()

        case "beginMove":
            if let item = store.selectedItem { store.beginMove(item.id) }

        case "commitMove":
            if arg.isEmpty { store.commitMove() }
            else { store.commitMove(to: ItemRole(rawValue: arg)) }

        case "cancelMove": store.cancelMove()

        case "clearProviders":
            for provider in AIService.shared.providers {
                AIService.shared.removeProvider(provider.id)
            }
            AIService.providerClientOverrides.removeAll()

        // "removeProviderAt <index>" - removes exactly one connection,
        // through the real `removeProvider(_:)` (so backup promotion runs),
        // rather than `clearProviders`' clean sweep.
        case "removeProviderAt":
            if let i = Int(arg), AIService.shared.providers.indices.contains(i) {
                let id = AIService.shared.providers[i].id
                AIService.providerClientOverrides.removeValue(forKey: id)
                AIService.shared.removeProvider(id)
            }

        // "providerScript <index> <ok|401|clear>" - scripts one connection's
        // answer directly, bypassing the network entirely, so the main/
        // backup failover chain in `AIService.run()` can be exercised: one
        // connection can be made to fail with a real HTTP status while
        // another in the same chain succeeds. The global "aiStub" cannot do
        // this - it answers before the chain is ever consulted.
        case "providerScript":
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard bits.count == 2, let i = Int(bits[0]),
                  AIService.shared.providers.indices.contains(i) else { break }
            let id = AIService.shared.providers[i].id
            switch bits[1] {
            case "401":
                AIService.providerClientOverrides[id] =
                    ScriptedProviderClient(outcome: .http(401, "unauthorized"))
            case "ok":
                AIService.providerClientOverrides[id] =
                    ScriptedProviderClient(outcome: .reply("ready"))
            case "clear":
                AIService.providerClientOverrides.removeValue(forKey: id)
            default: break
            }

        case "addStubProvider":
            // "addStubProvider <name> <healthy|broken>"
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            var p = AIProvider(name: bits.first ?? "Stub", kind: .openaiCompatible,
                               endpoint: "https://example.invalid/v1/chat/completions",
                               model: "stub-model")
            p.validatedAt = Date()
            p.health = (bits.count > 1 && bits[1] == "broken") ? .down : .ready
            AIService.shared.addProvider(p, key: "stub")

        // Parses a page's markup the way a fetched page would be parsed, with no
        // network involved - so the test is about the parser, not about a website.
        case "parseTitle":
            lastKitPath = LinkMetadata.parseTitle(from: arg) ?? ""

        case "setPageTitle":
            // "setPageTitle <title>" on the selected item.
            if let item = store.selectedItem { store.update(item.id) { $0.pageTitle = arg } }

        case "addLink":
            // Captures a URL the way the monitor would, so platform detection
            // is exercised through the real code path.
            let item = ClipboardItem(kind: .url, text: arg, sourceAppName: "Probe",
                                     platform: LinkPlatform.detect(arg))
            store.add(item)
            store.select(item.id)

        case "tabVisible":
            // "tabVisible <tabID> <true|false>"
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if bits.count == 2 { TabConfiguration.shared.setVisible(bits[0], bits[1] == "true") }

        case "panelToggleLayout":
            // Exactly what the footer's grid/list button does.
            if var spec = TabConfiguration.shared.spec(for: store.activeTabID) {
                spec.layout = (spec.layout == .gallery) ? .list : .gallery
                TabConfiguration.shared.update(spec)
            }

        case "tabLayout":
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if bits.count == 2, var spec = TabConfiguration.shared.spec(for: bits[0]),
               let layout = TabLayout(rawValue: bits[1]) {
                spec.layout = layout
                TabConfiguration.shared.update(spec)
            }

        case "tabDensity":
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if bits.count == 2, var spec = TabConfiguration.shared.spec(for: bits[0]),
               let density = GalleryDensity(rawValue: bits[1]) {
                spec.density = density
                TabConfiguration.shared.update(spec)
            }

        case "resetTabs": TabConfiguration.shared.resetToDefaults()

        // Runs a string through the real capture classifier and reports what
        // kind it became, with no pasteboard in the way.
        // Runs the real confirmation, so the menu bar can be read back.
        // Does this reply look like a theme, or like a model narrating?
        // "themeSaveDuplicate <preset id>" - the same two calls the pane's
        // Duplicate button makes, so the file round-trip below starts from a
        // theme that was really created the way a user creates one.
        case "themeSaveDuplicate":
            if let preset = AppTheme.presets.first(where: { $0.id == arg }) {
                let copy = CustomTheme.from(preset, name: preset.name)
                    .duplicated(named: CustomTheme.copyName(
                        for: preset.name,
                        existing: CustomThemeStore.shared.themes.map(\.name)))
                CustomThemeStore.shared.save(copy)
            }

        // "themeExport <path>" / "themeExportAll <path>" - writes the SAME
        // bytes the save panel writes (`ThemeFile.data(for:)`), to a path a
        // probe chooses instead of one a person picks.
        case "themeExport", "themeExportAll":
            let themes = verb == "themeExportAll"
                ? CustomThemeStore.shared.themes
                : Array(CustomThemeStore.shared.themes.suffix(1))
            lastThemeFileError = ""
            do { try ThemeFile.data(for: themes).write(to: URL(fileURLWithPath: arg)) }
            catch { lastThemeFileError = error.localizedDescription }

        // "themeImport <path>" - the reader and the adopt step the Restore
        // button runs, error text included.
        case "themeImport":
            lastThemeFileError = ""
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: arg))
                CustomThemeStore.shared.adopt(try ThemeFile.read(data))
            } catch {
                lastThemeFileError = error.localizedDescription
            }

        case "themeRemoveAll":
            for theme in CustomThemeStore.shared.themes {
                CustomThemeStore.shared.remove(theme.id)
            }

        // "themeStuckPreview" - leaves a preview theme behind with no builder
        // window, the state that makes every theme switch look ignored.
        case "themeStuckPreview":
            if let preset = AppTheme.presets.first(where: { $0.id != ThemeManager.shared.themeID }) {
                ThemeManager.shared.previewTheme = preset
            }

        case "themeDropOrphanedPreview":
            ThemeManager.shared.dropOrphanedPreview()

        case "themeAccepts":
            lastKitPath = AIService.looksLikeTheme(arg) ? "yes" : "no"

        case "confirmCopy":
            CopyConfirmation.shared.show(arg)

        // The label a given item would confirm with, without a pasteboard.
        case "confirmLabelFor":
            if let item = store.selectedItem { lastKitPath = item.copyConfirmation(limit: 28) }

        case "captureText":
            lastCapture = ClipboardMonitor.classify(arg, "Probe", "app.clip.probe")
                .map { item -> [String: Any] in
                    ["kind": item.kind.rawValue,
                     "paths": item.filePaths,
                     "role": item.role.rawValue,
                     "language": item.language ?? "",
                     "title": item.title ?? ""]
                } ?? [:]

        case "createItem":
            // "createItem <role> <title>"
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if let role = ItemRole(rawValue: bits.first ?? "") {
                store.createItem(role: role, title: bits.count > 1 ? bits[1] : "Untitled")
            }

        case "setRole":
            if let item = store.selectedItem, let role = ItemRole(rawValue: arg) {
                store.setRole(item.id, to: role)
            }

        // MARK: Performance measurement
        //
        // These drive the same code paths a person does, then report numbers
        // rather than booleans. `perfReset` is separate from the run so a
        // measurement never includes the cost of setting itself up.
        case "saveNow":
            HistoryStore.shared.saveNow()

        case "reloadFromDisk":
            // Throws away everything in memory and reads the database back.
            //
            // This is how persistence gets tested without killing the process:
            // whatever survives a reload is what a real relaunch would find. It
            // is the only honest way to check that a save actually wrote, and
            // that a delete actually deleted.
            HistoryStore.shared.saveNow()
            HistoryStore.shared.reloadFromDisk()

        case "historyLimit":
            // Setting a number means "cap at this", so it turns the cap on.
            // Otherwise every existing probe section that sets a limit would
            // silently be measuring the new unlimited default instead.
            PreferencesModel.shared.historyLimit = Int(arg) ?? 200
            PreferencesModel.shared.historyLimitEnabled = true
            HistoryStore.shared.applyHistoryLimitNow()
        case "historyLimitUnlimited":
            PreferencesModel.shared.historyLimitEnabled = false
        case "resetFilterStageTimings":
            FilterStageTimings.reset()

        case "keyedReply":
            // Feeds one canned model reply through the real parser. Named
            // cases, so a failure says which SHAPE broke rather than "the
            // parser returned nothing".
            let cases: [(String, String)] = [
                ("plain",       #"{"1":"Alpha","2":"Bravo"}"#),
                ("fenced",      #"```json\#n{"1":"Alpha","2":"Bravo"}\#n```"#),
                ("preamble",    #"Sure! Here are the titles:\#n{"1":"Alpha","2":"Bravo"}"#),
                ("numberKeys",  #"{"1": "Alpha", "2": "Bravo"}"#),
                ("intValues",   #"{"1":"Alpha","2":42}"#),
                ("wrapped",     #"{"titles":{"1":"Alpha","2":"Bravo"}}"#),
                ("array",       #"["Alpha","Bravo"]"#),
                ("arrayObjects", #"[{"number":1,"title":"Alpha"},{"number":2,"title":"Bravo"}]"#),
                // The one that produced the bug report: the token limit cut
                // the reply, so it can never parse - but the titles before the
                // cut are perfectly good.
                ("truncated",   #"{"1":"Alpha","2":"Bravo","3":"Charl"#),
                ("numberedList", "1. Alpha\n2. Bravo"),
                ("dottedKeys",  #"{"1.":"Alpha","2.":"Bravo"}"#),
                ("empty",       ""),
                ("prose",       "I am sorry, I cannot help with that."),
            ]
            var report: [String] = []
            for (name, reply) in cases {
                let parsed = KeyedReply.parse(reply)
                let first = parsed["1"] ?? "-"
                report.append("\(name)=\(parsed.count):\(first)")
            }
            lastKeyedReply = report.joined(separator: " ")

        case "batchTokens":
            lastBatchTokens = [1, 8, 40, 200]
                .map { "\($0):\(AIService.batchTokens(for: $0))" }
                .joined(separator: " ")

        case "frontmostApp":
            // "" clears it and the real frontmost application is used again.
            PanelController.frontmostBundleForTesting = arg.isEmpty ? nil : arg

        case "hotkeyDispatchReset": ShortcutManager.shared.resetHotkeyDispatchRecord()
        case "pasteRecordReset":
            TestIsolation.resetPasteRecord()

        case "focusLoss":
            // The unforced path, which is what a real resign-key is.
            PanelController.shared.simulateFocusLoss()

        case "systemDialogSeen":
            // Stands in for the workspace notification that an authorisation
            // dialog took focus. Lets the test drive the case that actually
            // broke: the dialog has already gone by the time the panel is told
            // it lost focus.
            PanelController.shared.markSystemDialogSeenForTesting()

        case "reorderPayload":
            // The plumbing a drag actually uses, end to end: make the provider
            // the drag source makes, then read it the way the drop handler
            // reads it. This is the check that was missing - the old provider
            // inspected perfectly and simply never called its completion, so
            // every test that looked at types or identifiers passed while
            // dragging did nothing at all.
            let id = UUID()
            let provider = ReorderPayload.provider(for: id)
            lastPayloadTypes = provider.registeredTypeIdentifiers.joined(separator: ",")
            lastPayloadResult = "no callback"
            let commandID = lastCommandID
            var answered = false
            ReorderPayload.read([provider]) { got in
                answered = true
                lastPayloadResult = got == id ? "round-trips" : "wrong id \(got)"
                finish(commandID, error: nil)
            }
            // A completion that never fires is precisely the bug, so the test
            // has to have its own deadline rather than waiting for ever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard !answered else { return }
                lastPayloadResult = "no callback"
                finish(commandID, error: nil)
            }
            return false

        case "reorderTo":
            // "reorderTo <from> <before>" - the exact call the drop handler
            // makes, with the collection as drawn. Reordering shipped with no
            // assertions at all, which is how "nothing happens at all" went
            // unnoticed.
            let bits = arg.split(separator: " ").compactMap { Int($0) }
            let list = store.visibleItems
            if bits.count == 2, bits[0] < list.count {
                let dragged = list[bits[0]].id
                let target: UUID? = bits[1] < list.count ? list[bits[1]].id : nil
                store.reorder([dragged], before: target, in: list)
            }

        case "visibleOrder":
            // The order as drawn, so a test can compare before and after
            // rather than trusting a count.
            lastVisibleOrder = store.visibleItems.prefix(12)
                .map { $0.displayTitle }.joined(separator: "|")

        case "manualOrders":
            lastManualOrders = store.visibleItems.prefix(12)
                .map { $0.manualOrder.map(String.init) ?? "-" }.joined(separator: ",")

        // ---- Paste actions
        case "pasteActionsReset":
            PasteActionStore.shared.resetToDefaults()

        case "pasteActionsReload":
            // Proves the arrangement survives a round trip through storage,
            // which reading the in-memory array never can.
            PasteActionStore.shared.reload()

        case "pasteActionEnable":
            // "pasteActionEnable <kind>|<true|false>"
            let bits = arg.split(separator: "|", maxSplits: 1).map(String.init)
            if bits.count == 2,
               let kind = PasteActionKind(rawValue: bits[0]),
               let action = PasteActionStore.shared.actions.first(where: { $0.kind == kind }) {
                PasteActionStore.shared.setEnabled(action.id, bits[1] == "true")
            }

        case "pasteActionOrder":
            // A comma-separated list of kinds, in the wanted order. Anything
            // not named keeps its place after them.
            let wanted = arg.split(separator: ",").compactMap { PasteActionKind(rawValue: String($0)) }
            let store = PasteActionStore.shared
            var reordered: [PasteAction] = []
            for kind in wanted {
                if let action = store.actions.first(where: { $0.kind == kind }) {
                    reordered.append(action)
                }
            }
            reordered += store.actions.filter { action in
                !wanted.contains(action.kind)
            }
            store.replaceAll(reordered)

        case "pasteAddCustom":
            // "pasteAddCustom <title>|<instruction>"
            // `omittingEmptySubsequences: false`, or "|no name at all" arrives
            // as ONE piece and the empty-name case can never be exercised.
            let bits = arg.split(separator: "|", maxSplits: 1,
                                 omittingEmptySubsequences: false).map(String.init)
            lastCustomProblem = bits.count == 2
                ? (PasteActionStore.shared.addCustom(title: bits[0], instruction: bits[1]) ?? "")
                : "bad arguments"

        case "pasteAddLanguage":
            lastLanguageProblem = PasteActionStore.shared.addLanguage(arg) ?? ""

        case "pastePair":
            let bits = arg.split(separator: "|", maxSplits: 1).map(String.init)
            if bits.count == 2 {
                PasteActionStore.shared.setPair(first: bits[0], second: bits[1])
            }

        // ---- The action panel
        case "actionPanelOpen":
            ActionPanelController.shared.open()

        case "actionPanelClose":
            ActionPanelController.shared.close()

        case "actionPanelSource":
            // "clipboard", or an index into the offered clips.
            let model = ActionPanelController.shared.model
            if arg == "clipboard" {
                model.useClipboard()
            } else if let index = Int(arg), model.candidates.indices.contains(index) {
                model.use(model.candidates[index])
            }

        // By TEXT, not position. The monitor files each clipboard write as a
        // clip of its own, so an index read from one snapshot can point at a
        // different item by the time the command runs - which is a race in the
        // test, not a defect in the picker.
        // Reads a secret exactly the way a real request does, so "once per
        // launch" can be COUNTED. The old version of this test called a command
        // that built an instruction string and never touched the Keychain at
        // all, so it passed with the cache removed - a vacuous assertion about
        // the thing it was written to protect.
        case "fullResync":
            let id = lastCommandID
            Task { @MainActor in
                let report = await SyncManager.shared.fullResync()
                lastResyncSummary = report?.summary ?? "no report"
                lastResyncAgrees = report?.agrees ?? false
                finish(id, error: nil)
            }
            return false

        case "tombstoneCount":
            lastTombstoneCount = Database.shared.tombstones().count

        // "local_hasTombstone <id>" - true when a tombstone row exists for
        // that id. M5 REVISED: a local-only item removed by
        // `StartupHealth.run()`'s dangling-image cleanup must leave NO
        // tombstone (the original still lives on whatever Mac really copied
        // it), so this is what S8 checks that against.
        case "local_hasTombstone":
            lastHasTombstone = UUID(uuidString: arg).map { id in
                Database.shared.tombstones().contains { $0.id == id }
            } ?? false

        case "trimNow":
            HistoryStore.shared.trimForTesting()

        // ---- M3: startup health, backups, migrations, the audit ----

        case "healthRun":
            lastHealthFindingsCount = StartupHealth.run().count

        case "setLastRunVersion":
            StartupHealth.versionOverrideForTesting = arg.isEmpty ? nil : arg

        case "setLastRunInstallStamp":
            StartupHealth.installStampOverrideForTesting = arg.isEmpty ? nil : arg

        case "resetIntegrityAlert":
            NoticeCenter.shared.resetIntegrityAlertForTesting()

        // Closes the live connection, overwrites the sandbox file with bytes
        // that are not a SQLite header at all, then reopens through the real
        // `open()` path - so recovery (restore, or staying closed) runs
        // exactly as it would against a real damaged file.
        case "corruptSandboxDatabase":
            Database.shared.closeForTesting()
            let garbage = Data("NOT A SQLITE FILE - GARBAGE BYTES WRITTEN BY THE QA HARNESS".utf8)
            try? garbage.write(to: AppPaths.database)
            Database.shared.reopenForTesting()

        case "writeBackupNow":
            lastBackupPath = Database.shared.snapshotBackup(tag: arg.isEmpty ? "manual" : arg)?.path ?? ""

        case "restoreNewestBackup":
            if let backup = Database.newestBackup() {
                lastRestoreSucceeded = Database.shared.restore(from: backup)
            } else {
                lastRestoreSucceeded = false
            }

        case "forceMigrationFailure":
            Database.forceMigrationFailureForTesting = (arg != "false")

        case "forceReconcileZeroDecodable":
            Database.forceEmptyLoadOnceForTesting = true

        // Points `AppPaths.support` at a path whose PARENT is a plain file
        // rather than a directory, so `createDirectory` fails for a real,
        // provable reason instead of a permissions trick that needs root.
        // Empty argument clears the override.
        case "forceUnwritableDir":
            AppPaths.resetCapturedErrorsForTesting()
            AppPaths.forcedUnwritableParentForTesting = arg.isEmpty ? nil : URL(fileURLWithPath: arg)

        case "auditRun":
            let orphans = AppPaths.audit()
            lastAuditOrphanCount = orphans.count
            lastAuditOrphans = orphans.map {
                ["category": $0.category.rawValue, "reason": $0.reason, "size": $0.size]
            }

        case "reclaimRun":
            lastReclaimPath = AppPaths.reclaim(AppPaths.audit())?.path ?? ""
            lastAuditOrphanCount = AppPaths.audit().count

        case "emptyReclaimed":
            lastEmptyReclaimedCount = AppPaths.emptyReclaimed()

        // Moves every existing backup aside (never deletes), so a probe can
        // set up the "no backup available" branch of the integrity recovery
        // path deterministically instead of hoping earlier sections left
        // none behind.
        case "clearAllBackupsForTesting":
            _ = AppPaths.reclaim(Database.backupCandidates())

        // Removes exactly the sandbox file `corruptSandboxDatabase` wrote
        // garbage into (plus its WAL/SHM companions), then reopens through
        // the real path - standing in for the person picking "Restore
        // backup…" when there was nothing to restore, so later sections get
        // a working database back.
        case "discardCorruptSandboxDatabase":
            let fm = FileManager.default
            for suffix in ["", "-wal", "-shm"] {
                try? fm.removeItem(at: URL(fileURLWithPath: AppPaths.database.path + suffix))
            }
            Database.shared.reopenForTesting()

        case "diagnosticsReportText":
            lastDiagnosticsReportText = DiagnosticsReport.full()

        case "m8_diagnosticsInsights":
            lastInsightLines = DiagnosticsInsights.all().map(\.reportLine)

        case "panelPlacement":
            if let placement = PanelPlacement(rawValue: arg) {
                PreferencesModel.shared.panelPlacement = placement
            }

        case "panelDragTo":
            // Stands in for a corner drag: "x,y".
            let parts = arg.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                PanelController.shared.setOriginForTesting(
                    NSPoint(x: parts[0], y: parts[1]))
            }

        case "readSecret":
            _ = KeychainStore.get(arg.isEmpty ? "probe.secret" : arg)

        case "writeSecret":
            let bits = arg.split(separator: "|", maxSplits: 1,
                                 omittingEmptySubsequences: false).map(String.init)
            if bits.count == 2 { KeychainStore.set(bits[1], for: bits[0]) }

        case "actionPanelSourceMatching":
            let model = ActionPanelController.shared.model
            if let match = model.candidates.first(where: { $0.fullText.contains(arg) }) {
                model.use(match)
            }

        case "actionPanelRun":
            // "actionPanelRun <kind>|<argument>"
            let bits = arg.split(separator: "|", omittingEmptySubsequences: false)
                .map(String.init)
            if let kind = bits.first.flatMap({ PasteActionKind(rawValue: $0) }) {
                let store = PasteActionStore.shared
                let action = store.actions.first { $0.kind == kind } ?? PasteAction(kind)
                ActionPanelController.shared.model.run(
                    action, argument: bits.count > 1 && !bits[1].isEmpty ? bits[1] : nil)
            }

        // Drives the action panel's keyboard navigation through the exact
        // same `ActionPanelModel` methods `ActionPanelView`'s `.onKeyPress`
        // handlers call, gated by the exact same `phase == .choosing` check
        // those handlers make - so this is glue that picks which model
        // method a key means, not a second copy of what any of them decide.
        // "up", "down", "left", "right", "return", "escape".
        case "actionPanelKey":
            let model = ActionPanelController.shared.model
            switch arg {
            case "down":
                guard model.phase == .choosing else { break }
                model.moveFocus(by: 1)
            case "up":
                guard model.phase == .choosing else { break }
                model.moveFocus(by: -1)
            case "right":
                guard model.phase == .choosing else { break }
                _ = model.expandFocusedIfPossible()
            case "left":
                guard model.phase == .choosing else { break }
                _ = model.collapseFocusedIfPossible()
            case "return":
                guard model.phase == .choosing else { break }
                model.activateFocusedRow()
            case "escape":
                // Same one-level-at-a-time rule as the real Escape handler:
                // step out of an open submenu first, only close once there
                // is nothing left to step out of.
                if model.phase == .choosing, model.collapseFocusedIfPossible() { break }
                ActionPanelController.shared.close()
            default: break
            }

        case "actionPanelEdit":
            ActionPanelController.shared.model.draft = arg

        case "actionPanelPaste":
            ActionPanelController.shared.model.paste()

        case "actionPanelCopy":
            ActionPanelController.shared.model.copyToClipboard()

        case "actionPanelRetry":
            ActionPanelController.shared.model.retry()

        case "actionPanelMoveMouse":
            // "actionPanelMoveMouse <x>,<y>" in Cocoa screen coordinates, or
            // an empty arg to park the pointer off in a corner where no
            // button in the panel can be under it. A REAL posted mouseMoved,
            // not a state write - this is what actually drives every
            // `.onHover` in `ActionPanelView.swift`, so the resulting
            // `tooltipTextForProbe` reflects the genuine render path.
            let parts = arg.split(separator: ",").compactMap { Double($0) }
            let point = parts.count == 2 ? NSPoint(x: parts[0], y: parts[1])
                                          : NSPoint(x: 4, y: 4)
            moveMouseHID(to: point)

        case "pasteInstruction":
            // "pasteInstruction <kind>|<argument>" - what the model would be told.
            let bits = arg.split(separator: "|", maxSplits: 1).map(String.init)
            if let kind = bits.first.flatMap({ PasteActionKind(rawValue: $0) }) {
                let store = PasteActionStore.shared
                let action = store.actions.first { $0.kind == kind } ?? PasteAction(kind)
                lastInstruction = store.instruction(
                    for: action, argument: bits.count > 1 ? bits[1] : nil)
            }

        case "pasteRunTitled":
            // Runs a custom action by its menu title, so a test can prove the
            // user's own instruction is what reaches the model.
            if let action = PasteActionStore.shared.actions.first(where: { $0.title == arg }) {
                PasteTransform.shared.run(action, from: .clipboard)
            }

        case "pasteRun":
            // "pasteRun <kind>|<argument>|<selection|clipboard>"
            let bits = arg.split(separator: "|", omittingEmptySubsequences: false)
                .map(String.init)
            if let kind = bits.first.flatMap({ PasteActionKind(rawValue: $0) }) {
                let store = PasteActionStore.shared
                let action = store.actions.first { $0.kind == kind } ?? PasteAction(kind)
                let argument = bits.count > 1 && !bits[1].isEmpty ? bits[1] : nil
                let source: PasteTransform.Source =
                    (bits.count > 2 && bits[2] == "selection") ? .selection : .clipboard
                PasteTransform.shared.run(action, argument: argument, from: source)
            }

        case "pasteTranslateKey":
            PasteActionRunner.translateAndPaste(from: arg == "selection" ? .selection : .clipboard)

        case "pasteboardSet":
            let pb = TestIsolation.board
            pb.clearContents()
            pb.setString(arg, forType: .string)

        // ---- Notices
        case "noticeError":
            NoticeCenter.shared.report(arg, remedy: "Test remedy.")

        case "noticeDismiss":
            NoticeCenter.shared.dismiss()

        case "m22_reportUntilFlag":
            // A persistent notice whose purpose is "the QA flag is on";
            // proves a banner resolves itself when its condition ends.
            m22Flag = true
            NoticeCenter.shared.report("QA condition is on", kind: .persistent, key: "qa.m22",
                                       stillNeeded: { QABridge.m22Flag })
        case "m22_setFlag": m22Flag = (arg == "on")
        case "m22_recheck": NoticeCenter.shared.recheck()
        case "noticeClear":
            NoticeCenter.shared.clear()

        case "noticeRefresh":
            NoticeCenter.shared.refreshInvitation()

        // M1 - N2: stands in for the twelve-second expiry so a probe does not
        // have to sleep through it.
        case "m1NoticeExpireTransients":
            NoticeCenter.shared.expireTransientsForTesting()

        // M1 - N3: a persistent notice whose action flips a QA-visible flag,
        // so "the button runs its closure" can be proved rather than assumed
        // from the button existing.
        case "m1NoticeReportWithAction":
            QABridge.noticeActionRanForTesting = false
            NoticeCenter.shared.report(
                "Test notice with an action.", kind: .persistent,
                key: arg.isEmpty ? "qa.action" : arg,
                action: NoticeCenter.Action(title: "Run test action") {
                    QABridge.noticeActionRanForTesting = true
                })

        case "m1NoticeRunAction":
            NoticeCenter.shared.current?.action?.run()

        // M1 - N4: a real `.integrity` notice, so the once-per-launch alert
        // counter can be driven without waiting for a real storage failure.
        case "m1NoticeIntegrity":
            NoticeCenter.shared.report(arg.isEmpty ? "Test integrity notice." : arg,
                                       kind: .integrity, key: "qa.integrity")

        case "m1NoticeResetIntegrityAlert":
            NoticeCenter.shared.resetIntegrityAlertForTesting()

        // M1 - N5: a real, deliberately invalid write through the database's
        // own queue, proving `.writeFailed` notices come from an actual
        // SQLite failure and not a stubbed path.
        case "m1ForceDatabaseWriteFailure":
            Database.shared.forceWriteFailureForTesting()

        case "m1ResetDatabaseWriteFailureCount":
            Database.shared.resetWriteFailureCountForTesting()

        // M1 - N7: the same action "Copy report" performs, independent of
        // whether the Diagnostics window has actually been built - it is
        // never built under CLIP_HEADLESS=1.
        case "m1DiagnosticsCopyReport":
            let text = DiagnosticsReport.full()
            let pb = TestIsolation.board
            pb.clearContents()
            pb.setString(text, forType: .string)

        case "promoDismissed":
            PreferencesModel.shared.aiPromoDismissed = (arg == "true")
            // Standing in for a fresh install: clearing the flag has to arm the
            // row again, or "a new user sees it" cannot be tested twice in one
            // run. The real app arms it by AI becoming available.
            if arg != "true" { NoticeCenter.shared.armInvitationForTesting() }

        // ---- Shortcut recording modality
        case "recording":
            arg == "on" ? ShortcutRecording.begin() : ShortcutRecording.resetForTesting()

        // Renders the panel to a PNG so the interface can actually be LOOKED
        // at. A tooltip once shipped clipped because every assertion about it
        // passed and nobody opened the picture; screen capture needs a
        // permission this process does not have, but a view can always draw
        // itself into a bitmap.
        case "snapshotPanel":
            if let view = PanelController.shared.panelContentViewForTesting {
                renderLayerToPNG(view, to: arg)
            }

        // NOTE: a "clickAt <x> <y>" command that posted synthetic
        // mouseDown/mouseUp NSEvents (via both `window.sendEvent` and
        // `NSApp.sendEvent`) was tried here and removed - neither reached
        // SwiftUI's gesture recognizers on this non-activating panel (the
        // gear button's own `settingsOpen` never flipped from either).
        // `sendKey` cannot stand in for it either: it calls
        // `KeyRouter.handleForTesting` directly, bypassing SwiftUI's
        // `@FocusState` machinery entirely. There is currently no in-process
        // seam that drives a REAL AppKit click through this panel - see the
        // 5c section of qa-probe.py for what that leaves unverified.

        // M8.4, 02/09: the same technique, aimed at the Settings window
        // instead of the panel - section 137's V6 rendered check needs a
        // real picture of a hovered Settings row to measure a pixel delta
        // against its idle state, and `snapshotPanel` only ever reaches the
        // panel. `arg` is the output path; the caller (qa-probe.py) moves a
        // real `CGEvent` mouse-moved event over the row first (see
        // `m8b_moveMouse`) so AppKit's own `.onHover` has already fired by
        // the time this snapshot is taken. Nothing is captured under
        // CLIP_HEADLESS=1, where `SettingsWindowController.show()` never
        // builds a real window.
        // `m9_describeSheet open|close` - Themes' describe-a-theme sheet, and
        // `m9_snapshotSheet <png>` renders whichever sheet is up.
        case "m9_describeSheet":
            SettingsProbe.themeDescribeOpen = (arg == "open")
            if arg == "open" { SettingsWindowController.shared.show(tab: .themes) }
        case "m9_snapshotSheet":
            if let sheet = NSApp.windows.first(where: { $0.isSheet && $0.isVisible }),
               let view = sheet.contentView {
                view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: arg))
                    }
                }
            }
        case "m8b_snapshotSettings":
            if let view = SettingsWindowController.shared.contentViewForTesting {
                renderLayerToPNG(view, to: arg)
            }

        // M14: `renderLayerToPNG`'s `layer.render(in:)` draws the CALayer
        // tree directly, which does not reliably reproduce an NSScrollView's
        // own clipped/scrolled content (a documented CoreAnimation
        // limitation, not a settle-timing issue - verified by comparing a
        // real `screencapture` of the on-screen hub, which renders
        // perfectly, against `m8b_snapshotSettings`'s own output, which came
        // back blank). `SettingsHub` is the first Settings surface built on
        // a raw `ScrollView` rather than `Form`/`List` - a new command
        // instead of changing `renderLayerToPNG` itself, which every
        // existing rendered check already depends on at an established,
        // verified pixel fidelity. `cacheDisplay(in:to:)` goes through
        // AppKit's real `-drawRect:` pipeline instead, which handles
        // scrolled/clipped content correctly.
        case "m14_snapshotSettings":
            if let view = SettingsWindowController.shared.contentViewForTesting {
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: arg))
                    }
                }
            }

        // M8.4, 02/09: see SettingsHoverTestForce's doc comment - forces
        // every `.settingsHover()`-wrapped view's tint on (or back off)
        // without a synthesized mouse event.
        case "m8b_settingsWindowNumber":
            // The window's own id, so a probe can capture THIS window with
            // `screencapture -l` even when something else is in front of it.
            // A full-screen capture measures whatever is frontmost, which for
            // an agent app driven from a terminal is the terminal: one run
            // reported the terminal's own text as a hover wash.
            settingsWindowNumber = NSApp.windows
                .first { $0.title == "Clip Settings" }?.windowNumber ?? 0

        case "m8b_forceSettingsHover":
            SettingsHoverTestForce.shared.isForced = (arg == "true")

        case "perfReset":
            Perf.reset()

        case "derivationAudit":
            // Proves the visible-list cache never returns a stale list.
            //
            // The shape of this check is the whole point. Each dimension is
            // stepped through with EVERY OTHER dimension held fixed, and the
            // cached read is compared against a fresh computation after each
            // step. If the cache key were missing that dimension, the cached
            // read would still be holding the previous step's list while the
            // fresh computation returned the correct one, and they would
            // disagree.
            //
            // The first version of this check varied two dimensions at once.
            // Removing the sort order from the key on purpose did not fail it,
            // because the query was changing on every iteration too, so the key
            // differed regardless and the cache never got the chance to be
            // stale. A check that cannot fail is not evidence, and that one
            // could not.
            var disagreements: [String] = []
            var combos = 0

            func compareNow(_ label: String) {
                combos += 1
                let cached = store.visibleItems.map(\.id)
                let fresh = store.computeVisibleItems().map(\.id)
                if cached != fresh {
                    // Say HOW they differ. Reporting only the counts made a
                    // reordering read as "211 vs 211", which looks like a
                    // passing check that printed itself by mistake.
                    let how = cached.count == fresh.count ? "same items, different order"
                                                          : "\(cached.count) vs \(fresh.count) items"
                    disagreements.append("\(label): \(how)")
                }
            }

            let savedTab = store.activeTabID
            let savedQuery = store.query
            let savedSort = store.sortOrder
            let savedMode = store.searchMode
            let savedFilters = store.activeFilters
            let savedTime = store.timeFilter

            // One dimension at a time, everything else fixed.
            for tab in TabConfiguration.shared.visible.map(\.id) {
                store.activeTabID = tab
                compareNow("tab=\(tab)")
            }
            store.activeTabID = "all"

            for sort in SortOrder.allCases {
                store.sortOrder = sort
                compareNow("sort=\(sort.rawValue)")
            }
            store.sortOrder = savedSort

            for q in ["", "a", "design", "e", "#tag", ""] {
                store.query = q
                compareNow("query=\(q.isEmpty ? "(empty)" : q)")
            }
            store.query = ""

            for mode in SearchMode.allCases {
                store.searchMode = mode
                store.query = "e"
                compareNow("mode=\(mode.rawValue)")
                store.query = "e"     // unchanged, so only the mode moved
            }
            store.query = ""
            store.searchMode = savedMode

            for time in TimeFilter.presets {
                store.timeFilter = time
                compareNow("time=\(time.title)")
            }
            store.timeFilter = savedTime

            let categories: [ItemCategory] = ItemKind.allCases.prefix(5).map { .kind($0) }
                + ItemRole.allCases.prefix(3).map { .role($0) }
            for category in categories {
                store.activeFilters = [category]
                compareNow("filter=\(category.id)")
            }
            store.activeFilters = savedFilters

            // Content and pins, which change the answer without changing a
            // setting.
            if let first = store.visibleItems.first {
                store.togglePin(first.id)
                compareNow("afterPin")
                store.togglePin(first.id)
                compareNow("afterUnpin")
            }
            store.add(ItemClassifier.item(fromText: "derivation audit probe item",
                                          sourceAppName: "Probe"))
            compareNow("afterAdd")
            if let added = store.items.first(where: { $0.fullText == "derivation audit probe item" }) {
                store.delete(added.id, recordDeletion: false)
            }
            compareNow("afterDelete")

            // Selection must NOT invalidate: that is the waste this cache
            // exists to remove, so it is asserted rather than assumed.
            _ = store.visibleItems
            let runsBefore = Perf.visibleItemsRuns
            for _ in 0..<10 { store.moveSelection(by: 1) }
            _ = store.visibleItems
            let wasted = Perf.visibleItemsRuns - runsBefore

            store.activeTabID = savedTab
            store.query = savedQuery
            lastDerivationAudit = "\(combos) steps, "
                + (disagreements.isEmpty ? "all agree" : disagreements.prefix(6).joined(separator: "; "))
                + ", selection caused \(wasted) recomputations"

        case "paletteAudit":
            // Proves the cache did not change any color.
            //
            // For every preset and every stored custom theme, the resolved
            // palette is compared against the same theme with no palette, which
            // falls back to computing each color the original way. These are
            // genuinely two different code paths, so agreement is evidence
            // rather than a tautology. Any disagreement is named, with both
            // values, instead of being reported as a count.
            var mismatches: [String] = []
            var checked = 0
            var themes = AppTheme.presets
            themes.append(contentsOf: CustomThemeStore.shared.themes.map(\.appTheme))
            for raw in themes {
                var plain = raw
                plain.palette = nil
                let ready = raw.prepared()
                func compare(_ label: String, _ a: Color, _ b: Color) {
                    checked += 1
                    if a.hexString != b.hexString {
                        mismatches.append("\(raw.id).\(label) \(a.hexString) vs \(b.hexString)")
                    }
                }
                compare("interaction", plain.interaction, ready.interaction)
                compare("hoverStroke", plain.hoverStroke, ready.hoverStroke)
                compare("selectionStroke", plain.selectionStroke, ready.selectionStroke)
                compare("focusRing", plain.focusRing, ready.focusRing)
                compare("actionHoverFill", plain.actionHoverFill, ready.actionHoverFill)
                compare("tabHoverFill", plain.tabHoverFill, ready.tabHoverFill)
                compare("destructive", plain.destructive, ready.destructive)
                compare("success", plain.success, ready.success)
                compare("warning", plain.warning, ready.warning)
                compare("onAccent", plain.onAccent, ready.onAccent)
                // M10: `accentText(on:)`, `text(on:)`, `secondaryText(on:)`,
                // `tertiaryText(on:)` and the default-icon chip gained the
                // same palette-table fast path `tint(for:on:)` already had,
                // for the same measured reason (each was a fresh
                // `Color` -> `NSColor` -> hex round trip per row, per
                // render). Audited exactly like `tint` above: two genuinely
                // different code paths compared per ground, per kind.
                for ground in ResolvedPalette.grounds(of: raw) {
                    compare("accentText@\(ground.hexString)",
                            plain.accentText(on: ground), ready.accentText(on: ground))
                    compare("text@\(ground.hexString)",
                            plain.text(on: ground), ready.text(on: ground))
                    compare("secondaryText@\(ground.hexString)",
                            plain.secondaryText(on: ground), ready.secondaryText(on: ground))
                    compare("tertiaryText@\(ground.hexString)",
                            plain.tertiaryText(on: ground), ready.tertiaryText(on: ground))
                    for kind in ItemKind.allCases {
                        compare("tint.\(kind.rawValue)",
                                plain.tint(for: kind, on: ground),
                                ready.tint(for: kind, on: ground))
                        let plainChip = plain.chipColors(for: kind, on: ground)
                        let readyChip = ready.chipColors(for: kind, on: ground)
                        compare("chip.\(kind.rawValue).fill@\(ground.hexString)", plainChip.fill, readyChip.fill)
                        compare("chip.\(kind.rawValue).fg@\(ground.hexString)", plainChip.foreground, readyChip.foreground)
                    }
                }
                let plainAccentChip = plain.accentChipOnCard
                let readyAccentChip = ready.accentChipOnCard
                compare("accentChipOnCard.fill", plainAccentChip.fill, readyAccentChip.fill)
                compare("accentChipOnCard.fg", plainAccentChip.foreground, readyAccentChip.foreground)
            }
            lastPaletteAudit = "\(themes.count) themes, \(checked) colors, "
                + (mismatches.isEmpty ? "identical" : mismatches.prefix(8).joined(separator: "; "))

        case "perfType":
            // One character at a time, reading the list after each, because
            // that is what the view does. Typing the whole string at once
            // measures a case that never happens.
            var typed = ""
            for ch in arg {
                typed.append(ch)
                store.query = typed
                _ = store.visibleItems.count
            }
            store.query = ""

        case "perfNavigate":
            // Arrow-key movement changes only the selection. Any pipeline run
            // counted here is work the app did not need to do.
            for _ in 0..<(Int(arg) ?? 10) { store.moveSelection(by: 1) }

        case "perfTabCycle":
            for _ in 0..<(Int(arg) ?? 8) {
                store.cycleTab(forward: true)
                _ = store.visibleItems.count
            }

        case "perfReadList":
            // Reads the list `arg` times, the way repeated body evaluations do.
            //
            // `store.visibleItems` cannot be used here: it is memoized on the
            // derivation key, which this loop never changes, so only the
            // FIRST call ever did any work and every one after it was a
            // dictionary lookup - measured, that reported no timing at any
            // item count, not because reads are free but because the metric
            // was answering a question nobody asked ("what does a cache hit
            // cost"). `perfMeasuredRead()` always does the real computation,
            // the way a cache MISS would - an item added, a keystroke, a tab
            // switch - which is the case this metric exists to bound, without
            // touching `visibleItems`'s own cache for anything else that
            // reads it afterward.
            for _ in 0..<(Int(arg) ?? 100) { store.perfMeasuredRead() }

        case "perfTheme":
            // Every derived color, the number of times a full list of rows
            // would ask for them.
            //
            // Timed INSIDE the app. Timing it from the probe measured the
            // command bridge as well: a fixed ~130 ms of acknowledgement
            // latency sat inside every reading, which made a real 2x look
            // like 1.3x.
            //
            // The theme is re-read per row on purpose. Views do exactly that,
            // and `ThemeManager.theme` was itself rebuilding the whole theme on
            // every read, so hoisting it out of the loop would measure a case
            // the app never runs.
            for _ in 0..<(Int(arg) ?? 200) {
                Perf.measure("rowColors") {
                    let theme = ThemeManager.shared.theme
                    _ = theme.destructive; _ = theme.success; _ = theme.warning
                    _ = theme.hoverStroke; _ = theme.selectionStroke
                    _ = theme.focusRing; _ = theme.actionHoverFill; _ = theme.tabHoverFill
                    _ = theme.interaction; _ = theme.onAccent
                    _ = theme.tint(for: .code, on: theme.cardBackground)
                }
            }

        case "perfDateLabels":
            // What scrolling a list of rows costs in date formatting alone.
            for _ in 0..<(Int(arg) ?? 5) {
                for item in store.items {
                    Perf.measure("dateLabel") { _ = item.dateLabel }
                }
            }

        // ---- Delete with undo. `deleteRow` goes through the same seam every
        // way a person deletes uses (⌥⌫, the row action, the context menu), so
        // a test exercises the undo window rather than the raw destroyer.
        case "deleteRow":
            if let id = UUID(uuidString: arg) {
                store.deleteKeepingSelection(id)
            } else if let item = store.selectedItem ?? store.visibleItems.first {
                store.deleteKeepingSelection(item.id)
            }
        // Settings' own light/dark choice: "automatic", "light" or "dark".
        case "settingsAppearance":
            if let a = ThemeManager.SettingsAppearance(rawValue: arg) {
                ThemeManager.shared.settingsAppearance = a
            }
        case "undoDelete":   store.undoPendingDelete()
        case "commitDelete": store.commitPendingDelete()

        case "seed":     seed(Int(arg) ?? 20)
        // A test reset, not a user action: it must not tell the server to
        // delete everything the next time the probe connects a token.
        case "clear":    store.clearAll(recordDeletions: false)

        // The user-facing "Clear Everything", which *does* propagate.
        case "clearAndPropagate": store.clearAll()

        // ---- M4: the 25 silent paths, each proved red before it was fixed

        // Row 3: deletes the media file backing the item at visible index
        // `arg`, so `ClipboardWriter.write` sees a missing image.
        case "removeMediaFileOf":
            if let i = Int(arg), let item = store.item(atVisibleIndex: i), let f = item.imageFile,
               let url = MediaStore.shared.url(for: f) {
                try? FileManager.default.removeItem(at: url)
            }

        // Row 4: drives the real image reader directly against a real PNG on
        // the pasteboard, so a save failure is provable synchronously rather
        // than waiting on the poll timer.
        case "captureImageNow":
            let pb = TestIsolation.board
            pb.clearContents()
            if let png = Self.onePixelPNG() { pb.setData(png, forType: .png) }
            if let item = ClipboardMonitor.shared.testCaptureImage(pb) {
                store.add(item)
                QABridge.lastImageCaptureSucceeded = true
            } else {
                QABridge.lastImageCaptureSucceeded = false
            }

        case "makeMediaDirReadOnly":
            try? FileManager.default.setAttributes([.posixPermissions: 0o500],
                                                    ofItemAtPath: MediaStore.shared.mediaDir.path)

        case "restoreMediaDir":
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                    ofItemAtPath: MediaStore.shared.mediaDir.path)
            MediaStore.shared.resetSaveFailureReportForTesting()

        // Row 5/6: registers a REAL Carbon hotkey outside ShortcutManager, on
        // a different signature/id, so the manager's own attempt to register
        // the identical combination is genuinely refused by the OS - not
        // simulated - the way "another app already owns this key" happens
        // for a real user.
        case "registerConflictingGlobal":
            lastKitPath = Self.registerConflictingGlobal(arg) ? "registered" : "refused"
        case "unregisterConflictingGlobal":
            Self.unregisterConflictingGlobal()

        // Row 13: makes one item's media file immutable, so removing it
        // fails even though the containing directory stays writable -
        // distinct from `makeMediaDirReadOnly` above, which blocks writes to
        // the whole folder rather than one already-written file.
        case "lockMediaFileOf":
            if let i = Int(arg), let item = store.item(atVisibleIndex: i), let f = item.imageFile,
               let url = MediaStore.shared.url(for: f) {
                try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
            }
        case "unlockMediaFileOf":
            if let i = Int(arg), let item = store.item(atVisibleIndex: i), let f = item.imageFile,
               let url = MediaStore.shared.url(for: f) {
                try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
            }
        case "resetMediaResidue":
            MediaStore.shared.resetResidueForTesting()

        // Drives `MediaStore.delete` directly on the item's own media file,
        // WITHOUT deleting the clipboard item itself - so a locked file can
        // be unlocked and cleaned up afterward through the very same index.
        case "deleteMediaFileOf":
            if let i = Int(arg), let item = store.item(atVisibleIndex: i) {
                QABridge.lastMediaDeleteSucceeded = MediaStore.shared.delete(item.imageFile)
            }

        // Row 15/16: drives `ExportPane.apply`/`writeQuietly` directly at a
        // path on disk, bypassing the open/save panels a headless run cannot
        // drive.
        case "importFixture":
            if let data = try? Data(contentsOf: URL(fileURLWithPath: arg)),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let outcome = ExportPane.apply(root, into: store, importSettings: false)
                QABridge.lastExportImportOutcome = outcome.summary
                QABridge.lastExportImportUnreadable = outcome.unreadable
            } else {
                QABridge.lastExportImportOutcome = ""
                QABridge.lastExportImportUnreadable = -1
            }

        // Writes every CURRENT item through the real export encoder, plus one
        // row that cannot decode, to `arg` - a fixture for `importFixture`
        // that does not require hand-building `ClipboardItem`'s JSON shape
        // from outside Swift.
        case "writeCorruptImportFixture":
            // `ClipboardItem`'s decoder is deliberately forgiving - almost
            // every field falls back to a default when ABSENT, so a row
            // that is merely incomplete (e.g. `{}`) still decodes fine. A
            // type MISMATCH on a field that has no `try?` around it is the
            // one thing `decodeIfPresent` does not forgive: the key is
            // present, but "isPinned" holding a string instead of a bool
            // throws instead of defaulting.
            let corrupt: [String: Any] = ["id": UUID().uuidString, "isPinned": "not-a-boolean"]
            let dicts = store.items.map(ExportPane.dictionary) + [corrupt]
            let root: [String: Any] = ["application": "Clip", "clips": dicts]
            if let data = try? JSONSerialization.data(withJSONObject: root) {
                try? data.write(to: URL(fileURLWithPath: arg))
            }

        case "exportWriteFixture":
            let url = URL(fileURLWithPath: arg)
            QABridge.lastExportImportOutcome =
                ExportPane.writeQuietly(["application": "Clip", "clips": []], to: url) ?? "ok"

        // Row 18: exercises the real fallback-and-notice path with a
        // deliberately bogus application path standing in for one that was
        // uninstalled after the target list was built.
        case "openLinkWithMissingApp":
            if let item = store.selectedItem {
                let id = lastCommandID
                let bogus = OpenTarget(id: "/Applications/Definitely Not Installed.app",
                                       name: "Definitely Not Installed", isDefault: false, isNative: false)
                LinkOpener.open(item, with: bogus)
                // The fallback-and-notice runs inside NSWorkspace's own
                // completion handler, not synchronously - acknowledge once
                // it has had time to land, so the probe reads the real
                // outcome rather than a snapshot taken before it fired.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    acknowledged = id
                    writeState()
                }
                return false
            }

        // Row 25: exercises the real quit path without exiting the process,
        // and the real launch-time recovery check without relaunching it.
        case "forceSaveFailure":
            HistoryStore.forceNextSaveFailureForTesting = true
        case "clearForcedSaveFailure":
            HistoryStore.forceNextSaveFailureForTesting = false
        case "quitSimulation":
            AppDelegate.shared?.applicationWillTerminate(
                Notification(name: NSApplication.willTerminateNotification))
            // Undoes the `ClipboardMonitor.shared.stop()` the real quit path
            // takes, so later sections in the same run still see captures.
            ClipboardMonitor.shared.start()
        case "checkUnsavedSnapshot":
            AppDelegate.checkForUnsavedSnapshot()
        // ---- M2: the AI key and the sync token repair themselves ----
        // Added at the end of the switch, deliberately, so lanes working on
        // the same file's earlier cases in parallel do not collide here.

        // "simulateKeychainStatus <account> <OSStatus>" - forces the next
        // read for that account to fail with exactly this status, without
        // ever touching the real Keychain (see `TestIsolation`, which this
        // deliberately reads past). Status 0 clears the simulation, standing
        // in for "the underlying problem went away".
        case "simulateKeychainStatus":
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if bits.count == 2, let raw = Int32(bits[1]) {
                if raw == 0 { KeychainStore.clearSimulatedStatusForTesting(bits[0]) }
                else { KeychainStore.simulateStatusForTesting(OSStatus(raw), for: bits[0]) }
            }

        // Forces the very next read-back after a write to look like it did
        // not really take - proves a repair counts a VERIFIED read, not an
        // attempt.
        case "forceReadBackFailure":
            KeychainStore.forceNextReadBackFailureForTesting = true

        // "repairKeychain [account]" - empty repairs every account this
        // launch has seen fail; named repairs just that one.
        case "repairKeychain":
            let id = lastCommandID
            Task { @MainActor in
                let result = await KeychainStore.selfRepair(reason: "probe",
                                                            accounts: arg.isEmpty ? [] : [arg])
                lastRepairResult = result
                // One more hop than `finish` needs on its own: `selfRepair`
                // schedules its own notice work via `DispatchQueue.main.async`
                // while it runs, and finishing on the same turn would let the
                // probe read state a beat before that lands. Queuing behind
                // it, on the same queue, is what makes the order guaranteed
                // rather than merely likely.
                DispatchQueue.main.async { finish(id, error: nil) }
            }
            return false

        // Writes one row into `aiProviders` that cannot decode, alongside
        // whatever connections are already there, then reloads - the same
        // path a real launch takes. See K7.
        case "quarantineProviderRow":
            AIService.shared.quarantineRowForTesting()

        // A separate, explicit action from disconnecting - see
        // `SyncManager.forgetTokenOnThisMac`.
        case "forgetToken":
            SyncManager.shared.forgetTokenOnThisMac()

        // Forces exactly one `KeychainStore.set` to fail, so K2 can prove a
        // caller actually checks the status instead of assuming success.
        case "simulateKeychainSetFailure":
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if bits.count == 2, let raw = Int32(bits[1]) {
                KeychainStore.simulatedSetStatus[bits[0]] = OSStatus(raw)
            }

        // "aiDiagnosisHTTP <code>" - reads `AIDiagnosis.read` directly for an
        // HTTP status, with no network and no provider needed. K6.
        case "aiDiagnosisHTTP":
            lastKitPath = AIDiagnosis.read(AIError.http(Int(arg) ?? 0, "")).message

        // Calls the interactive repair path DIRECTLY - never through the
        // notice action or the menu item, both of which end in a real
        // `NSAlert().runModal()` with nobody there to click it, which hangs
        // this harness forever under CLIP_HEADLESS. `repairAccess` itself is
        // safe to call under test: its own first real step is
        // `guard !TestIsolation.isActive`, and the interactive-repair
        // counter increments before that guard either way - so this proves
        // the counter genuinely CAN move (K5c) without opening anything.
        case "directRepairAccess":
            _ = KeychainStore.repairAccess()

        // Runs the same continuity check a real launch runs once, so K9 can
        // exercise it more than the one time an app actually launches.
        case "checkTokenContinuity":
            let id = lastCommandID
            Task { @MainActor in
                await SyncManager.shared.checkTokenContinuityAtLaunch()
                DispatchQueue.main.async { finish(id, error: nil) }
            }
            return false

        // ---- M8: first-run overview, menu hygiene, credential explainer ----

        // Standing in for a fresh launch: without this, section 137 could
        // only ever see the overview on the very first `open` this process
        // ever makes, which every earlier section has already consumed.
        case "m8_resetFirstOpenOverview":
            SetupOverviewCoordinator.shared.resetForTesting()

        // The launch-scoped Dismiss - proves it hides the overview without
        // touching the conditions themselves (V2).
        case "m8_dismissOverview":
            SetupOverviewCoordinator.shared.dismiss()

        // "m8_forceCredentialAnswer continue|cancel|nil" - stands in for a
        // person clicking Continue or Not now on a real `NSAlert`, which a
        // headless run can never click for itself.
        case "m8_forceCredentialAnswer":
            switch arg {
            case "continue": CredentialExplainer.forcedAnswer = true
            case "cancel":   CredentialExplainer.forcedAnswer = false
            default:         CredentialExplainer.forcedAnswer = nil
            }

        case "m8_resetCredentialExplainer":
            CredentialExplainer.resetForTesting()
            AppDelegate.resetRepairOutcomeForTesting()

        // "m27_clickStatusMenuItem <title>" - fires the exact row's real
        // action through NSApp.sendAction(_:to:from:), the same dispatch a
        // real click uses. Deliberately not part of any full-suite section:
        // clicking "Quit Clip" ends the process this probe is driving, and
        // does not return to write an ack, so a manual one-off check polls
        // for the process to exit instead of waiting on the state file.
        case "m27_clickStatusMenuItem":
            AppDelegate.clickStatusMenuItemForTesting(title: arg)

        // Calls the REAL, gated entry point and awaits it directly - proves
        // the gate itself blocks or allows the repair, unlike
        // `directRepairAccess` above (which deliberately bypasses
        // everything this gate exists to enforce). Awaited rather than
        // fired-and-forgotten like the `@objc` method does, so the ack this
        // command writes - and the state snapshot a probe reads right after
        // - reflects the repair having actually run, not merely started.
        case "m8_repairKeychainAccess":
            let id = lastCommandID
            Task { @MainActor in
                _ = await AppDelegate.shared?.repairKeychainAccessAsync()
                finish(id, error: nil)
            }
            return false

        // ---- M28: recovering the connections a reinstall lost ----

        // The launch-time offer, run on demand. Exactly the call
        // `StartupHealth.run()` makes on the next main-loop turn, so what a
        // probe drives is the shipped path and not a copy of it.
        case "m28_offerKeyRecovery":
            KeyRecovery.offerIfNeeded()

        // The REAL recovery, gate included, awaited so the ack is written
        // after it has finished rather than after it has started.
        // `CredentialExplainer.forcedAnswer` decides whether the gate says
        // yes, which is how a refusal is provable without a dialog nobody
        // can click.
        case "m28_recoverKeys":
            let id = lastCommandID
            Task { @MainActor in
                _ = await KeyRecovery.recover()
                DispatchQueue.main.async { finish(id, error: nil) }
            }
            return false

        // "m28_forceCredentialAnswer <allow|deny|reset>" - what the
        // explanation dialog answers next time, so a cancelled or refused
        // authorisation is a real path through the real gate.
        case "m28_forceCredentialAnswer":
            switch arg {
            case "allow": CredentialExplainer.forcedAnswer = true
            case "deny":  CredentialExplainer.forcedAnswer = false
            default:      CredentialExplainer.forcedAnswer = nil
            }

        // Resets this milestone's own counters and nothing else. Deliberately
        // NOT `CredentialExplainer.resetForTesting()`, which would also empty
        // `invocationsForTesting` - a list other sections read cumulatively,
        // and one this section only ever inspects the tail of. A teardown
        // that clears another section's evidence is how a suite starts
        // depending on the order it happens to run in.
        case "m28_resetRecovery":
            KeyRecovery.resetForTesting()
            CredentialExplainer.forcedAnswer = nil

        // A reinstall, staged: the app's record of its connections goes, the
        // store keeps every key. Deliberately NOT `clearProviders`, which
        // routes through `removeProvider` and takes each secret with it -
        // that is a person deleting a connection, which is the opposite of
        // what happens when a database is thrown away. This drops the rows
        // the way losing `clip.sqlite` does, and touches no secret at all.
        case "m28_forgetProvidersKeepingKeys":
            Database.shared.setPreference("aiProviders", "")
            AIService.shared.reloadProvidersForTesting()
            AIService.providerClientOverrides.removeAll()

        // ---- M15: Getting Started checklist ----

        // "m15_markDone <id> <true|false>" - the same call the card's own
        // "Mark as done"/"Mark as not done" ClipLink makes.
        // M9: "diagnosticsCopyFullReport" - the exact call
        // `SettingsDiagnosticsPane`'s "Copy full report" link makes
        // (`DiagnosticsReport.full()` then `TestIsolation.board`), for a
        // probe to prove that single button actually produces the whole
        // report on the pasteboard, without a synthetic click reaching a
        // SwiftUI `Button` (no such path exists on this panel - see the
        // note beside `snapshotPanel` above).
        case "diagnosticsCopyFullReport":
            let text = DiagnosticsReport.full()
            let pb = TestIsolation.board
            pb.clearContents()
            pb.setString(text, forType: .string)
            lastDiagnosticsFullReportLength = text.count

        case "fixtureCreateFiles":
            let support = AppPaths.support
            let fixtureDir = support.appendingPathComponent("fixtures", isDirectory: true)
            try? FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)

            let fileURL = fixtureDir.appendingPathComponent("file-fixture.txt")
            let folderURL = fixtureDir.appendingPathComponent("folder-fixture", isDirectory: true)
            try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

            let dummyContent = "fixture file content\n"
            try? dummyContent.write(to: fileURL, atomically: true, encoding: .utf8)

            let fileItem = ClipboardItem(kind: .file,
                                         text: fileURL.path,
                                         filePaths: [fileURL.path],
                                         sourceAppName: "Finder",
                                         title: fileURL.lastPathComponent)
            store.addExisting(fileItem)
            lastCreatedFixtureFileID = fileItem.id.uuidString
            lastCreatedFixtureFilePath = fileURL.path

            let folderItem = ClipboardItem(kind: .folder,
                                           text: folderURL.path,
                                           filePaths: [folderURL.path],
                                           sourceAppName: "Finder",
                                           title: folderURL.lastPathComponent)
            store.addExisting(folderItem)
            lastCreatedFixtureFolderID = folderItem.id.uuidString
            lastCreatedFixtureFolderPath = folderURL.path

        case "fixtureCreateStaleFile":
            let stalePath = "/tmp/clip-qa-stale-\(UUID().uuidString).txt"
            let item = ClipboardItem(kind: .file, text: stalePath, filePaths: [stalePath])
            store.addExisting(item)
            lastCreatedFixtureFileID = item.id.uuidString
            lastCreatedFixtureFilePath = stalePath

        case "activatePrimary":
            let parts = arg.components(separatedBy: " ").filter { !$0.isEmpty }
            guard let idString = parts.first, let id = UUID(uuidString: idString),
                  let item = store.item(id) else {
                lastPrimaryActivationOutcome = "unavailable"
                break
            }
            let presentationString = parts.count > 1 ? parts[1] : "historyList"
            let presentation = PrimaryActivationPresentation(rawValue: presentationString) ?? .historyList
            let outcome = store.activatePrimary(item, presentation: presentation)
            lastPrimaryActivationOutcome = outcome.rawValue

        case "m15_markDone":
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if bits.count == 2 { SetupChecklist.shared.setManual(bits[0], done: bits[1] == "true") }

        // Runs the named step's own deep link - the exact closure its
        // action button calls. Step 1's is gated against the real system
        // prompt under `QABridge.isEnabled` (see `SetupChecklist.swift`),
        // so this is safe to call for every step under an automated run.
        case "m15_openStep":
            SetupChecklist.shared.step(arg)?.deepLink()

        case "m15_reset":
            SetupChecklist.shared.resetForTesting()

        // ---- M19: "Inspect element" in the theme builder ----
        //
        // "m19_inspect on|off" - the same call the builder header's own
        // scope-icon toggle makes (`ThemeInspectController.toggle`/
        // `setOn`), headless-safe: `ThemeInspectController.setOn` no-ops
        // its own overlay-window half when there is no real panel window
        // (`PanelController.panelWindowForInspect` is `nil` headless), but
        // `ThemeInspectRegistry.isInspecting` still flips either way, which
        // is what `.themeTokens` itself reads.
        case "m19_inspect":
            ThemeInspectController.shared.setOn(arg == "on")

        // "m19_hover <x> <y>" - the SAME call the overlay's own
        // `mouseMoved` makes (`ThemeInspectRegistry.hover(at:)`), given a
        // panel-local point directly rather than a synthesized NSEvent, so
        // this runs identically headless or not. The point is in the
        // registry's own coordinate space - top-left origin, y-down, the
        // same convention `ThemeTokenTaggingModifier`'s frames and a real
        // flipped `NSHostingView` both already use.
        case "m19_hover":
            let bits = arg.split(separator: " ").map(String.init)
            if bits.count == 2, let x = Double(bits[0]), let y = Double(bits[1]) {
                ThemeInspectRegistry.shared.hover(at: CGPoint(x: x, y: y))
            }

        // "m19_click" - the SAME call the overlay's own `mouseDown` makes
        // (`ThemeInspectRegistry.selectHovered()`), acting on whatever the
        // last `m19_hover` found. Deliberately does NOT touch
        // `HistoryStore` in any way - the swallow the real overlay window
        // performs at the AppKit event layer (a click never reaches the
        // panel while it is frontmost) has no downstream call to mirror
        // here, which is exactly the behaviour section 146 proves: an
        // item's `useCount` cannot move from this command.
        case "m19_click":
            ThemeInspectRegistry.shared.selectHovered()

        // "m19_renderOverlay <path>" - renders the real Inspect overlay
        // view (whatever it last drew: the accent outline + token label, or
        // "no theme token here") to a PNG, the same `renderLayerToPNG`
        // every other rendered-check command already uses. Empty/no-op
        // with no overlay open (headless, or Inspect never turned on).
        case "m19_renderOverlay":
            if let view = ThemeInspectController.shared.overlayViewForProbe {
                view.needsDisplay = true
                renderLayerToPNG(view, to: arg)
            }

        // ---- REAL INPUT (M23). See "TWO INPUT PATHS" at the top of this
        // file. Nothing in this group calls a handler; each posts an event and
        // lets the app receive it. They are asynchronous by nature - an event
        // posted to the window server comes back on a later run-loop turn, so
        // acknowledging at the usual 0.12s would read the state before the app
        // had processed its own keystroke and report every one of them as
        // dead. `realSettle` is the one number that has to be generous here.

        case "real_activate":
            installRealMonitor()
            let activateID = lastCommandID
            whenActive {
                acknowledged = activateID
                writeState()
            }
            return false

        // "real_hold true|false" - stop an AMBIENT focus change from
        // dismissing the panel for the length of a real-input sequence.
        //
        // Not a convenience. Something on this Mac takes focus back roughly
        // every two to four seconds (measured), the panel is designed to
        // dismiss when it loses key, and a ten-step sequence takes longer than
        // that - so the overlay under test vanished mid-run and the failure got
        // reported against the keyboard code. This is the same exemption
        // `windowDidResignKey` already makes under CLIP_HEADLESS, for the same
        // stated reason, and it is just as narrow: only the ambient path is
        // held. Every explicit dismissal (`clickOutside`, `simulateResignKey`,
        // a real click outside the panel) still runs, so click-outside-to-
        // dismiss keeps its own coverage.
        case "real_hold":
            realInputHoldsPanel = (arg == "true")

        // "real_afterDetailClose <key>" - closes the detail overlay and posts
        // ONE real key while the overlay's text view is still the window's
        // first responder. This is RT-2's actual trigger, and nothing else in
        // this harness can reach it.
        //
        // Why it has to be one command. SwiftUI removes the `TextEditor` with
        // an animated transition and does not resign first responder on the
        // way out, so for a moment the key window still points at a text view
        // that is no longer in any window. That is the whole bug: the router
        // read that stale responder as "someone is typing" and handed it every
        // key but Escape, so Option+P and Option+Delete went dead - but only
        // after the overlay had been opened once, which is why it read as
        // random. Measured here, the stale responder is gone again inside
        // 380ms. Two probe commands cannot both fit in that window (the
        // command file is polled at 100ms and each command settles), so a test
        // that closes the overlay and then presses a key in a separate command
        // always arrives too late and passes against the unfixed code. It did:
        // section 160 was green on a build with the fix reverted until this
        // existed.
        //
        // `responderAtPost` and `detachedAtPost` record what was actually true
        // at the instant the key was posted, so a run where the trigger did
        // NOT reproduce is reported as that, rather than counted as a pass.
        case "real_afterDetailClose":
            installRealMonitor()
            let rtID = lastCommandID
            let rtKey = arg
            whenActive {
                HistoryStore.shared.closeDetail()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    MainActor.assumeIsolated {
                        let responder = NSApp.keyWindow?.firstResponder
                        realResponderAtPost = String(describing: type(of: responder ?? NSNull()))
                        if let text = responder as? NSTextView, !text.isFieldEditor {
                            realDetachedAtPost = (text.window == nil || text.window !== NSApp.keyWindow)
                        } else {
                            realDetachedAtPost = false
                        }
                        _ = realKeyHID(rtKey)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            acknowledged = rtID
                            writeState()
                        }
                    }
                }
            }
            return false

        // "real_axDump" - every accessibility element under the target
        // window, as role/title/label/frame lines. Not an assertion: it is
        // how a test author finds the exact label to name in `real_click`,
        // instead of guessing one and getting `no_element`.
        case "real_axDump":
            realAXDump = axDump()

        case "real_resetCounters":
            realKeysSeen = 0
            realClicksSeen = 0
            realLastKeySeen = -1
            realDelivery = .notAttempted
            realDetail = ""

        case "real_key", "real_keyHID", "real_keyPid", "real_keyQueue":
            installRealMonitor()
            let keyID = lastCommandID
            let route = verb
            whenActive {
                let posted: Bool
                switch route {
                case "real_keyPid":   posted = realKeyPID(arg)
                case "real_keyQueue": posted = realKeyQueue(arg)
                default:              posted = realKeyHID(arg)  // "real_key" is the HID route
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + (posted ? 0.45 : 0.0)) {
                    acknowledged = keyID
                    writeState()
                }
            }
            return false

        // "real_clickAt <x> <y>" - Cocoa SCREEN points, bottom-left origin,
        // the same space `panelFrame` reports in. The queue route has no
        // by-coordinate twin on purpose: nothing asserts one, and an unexercised
        // command is a claim nobody has checked.
        case "real_clickAt":
            installRealMonitor()
            let bits = arg.split(separator: " ").compactMap { Double($0) }
            guard bits.count == 2 else { realDelivery = .buildFailed; break }
            let point = NSPoint(x: bits[0], y: bits[1])
            realResolvedRect = [bits[0], bits[1], 0, 0]
            let atID = lastCommandID
            whenActive {
                let posted = realClickHID(at: point)
                DispatchQueue.main.asyncAfter(deadline: .now() + (posted ? 0.45 : 0.0)) {
                    acknowledged = atID
                    writeState()
                }
            }
            return false

        // "real_rect <name>" - resolve a named element to a screen rect
        // WITHOUT clicking it, so a test can assert the thing it is about to
        // click was actually found. A click on an element that was never found
        // would otherwise land at the origin and look like a broken control.
        case "real_rect":
            realResolvedRect = realRect(arg).map(rectArray) ?? []
            if !realResolvedRect.isEmpty { realDelivery = .notAttempted; realDetail = arg }

        // "real_click <name>" - the centre of a named element, clicked for
        // real. `editor`/`field` find a genuine NSTextView in the view tree;
        // any other name is matched against SwiftUI's accessibility labels.
        case "real_click", "real_clickQueue":
            installRealMonitor()
            let clickID = lastCommandID
            let queuedRoute = verb == "real_clickQueue"
            let target = arg
            whenActive {
                // Resolved AFTER activation, not before: bringing the panel
                // forward can move it (it opens near the status item, and that
                // is not in the same place on every screen), and a rect
                // measured a moment earlier aims the click at where the control
                // used to be.
                whenRectStable(target) { rect in
                    guard let rect else {
                        realDetail = "no element matching \(target)"
                        acknowledged = clickID
                        writeState()
                        return
                    }
                    realResolvedRect = rectArray(rect)
                    realDetail = target
                    let centre = NSPoint(x: rect.midX, y: rect.midY)
                    let posted = queuedRoute ? realClickQueue(at: centre) : realClickHID(at: centre)
                    DispatchQueue.main.asyncAfter(deadline: .now() + (posted ? 0.45 : 0.0)) {
                        acknowledged = clickID
                        writeState()
                    }
                }
            }
            return false

        default:         break
        }
        return true
    }


    private static var lastShortcutError = ""
    // T1-M1: the URL title fetch's own SSRF/byte-cap guard (LinkMetadata.swift).
    private static var linkFetchDone = false
    private static var linkFetchResult: String?
    private static var lastTabRenderMS: Double = 0
    static var m22Flag = false
    private static var tabRenderSamples: [Double] = []
    private static var lastConflict = ""
    private static var lastConflictOwner = ""
    private static var lastAISuggestion = ""
    private static var lastAIError = ""
    /// The token the last `createToken` produced, so the probe can reconnect with it.
    private static var lastToken = ""
    /// What `captureText` made of the last string it was given.
    private static var lastCapture: [String: Any] = [:]
    /// Where the last kit or settings file went, or what the last test said.
    private static var lastKitPath = ""
    private static var themeAudit: [[String: Any]] = []
    private static var themePairings = 0
    private static var presetRepairReport: [[String: Any]] = []
    private static var pendingDraft: String?

    private static func applyPreference(_ key: String, _ value: String) {
        let p = PreferencesModel.shared
        switch key {
        case "statusIcon":    p.statusIcon = value
        case "showInDock":    p.showInDock = (value == "true")
        case "showCopyConfirmation": p.showCopyConfirmation = (value == "true")
        case "copyConfirmationSeconds": p.copyConfirmationSeconds = Int(value) ?? p.copyConfirmationSeconds
        case "aiFeatures":
            p.aiFeaturesEnabled = (value == "true")
            NoticeCenter.shared.refreshInvitation()
        case "syncMethod":
            // The Sync hub's chooser, as the pane reads it on appear
            // (`SyncPane.methodChoiceKey`); "" clears the choice.
            if value.isEmpty { AppPaths.defaults.removeObject(forKey: SyncPane.methodChoiceKey) }
            else { AppPaths.defaults.set(value, forKey: SyncPane.methodChoiceKey) }
        case "syncAdvancedOpen": SettingsProbe.syncAdvancedOpen = (value == "true")
        case "ignoredApps":   p.ignoredApps = value
        case "numberShortcuts": p.numberShortcuts = (value == "true")
        case "clearOnQuit":   p.clearOnQuit = (value == "true")
        // M20/S1: "Remove duplicates" has to be reachable from the probe,
        // because the defect was that it gated capture and nothing else.
        case "deduplicate":   HistoryStore.shared.deduplicate = (value == "true")
        case "pasteAutomatically": p.pasteAutomatically = (value == "true")
        default: break
        }
    }

    /// Routes a named key through the *same* handler a real keystroke uses.
    // MARK: - AI helpers

    /// Adds a connection using the *nth* key from a key file, so a backup can be
    /// set up on a different credential from the main one.
    private static func configureNth(_ arg: String) {
        let id = lastCommandID
        let parts = arg.split(separator: "|").map(String.init)
        guard parts.count >= 6, let keyIndex = Int(parts[0]) else {
            finish(id, error: "bad aiConfigureNth arguments"); return
        }
        let name = parts[1]
        let role = ProviderRole(rawValue: parts[2]) ?? .unused
        let keyPath = parts[3]
        let kind = ProviderKind(rawValue: parts[4]) ?? .openaiCompatible
        let model = parts[5]
        let endpoint = parts.count > 6 ? parts[6] : kind.endpointHint

        guard let key = key(at: keyIndex, inFileAt: keyPath) else {
            finish(id, error: "no key at index \(keyIndex) in \(keyPath)"); return
        }

        let provider = AIProvider(name: name, kind: kind, endpoint: endpoint, model: model)
        let ai = AIService.shared
        ai.clientOverride = nil
        ai.addProvider(provider, key: key)

        Task { @MainActor in
            switch await ai.validate(provider) {
            case .success(let reply):
                ai.setRole(role, for: provider.id)
                lastAISuggestion = reply
                finish(id, error: nil)
            case .failure(let error):
                finish(id, error: error.localizedDescription)
            }
        }
    }

    /// The nth key in a JSON key file, sorted by key name for stability.
    private static func key(at index: Int, inFileAt path: String) -> String? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
              let data = raw.data(using: .utf8),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        let values = map.sorted { $0.key < $1.key }.map(\.value)
        return values.indices.contains(index) ? values[index] : nil
    }

    private static func configureProvider(_ arg: String) {
        let id = lastCommandID
        let parts = arg.split(separator: "|").map(String.init)
        guard parts.count >= 3 else { finish(id, error: "bad aiConfigure arguments"); return }

        let keyPath = parts[0]
        let kind = ProviderKind(rawValue: parts[1]) ?? .openaiCompatible
        let model = parts[2]
        let endpoint = parts.count > 3 ? parts[3] : kind.endpointHint

        guard let key = firstKey(inFileAt: keyPath) else {
            finish(id, error: "no API key found in \(keyPath)")
            return
        }

        let provider = AIProvider(name: "Probe \(kind.title)", kind: kind,
                                  endpoint: endpoint, model: model)
        let ai = AIService.shared
        ai.clientOverride = nil          // use the real network path
        ai.addProvider(provider, key: key)

        Task { @MainActor in
            switch await ai.validate(provider) {
            case .success(let reply):
                ai.makeActive(provider.id)
                lastAISuggestion = reply
                finish(id, error: nil)
            case .failure(let error):
                finish(id, error: error.localizedDescription)
            }
        }
    }

    /// Pulls the first key-looking value out of a JSON-ish file.
    private static func firstKey(inFileAt path: String) -> String? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        if let data = raw.data(using: .utf8),
           let map = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let first = map.sorted(by: { $0.key < $1.key }).first?.value {
            return first
        }
        // Fall back to the first token that looks like a key.
        let pattern = #"(nvapi-|sk-)[A-Za-z0-9_\-]{10,}"#
        guard let range = raw.range(of: pattern, options: .regularExpression) else { return nil }
        return String(raw[range])
    }

    private static func runFeature(named name: String, text: String) {
        let id = lastCommandID
        let ai = AIService.shared
        Task { @MainActor in
            do {
                let out: String
                switch name {
                case "improve":   out = try await ai.improvePrompt(text).body
                case "proofread": out = try await ai.proofread(text)?.body ?? "NO_CHANGES"
                case "title":     out = try await ai.suggestTitle(for: text).body
                case "tags":      out = try await ai.suggestTags(for: text).joined(separator: ", ")
                case "summarise": out = try await ai.summarise(text).body
                case "explain":   out = try await ai.explainCode(text, language: "swift").body
                case "template":  out = try await ai.makeTemplate(from: text).body
                case "translate": out = try await ai.translate(text, to: "French").body
                case "theme":
                    let theme = try await ai.generateTheme(from: text)
                    CustomThemeStore.shared.save(theme)
                    out = theme.name
                default:          out = ""
                }
                lastAISuggestion = out
                finish(id, error: nil)
            } catch {
                lastAISuggestion = ""
                finish(id, error: error.localizedDescription)
            }
        }
    }

    private static func finish(_ id: String, error: String?) {
        lastAIError = error ?? ""
        acknowledged = id
        writeState()
    }

    /// A minimal, genuinely decodable PNG - a solid-colour square - for tests
    /// that need real image bytes rather than a stand-in: sha256 comparisons
    /// and `MediaPreview`'s own decode path both have to see something a real
    /// screenshot could have produced.
    private static func makeSolidPNG(side: Int) -> Data? {
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// The key names both input paths understand.
    ///
    /// One table, deliberately: `key` (in process) and `real_key*` (through the
    /// system) must mean exactly the same keystroke, or a red-then-green
    /// comparison between them is comparing two different keys. Adding a name
    /// here makes it available to both at once.
    static let keyTable: [String: (UInt16, NSEvent.ModifierFlags)] = [
        "escape": (53, []), "down": (125, []), "up": (126, []),
        "left": (123, []), "right": (124, []), "return": (36, []),
        "tab": (48, []), "shiftTab": (48, .shift),
        "cmd1": (18, .command), "cmd2": (19, .command), "cmd3": (20, .command),
        "optP": (35, .option), "optDelete": (51, .option),
        "optRight": (124, .option), "optLeft": (123, .option),
        "cmdReturn": (36, .command), "optShiftReturn": (36, [.option, .shift]),
        // Plain printable keys. The in-process `key` path never needed one -
        // it never reached a text view - but a real-input test does: section
        // 160b presses an UNBOUND printable key to prove its own assertions
        // can fail, which needs a key that arrives and correctly does nothing.
        "a": (0, []), "b": (11, []), "x": (7, []), "z": (6, []),
        "p": (35, []), "space": (49, []), "delete": (51, [])
    ]

    @MainActor
    private static func sendKey(_ name: String) {
        let map = keyTable
        guard let (code, flags) = map[name] else { return }
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil,
            characters: characters(for: code, flags: flags),
            charactersIgnoringModifiers: characters(for: code, flags: []),
            isARepeat: false, keyCode: code
        ) else { return }
        _ = KeyRouter.handleForTesting(event)
    }

    /// Posts a REAL key event at the HID event tap, so it travels the same
    /// system route a physical keypress does and reaches Carbon's
    /// `RegisterEventHotKey` dispatcher.
    ///
    /// `sendKey` above builds an `NSEvent` and calls
    /// `KeyRouter.handleForTesting` directly - that reaches only KeyRouter's
    /// in-panel *local* monitor. A global hotkey is delivered by a
    /// system-wide handler KeyRouter never sees, so `sendKey` structurally
    /// cannot exercise it; this is why the leaked-recording-depth regression
    /// (every global and per-item hotkey silently no-oping) had no seam to
    /// catch it.
    ///
    /// Posting to `.cghidEventTap` requires Accessibility permission. If it
    /// is absent the post is dropped with no error, which would make this
    /// assertion pass or fail for the wrong reason - so the permission is
    /// checked and recorded in `lastHotkeyOutcome` (surfaced as
    /// `hotkeyOutcome`/`axTrusted` in state) every time, rather than being
    /// inferred from whether the hotkey's effect showed up.
    @MainActor
    private static func fireGlobalHotkey(_ combo: String) {
        guard let parsed = Shortcut.parse(combo) else {
            lastHotkeyOutcome = .invalidCombo
            return
        }
        guard AXIsProcessTrusted() else {
            lastHotkeyOutcome = .noPermission
            return
        }
        var flags: CGEventFlags = []
        if parsed.modifiers & UInt32(cmdKey) != 0     { flags.insert(.maskCommand) }
        if parsed.modifiers & UInt32(shiftKey) != 0    { flags.insert(.maskShift) }
        if parsed.modifiers & UInt32(optionKey) != 0   { flags.insert(.maskAlternate) }
        if parsed.modifiers & UInt32(controlKey) != 0  { flags.insert(.maskControl) }

        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source,
                                  virtualKey: CGKeyCode(parsed.keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                                virtualKey: CGKeyCode(parsed.keyCode), keyDown: false)
        else {
            lastHotkeyOutcome = .invalidCombo
            return
        }
        down.flags = flags
        up.flags = flags
        lastHotkeyPostAt = Date()
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        lastHotkeyOutcome = .posted
    }

    private static func characters(for code: UInt16, flags: NSEvent.ModifierFlags) -> String {
        switch code {
        case 0:  return "a"
        case 6:  return "z"
        case 7:  return "x"
        case 11: return "b"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 35: return "p"
        case 36: return "\r"
        case 48: return "\t"
        case 49: return " "
        case 51: return "\u{8}"
        case 53: return "\u{1b}"
        case 123: return "\u{F702}"
        case 124: return "\u{F703}"
        case 125: return "\u{F701}"
        case 126: return "\u{F700}"
        default: return ""
        }
    }

    // =====================================================================
    // MARK: - REAL INPUT: keys and clicks that travel the system's own route
    // =====================================================================
    //
    // See the "TWO INPUT PATHS" section at the top of this file first. Nothing
    // below calls a handler. Every command here posts an event and then lets
    // the app receive it exactly as it receives one from the keyboard or the
    // mouse, which is the only way to prove the delivery path itself.

    /// What the last `real_` command did, and why, in one word.
    ///
    /// Kept separate from whether the effect showed up, for the same reason
    /// `HotkeyPostOutcome` is: an event that was never posted and an event that
    /// was posted and ignored produce the identical "nothing happened" from
    /// outside, and they need opposite fixes.
    private enum RealDelivery: String {
        case notAttempted   = "not_attempted"
        case unknownKey     = "unknown_key"      // no such name in `keyTable`
        case noWindow       = "no_window"        // nothing on screen to aim at
        case noElement      = "no_element"       // the named element was not found
        case noPermission   = "no_permission"    // HID tap refused: not AX-trusted
        case buildFailed    = "build_failed"     // CGEvent/NSEvent would not construct
        case postedHID      = "posted_hid"       // CGEvent to the session tap
        case postedPID      = "posted_pid"       // CGEvent to this process
        case postedQueue    = "posted_queue"     // NSApp.postEvent, in-process queue
    }

    private static var realDelivery: RealDelivery = .notAttempted
    private static var realDetail = ""
    /// The rect the last element lookup resolved to, in Cocoa screen points.
    private static var realResolvedRect: [Double] = []

    // ---- Instrumentation: what actually ARRIVES ------------------------
    //
    // The counter below is the difference between a useful failure and a
    // useless one. Without it, a `real_` command that changed nothing could
    // mean the event never reached the app OR that it reached it and the app
    // chose to ignore it, and those are not the same bug.
    //
    // CAVEAT, stated because it bounds what the number proves: this is a
    // LOCAL monitor, and `KeyRouter.install()` registered its own one first,
    // at launch. AppKit does not document the order it calls them in, and a
    // monitor that returns `nil` swallows the event for the ones after it. So
    // treat this as a LOWER bound on arrival: a non-zero increment proves the
    // event arrived, a zero increment does not by itself prove it did not.
    // The behavioural assertion is always the primary evidence; this only
    // tells the two failure modes apart when the behaviour did not change.
    // Section `real_selfTest` measures which order this build actually uses,
    // so the bound is a measurement rather than an assumption.
    /// See the `real_hold` command. Read by `PanelController`.
    static var realInputHoldsPanel = false

    private static var realMonitor: Any?
    private static var realKeysSeen = 0
    private static var realClicksSeen = 0
    private static var realLastKeySeen = -1
    /// DEBUG (T2-M1 investigation): the raw `.characters` AppKit itself
    /// resolved for the last real keyDown this monitor saw. Empty on a key
    /// that arrived with no printable payload, which is the difference
    /// between "arrived and was ignored" and "arrived with nothing to
    /// insert" - the two look identical from `keysSeen` alone.
    private static var realLastKeyChars = ""

    /// Installed lazily, on the first `real_` command only, so an ordinary QA
    /// run carries no extra event monitor at all.
    @MainActor
    private static func installRealMonitor() {
        guard realMonitor == nil else { return }
        realMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            if event.type == .keyDown {
                realKeysSeen += 1
                realLastKeySeen = Int(event.keyCode)
                realLastKeyChars = event.characters ?? "<nil>"
            } else {
                realClicksSeen += 1
            }
            return event
        }
    }

    /// Brings Clip forward and makes the panel the key window.
    ///
    /// Not optional, and not a detail. `KeyRouter.install()` is a LOCAL event
    /// monitor: it is only ever called for events AppKit delivers to this
    /// process, and a borderless `.nonactivatingPanel` gets none while some
    /// other application is active. Every `real_key*` command therefore has to
    /// be able to state whether this precondition held, which is why the result
    /// is reported (`appActive`, `panelKey`) rather than assumed.
    @MainActor
    private static func realActivate() {
        NSApp.activate(ignoringOtherApps: true)
        if let panel = PanelController.shared.panelWindowForInspect {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Whether the last activation reached "active and key", and how long it
    /// took. Reported, because the alternative to reporting it is a suite that
    /// fails intermittently and blames the code under test.
    private static var realActivationReady = false
    private static var realActivationWaitMS = 0.0

    /// Runs `body` only once Clip is genuinely active with its panel key -
    /// or, after half a second of trying, runs it anyway and records that it
    /// was not ready.
    ///
    /// THIS IS THE WHOLE DIFFERENCE between a seam and a coin flip, and it was
    /// measured rather than guessed. `NSApp.activate` is a REQUEST: it returns
    /// immediately and the app becomes frontmost some run-loop turns later. A
    /// `CGEvent` posted in the same turn therefore goes to whichever app is
    /// still frontmost - and a real click that lands in another application
    /// takes key away from the panel, which dismisses it, which closes the
    /// overlay under test. Run back to back, the same ten-step sequence on the
    /// SAME build passed cleanly, then failed three steps in, then failed at
    /// the first step. An A/B against a reverted fix compared nothing at all
    /// until this existed.
    @MainActor
    private static func whenActive(_ body: @escaping @MainActor () -> Void) {
        realActivate()
        let start = CFAbsoluteTimeGetCurrent()
        // TWICE in a row, 20ms apart, not once. Losing key resets the
        // window's first responder, and AppKit restores it a turn or two after
        // the app becomes active again. A key posted in between is decided
        // against the WRONG text context: measured once as an Option+Delete
        // that was supposed to stay in the editor and instead moved the
        // panel's selection, on a step whose activation had just had to wait.
        // One sample of "ready" cannot tell a settled window from a window
        // half way through becoming one.
        func attempt(_ n: Int, _ readyBefore: Bool) {
            let panel = PanelController.shared.panelWindowForInspect
            // Three conditions, and the third is not redundant.
            // `NSApp.isActive` is this process's OWN opinion, and it can be
            // true while the window server still considers another app
            // frontmost - during a contested activation the two disagree for a
            // few turns. An event posted to the HID tap is delivered by the
            // window server, so the window server's answer is the one that
            // decides where it lands. Measured: a whole ten-step sequence
            // arrived nowhere with `isActive` true throughout.
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let isFront = front == ProcessInfo.processInfo.processIdentifier
            let ready = NSApp.isActive && isFront && (panel == nil || panel === NSApp.keyWindow)
            if (ready && readyBefore) || n >= 30 {
                realActivationReady = ready
                realActivationWaitMS = ((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded()
                body()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                MainActor.assumeIsolated { attempt(n + 1, ready) }
            }
        }
        attempt(0, false)
    }

    /// The window a real event should be aimed at: whatever holds the keyboard,
    /// falling back to the panel. A sheet (the theme "describe it" sheet) is a
    /// window of its own and becomes key, so this finds it without naming it.
    @MainActor
    private static var realTargetWindow: NSWindow? {
        NSApp.keyWindow ?? PanelController.shared.panelWindowForInspect
    }

    // ---- Key delivery ---------------------------------------------------

    /// A REAL key press posted to the session event tap, the same tap a
    /// physical keyboard posts to. It leaves this process, goes through the
    /// window server, and comes back to whichever app is active - so it proves
    /// the whole delivery path, and it also means it can land somewhere else
    /// entirely if Clip is not frontmost, which is why `realActivate()` runs
    /// first and the outcome records whether that worked.
    ///
    /// PRECONDITION: Accessibility permission. Without it `CGEvent.post` is
    /// dropped silently, so it is checked rather than inferred.
    @MainActor
    private static func realKeyHID(_ name: String) -> Bool {
        guard let (code, flags) = keyTable[name] else { realDelivery = .unknownKey; return false }
        guard AXIsProcessTrusted() else { realDelivery = .noPermission; return false }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false)
        else { realDelivery = .buildFailed; return false }
        down.flags = cgFlags(flags)
        up.flags = cgFlags(flags)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        realDelivery = .postedHID
        realDetail = "keyCode=\(code)"
        return true
    }

    /// The same real key event, posted straight to THIS process instead of to
    /// the session. It never reaches the window server, so no other app can
    /// receive it by accident - the reason to prefer it where it works. Whether
    /// it works at all on this window type is the empirical question
    /// `real_selfTest` answers; the outcome is recorded either way.
    @MainActor
    private static func realKeyPID(_ name: String) -> Bool {
        guard let (code, flags) = keyTable[name] else { realDelivery = .unknownKey; return false }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false)
        else { realDelivery = .buildFailed; return false }
        down.flags = cgFlags(flags)
        up.flags = cgFlags(flags)
        let pid = ProcessInfo.processInfo.processIdentifier
        down.postToPid(pid)
        up.postToPid(pid)
        realDelivery = .postedPID
        realDetail = "keyCode=\(code) pid=\(pid)"
        return true
    }

    /// A real `NSEvent` pushed onto this application's OWN event queue.
    ///
    /// `NSApplication.run` dequeues it and calls `sendEvent(_:)` on it, which is
    /// the stage that invokes local event monitors and then hands the event to
    /// the key window's first responder. It is in-process and needs no
    /// permission at all, which makes it the cheapest of the three - but it
    /// starts one stage later than the HID tap does, so it proves the app's own
    /// dispatch and not the window server's.
    ///
    /// `atStart: false` on purpose: the event queues behind anything already
    /// pending, in order, the way a typed key does.
    @MainActor
    private static func realKeyQueue(_ name: String) -> Bool {
        guard let (code, flags) = keyTable[name] else { realDelivery = .unknownKey; return false }
        guard let window = realTargetWindow else { realDelivery = .noWindow; return false }
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: characters(for: code, flags: flags),
            charactersIgnoringModifiers: characters(for: code, flags: []),
            isARepeat: false, keyCode: code)
        else { realDelivery = .buildFailed; return false }
        NSApp.postEvent(event, atStart: false)
        realDelivery = .postedQueue
        realDetail = "keyCode=\(code) window=\(window.windowNumber)"
        return true
    }

    private static func cgFlags(_ flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var out: CGEventFlags = []
        if flags.contains(.command) { out.insert(.maskCommand) }
        if flags.contains(.shift)   { out.insert(.maskShift) }
        if flags.contains(.option)  { out.insert(.maskAlternate) }
        if flags.contains(.control) { out.insert(.maskControl) }
        return out
    }

    // ---- Click delivery -------------------------------------------------

    /// Cocoa screen points (bottom-left origin) to the top-left origin Quartz
    /// uses. Getting this backwards puts every click off-screen at the far end
    /// of the display, where it silently hits nothing - a failure that reads
    /// exactly like "clicks do not work".
    private static func quartzPoint(_ p: NSPoint) -> CGPoint {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: height - p.y)
    }

    /// A REAL mouse click at a point in Cocoa screen coordinates, posted to the
    /// session tap. It moves the actual pointer, because that is what a click
    /// is: AppKit resolves a click against the window under the cursor, and a
    /// down/up pair with no preceding move lands wherever the pointer already
    /// was.
    @MainActor
    private static func realClickHID(at point: NSPoint) -> Bool {
        guard AXIsProcessTrusted() else { realDelivery = .noPermission; return false }
        let p = quartzPoint(point)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: p, mouseButton: .left),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: p, mouseButton: .left),
              let up   = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                                 mouseCursorPosition: p, mouseButton: .left)
        else { realDelivery = .buildFailed; return false }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        move.post(tap: .cghidEventTap)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        realDelivery = .postedHID
        realDetail = String(format: "screen=%.0f,%.0f", point.x, point.y)
        return true
    }

    /// A REAL mouse move, with no click, posted to the session tap. This is
    /// the actual signal `.onHover` resolves against - a state write would
    /// only prove the `@State` variable can be set, not that the pointer
    /// arriving over the control is what turns it on.
    @MainActor
    private static func moveMouseHID(to point: NSPoint) {
        guard AXIsProcessTrusted() else { return }
        let p = quartzPoint(point)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: p, mouseButton: .left)
        else { return }
        move.post(tap: .cghidEventTap)
    }

    /// The same click as a pair of `NSEvent`s on this app's own queue.
    ///
    /// The location must be in the TARGET WINDOW's coordinates and the
    /// `windowNumber` must be that window's, or `sendEvent` has nothing to
    /// route it to. An earlier attempt at a synthetic click here was built with
    /// `windowNumber: 0` and posted through `NSApp.sendEvent`; it reached
    /// nothing and was removed. This is the corrected form of the same idea,
    /// kept because it needs no permission, and it is measured against
    /// `realClickHID` rather than assumed to be equivalent.
    @MainActor
    private static func realClickQueue(at screenPoint: NSPoint) -> Bool {
        guard let window = realTargetWindow else { realDelivery = .noWindow; return false }
        let inWindow = window.convertPoint(fromScreen: screenPoint)
        let stamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: inWindow, modifierFlags: [],
                timestamp: stamp, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: inWindow, modifierFlags: [],
                timestamp: stamp + 0.02, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0)
        else { realDelivery = .buildFailed; return false }
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
        realDelivery = .postedQueue
        realDetail = String(format: "window=%d local=%.0f,%.0f",
                            window.windowNumber, inWindow.x, inWindow.y)
        return true
    }

    // ---- Finding something real to click --------------------------------

    /// The on-screen rect of a named element, in Cocoa screen points.
    ///
    /// Two lookups, because the panel is one `NSHostingView` and most of what
    /// is in it is not an `NSView` at all:
    ///
    /// - `editor` / `field` walk the real view tree. A SwiftUI `TextEditor` and
    ///   the field editor an `NSTextField` borrows are both genuine
    ///   `NSTextView`s, so they are findable there - and they are exactly the
    ///   two things RT-2 and S2 are about.
    /// - everything else walks SwiftUI's own ACCESSIBILITY tree, which is the
    ///   only place a `Button` inside a hosting view exists as an addressable
    ///   object with a frame. Matched on the visible label, so a test names the
    ///   control the way a person would ("Prompts"), not by a coordinate that
    ///   goes stale the moment the layout moves.
    @MainActor
    private static func realRect(_ name: String) -> NSRect? {
        guard let window = realTargetWindow, let root = window.contentView else {
            realDelivery = .noWindow
            return nil
        }
        if name == "editor" || name == "field" {
            let wantField = (name == "field")
            guard let view = firstTextView(in: root, fieldEditor: wantField) else {
                realDelivery = .noElement
                return nil
            }
            // `visibleRect`, not `bounds`. An `NSTextView` inside a scroll
            // view is as tall as its DOCUMENT, not as tall as the box you can
            // see: measured here at 3512pt high with its origin 2661pt above
            // the screen, so the centre of `bounds` is a point in mid-air far
            // outside the panel. Clicking there hits the desktop, and the
            // editor that never took focus reads exactly like a routing bug.
            let box = view.visibleRect.isEmpty ? view.bounds : view.visibleRect
            let inWindow = view.convert(box, to: nil)
            return window.convertToScreen(inWindow)
        }
        // A control that published its own rendered frame (`.realTarget`).
        // Panel-only by construction: the space it measures in is rooted on
        // `PanelRootView`, so it is resolved against the PANEL window even when
        // a sheet currently holds the keyboard.
        if let rect = RealTargetRegistry.shared.frames[name] {
            guard let panel = PanelController.shared.panelWindowForInspect,
                  let content = panel.contentView else {
                realDelivery = .noWindow
                return nil
            }
            // Top-left origin (SwiftUI, and the flipped `NSHostingView`) to
            // bottom-left origin (Cocoa). Flipping the wrong way puts the click
            // on the mirror image of the control, which on a tab bar is a
            // different tab that still changes something - a failure that looks
            // like a pass.
            let cocoa = NSRect(x: rect.origin.x,
                               y: content.bounds.height - rect.maxY,
                               width: rect.width, height: rect.height)
            return panel.convertToScreen(cocoa)
        }
        return axFrame(labelled: name, under: root)
    }

    /// A rect as [x, y, width, height] in Cocoa screen points, the shape the
    /// probe's own geometry helpers already read `panelFrame` in.
    private static func rectArray(_ r: NSRect) -> [Double] {
        [r.origin.x, r.origin.y, r.width, r.height]
    }

    private static func firstTextView(in view: NSView, fieldEditor: Bool) -> NSTextView? {
        if let text = view as? NSTextView, text.isFieldEditor == fieldEditor { return text }
        for sub in view.subviews {
            if let found = firstTextView(in: sub, fieldEditor: fieldEditor) { return found }
        }
        return nil
    }

    /// The REAL detail editor's live on-screen text, read straight off the
    /// `NSTextView` a real click focused - not `store.selectedItem?.fullText`
    /// (`selectedText` in state), which is the SAVED value and does not move
    /// until Save is pressed. `DetailView` holds what a user is mid-typing in
    /// a private `@State draft`, bound to the on-screen `TextEditor`; the only
    /// way to see it change without pressing Save is to read the real view's
    /// own `.string`, which is exactly what a person looking at the screen
    /// sees. This is RT-2's missing live proof: a real key typed here has to
    /// show up HERE, not in the model underneath it.
    @MainActor
    private static func realEditorText() -> String? {
        guard let window = realTargetWindow, let root = window.contentView else { return nil }
        return firstTextView(in: root, fieldEditor: false)?.string
    }

    /// Depth-first search of the accessibility tree for an element whose title,
    /// label or value starts with `label`, returning its screen frame.
    ///
    /// In process, through `NSAccessibility`'s own methods on the hosting view -
    /// NOT `AXUIElementCreateApplication(getpid())`. Asking the AX API about
    /// your own process from the main thread deadlocks: the request is serviced
    /// on the main run loop of the target, and here the target is us.
    @MainActor
    private static func axFrame(labelled label: String, under root: NSView) -> NSRect? {
        var found: NSRect?
        // Through `NSAccessibilityProtocol`, the protocol both `NSView` and
        // the `NSAccessibilityElement`s SwiftUI builds for its own controls
        // conform to. Not `AnyObject` dynamic lookup, which makes several of
        // these ambiguous at compile time, and not `NSObject`, which does not
        // carry them in Swift at all.
        func walk(_ node: Any, depth: Int) {
            guard found == nil, depth < 40,
                  let object = node as? NSAccessibilityProtocol else { return }
            let title = object.accessibilityTitle() ?? ""
            let text  = object.accessibilityLabel() ?? ""
            // AXHelp too. A SwiftUI `Button` styled `.plain` inside a hosting
            // view comes back as AXUnknown with no title at all through this
            // in-process route (measured - see `real_axDump`), but a `.help()`
            // tooltip survives, and the tab bar already carries one naming
            // every tab. Matching it means a test names the control by the
            // words the interface itself shows, with no change to the view.
            let help  = object.accessibilityHelp() ?? ""
            if title.hasPrefix(label) || text.hasPrefix(label) || help.hasPrefix(label) {
                let frame = object.accessibilityFrame()
                if frame.width > 0, frame.height > 0 {
                    found = frame
                    return
                }
            }
            // Both trees, in that order. A SwiftUI hosting view answers
            // `accessibilityChildren()` with its own element tree; a plain
            // `NSView` in the chrome above it answers nil, and its real
            // children are its subviews. Following only one of the two stops
            // at whichever kind of node comes first.
            for child in object.accessibilityChildren() ?? [] {
                walk(child, depth: depth + 1)
                if found != nil { return }
            }
            if let view = node as? NSView {
                for sub in view.subviews {
                    walk(sub, depth: depth + 1)
                    if found != nil { return }
                }
            }
        }
        walk(root, depth: 0)
        if found == nil { realDelivery = .noElement }
        return found
    }

    private static var realAXDump: [String] = []

    /// Every accessibility element under the target window, flattened.
    @MainActor
    private static func axDump() -> [String] {
        guard let window = realTargetWindow, let root = window.contentView else { return [] }
        var lines: [String] = []
        func walk(_ node: Any, depth: Int) {
            // 1200, not 400: the Settings sidebar's own outline is several
            // hundred nodes on its own, so a 400-line cap never reached the
            // detail pane - the half every layout question is about.
            guard depth < 40, lines.count < 1200,
                  let object = node as? NSAccessibilityProtocol else { return }
            let role = object.accessibilityRole()?.rawValue ?? ""
            let title = object.accessibilityTitle() ?? ""
            let label = object.accessibilityLabel() ?? ""
            let frame = object.accessibilityFrame()
            let help = object.accessibilityHelp() ?? ""
            let ident = object.accessibilityIdentifier() ?? ""
            if !role.isEmpty || !title.isEmpty || !label.isEmpty || !help.isEmpty {
                lines.append(String(format: "%@%@ | title=%@ | label=%@ | help=%@ | id=%@ | %.0f,%.0f %.0fx%.0f",
                                    String(repeating: ".", count: depth), role, title, label, help, ident,
                                    frame.origin.x, frame.origin.y, frame.width, frame.height))
            }
            for child in object.accessibilityChildren() ?? [] { walk(child, depth: depth + 1) }
            if let view = node as? NSView {
                for sub in view.subviews { walk(sub, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return lines
    }

    /// What held the keyboard at the instant `real_afterDetailClose` posted
    /// its key, and whether that thing was a text view no longer in the key
    /// window - RT-2's exact precondition, recorded rather than assumed.
    private static var realResponderAtPost = ""
    private static var realDetachedAtPost = false

    /// How many polls the last click waited for its target to stop moving.
    private static var realRectSettleMS = 0.0

    /// Calls `body` once the named element's rect has been the same twice in a
    /// row, 40ms apart - or with whatever it last read, after 800ms.
    ///
    /// The detail overlay arrives on an animated transition. A rect read the
    /// instant the overlay is asked to open is a rect the editor is still
    /// travelling through, and a real click posted at that point lands on the
    /// backdrop: the editor never takes focus, every following keystroke goes
    /// to the panel's command ladder instead, and the run reads as "keyboard
    /// routing is broken". Measured directly - one run in three failed exactly
    /// this way, with activation already confirmed ready. A fixed sleep would
    /// only move the race; waiting for the value to stop changing ends it.
    @MainActor
    private static func whenRectStable(_ name: String,
                                       _ body: @escaping @MainActor (NSRect?) -> Void) {
        let start = CFAbsoluteTimeGetCurrent()
        func attempt(_ previous: NSRect?, _ n: Int) {
            let now = realRect(name)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            if now == nil, n == 0 {
                // Not there at all on the first look. One more chance, in case
                // the view is still being built, then report it honestly.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    MainActor.assumeIsolated { attempt(nil, n + 1) }
                }
                return
            }
            if now == nil || (previous != nil && now == previous) || elapsed > 800 {
                realRectSettleMS = elapsed.rounded()
                body(now)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                MainActor.assumeIsolated { attempt(now, n + 1) }
            }
        }
        attempt(nil, 0)
    }

    /// The `realInput` state dictionary. One key in the big literal, on
    /// purpose: that literal already times the type checker out when it grows,
    /// and one nested value also keeps this lane's merge to a single line.
    @MainActor
    private static var realInputState: [String: Any] {
        let panel = PanelController.shared.panelWindowForInspect
        let key = NSApp.keyWindow
        return [
            "lastDelivery": realDelivery.rawValue,
            "lastDetail": realDetail,
            "resolvedRect": realResolvedRect,
            // Preconditions, read live. A `real_` assertion that fails while
            // any of these is false failed for a reason that has nothing to do
            // with the behaviour under test.
            "axTrusted": AXIsProcessTrusted(),
            "appActive": NSApp.isActive,
            "panelWindow": panel?.windowNumber ?? 0,
            "keyWindow": key?.windowNumber ?? 0,
            "panelIsKey": panel != nil && panel === key,
            "firstResponder": String(describing: type(of: key?.firstResponder ?? NSNull())),
            // Arrival counters. See the CAVEAT above `realMonitor`: a rise
            // proves arrival, a flat count does not prove absence.
            "keysSeen": realKeysSeen,
            "clicksSeen": realClicksSeen,
            "lastKeySeen": realLastKeySeen,
            "lastKeyChars": realLastKeyChars,
            "monitorInstalled": realMonitor != nil,
            "activationReady": realActivationReady,
            "activationWaitMS": realActivationWaitMS,
            "rectSettleMS": realRectSettleMS,
            "responderAtPost": realResponderAtPost,
            "detachedAtPost": realDetachedAtPost,
            "holdsPanel": realInputHoldsPanel,
            "frontmostApp": NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
            "axDump": realAXDump,
            "editorText": realEditorText() ?? "",
            // Every name `real_click` can aim at through the registry, so a
            // test that asks for one that is not there gets a list rather than
            // a bare "no_element".
            "targets": RealTargetRegistry.shared.names
        ]
    }

    // MARK: - M4 test fixtures

    /// Renders one view's actual CALayer into a PNG at `path` - the
    /// technique `snapshotPanel` used before this was pulled out so
    /// `m8b_snapshotSettings` (M8.4, 02/09) could reuse it for the Settings
    /// window instead of re-implementing it.
    ///
    /// Through the LAYER, not `cacheDisplay`: a SwiftUI hosting view is
    /// layer-backed, and asking the view to draw itself produced a picture
    /// of the background and nothing else - which would have been a
    /// snapshot that looks like a bug in the interface it was taken to
    /// check. Flipped, because a `CGContext`'s origin is bottom-left and a
    /// view's is top-left - the un-flipped render came out mirrored, a
    /// picture nobody would trust to check a layout with.
    private static func renderLayerToPNG(_ view: NSView, to path: String) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let scale = view.window?.backingScaleFactor ?? 2
        let pixels = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        guard let layer = view.layer,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: Int(pixels.width),
                                      height: Int(pixels.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.translateBy(x: 0, y: pixels.height)
        context.scaleBy(x: scale, y: -scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Mean relative luminance (0...1) of a rendered view, via the SAME
    /// layer-render technique `renderLayerToPNG` uses.
    ///
    /// M9 9.1: "when clicking dark theme and switching to light theme then i
    /// expect to see a white glass background and not the same one like
    /// now." The AUTHORED `panelBackground` hex never shows this bug - the
    /// panel is real translucent glass over the real desktop
    /// (`VisualEffectView` in PanelRootView.swift) - only a render of what
    /// actually reaches the screen can. Sampled rather than exhaustive: a
    /// full-size panel is well over a million pixels, and this runs inside a
    /// QA command the probe is actively blocked waiting on.
    private static func meanLuminance(of view: NSView) -> Double? {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let scale = view.window?.backingScaleFactor ?? 2
        let width = max(1, Int(view.bounds.width * scale))
        let height = max(1, Int(view.bounds.height * scale))
        guard let layer = view.layer,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        layer.render(in: context)
        guard let data = context.data else { return nil }
        let bytesPerPixel = 4
        let pixelCount = width * height
        guard pixelCount > 0 else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: pixelCount * bytesPerPixel)

        func linear(_ raw: UInt8) -> Double {
            let v = Double(raw) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }

        let step = max(1, pixelCount / 20_000)     // sampled, not exhaustive
        var total = 0.0
        var sampled = 0
        var i = 0
        while i < pixelCount {
            let offset = i * bytesPerPixel
            let r = linear(buffer[offset]), g = linear(buffer[offset + 1]), b = linear(buffer[offset + 2])
            total += 0.2126 * r + 0.7152 * g + 0.0722 * b
            sampled += 1
            i += step
        }
        return sampled > 0 ? total / Double(sampled) : nil
    }

    /// A real, decodable 16x16 PNG of random pixels (852 bytes) - a solid
    /// colour compresses to well under 200 bytes and `readImage` treats
    /// anything that small as noise rather than a real image, so a plain
    /// one-pixel fixture failed for a completely different reason than the
    /// one this probe means to test.
    private static func onePixelPNG() -> Data? {
        let base64 = """
        iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAADG0lEQVR42gEQA+/8ADkMjH1yRzQs\
        2BAPL293DWXWcOWOA1HYro5Pbqw0L8Ixt7CHFus/wSiWuWIjF3SUKAB3M8KO6LpTvbVriCRXfVPs\
        wopwphx1EKHNiSFsoWz/yupJh0d+htvMuXBG/C4YOE4AUdggxcPvgAU6iK45lt5Q6AGGWzaYZU6/\
        UgCl+gk5uZ16HXsoK/gjQEHzVIfYbGafAMy/4Oc9fnMgrQp1cAMkHnUiEKkkeY74bUPyfPLQYTAx\
        3LXY0u8bMh/OrTd/YmHlRwDYXY7sfybiMhkHL3lV0Pj2bc0eVMIBx4foktj5T2GXbx0foB0Z9FAd\
        KV8jInjOPX4AFCnWoYVooHqHykOZ6qElBOozJW2HQ7Ijfb2RUOCaBJk1RIc7Nk+LkGuvaIf6gBov\
        ANiNFgGqQoZS4toEOSZMEr1L3EEVnboUt2t/NLXQT3lTWtMMW6rSf4hRN8MT8HFm6wCznHRyDGLM\
        qI4jjrPMqQ47hVuHEzfesKDfO8VhghbfAGS63COpoD+ZntGnzpdBYtcAwlmazwCbkmvcpO7i4m3y\
        ViuRqy94nnNlSwwXffMl6dRjxP3MfEsCNtlwWu0Zfz7pAETtouLa5FHz5oR+jfh6jOEnkniLq6Mp\
        Rk12xE5tINTQqe7UH2nXxwrC9AO0mMfWcAD5cIvf+A7HrM9U70ENyQ0q20XsXRmFwqds6Keswo7X\
        gSnwCRqzciMUD35mCk56QPIAOm/ug7xVOlOfNw2fwMtlJnw0mj0Vsdu9I64G1/o23bnrTt5aivfu\
        34mlfSyO5nztAMKsDv2mXflstYSuj40FYSt70Pp78/vlCC+Wcc98nLzysNmptOiKnIB2PWKhPV5i\
        bgD3jZAzY5d0uFuaB0CMFxuVQPs0BpHw9eGuXhqB9DohzfslG01Mmyt/PNVzwubimNsAnB4yamy\
        HKVB6WCZQAdHm8JUQdpOQ6CR3h2XZOnNMiEgkHlSdk+A/75vOi/zgKRTdAKWADS51CokUWfDijl\
        zf+y7wstGqpDVSqNL9k80S6C2hgaU7zgDs0xtguf/iGmiIQ6oWgQS0lIrQAAAAAElFTkSuQmCC
        """
        return Data(base64Encoded: base64.replacingOccurrences(of: "\n", with: ""))
    }

    /// A REAL Carbon registration, on a signature/id this app never dispatches
    /// on, standing in for "another app already owns this key" so
    /// `ShortcutManager`'s own registration of the identical combination is
    /// genuinely refused by the OS rather than assumed.
    private static var conflictingHotKeyRef: EventHotKeyRef?

    @discardableResult
    private static func registerConflictingGlobal(_ combo: String) -> Bool {
        guard let parsed = Shortcut.parse(combo) else { return false }
        unregisterConflictingGlobal()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(parsed.keyCode, parsed.modifiers,
                                         EventHotKeyID(signature: OSType(0x51415054), id: 9_999),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr { conflictingHotKeyRef = ref }
        return status == noErr
    }

    private static func unregisterConflictingGlobal() {
        if let existing = conflictingHotKeyRef {
            UnregisterEventHotKey(existing)
            conflictingHotKeyRef = nil
        }
    }

    // MARK: - Seeding

    /// Creates a deterministic spread of every item kind so previews, filters
    /// and sorting can all be exercised without touching the real pasteboard.
    @MainActor
    private static func seed(_ count: Int) {
        let store = HistoryStore.shared
        store.clearAll(recordDeletions: false)

        var made: [ClipboardItem] = []
        let samples: [(ItemKind, String)] = [
            (.text, "Plain note number"),
            (.code, "func greet(name: String) -> String {\n    return \"hi \\(name)\"\n}"),
            (.url, "https://github.com/p0deje/Maccy"),
            (.emoji, "🎉"),
            (.color, "#3A7BD5"),
            (.text, "Another plain clipping")
        ]
        // Every template varies by index, not just the two `.text` ones.
        //
        // Four of the six used to repeat byte-for-identical on every cycle, so
        // the store's own fold collapsed them into their existing row and
        // `seed(4700)` produced about 1,776 items. Every baseline recorded
        // under `perf-baselines/` therefore states an item count it was never
        // actually measured at. The fold was working exactly as designed; the
        // fixture was the thing lying, so the fixture is what changes.
        //
        // The variation goes somewhere each kind still parses: a fragment on
        // the URL, a trailing comment in the code, a hex that really is a
        // different colour, and a repeated emoji.
        // Ten emoji used as digits, so the index itself spells the body. A
        // repeat count would have been the obvious variation and is not enough:
        // `count: (i % 8) + 1` gives eight distinct strings however large the
        // seed is, so `seed(300)` still folded 46 rows away. The body has to be
        // injective in `i`, not merely varied.
        let emojiDigits = ["0️⃣", "1️⃣", "2️⃣", "3️⃣", "4️⃣", "5️⃣", "6️⃣", "7️⃣", "8️⃣", "9️⃣"]
        func emojiBody(_ template: String, _ i: Int) -> String {
            let digits = String(i).compactMap { $0.wholeNumberValue }
                .map { emojiDigits[$0] }.joined()
            return template + digits
        }
        func vary(_ kind: ItemKind, _ template: String, _ i: Int) -> String {
            switch kind {
            case .code:  return "\(template)\n// sample \(i)"
            case .url:   return "\(template)#sample-\(i)"
            case .emoji: return emojiBody(template, i)
            case .color: return String(format: "#%06X", (0x3A7BD5 &+ i &* 7) & 0xFFFFFF)
            default:     return "\(template) \(i)"
            }
        }
        for i in 0..<count {
            let (kind, template) = samples[i % samples.count]
            let body = vary(kind, template, i)
            var item = ClipboardItem(
                kind: kind,
                text: body,
                hexColor: kind == .color ? body : nil,
                sourceAppName: "Probe",
                timestamp: Date().addingTimeInterval(Double(-i * 60)),
                language: kind == .code ? "swift" : nil
            )
            item.useCount = i % 4
            made.append(item)
        }
        // Insert oldest-first so the newest ends up at the head.
        for item in made.reversed() { store.add(item) }
        store.select(store.visibleItems.first?.id)
    }

    // MARK: - State report

    @MainActor
    static func writeState() {
        guard isEnabled else { return }
        // Snapshotted BEFORE this function reads the list itself. Writing the
        // state file runs the pipeline more than once, and a counter that
        // includes the observer measuring it is a counter that lies.
        let perfSnapshot = Perf.report
        // Read once. This was three separate `ServerConfig.load()` calls in the
        // dictionary below, and each one used to hit the Keychain.
        let serverConfigSnapshot = ServerConfig.load()
        let residentSnapshot = Perf.residentMB
        let store = HistoryStore.shared
        let visible = store.visibleItems

        // M3: startup health, backups, schema migrations, the audit.
        // Precomputed as plain `let`s (not inline in the dictionary literal
        // below) so each entry is a trivial reference for the type checker -
        // an inline `.merging(...)` split was tried here first and made the
        // single big literal time out during type-checking.
        let m3HealthFindingsSnapshot = StartupHealth.lastFindings.map {
            ["severity": $0.severity.rawValue, "title": $0.title, "detail": $0.detail]
        }
        let m3HealthMSSnapshot = StartupHealth.lastRunMilliseconds
        let m3DbUserVersionSnapshot = (Database.shared.query("PRAGMA user_version;").first?["user_version"] as? Int) ?? -1
        let m3DbItemCountSnapshot = (Database.shared.query("SELECT COUNT(*) AS n FROM items;").first?["n"] as? Int) ?? -1
        let m3BackupCandidatesSnapshot = Database.backupCandidates().map(\.lastPathComponent)
        let m3LastRunVersionPrefSnapshot = Database.shared.preference(StartupHealth.versionPreferenceKey) ?? ""
        let m3LastRunVersionDefaultsSnapshot = AppPaths.defaults.string(forKey: StartupHealth.versionDefaultsKey) ?? ""

        // M8: first-run overview, the permissions row, the lean status menu,
        // the credential explainer. Precomputed for the same reason as the
        // M3 snapshots above - a trivial reference in the literal, not a
        // fresh closure the type checker has to solve inline.
        let m8OverviewRowsSnapshot = NoticeCenter.shared.pending
            .filter { $0.kind.isCondition }
            .map { ["message": $0.message, "remedy": $0.remedy ?? "",
                    "action": $0.action?.title ?? "", "key": $0.key ?? ""] }
        let m8StatusMenuTitlesSnapshot = AppDelegate.statusMenuTitlesForTesting()
        let m8CredentialInvocationsSnapshot = CredentialExplainer.invocationsForTesting.map(\.rawValue)
        // M27: per-row enabled/target evidence for the status menu - "Quit
        // Clip" greyed out and unusable, fixed in AppDelegate.buildStatusMenu().
        let m27StatusMenuDiagnosticsSnapshot = AppDelegate.statusMenuDiagnosticsForTesting()

        // M15: Getting Started checklist - each step's real state, so a
        // probe reads the exact same `isAutoDone()`/manual-mark combination
        // the pane itself renders, not a lookalike derived separately.
        // M28: key recovery. Precomputed for the same reason - and read ONCE
        // rather than three times, because every read of the store is a real
        // read: the vault in production, the sandbox's secrets file under
        // test. A dump that consulted it per key would be measuring itself.
        let m28SecretsSnapshot = KeychainStore.allStoredSecrets().accounts
        let m28StoredAccountsSnapshot = KeyRecovery.providerAccounts(in: m28SecretsSnapshot)
        let m28RecoverableSnapshot = KeyRecovery.recoverable(in: m28SecretsSnapshot)
        let m28ScanSnapshot: String
        switch KeyRecovery.scan() {
        case .nothingStored:    m28ScanSnapshot = "nothingStored"
        case .readable:         m28ScanSnapshot = "readable"
        case .lockedButPresent: m28ScanSnapshot = "lockedButPresent"
        }
        let m28Outcome = KeyRecovery.lastOutcomeForTesting
        // Worked examples, not a mirror of the implementation: each of these
        // prefixes is what the named vendor stamps on every key it issues.
        let m28InferredKindsSnapshot = [
            KeyRecovery.inferredKind(fromKey: "sk-ant-api03-abc").rawValue,
            KeyRecovery.inferredKind(fromKey: "sk-proj-abc").rawValue,
            KeyRecovery.inferredKind(fromKey: "AIzaSyAbc").rawValue,
            KeyRecovery.inferredKind(fromKey: "nvapi-abc").rawValue
        ]

        let m15ChecklistSnapshot = SetupChecklist.shared
        let m15StepsSnapshot = m15ChecklistSnapshot.steps.map { step -> [String: Any] in
            ["id": step.id,
             "autoDone": step.isAutoDone(),
             "manualDone": m15ChecklistSnapshot.isManual(step.id),
             "isDone": m15ChecklistSnapshot.isDone(step)]
        }

        let pb = TestIsolation.board
        let pbItemCount = pb.pasteboardItems?.count ?? 0
        let pbTypes = (pb.types ?? []).map(\.rawValue)
        let pbString = pb.string(forType: .string) ?? ""
        let pbURLs = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        let pbDecodedURLs: [[String: Any]] = pbURLs.map { url in
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return [
                "path": url.path,
                "urlString": url.absoluteString,
                "exists": exists,
                "isDirectory": isDir.boolValue
            ]
        }
        let pbSnapshot: [String: Any] = [
            "itemCount": pbItemCount,
            "types": pbTypes,
            "string": pbString,
            "decodedURLs": pbDecodedURLs
        ]

        let state: [String: Any] = [
            "ack": acknowledged,
            "panelOpen": PanelController.shared.isOpen,
            "suppressedPasteCount": TestIsolation.suppressedPasteCount,
            "lastSuppressedPaste": TestIsolation.lastSuppressedPaste,
            "isolationActive": TestIsolation.isActive,
            "focusLossVerdict": PanelController.shared.focusLossVerdictForTesting,
            "panelHasSheet": PanelController.shared.hasAttachedSheet,
            "settingsOpen": SettingsWindowController.shared.isOpen,
            "detailOpen": store.isDetailOpen,
            "tab": store.activeTabID,
            "sort": store.sortOrder.rawValue,
            "searchMode": store.searchMode.rawValue,
            "query": store.query,
            "filter": store.activeFilter?.id ?? "",
            "filters": store.activeFilters.map(\.id).sorted(),
            "itemCount": store.items.count,
            // Delete with undo: what is still takeable back, and the notice
            // that is offering it. Empty when nothing is pending.
            "settingsAppearance": ThemeManager.shared.settingsAppearance.rawValue,
            "settingsAppearanceApplies": ThemeManager.shared.settingsAppearanceApplies,
            "settingsThemeIsDark": ThemeManager.shared.settingsTheme.isDark,
            "settingsThemeCardHex": ThemeManager.shared.settingsTheme.cardBackground.hexString,
            "settings_syncGlyphKind": SettingsProbe.settingsSyncGlyphKind,
            "panelThemeIsDark": ThemeManager.shared.theme.isDark,
            "pendingDeleteID": store.pendingDelete?.item.id.uuidString ?? "",
            "pendingDeleteTitle": store.pendingDelete?.item.displayTitle ?? "",
            "pendingDeleteIndex": store.pendingDelete?.index ?? -1,
            "pendingDeleteWasPinned": store.pendingDelete?.pinIndex != nil,
            "noticeMessages": NoticeCenter.shared.pending.map(\.message),
            "noticeActions": NoticeCenter.shared.pending.compactMap { $0.action?.title },
            "visibleCount": visible.count,
            "promptCount": store.promptCount,
            "selectedIndex": store.selectedIndex ?? -1,
            "selectedTitle": store.selectedItem?.displayTitle ?? "",
            "selectedKind": store.selectedItem?.kind.rawValue ?? "",
            "selectedPinned": store.selectedItem.map { store.isPinned($0.id) } ?? false,
            "selectedDisplayTitle": store.selectedItem?.displayTitle ?? "",
            "selectedShortURL": store.selectedItem?.shortURL ?? "",
            "selectedTypeLabel": store.selectedItem?.typeLabel ?? "",
            "selectedPageTitle": store.selectedItem?.pageTitle ?? "",
            "selectedSkillDescription": store.selectedItem?.skillDescription ?? "",
            "selectedSkillUsage": store.selectedItem?.skillUsage ?? "",
            "selectedWordCount": store.selectedItem?.wordCount ?? 0,
            "selectedUpdatedAfterCapture": store.selectedItem
                .map { $0.updatedAt > $0.timestamp } ?? false,
            "selectedText": store.selectedItem?.fullText ?? "",
            "shortcutError": lastShortcutError,
            "linkFetchDone": linkFetchDone,
            "linkFetchResult": linkFetchResult ?? "",
            "linkFetchBytesRead": LinkMetadata.lastBytesReadForTesting,
            "linkFetchRequestsAttempted": LinkMetadata.requestsAttemptedForTesting,
            "assignedShortcuts": store.items.compactMap(\.shortcut),
            "visibleTitles": visible.prefix(12).map(\.displayTitle),
            "visibleKinds": visible.prefix(12).map { $0.kind.rawValue },
            "conflict": lastConflict,
            "conflictOwner": lastConflictOwner,
            "aiAvailable": AIService.shared.isAvailable,
            "aiThemeName": lastAISuggestion,
            "aiSuggestion": lastAISuggestion,
            "aiError": lastAIError,
            "aiProviderCount": AIService.shared.providers.count,
            "aiActiveModel": AIService.shared.activeProvider?.model ?? "",
            "aiActiveValidated": AIService.shared.activeProvider?.isValidated ?? false,
            "pendingDraft": pendingDraft ?? "",
            "versionCount": store.selectedItem.map { Database.shared.versionCount(for: $0.id) } ?? 0,
            "customThemeCount": CustomThemeStore.shared.themes.count,
            "themeFileError": lastThemeFileError,
            "themeID": ThemeManager.shared.themeID,
            "themeRendered": ThemeManager.shared.theme.id,
            "themeClaimStamp": SettingsDocument.stampForTesting("themeID"),
            "presetCount": AppTheme.presets.count,
            "systemIsDark": ThemeManager.shared.systemIsDark,
            "resolvedThemeID": ThemeManager.shared.theme.id,
            "resolvedThemeIsDark": ThemeManager.shared.theme.isDark,
            "openPanelShortcut": ShortcutRegistry.shared.shortcut(for: .openPanel),
            "pasteShortcut": ShortcutRegistry.shared.shortcut(for: .pasteSelection),
            "statusIcon": PreferencesModel.shared.statusIcon,
            "showInDock": PreferencesModel.shared.showInDock,
            "ignoredApps": PreferencesModel.shared.ignoredApps,
            "filterChips": ItemKind.filterable.map(\.rawValue),
            // What `FilterChips` actually drew as selected on its last render
            // pass - independent of `filters`/`filter` above, which only ever
            // prove the model changed. See `RenderProbe.activeChipIDs`.
            "renderedActiveChips": Array(RenderProbe.activeChipIDs).sorted(),
            // A chip's keyboard focus is meant to be independent of its
            // selection - a pointer click must not leave a persistent
            // accent ring that reads as still-selected once the model has
            // moved to another chip. See `RenderProbe.focusedChipIDs`.
            "renderedFocusedChips": Array(RenderProbe.focusedChipIDs).sorted(),
            "tabs": TabConfiguration.shared.tabs.map(\.id),
            "visibleTabs": TabConfiguration.shared.visible.map(\.id),
            "tabLayout": store.activeTab.layout.rawValue,
            "storedTabLayout": (TabConfiguration.shared.spec(for: store.activeTabID)?.layout.rawValue) ?? "",
            "renderedLayout": RenderProbe.layout,
            "tabDensity": store.activeTab.density.rawValue,
            "selectedRole": store.selectedItem?.role.rawValue ?? "",
            "noteCount": store.count(ofRole: .note),
            "skillCount": store.count(ofRole: .skill),
            "clipCount": store.count(ofRole: .clip),
            "fileCount": store.fileCount,
            "selectedPlatform": store.selectedItem?.platform?.rawValue ?? "",
            "focusedAction": store.focusedActionIndex ?? -1,
            "actionCount": store.actionsForSelection.count,
            "selectionStride": store.selectionStride,
            "movingItem": store.movingItemID?.uuidString ?? "",
            "historyLimitEnabled": PreferencesModel.shared.historyLimitEnabled,
            "historyLimitValue": PreferencesModel.shared.historyLimit,
            "filterStages": FilterStageTimings.report,
            "openingItem": store.openingItemID?.uuidString ?? "",
            "openChoice": store.openChoice,
            "openTargets": store.openTargets.map { ["name": $0.name,
                                                    "isDefault": $0.isDefault,
                                                    "isNative": $0.isNative] },
            "syncConnected": SyncManager.shared.isConnected,
            "syncServiceRunning": SyncService.shared.isRunning,
            "syncToken": SyncManager.shared.token ?? "",
            "syncSpaceID": SyncManager.shared.space?.id ?? "",
            "syncDevices": SyncManager.shared.space?.devices ?? 0,
            "syncShared": SyncManager.shared.space?.shared ?? false,
            "syncRemoteItems": SyncManager.shared.space?.items ?? 0,
            "syncMerge": SyncManager.shared.mergeOnSync,
            "lastChangeCount": SyncManager.shared.lastChangeCount,
            // ---- M5: pin/order round-trip, fresh-install restore, local-only sync
            "m5_pinnedOrder": store.pinnedIDs.map(\.uuidString),
            // M20/S4: the item rows' own flags, which is the OTHER pin record.
            // A fold that updates one and not the other is invisible to either
            // one on its own.
            "m20_pinnedFlagIDs": store.items.filter(\.isPinned).map(\.id.uuidString),
            "m20_mediaFileExists": lastMediaFileExists,
            "m20_deduplicate": store.deduplicate,
            "m20_titles": store.items.map(\.displayTitle),
            "m5_lastMediaFile": lastMediaFile,
            "m5_lastMediaItemID": lastMediaItemID,
            "m5_hasRestorableAccount": SyncManager.shared.hasRestorableAccount,
            "local_hasTombstone": lastHasTombstone,
            "lastKitPath": lastKitPath,
            "syncConfigured": SyncClient.shared.isConfigured,
            "serverConfigComplete": serverConfigSnapshot.isComplete,
            "serverConfigMissing": serverConfigSnapshot.missing,
            "serverDatabaseName": serverConfigSnapshot.databaseName,
            "selectedDateLabel": store.selectedItem?.dateLabel ?? "",
            "menuBarTitle": CopyConfirmation.shared.title,
            "menuBarIconTrailing": CopyConfirmation.shared.iconTrailing,
            "syncService": SyncClient.shared.baseURL?.absoluteString ?? "",
            "syncError": SyncManager.shared.lastError ?? "",
            // "Is there something a person should go look at right now" -
            // the coarser, stickier question `syncError`/`syncState` do not
            // answer, driven by `syncSimulateFailure`/`syncSimulateSuccess`.
            "hasVisibleFailure": SyncManager.shared.hasVisibleFailure,
            "visibleFailureMessage": SyncManager.shared.visibleFailureMessage ?? "",
            // What the menu-bar tooltip would say, built the same way the
            // real badge builds it - see AppDelegate.currentSyncTooltipForTesting
            // for why this cannot be read off a real status item under
            // CLIP_HEADLESS=1.
            "syncTooltip": AppDelegate.currentSyncTooltipForTesting,
            "lastToken": lastToken,
            "capture": lastCapture,
            "emptyActionFocus": store.focusedEmptyAction ?? -1,
            "emptyTabFocusable": store.isEmptyTabFocusable,
            "moveChoice": store.moveChoice,
            "moveDestinations": store.moveDestinations.map(\.rawValue),
            "actionSymbols": store.actionsForSelection.map { $0.rawValue },
            "skillCountDetected": store.count(ofRole: .skill),
            "providers": AIService.shared.providers.map {
                // `account` (M28): which Keychain entry this connection's key
                // lives under. A recovered connection is only correct if it
                // came back bound to the account the key was actually found
                // in - a rebuild with a fresh id would look identical here
                // without it, and would never find its own key again.
                ["name": $0.name, "role": $0.role.rawValue, "health": $0.health.rawValue,
                 "model": $0.model, "kind": $0.kind.rawValue, "account": $0.keychainAccount]
            },
            "primaryProvider": AIService.shared.primaryProvider?.name ?? "",
            "backupProvider": AIService.shared.backupProvider?.name ?? "",
            "aiLastUsedProvider": AIService.shared.lastUsedProviderName ?? "",
            "aiDidFailOver": AIService.shared.didFailOver,
            // Every AI-dependent surface's own live "is this here" check, so
            // a probe can prove none of them was missed rather than trusting
            // that a grep for `isAvailable` found every call site.
            "aiGateSurfaces": AIGate.surfaces.map {
                ["name": $0.name, "present": $0.isPresent()]
            },
            "aiGateSentence": AIGate.sentence,
            "copyConfirmation": PreferencesModel.shared.showCopyConfirmation,
            "copyConfirmationTitle": CopyConfirmation.shared.title,
            "panelFrame": PanelController.shared.frameForProbe,
            // ---- M9: badge/action-row overlap (requirement 1's own probe) -
            // reads whatever `HistoryStore.selectedID` currently is, since
            // both the badge and the action row are drawn for the SELECTED
            // row regardless of a real hover (no synthetic mouse event
            // reaches SwiftUI's gesture recognizers on this panel - see the
            // note beside `snapshotPanel` above). `[]` for either frame
            // means that slot was never reported (e.g. selected item has no
            // quick-paste badge, index >= 9) - distinct from a reported
            // zero-size rect.
            "m9_selectedBadgeFrame": HistoryStore.shared.selectedID
                .flatMap { ItemFrameProbe.shared.frame(.badge, for: $0) }
                .map { [$0.origin.x, $0.origin.y, $0.width, $0.height] } ?? [],
            "m9_selectedActionsFrame": HistoryStore.shared.selectedID
                .flatMap { ItemFrameProbe.shared.frame(.actions, for: $0) }
                .map { [$0.origin.x, $0.origin.y, $0.width, $0.height] } ?? [],
            // `false` both when the two genuinely do not intersect AND when
            // either frame was never reported - the two empty-frame arrays
            // above are what a probe checks first to tell those apart.
            "m9_selectedBadgeActionsIntersect": HistoryStore.shared.selectedID
                .flatMap { ItemFrameProbe.shared.intersects(for: $0) } ?? false,
            "m9_frameProbeSelfTestOverlap": lastFrameProbeSelfTestOverlap ?? false,
            "m9_frameProbeSelfTestDisjoint": lastFrameProbeSelfTestDisjoint ?? false,
            "m9_diagnosticsFullReportLength": lastDiagnosticsFullReportLength,
            // ---- M7: theme editor beside the panel, one layout on every screen
            "m7_layoutMode": PanelController.shared.layoutMode == .themeEditing
                ? "themeEditing" : "normal",
            "m7_settingsFrame": PanelController.shared.themeEditingSettingsFrameForProbe,
            "m7_sheetFrame": PanelController.shared.themeEditingSheetFrameForProbe,
            "m7_panelFrame": PanelController.shared.frameForProbe,
            "m7_panelVisible": PanelController.shared.isVisibleForProbe,
            "m7_panelWindowNumber": PanelController.shared.panelWindowNumberForProbe,
            "m7_focusLossAllowlistContainsSettings":
                PanelController.shared.themeEditingAllowlistContainsSettingsForProbe,
            "m7_settingsKeyWindow": SettingsWindowController.shared.isKeyWindow,
            "m7_panelIsKeyWindow": PanelController.shared.panelIsKeyForProbe,
            "m7_previewAccent": ThemeManager.shared.previewTheme?.accent.hexString ?? "",
            "m7_panelBehindSettings": PanelController.shared.panelIsBehindSettingsForProbe,
            // ---- M9: theme builder as a design system, 9.1-9.4
            "m9_panelLuminance": lastPanelLuminance ?? -1,
            "m9_previewIsDark": ThemeManager.shared.previewTheme?.isDark ?? false,
            "m9_prompts": MarkdownPromptTestRegistry.shared.snapshot(),
            "m7_settingsFrameNow": {
                guard let w = NSApp.windows.first(where: { $0.title == "Clip Settings" })
                else { return [Double]() }
                let f = w.frame
                return [f.origin.x, f.origin.y, f.width, f.height]
            }() as [Double],
            // ---- M17: the theme builder as its own window, with a contrast
            // matrix. `m17_builderFrame`/`m17_panelFrame` reuse the exact
            // properties section 136 already reads (M7's own layout
            // machinery, now pointed at the builder window) so the two
            // sections can never disagree about what "the builder window"
            // or "the panel" actually measures.
            "m17_isOpen": ThemeBuilderWindowController.shared.isOpen,
            "m17_builderFrame": PanelController.shared.themeEditingSettingsFrameForProbe,
            "m17_panelFrame": PanelController.shared.frameForProbe,
            "m17_builderFrameNow": {
                guard let w = NSApp.windows.first(where: { $0.title == "Theme Builder" })
                else { return [Double]() }
                let f = w.frame
                return [f.origin.x, f.origin.y, f.width, f.height]
            }() as [Double],
            // `.orderOut` (what `close()` calls) leaves the window in
            // `NSApp.windows` but not visible - `m17_builderFrameNow` alone
            // cannot tell "closed" from "still on screen", this can.
            "m17_builderIsVisible": NSApp.windows.first(where: { $0.title == "Theme Builder" })?.isVisible ?? false,
            "m17_groupsOpen": ThemeBuilderView.groupTitles,
            "m17_selectedToken": ThemeBuilderWindowController.shared.state.selectedToken ?? "",
            "m17_matrixCells": ThemeRules.matrixCells(for: ThemeBuilderWindowController.shared.state.theme.appTheme).map {
                // `name` is the pairing's own unique key (`ThemeRules.
                // Pairing.name`, also `MatrixCell.id`) - `text`/`surface`
                // alone are NOT unique: e.g. "Accent as text on card" and
                // "Accent as a mark on card" share the same (accent,
                // cardBackground) pair but grade a different, derived
                // foreground colour. `m17_ratioFor` takes this name so a
                // probe can address the SAME cell unambiguously.
                ["name": $0.pairing.name, "text": $0.pairing.foregroundToken,
                 "surface": $0.pairing.backgroundToken,
                 "ratio": $0.ratio, "aa": $0.passesAA, "aaa": $0.passesAAA, "apca": $0.apca,
                 "required": $0.pairing.level.ratio, "level": $0.pairing.level.label,
                 // M33: the SAME classifier `IssueCard.preview` renders
                 // from ("text"/"ring"/"surfaceStep"/"icon") and the SAME
                 // visibility tier `rankedFailing` groups by - both read
                 // straight off `ContrastMatrixView`'s own shared
                 // functions, so a probe can assert the real category and
                 // the real group a cell renders in, not a re-derivation.
                 "previewKind": ContrastMatrixView.previewKind(for: $0.pairing).rawValue,
                 "visibilityTier": ContrastMatrixView.visibilityTier($0)] as [String: Any]
            },
            // M30 redesign: the same "is there anything to say" question
            // `ContrastMatrixView`'s own header asks.
            "m17_matrixAllClear": ThemeRules.matrixCells(
                for: ThemeBuilderWindowController.shared.state.theme.appTheme
            ).allSatisfy(\.passesAA),
            // M33: calls `ContrastMatrixView.rankedFailing` itself - the
            // SAME static function the panel's own `rankedFailing` property
            // calls - rather than re-sorting `ThemeRules.matrixCells` a
            // second time here. The order used to be re-derived in both
            // places by hand (worst-first, spelled out twice); a probe
            // reading a hand-copied second sort is exactly how a ranking
            // change ships in the view while the probe keeps testing the
            // old one.
            "m17_matrixIssueOrder": ContrastMatrixView.rankedFailing(
                for: ThemeBuilderWindowController.shared.state.theme.appTheme
            ).map(\.pairing.name),
            // T3-M9: the exact ratio the guidance panel's own note-role text
            // (the "N colors may be hard to see" header, every row's
            // location/problem caption) reads at right now, computed the
            // SAME way `ContrastMatrixView.panelNote` computes it -
            // `AppTheme.secondaryText(on:)` against the theme's OWN
            // `panelBackground` - so a probe checks the real committed
            // color rather than a hand-copied second formula. Before T3-M9
            // this text used `SettingsPalette.note`, resolved by the
            // SYSTEM's appearance rather than the theme's own mode; this
            // key lets a probe catch that class of regression again without
            // needing a real screenshot.
            "m30_panelNoteRatio": {
                let t = ThemeBuilderWindowController.shared.state.theme.appTheme
                return ThemeRules.ratio(t.secondaryText(on: t.panelBackground), on: t.panelBackground)
            }(),
            // T3-M10: the SAME per-mode formula as `m30_panelNoteRatio`
            // above, computed against `cardBackground` instead of
            // `panelBackground` - the ground the assistant strip's own
            // labels ("Ask for a change", "Or choose one", the chevron)
            // paint on now that the strip's background itself reads
            // `AppTheme.cardBackground` instead of the native
            // `Color(nsColor: .controlBackgroundColor)` it used before.
            // Computed directly off the draft theme (no AI connection
            // required to exist), so a probe can grade it even when the
            // assistant strip itself is hidden.
            "m10_cardNoteRatio": {
                let t = ThemeBuilderWindowController.shared.state.theme.appTheme
                return ThemeRules.ratio(t.secondaryText(on: t.cardBackground), on: t.cardBackground)
            }(),
            // Whether the hand-rolled "Show the full check" row is
            // currently expanded - the shared state toggle itself, not a
            // proxy for it.
            "m17_matrixFullAuditOpen": ThemeBuilderWindowController.shared.state.matrixFullAuditOpen,
            "m17_lastIssueCopy": lastIssueCopy ?? [String: String](),
            // The ground truth for "matrix cell count == pairings count" -
            // computed directly from `ThemeRules.pairings.count` rather than
            // a probe re-deriving it by scanning source text, which
            // undercounts the pairings a loop generates from one line of
            // Swift (the type-tint and panel-over-desktop loops each turn
            // ONE source line into several real pairings).
            "m17_pairingsCount": ThemeRules.pairings.count,
            // Every editable token's CURRENT hex on the live draft - what
            // `ColorTokenRow`'s own hex field is, at this instant, showing -
            // for the alpha round-trip proof (set A0 alpha, read it straight
            // back here).
            "m17_draftTokens": Dictionary(uniqueKeysWithValues: CustomTheme.allTokenNames.compactMap {
                name -> (String, String)? in
                ThemeBuilderWindowController.shared.state.theme.hex(forToken: name).map { (name, $0) }
            }),
            // M34: whether `ColorTokenRow`'s own quiet dot would show for
            // each editable token right now - the exact same
            // `ColorTokenRow.worstFinding` call the row itself makes to
            // decide the dot, read back as a dict (a plain SwiftUI `Circle`
            // carries no text a probe could otherwise read off the render).
            // The ratio number that used to sit here is gone from the row
            // entirely, so there is nothing left to read it back as.
            "m17_colorRowFlag": Dictionary(uniqueKeysWithValues: CustomTheme.allTokenNames.map {
                name -> (String, Bool) in
                let finding = ColorTokenRow.worstFinding(
                    for: name, in: ThemeBuilderWindowController.shared.state.theme.appTheme)
                return (name, finding.map { !$0.passes } ?? false)
            }),
            // The PERSISTED theme's tokens, read back from `CustomThemeStore`
            // (not the live draft) - proves alpha survives a real save, not
            // only the in-memory editor.
            "m17_activeCustomTheme": {
                guard ThemeManager.shared.themeID.hasPrefix("custom:"),
                      let custom = CustomThemeStore.shared.theme(withID: ThemeManager.shared.themeID)
                else { return [String: String]() }
                return Dictionary(uniqueKeysWithValues: CustomTheme.allTokenNames.compactMap {
                    name -> (String, String)? in custom.hex(forToken: name).map { (name, $0) }
                })
            }(),
            // "in front (NSApp.orderedWindows)" exactly as the M17 plan's
            // own QA line spells it - front-to-back, so the panel's index
            // must be SMALLER than the builder window's.
            "m17_lastRatioProbe": lastRatioProbe ?? -1,
            "m17_lastStuckExplanation": lastStuckExplanation ?? [String: String](),
            // `NSApp.orderedWindows` does not reliably include a borderless
            // `.floating` `NSPanel` next to a titled window (the exact
            // caveat `panelIsBehindSettingsForProbe`'s own doc comment
            // already records from M7) - so this reuses that same
            // CGWindowList-based ground truth rather than repeating the
            // unreliable approach here.
            "m17_panelInFrontOfBuilder": !PanelController.shared.panelIsBehindSettingsForProbe,
            // ---- M19: "Inspect element" in the theme builder ----
            "m19_isInspecting": ThemeInspectRegistry.shared.isInspecting,
            // What the last `m19_hover` found under the point - empty for a
            // hover over nothing tagged (the real "no theme token here"
            // case), not a missing key.
            "m19_hitTokens": ThemeInspectRegistry.shared.hoveredTokens,
            "m19_scrolledToken": ThemeInspectRegistry.shared.scrolledToken ?? "",
            "m19_flashCount": ThemeInspectRegistry.shared.lastFlashCount,
            // How many tokens are STILL flashing right now, distinct from
            // `m19_flashCount` (the total the last click flashed, which
            // does not itself decay) - this one goes back to 0 on its own
            // 600ms after a click, whether or not another command has run
            // since.
            "m19_activeFlashCount": ThemeInspectRegistry.shared.flashedTokens.count,
            "m19_registryCount": ThemeInspectRegistry.shared.registeredCount,
            // Every registered frame, so a probe can find (say) "the frame
            // carrying `selectedBackground`" and hover its own centre,
            // rather than the app exposing raw screen geometry some other
            // way. Rect is `[x, y, width, height]` in the SAME panel-local,
            // top-left-origin space `m19_hover` takes a point in.
            "m19_registryFrames": ThemeInspectRegistry.shared.allFrames.map {
                ["tokens": $0.tokens,
                 "rect": [$0.rect.origin.x, $0.rect.origin.y, $0.rect.width, $0.rect.height]]
            },
            // The selected item's OWN useCount, read fresh every snapshot -
            // what section 146's swallow proof compares before/after
            // `m19_click`.
            "m19_selectedUseCount": store.selectedItem?.useCount ?? -1,
            // The rule itself, computed against a known screen so the harness
            // cannot pass by parking the panel offscreen.
            "hotkeyOrigin": originProbe(.hotkey),
            "statusItemOrigin": originProbe(.statusItem),
            "tinyScreenHotkeyOrigin": PanelController.origin(
                for: .hotkey, size: PanelController.size,
                visible: NSRect(x: 0, y: 0, width: 400, height: 300), anchor: nil)
                .asArray,
            "screenVisibleFrame": PanelController.probeScreenFrame,
            "lastImportSummary": lastImportSummary,
            "m4_lastImportFailed": lastImportFailed,
            "m4_lastExportImportOutcome": lastExportImportOutcome,
            "m4_lastExportImportUnreadable": lastExportImportUnreadable,
            "m4_lastImageCaptureSucceeded": lastImageCaptureSucceeded,
            "m4_lastMediaDeleteSucceeded": lastMediaDeleteSucceeded,
            "m4_mediaDirPath": MediaStore.shared.mediaDir.path,
            "m4_mainShortcutStatus": ShortcutManager.shared.mainDiagnostic.map { Int($0.status) } ?? Int(noErr),
            "m4_secondaryShortcutStatus": ShortcutManager.shared.secondaryDiagnostic.map { Int($0.status) } ?? Int(noErr),
            "m4_namedShortcutStatuses": ShortcutManager.shared.namedDiagnostics.mapValues { Int($0.status) },
            "m4_unsavedSnapshotPreference": Database.shared.preference("unsavedSnapshotPath") ?? "",
            "metricsSearching": PanelMetrics.shared.isSearching,
            "metricsNoticeRow": PanelMetrics.shared.showsNoticeRow,
            "metricsBannerHeight": PanelMetrics.shared.bannersHeight,
            "metricsBanners": PanelMetrics.shared.bannerHeights
                .map { "\($0.key)=\($0.value)" }.sorted(),
            "metricsWantedHeight": PanelMetrics.shared.height(within: PanelController.visibleFrame(on: PanelController.activeScreen)),
            "crowding": AppDelegate.lastCrowdingReport,
            "googlePaneText": SettingsProbe.googlePaneText,
            "privacyPaneText": SettingsProbe.privacyPaneText,
            "syncSwitchText": SettingsProbe.syncSwitchText,
            // The property that has to hold: whatever the Google pane drew, the
            // official address is not in it.
            "googlePaneLeaksHost": {
                guard let host = OfficialService.url?.host, !host.isEmpty else { return false }
                return SettingsProbe.googlePaneText.contains(host)
            }() as Bool,
            "serviceKind": SyncManager.shared.serviceKind.rawValue,
            // Proves the official address is reachable by the app and, in the
            // same breath, that it is not the personal one.
            "officialHost": OfficialService.url?.host ?? "",
            "personalHost": SyncClient.shared.personalURL?.host ?? "",
            "statusItemExists": AppDelegate.shared?.hasStatusItem ?? false,
            "lastHexReading": lastHexReading,
            "lastSignIn": lastSignIn,
            "googleEmail": GoogleAuth.shared.account?.email ?? "",
            "syncSpaceItems": SyncManager.shared.space?.items ?? -1,
            "lastSettingsRoundTrip": lastSettingsRoundTrip,
            "lastSettingsDiagnostic": lastSettingsDiagnostic,
            "searchMs": (lastSearchMilliseconds * 10).rounded() / 10,
            "perf": perfSnapshot,
            "paletteAudit": lastPaletteAudit,
            "derivationAudit": lastDerivationAudit,
            "visibleOrder": lastVisibleOrder,
            "payloadResult": lastPayloadResult,
            "keyedReply": lastKeyedReply,
            "batchTokens": lastBatchTokens,
            "payloadTypes": lastPayloadTypes,
            "manualOrders": lastManualOrders,
            "perfEnabled": Perf.isEnabled,
            "rssMB": residentSnapshot,
            "lastThemeFromDesign": lastThemeFromDesign,
            "marked": store.markedIDs.count,
            "selectedHex": store.selectedItem?.hexColor ?? "",
            "selectedReviewed": store.selectedItem?.reviewedAt != nil,
            "sortOptions": SortOrder.allCases.map(\.rawValue),
            "actionOrder": store.selectedItem.map {
                ItemAction.available(for: $0, isPinned: store.isPinned($0.id)).map(\.rawValue)
            } ?? [],
            "settingsCadence": SettingsSync.shared.cadence.rawValue,
            // `hasPendingRow`, never `pendingRow()`: the latter records what it
            // hands out, so polling state used to mark the settings row sent
            // without it ever reaching a request.
            "settingsRowPending": SettingsSync.shared.hasPendingRow,
            // ---- M29
            "settingsValue": Self.lastSettingsValue,
            "settingsPayload": Self.lastSettingsPayload,
            "settingsStamps": Self.lastSettingsStamps,
            "syncedKeyCount": SettingsRegistry.syncedKeys.count,
            "machineLocalKeys": SettingsRegistry.machineLocalKeys.sorted(),
            "backupError": Self.lastBackupError,
            "backupSections": Self.lastBackupSections,
            "backupCounts": Self.lastBackupCounts,
            "backupDropSummary": Self.lastBackupDropSummary,
            "restoreSummary": Self.lastRestoreSummary,
            "safetyCopy": Self.lastSafetyCopy,
            "mergeResult": Self.lastMergeResult,
            "syncConnection": Self.connectionLabel,
            "checkingConnections": AIService.shared.checkProgress.map {
                "\($0.name) \($0.index)/\($0.total)"
            } ?? "",
            "composeCount": lastComposeCount,
            // ---- Paste actions
            "pasteActionsOrder": PasteActionStore.shared.actions.map(\.kind.rawValue),
            // What the action panel would offer, and what it is doing.
            "pasteMenuTitles": PasteActionStore.shared.enabled.map(\.title),
            "pasteMenuSubmenus": Dictionary(uniqueKeysWithValues:
                PasteActionStore.shared.enabled
                    .filter { $0.kind.hasSubmenu }
                    .map { ($0.title, PasteActionStore.shared.submenu(for: $0)) }),
            "actionPanelOpen": ActionPanelController.shared.isOpen,
            // Empty under CLIP_HEADLESS=1 - see ActionPanelController.frameForProbe.
            "actionPanelFrame": ActionPanelController.shared.frameForProbe,
            "actionPanelPhase": Self.actionPanelPhase,
            "actionPanelFailureMessage": Self.actionPanelFailureMessage,
            "actionPanelFailureRemedy": Self.actionPanelFailureRemedy,
            "actionPanelSource": ActionPanelController.shared.model.sourceText,
            "actionPanelDraft": ActionPanelController.shared.model.draft,
            "actionPanelOriginal": ActionPanelController.shared.model.original,
            "actionPanelStored": ActionPanelController.shared.model.lastStored?.fullText ?? "",
            "actionPanelCandidates": ActionPanelController.shared.model.candidates
                .map(\.fullText),
            // The keyboard-navigable row currently highlighted, and whether
            // one row's submenu is open right now - both read straight off
            // `ActionPanelModel`, the same source `ActionPanelView` renders
            // from.
            "actionPanelFocusedRow": ActionPanelController.shared.model.focusedRowID ?? "",
            "actionPanelSubmenuOpen": ActionPanelController.shared.model.expandedParentID != nil,
            // What `ActionTooltipKey` currently publishes for the four
            // always-on-turned-conditional tooltips (close/discard/copy/
            // paste) - empty string when nothing is showing. See
            // `ActionPanelController.tooltipTextForProbe`.
            "actionPanelTooltip": ActionPanelController.shared.tooltipTextForProbe ?? "",
            "keychainReads": KeychainStore.backingStoreReads,
            "resyncSummary": lastResyncSummary,
            "resyncAgrees": lastResyncAgrees,
            "tombstoneCount": lastTombstoneCount,
            "syncSkipped": SyncClient.shared.lastSkipped.map { "\($0.seq): \($0.reason)" },
            "secretReads": KeychainStore.readsByAccount,
            "panelPlacement": PreferencesModel.shared.panelPlacement.rawValue,
            "panelOrigin": PreferencesModel.shared.rememberedPanelOrigin?.asArray ?? [],
            // Where the panel WOULD open, for each placement, on a fixed screen
            // - so the rule can be checked without moving a real window.
            "placementOrigins": Dictionary(uniqueKeysWithValues:
                PanelPlacement.allCases.map { placement in
                    (placement.rawValue, PanelController.origin(
                        for: .hotkey,
                        size: NSSize(width: 520, height: 640),
                        visible: NSRect(x: 0, y: 0, width: 1600, height: 1000),
                        anchor: nil,
                        remembered: NSPoint(x: 300, y: 200),
                        placement: placement,
                        pointer: NSPoint(x: 900, y: 800)).asArray)
                }),
            "pasteEnabledCount": PasteActionStore.shared.enabled.count,
            "pasteLanguages": PasteActionStore.shared.languages,
            "pasteStyles": PasteActionStore.shared.styles,
            "pastePair": [PasteActionStore.shared.pair.first,
                          PasteActionStore.shared.pair.second],
            "pasteInstruction": lastInstruction,
            "pasteCustomProblem": lastCustomProblem,
            "pasteLanguageProblem": lastLanguageProblem,
            "pasteRunning": PasteTransform.shared.runningLabel ?? "",
            "pasteOutcome": PasteTransform.shared.lastOutcome.map {
                ["instruction": $0.instruction, "input": $0.input, "output": $0.output,
                 "pasted": $0.pasted, "failure": $0.failure ?? ""]
            } ?? [:],
            // ---- Notices
            "noticeKind": NoticeCenter.shared.current?.kind.rawValue ?? "",
            "noticeMessage": NoticeCenter.shared.current?.message ?? "",
            "noticeRemedy": NoticeCenter.shared.current?.remedy ?? "",
            "noticeOpensAI": NoticeCenter.shared.current?.opensAISettings ?? false,
            "noticeAction": NoticeCenter.shared.current?.action?.title ?? "",
            "noticeKey": NoticeCenter.shared.current?.key ?? "",
            "noticePendingCount": NoticeCenter.shared.pending.count,
            "noticePendingKinds": NoticeCenter.shared.pending.map(\.kind.rawValue),
            "badgeVisible": NoticeCenter.shared.badgeVisible,
            "badgeMessage": NoticeCenter.shared.badgeMessage ?? "",
            "promoDismissed": PreferencesModel.shared.aiPromoDismissed,
            // M1 - N3/N4: proof that an action closure actually ran, and how
            // many integrity alerts this launch would have shown.
            "m1_noticeActionRan": QABridge.noticeActionRanForTesting,
            "m1_integrityAlertsForTesting": AppDelegate.integrityAlertsForTesting,
            // ---- Onboarding
            "hasSeenOnboarding": PreferencesModel.shared.hasSeenOnboarding,
            "appearanceName": NSApp.effectiveAppearance.name.rawValue,
            "settingsAppearanceName": SettingsWindowController.shared.windowAppearanceNameForTesting,
            // Whether the real welcome window is up right now, so a probe can
            // confirm `onboardingWindowClose` (or either in-content button,
            // once one exists) actually took it away rather than merely
            // setting the flag.
            "onboardingWindowOpen": NSApp.windows.contains {
                $0.title == "Welcome to Clip" && $0.isVisible
            },
            // ---- Keyboard modality and global bindings
            "recordingActive": ShortcutRecording.isActive,
            "appActive": NSApp.isActive,
            "m0_headless": isHeadless,
            "m22_recheckArmed": NoticeCenter.shared.recheckArmed,
            "m22_recheckTicks": NoticeCenter.shared.recheckTicks,
            "m0_lastTabRenderMS": lastTabRenderMS,
            "m0_tabRenderSamples": tabRenderSamples,
            "m0_pendingNoticeKeys": NoticeCenter.shared.pending.compactMap(\.key).sorted(),
            // Every unresolved notice, so a probe can assert a persistent
            // condition is up while a transient message sits in front of it.
            "m0_pendingNotices": NoticeCenter.shared.pending.map {
                ["kind": $0.kind.rawValue, "message": $0.message,
                 "remedy": $0.remedy ?? "", "action": $0.action?.title ?? ""]
            },
            "globalShortcutNames": ShortcutManager.shared.registeredGlobalNames,
            // Carbon's actual registration table, not the shortcut string
            // stored next to the item - proves the row exists, not just that
            // a string got saved. See ShortcutManager.registeredItemIDs.
            "registeredItemIDs": ShortcutManager.shared.registeredItemIDs.map(\.uuidString).sorted(),
            // The SHIPPED diagnostics, not the CLIP_TESTING mirror above.
            // Everything the user's own Shortcut Diagnostics panel shows comes
            // from these, so a test of them is a test of what the user reads.
            "itemShortcutDiagnostics": ShortcutManager.shared.itemDiagnostics.map { id, d in
                ["id": id.uuidString, "shortcut": d.shortcut, "status": Int(d.status),
                 "registered": d.registeredAt != nil, "outcome": d.lastOutcome,
                 "fired": d.lastFiredAt != nil]
            }.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") },
            "shortcutLaunchReport": ShortcutManager.shared.lastLaunchReport,
            "shortcutDiagnosticReport": ShortcutManager.shared.diagnosticReport(items: store.items),
            // M8.5, 02/09: exactly what Settings > Shortcuts' "Item
            // shortcuts" section renders - same sort (title, case
            // insensitive), same status words (ShortcutManager.
            // itemStatusWord) - so section 137's V7 gate can assert on the
            // section's content without a live Settings window, which
            // CLIP_HEADLESS=1 never creates.
            "m8b_itemShortcutRows": store.items
                .filter { !($0.shortcut ?? "").isEmpty }
                .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
                .map { item -> [String: Any] in
                    let (registered, word) = ShortcutManager.shared.itemStatusWord(item.id)
                    return ["id": item.id.uuidString, "title": item.displayTitle,
                            "combo": Shortcut.display(item.shortcut ?? ""),
                            "status": word, "registered": registered,
                            "location": ShortcutsPane.location(for: item)]
                },
            "m8b_itemShortcutsEmptyText": ShortcutsPane.noItemShortcutsText,
            // M8.3, 02/09: every mounted `EditableLabel`'s live state, keyed
            // by its `testID` - see EditableLabelTestRegistry.
            "m8b_editableLabels": EditableLabelTestRegistry.shared.snapshot(),
            "pasteKeystrokeOutcome": PasteKeystroke.lastOutcome,
            // Problem 2: a Keychain read must never be allowed to prompt, so
            // the status it returns is the only evidence there is.
            "keychainLastReadStatus": Int(KeychainStore.lastReadStatus),
            "keychainNeedsRepair": KeychainStore.needsRepair,
            // What Carbon's handler actually did with the last keypress:
            // splits "the event never arrived" from "it arrived and resolved
            // to nothing".
            "hotkeyDispatchCount": ShortcutManager.shared.hotkeyDispatchCount,
            "lastHotkeyDispatch": ShortcutManager.shared.lastHotkeyDispatch,
            "hotkeySuppressedByRecording": ShortcutManager.shared.hotkeySuppressedByRecording,
            "lastPasteGate": PasteTrace.lastStage,   // the shipped trace, not a test-only mirror
            "hotkeyToPasteMS": {
                guard let a = lastHotkeyPostAt, let b = TestIsolation.lastSuppressedPasteAt,
                      b > a else { return -1.0 }
                return (b.timeIntervalSince(a) * 1000).rounded()
            }(),
            // Whether this process is allowed to post to the HID event tap,
            // read live every state write, plus the outcome of the last
            // `fireGlobalHotkey` command - together these tell "did not
            // fire" apart from "was not permitted to send one".
            "axTrusted": AXIsProcessTrusted(),
            "hotkeyOutcome": lastHotkeyOutcome.rawValue,
            // How many per-item hotkeys `AccessibilityGate` has refused, and
            // when the last one was (seconds since epoch, -1 for "never") -
            // proves the gate is actually being consulted on that route,
            // rather than just that the hotkey arrived.
            "accessibilityBlockedCount": AccessibilityGate.blockedCount,
            "accessibilityLastBlockedAt": AccessibilityGate.lastBlockedAt?.timeIntervalSince1970 ?? -1,
            "pasteboard": TestIsolation.board.string(forType: .string) ?? "",
            "pasteboardSnapshot": pbSnapshot,
            "lastCreatedFixtureFileID": lastCreatedFixtureFileID ?? "",
            "lastCreatedFixtureFolderID": lastCreatedFixtureFolderID ?? "",
            "lastCreatedFixtureFilePath": lastCreatedFixtureFilePath ?? "",
            "lastCreatedFixtureFolderPath": lastCreatedFixtureFolderPath ?? "",
            "lastPrimaryActivationOutcome": lastPrimaryActivationOutcome ?? "",
            "selectedID": store.selectedID?.uuidString ?? "",
            "fillingVariables": store.fillingVariablesFor?.displayTitle ?? "",
            "lastThemeFromDesignPasses": lastThemeFromDesignPasses,
            "lastThemeFromDesignFailures": lastThemeFromDesignFailures,
            "timeFilter": store.timeFilter.shortTitle,
            "customThemeNames": CustomThemeStore.shared.themes.map(\.name),
            "customThemes": CustomThemeStore.shared.themes.map { t in
                ["name": t.name, "accent": t.accent, "translucency": t.translucency ?? -1,
                 "accentTextOverride": t.accentTextOverride ?? "",
                 "typeTints": t.typeTints?.count ?? 0]
            },
            "settingsContrast": SettingsPalette.audit(),
            "settingsWindowNumber": settingsWindowNumber,
            // The colors Settings USED to paint, kept as the control: if the
            // measurement is sound these must still fail in light appearance.
            "systemContrastControl": SettingsPalette.systemControl(),
            "designCount": store.count(ofRole: .design),
            "roles": ItemRole.allCases.map(\.rawValue),
            "offerableTabs": ItemCategory.offerable.map(\.id),
            "visibleRoles": store.visibleItems.map { $0.role.rawValue },
            "settingsTabs": SettingsTab.visible.map(\.rawValue),
            "aiFeaturesEnabled": PreferencesModel.shared.aiFeaturesEnabled,
            "themeAudit": themeAudit,
            "themePairings": themePairings,
            "presetRepairReport": presetRepairReport,
            "visiblePlatforms": visible.prefix(12).map { $0.platform?.rawValue ?? "" },

            // ---- M2: the AI key and the sync token repair themselves ----
            // Prefixed so a state key added by another lane's own section
            // cannot collide with one of these under the same name.
            "m2_keychainMissingSecret": KeychainStore.missingSecret,
            "m2_keychainVaultRoundTrip": KeychainStore.vaultRoundTripForTesting,
            "m2_keychainFailingAccounts": Array(KeychainStore.failingAccounts).sorted(),
            "m2_keychainNeedsRepairAccounts": Array(KeychainStore.needsRepairAccounts).sorted(),
            "m2_keychainMissingSecretAccounts": Array(KeychainStore.missingSecretAccounts).sorted(),
            "m2_keychainRepaired": lastRepairResult.repaired,
            "m2_keychainRepairFailed": lastRepairResult.failed,
            "m2_keychainRepairUnreadable": lastRepairResult.unreadable.sorted(),
            "m2_keychainRepairStillMissing": lastRepairResult.stillMissing.sorted(),
            "m2_interactiveRepairInvocations": KeychainStore.interactiveRepairInvocationsForTesting,
            "m2_quarantinedProviderCount": AIService.shared.quarantinedProviderCount,
            "m2_tokenFingerprintPresent": !(Database.shared.preference("sync.tokenFingerprint") ?? "").isEmpty,
            "m2_aiRepairBannerText": SettingsProbe.aiRepairBannerText,
            "m2_syncRepairBannerText": SettingsProbe.syncRepairBannerText,
            // ---- M28: key recovery after a reinstall ----
            // What the store actually holds, enumerated rather than assumed.
            // Under a sandboxed run this reads the sandbox's secrets file and
            // never `SecItem*`, so nothing here can see the real service.
            "m28_storedProviderAccounts": m28StoredAccountsSnapshot,
            "m28_recoverableAccounts": m28RecoverableSnapshot,
            "m28_scan": m28ScanSnapshot,
            "m28_recoveryRuns": KeyRecovery.runsForTesting,
            "m28_recoveryRestored": m28Outcome?.restored ?? [],
            "m28_recoveryAlreadyConfigured": m28Outcome?.alreadyConfigured ?? [],
            "m28_recoveryRefused": m28Outcome?.refused ?? false,
            "m28_recoveryMessage": m28Outcome?.message ?? "",
            "m28_recoveryPaneMessage": SettingsProbe.aiRecoveryMessage,
            "m28_inferredKinds": m28InferredKindsSnapshot,
            // Which Keychain service this run is pointed at. The one check
            // that can catch a sandbox that silently stopped being a sandbox.
            "keychainService": AppPaths.keychainService,
            // ---- M3: startup health, backups, migrations, the audit.
            // Prefixed "m3_" per cross-lane coordination: five branches touch
            // this same dictionary, and a duplicate key across lanes is a
            // launch-time crash `guard_state_dictionary()` cannot catch once
            // two lanes' additions are merged into one file.
            "m3_startupHealthFindings": m3HealthFindingsSnapshot,
            "m3_startupHealthMS": m3HealthMSSnapshot,
            "m3_healthFindingsCount": lastHealthFindingsCount,
            "m3_dbUserVersion": m3DbUserVersionSnapshot,
            "m3_dbItemCount": m3DbItemCountSnapshot,
            "m3_dbIntegrityResult": Database.shared.lastIntegrityResult,
            "m3_dbIsOpen": Database.shared.isOpen,
            "m3_lastBackupPath": lastBackupPath,
            "m3_lastRestoreSucceeded": lastRestoreSucceeded,
            "m3_backupCandidateCount": m3BackupCandidatesSnapshot.count,
            "m3_backupCandidates": m3BackupCandidatesSnapshot,
            "m3_auditOrphanCount": lastAuditOrphanCount,
            "m3_auditOrphans": lastAuditOrphans,
            "m3_lastReclaimPath": lastReclaimPath,
            "m3_lastEmptyReclaimedCount": lastEmptyReclaimedCount,
            "m3_hasReclaimedFolder": AppPaths.hasReclaimedFolder(),
            "m3_integrityAlertsForTesting": AppDelegate.integrityAlertsForTesting,
            "m3_lastRunVersionPref": m3LastRunVersionPrefSnapshot,
            "m3_lastRunVersionDefaults": m3LastRunVersionDefaultsSnapshot,
            "m3_lastDirectoryErrorPath": AppPaths.lastDirectoryError?.path ?? "",
            "m3_lastPermissionErrorPath": AppPaths.lastPermissionError?.path ?? "",
            "m3_diagnosticsReportText": lastDiagnosticsReportText,
            // ---- M8: first-run overview, menu hygiene, credential explainer
            "m8_overviewVisible": SetupOverviewCoordinator.shared.isVisible,
            "m8_overviewRows": m8OverviewRowsSnapshot,
            "m8_overviewRowCount": m8OverviewRowsSnapshot.count,
            "m8_noticeSecondaryAction": NoticeCenter.shared.current?.secondaryAction?.title ?? "",
            "m8_versionChangeResetCount": AccessibilityGate.versionChangeResetCountForTesting,
            "m8_statusMenuTitles": m8StatusMenuTitlesSnapshot,
            "m27_statusMenuDiagnostics": m27StatusMenuDiagnosticsSnapshot,
            "m8_credentialInvocations": m8CredentialInvocationsSnapshot,
            "m8_credentialInvocationCount": m8CredentialInvocationsSnapshot.count,
            "m8_keychainNeedsRepair": KeychainStore.needsRepair,
            "m8_repairAttempted": AppDelegate.lastRepairOutcomeForTesting != nil,
            "m8_interactiveRepairInvocations": KeychainStore.interactiveRepairInvocationsForTesting,
            // ---- M8 (02/09 follow-up): the Diagnostics-tab sidebar bug,
            // and the Insights summary.
            "m8_settingsSidebarTabCount": settingsSidebarRowCount,
            "m8_settingsSelectedTab": SettingsRouter.shared.tab.rawValue,
            "m8_settingsSidebarVisibility": {
                // `NavigationSplitViewVisibility` is a struct of static
                // values, not an enum - there is no exhaustive switch over
                // it, so this is `==` comparisons with an explicit default.
                let v = SettingsRouter.shared.sidebarVisibility
                if v == .all { return "all" }
                if v == .doubleColumn { return "doubleColumn" }
                if v == .detailOnly { return "detailOnly" }
                return "automatic"
            }() as String,
            "m8_insightCount": lastInsightLines.count,
            "m8_insightLines": lastInsightLines,

            // ---- M15: Getting Started checklist ----
            "m15_steps": m15StepsSnapshot,
            "m15_progress": ["done": m15ChecklistSnapshot.doneCount,
                              "total": m15ChecklistSnapshot.steps.count],
            "m15_badge": m15ChecklistSnapshot.remainingCount,
            "m15_step1DeepLinkCount": SetupChecklist.step1DeepLinkCountForTesting,
            // ---- M14: two-layer settings (hub + sub-pages), section 141.
            "m14_settingsPage": SettingsRouter.shared.page() ?? "",
            "m23_settingsWindow": SettingsWindowController.shared.windowNumberForTesting,
            "m23_builderWindow": ThemeBuilderWindowController.shared.window?.windowNumber ?? 0,
            "m14_canGoBack": SettingsRouter.shared.canGoBack(),
            "m14_canGoForward": SettingsRouter.shared.canGoForward(),
            "m14_settingsTabIsHub": SettingsRouter.shared.tab.isHub,
            // Every hub tab's own sub-pages, straight from the same registry
            // the sidebar's search reads (`SettingsTab.subpages`) - lets the
            // probe enumerate every real (tab, page) pair without keeping a
            // second, hand-maintained list in Python that could drift from
            // what the app actually offers.
            // Settings > Sync account card (user, 03/09 night): the same
            // words the card renders - name, email, picture URL, status word.
            "sync_accountName": GoogleAuth.shared.account?.name ?? "",
            "sync_accountEmail": GoogleAuth.shared.account?.email ?? "",
            "sync_accountPicture": GoogleAuth.shared.account?.picture ?? "",
            "sync_accountStatus": SyncPane.syncStatus(SyncManager.shared.syncState).word,
            "m14_allSubpages": SettingsTab.visible.flatMap { tab in
                (tab.subpages ?? []).map {
                    ["tab": tab.rawValue, "id": $0.id, "title": $0.title] as [String: String]
                }
            },
            // M23: everything about the REAL input path - what the last
            // `real_` command delivered, and the preconditions it needed.
            // One nested key rather than a dozen flat ones, so the literal
            // above stays inside the type checker's budget.
            "realInput": realInputState
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted]) {
            try? data.write(to: stateURL)
            // Written after `secureStorage()` has already run at launch, so it
            // needs its own lock-down. This file is a full state dump - it
            // contains clipboard content - and it was landing at 0644.
            AppPaths.restrict(stateURL, to: 0o600)
        }
    }
}


/// A deterministic offline model, so every AI feature can be exercised in tests
/// without a key, a network, or a bill.
struct StubAIClient: AIClient {

    /// A reply to hand back instead of the canned ones.
    ///
    /// Without this the stub answered every theme request with the same valid
    /// JSON, so tests that meant to exercise a *messy* reply were really
    /// exercising a clean one and passed no matter what the parser did. A test
    /// that cannot fail is worse than no test: it reports safety it never checked.
    nonisolated(unsafe) static var scriptedReply: String?

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        if let scripted = Self.scriptedReply { return scripted }
        if system.contains("color themes") {
            return """
            {"name":"Stub Theme","accent":"#4F7CFF","accentSecondary":"#8B5CF6",
             "panelBackground":"#0B0E1A","cardBackground":"#171B2E","cardHoverBackground":"#212643",
             "selectedBackground":"#2E3566","surfaceBackground":"#12162608","textPrimary":"#FFFFFF",
             "textSecondary":"#B9BECE","textTertiary":"#787E93","border":"#262B40",
             "isDark":true,"cornerRadius":14}
            """
        }
        if system.contains("proofreader") {
            return user.contains("teh") ? user.replacingOccurrences(of: "teh", with: "the") : "NO_CHANGES"
        }
        if system.contains("tags") { return "alpha, beta, gamma" }
        if system.contains("title") { return "Stub Title" }
        return "IMPROVED: " + user
    }
}

/// Where a named control ACTUALLY ended up on screen, so a real click can be
/// aimed at it.
///
/// This exists because of a measurement, not a preference. A SwiftUI `Button`
/// inside the panel's one `NSHostingView` is not an `NSView`, and through the
/// in-process accessibility tree it comes back as `AXUnknown` with no title,
/// no label and no help - `real_axDump` prints the whole tree, and every tab in
/// the tab bar is one of those. So there is nothing in the rendered output to
/// match a tab by name against.
///
/// The alternative was to compute a tab's position from the layout rules
/// (`HStack`, equal padding). That would be a test that recomputes the thing it
/// is checking, and it would also be wrong: the tabs are content-sized, not
/// equal-width, so the arithmetic would put the click on the neighbouring tab.
///
/// So the view says where it is. `frame(in:)` reports what SwiftUI LAID OUT,
/// not what the source asked for, which means a layout regression moves this
/// rect and the click lands somewhere else - the failure a geometry constant
/// would have hidden.
@MainActor
final class RealTargetRegistry {
    static let shared = RealTargetRegistry()
    private init() {}

    /// Rects in `ThemeInspectRegistry.coordinateSpaceName` - the top-left
    /// origin space `PanelRootView` already declares for the whole panel. Not
    /// a new space: two spaces rooted at the same view that disagree by a flip
    /// is the bug that would make every click land mirrored.
    private(set) var frames: [String: CGRect] = [:]

    func record(_ name: String, _ rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        frames[name] = rect
    }

    var names: [String] { frames.keys.sorted() }
}

extension View {
    /// Publishes this view's rendered frame under `name` for `real_click`.
    ///
    /// Compiled to nothing outside the `Testing` configuration (see the `#else`
    /// half of this file): the shipped app attaches no `GeometryReader` and
    /// keeps no registry.
    func realTarget(_ name: String) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        RealTargetRegistry.shared.record(
                            name, proxy.frame(in: .named(ThemeInspectRegistry.coordinateSpaceName)))
                    }
                    .onChange(of: proxy.frame(in: .named(ThemeInspectRegistry.coordinateSpaceName))) { _, new in
                        RealTargetRegistry.shared.record(name, new)
                    }
            }
        )
    }
}

#else

/// The shipped build has no test harness in it at all.
///
/// The bridge reads commands from a file in Application Support and writes the
/// app's whole observable state back out, including the clipboard history. In a
/// downloadable app that is a remote control: anything able to set an
/// environment variable on the process - a LaunchAgent plist, a modified
/// launcher, another tool the user was persuaded to run - could drive Clip and
/// read everything in it. Gating it on an environment variable is not a
/// security boundary, because the attacker controls the environment.
///
/// So it is compiled out. The `Testing` configuration is identical to `Release`
/// except that it defines `CLIP_TESTING`, and the suite runs against that. What
/// ships cannot be driven, because the code is not in it.
///
/// These stubs exist only so the handful of call sites keep compiling.
@MainActor
enum QABridge {
    static var isEnabled: Bool { false }
    static var isHeadless: Bool { false }
    /// Always false in the shipped app: the real-input harness is not in it.
    static var realInputHoldsPanel: Bool { false }
    static func startIfEnabled() {}
    static func writeState() {}
    static func writeStateFromAmbientChange() {}
}

extension View {
    /// The shipped build records nothing and attaches no `GeometryReader`.
    /// Same signature as the `Testing` half above, so the call site in
    /// `TabsView` needs no `#if` around it.
    func realTarget(_ name: String) -> some View { self }
}

#endif
