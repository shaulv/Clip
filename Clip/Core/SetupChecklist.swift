import SwiftUI

/// One step of the "Getting Started" checklist (M15, added 03/09).
///
/// The user's own words: "give a check list of things to setup and you can
/// see what you already made and what still needs your attention. the user
/// could mark done for his steps if he wanted to."
struct SetupStep: Identifiable {
    let id: String
    let title: String
    let explanation: String
    /// True the moment the real condition is met, independent of any manual
    /// mark - Accessibility granted, a validated AI connection, a tab
    /// layout that differs from the default set, or a connected sync space.
    ///
    /// Explicitly `@MainActor`: every real condition it reads
    /// (`AIService.isAvailable`, `TabConfiguration.tabs`, `SyncManager.space`)
    /// is itself main-actor-isolated, and leaving this plain `() -> Bool`
    /// would make the closure literal below `nonisolated` by the type it is
    /// assigned to, not by where it is written - which is exactly backwards.
    let isAutoDone: @MainActor () -> Bool
    /// Sends the user to wherever finishing this step actually happens.
    let deepLink: @MainActor () -> Void
}

/// The four-step setup checklist and its persisted manual marks.
///
/// `isDone` for any step is `isAutoDone() || manual mark`: a step already
/// satisfied for real cannot be un-done by a stray manual "not done" (the
/// OR reads that way on purpose), and a step the detector cannot prove on
/// its own - nobody can tell "four default tabs" apart from "four tabs this
/// person chose on purpose" - can still be marked done by the person
/// looking at it.
@MainActor
final class SetupChecklist: ObservableObject {

    static let shared = SetupChecklist()

    let steps: [SetupStep]

    /// Bumped whenever something this object cannot observe through Combine
    /// changes - the Accessibility grant (there is no publisher for
    /// `AXIsProcessTrusted()`) or a manual mark. `AIService`, `TabConfiguration`
    /// and `SyncManager` are all `ObservableObject`s already, so a view
    /// holding them as `@ObservedObject` re-renders on its own for those
    /// three; this exists for the one condition that has no object to watch.
    @Published private(set) var revision = 0

    #if CLIP_TESTING
    /// How many times step 1's deep link has actually run, counted
    /// unconditionally so a probe can prove the wiring exists (Z3) without
    /// ever raising the real `tccutil`/system-prompt path - see the guard
    /// inside the closure below, the same shape as
    /// `AccessibilityGate.resetAndAskAgainOnVersionChange()`.
    nonisolated(unsafe) static var step1DeepLinkCountForTesting = 0
    #endif

    private init() {
        steps = [
            SetupStep(
                id: "accessibility",
                title: "Give Clip permission to paste",
                explanation: """
                    Clip types the clip you pick into whatever app you're in, and macOS \
                    requires Accessibility permission for that. Without it, pasting from \
                    Clip does nothing. It fails silently, with no warning, until you turn it \
                    on yourself, in System Settings, under Privacy & Security, then Accessibility.
                    """,
                isAutoDone: { AccessibilityGate.isTrusted },
                deepLink: {
                    #if CLIP_TESTING
                    SetupChecklist.step1DeepLinkCountForTesting += 1
                    // Never the real tccutil reset or system prompt under an
                    // automated run - the same reasoning as every other
                    // `guard !QABridge.isEnabled` in AccessibilityGate: a
                    // real prompt here would hang the harness exactly like
                    // an un-suppressed Keychain prompt does.
                    guard !QABridge.isEnabled else { return }
                    #endif
                    AccessibilityGate.resetAndAskAgain()
                }),
            SetupStep(
                id: "ai",
                title: "Connect an AI model",
                explanation: """
                    Connect a model, and Clip can rewrite, translate, or summarize what you \
                    copy, using a connection you provide. Paste actions run right from an \
                    item's own menu: fix grammar, write a commit message, or turn text into \
                    JSON, among others. Clip can also suggest a name and tags for anything \
                    in your library, and turn a theme you describe in your own words into \
                    one you can use.
                    """,
                isAutoDone: { AIService.shared.isAvailable },
                // M14 page: connections
                deepLink: { SettingsWindowController.shared.show(tab: .ai) }),
            SetupStep(
                id: "tabs",
                title: "Customize your tabs",
                explanation: """
                    Clip starts with a short bar of tabs: All, Prompts, Notes, Skills and \
                    Files. Turn on the ones you use (Design, Colors, Images, Code, \
                    Repositories), put them in the order you want, and choose gallery or \
                    list for each, so the bar matches how you actually work.
                    """,
                // Compares `visible` (what actually shows in the panel's
                // tab bar), never the raw `tabs` array against `defaults`
                // directly - `TabConfiguration.migrateIfNeeded()` runs on
                // every launch and appends every category the user has
                // never seen as a new HIDDEN row, so `tabs` already differs
                // from the literal `defaults` array on a completely
                // untouched fresh install. Those migrated rows are always
                // `visible: false`, so `visible` is unaffected by them and
                // only changes when the user actually turns one on, hides
                // one, reorders, or changes a layout/density - `defaults`'s
                // own hidden entries are excluded the same way on both sides.
                isAutoDone: {
                    TabConfiguration.shared.visible
                        != TabConfiguration.defaults.filter(\.isVisible)
                },
                deepLink: { SettingsWindowController.shared.show(tab: .tabs) }),
            SetupStep(
                id: "sync",
                title: "Sync your account",
                explanation: """
                    Combine this Mac's clipboard history with your other Macs over a token, \
                    so a copy on one shows up on the rest, your own server or Google \
                    sign-in, either way.
                    """,
                isAutoDone: { SyncManager.shared.space != nil },
                // M14 page: account
                deepLink: { SettingsWindowController.shared.show(tab: .sync) })
        ]
    }

    static func manualKey(_ id: String) -> String { "setup.step.\(id).manual" }

    func isManual(_ id: String) -> Bool {
        Database.shared.preference(Self.manualKey(id)) == "1"
    }

    func setManual(_ id: String, done: Bool) {
        Database.shared.setPreference(Self.manualKey(id), done ? "1" : "0")
        revision &+= 1
    }

    /// The combined state a card actually shows: the real condition, or a
    /// manual mark standing in for it.
    func isDone(_ step: SetupStep) -> Bool { step.isAutoDone() || isManual(step.id) }

    /// Whether a shown "done" is a manual mark rather than the real
    /// condition - the "marked by you" note is only honest when this is why.
    func isManualOnly(_ step: SetupStep) -> Bool { isManual(step.id) && !step.isAutoDone() }

    func step(_ id: String) -> SetupStep? { steps.first { $0.id == id } }

    var doneCount: Int { steps.filter { isDone($0) }.count }
    var remainingCount: Int { steps.count - doneCount }

    /// The step the one call-to-action styling should point at.
    var nextUndone: SetupStep? { steps.first { !isDone($0) } }

    /// Forces every dependent view to recompute - called on appear and when
    /// the app regains focus, since granting Accessibility in System
    /// Settings happens in a different app with no notification back here.
    func refresh() { revision &+= 1 }

    #if CLIP_TESTING
    func resetForTesting() {
        for step in steps { Database.shared.setPreference(Self.manualKey(step.id), "0") }
        revision = 0
        Self.step1DeepLinkCountForTesting = 0
    }
    #endif
}
