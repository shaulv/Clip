import AppKit

/// The two things an automated run must never touch: the real Keychain, and the
/// real machine.
///
/// Both were being touched, and both were the same class of mistake as the run
/// that seeded the user's own database.
///
/// 1. **The Keychain.** Every rebuild is ad-hoc signed afresh, so its signature
///    does not match the access list on an item an earlier build created. macOS
///    then asks the user for permission - in an agent app with no window, which
///    means a dialog that cannot appear and a call that never returns. Half an
///    hour was lost to it twice, and every test session interrupted the user for
///    a password they should never have been asked for.
///
/// 2. **The keyboard and the clipboard.** The paste path posts a real ⌘V to the
///    frontmost application and writes to the system pasteboard. Under test that
///    means text appearing in whatever the user happens to be typing in, and
///    their own clipboard replaced without warning, while they are working.
///
/// Everything here is compiled out of the shipped build entirely. In Release the
/// file's contents do not exist, so no environment variable can reach them.
enum TestIsolation {

    /// True only when the harness is compiled in AND the sandbox is on.
    ///
    /// Both halves are required. `CLIP_QA` alone is an interactive session
    /// against real data, where a paste must be a real paste - that is the
    /// point of being able to run the app with the bridge on and use it.
    static var isActive: Bool {
        #if CLIP_TESTING
        return AppPaths.isSandboxed
        #else
        return false
        #endif
    }

    // MARK: - Secrets without the Keychain

    /// Where a sandboxed run keeps the secrets the Keychain would hold.
    ///
    /// A plain file, 0600, inside the sandbox's own 0700 directory, which is
    /// thrown away with the rest of the test data. It holds nothing real: the
    /// probe's own fake tokens and stub keys. Deliberately not an attempt at a
    /// second Keychain - the value here is that there is no prompt and no
    /// access list, not that the file is a vault.
    private static var secretsFile: URL {
        AppPaths.support.appendingPathComponent("test-secrets.json")
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: secretsFile),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    private static func save(_ map: [String: String]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: secretsFile)
        AppPaths.restrict(secretsFile, to: 0o600)
    }

    static func secret(_ account: String) -> String? { load()[account] }

    /// Everything the sandbox is holding, for the one caller that has to see
    /// the whole set rather than name an account it already knows: key
    /// recovery after a reinstall (`KeyRecovery`), where the store IS the
    /// only surviving record of what was configured.
    ///
    /// This is the reason `KeyRecovery` can be tested at all. Its production
    /// path enumerates the real Keychain; routed through here, a sandboxed
    /// run enumerates this file instead and `SecItem*` is never reached, so
    /// the real `app.clip.ai` service cannot be read, written or deleted by
    /// a probe no matter what it asks for.
    static func allSecrets() -> [String: String] { load() }

    static func setSecret(_ value: String, for account: String) {
        var map = load()
        if value.isEmpty { map.removeValue(forKey: account) } else { map[account] = value }
        save(map)
    }

    static func removeSecret(_ account: String) {
        var map = load()
        map.removeValue(forKey: account)
        save(map)
    }

    // MARK: - A pasteboard of its own

    /// The board a sandboxed run reads and writes.
    ///
    /// A named pasteboard is a real `NSPasteboard` with real types and real
    /// change counts, so nothing in the capture or paste path has to behave
    /// differently to be tested - it simply does it somewhere the user cannot
    /// see.
    private static let sandboxBoard = NSPasteboard(name: .init("app.clip.qa.pasteboard"))

    static var board: NSPasteboard { (isActive && !usesTheRealMachine) ? sandboxBoard : .general }

    // MARK: - The one run that is allowed to touch the real machine

    /// Opt-in, `CLIP_TESTING` only: let ONE probe prove the whole journey
    /// ends in another application's document.
    ///
    /// Every other assertion in this suite stops one step short of the thing
    /// the user actually reports. `sendsRealKeystrokes` is false in every
    /// sandboxed run, so the synthesized Command-V - the last step, the only
    /// step the window server can drop in silence, and the step a user with no
    /// Accessibility grant loses - has never once executed under test. A hotkey
    /// path can be green end to end here and dead on their Mac, and it was.
    ///
    /// This flag closes that gap, and nothing else. The store, the media
    /// folder, the preferences and the Keychain stand-in all stay sandboxed:
    /// only the pasteboard and the keystroke become real, because those two
    /// are precisely what cannot be faked. It is off unless the environment
    /// asks for it by name, it does not exist in Release, and the harness that
    /// sets it saves and restores the general pasteboard around the run.
    static var usesTheRealMachine: Bool {
        #if CLIP_TESTING
        return ProcessInfo.processInfo.environment["CLIP_REAL_PASTE"] == "1"
        #else
        return false
        #endif
    }

    // MARK: - Keystrokes that go nowhere

    /// How many ⌘V keystrokes were suppressed, and the last thing that would
    /// have been pasted. Assertions read these instead of the user's documents.
    ///
    /// Inside the flag, like everything else here. These were plain stored
    /// properties, so their storage and their symbols shipped in Release even
    /// though nothing there can ever write to them - a test seam in the user's
    /// binary, which is the same finding as the QA bridge being in it.
    #if CLIP_TESTING
    nonisolated(unsafe) static var suppressedPasteCount = 0
    nonisolated(unsafe) static var lastSuppressedPaste = ""
    #endif

    /// Whether to actually post the keystroke. False under test, always.
    static var sendsRealKeystrokes: Bool { !isActive || usesTheRealMachine }

    /// When the last suppressed paste was recorded, so a probe can measure how
    /// long the whole hotkey round trip actually took instead of guessing a
    /// sleep long enough to cover it.
    #if CLIP_TESTING
    nonisolated(unsafe) static var lastSuppressedPasteAt: Date?
    #endif

    /// Called after a paste is recorded, so whoever is publishing observable
    /// state can republish it.
    ///
    /// This is the half that made two behavioural assertions look like a
    /// broken product. A suppressed paste happens on its own clock - a hotkey
    /// arrives through Carbon, the paste is scheduled, and the keystroke is
    /// recorded roughly 130ms later - and it changes neither the command file
    /// nor `HistoryStore`'s published items, which are the only two things
    /// that used to trigger a state write. So the snapshot a probe reads was
    /// always the one written BEFORE the paste landed, and the counter it
    /// asserted on read zero for ever no matter how long it waited.
    #if CLIP_TESTING
    nonisolated(unsafe) static var onPasteRecorded: (() -> Void)?
    #endif

    static func recordSuppressedPaste(_ text: String) {
        #if CLIP_TESTING
        lastSuppressedPasteAt = Date()
        suppressedPasteCount += 1
        lastSuppressedPaste = text
        onPasteRecorded?()
        #endif
    }

    static func resetPasteRecord() {
        PasteTrace.reset()
        PasteKeystroke.resetRecord()
        #if CLIP_TESTING
        suppressedPasteCount = 0
        lastSuppressedPaste = ""
        #endif
    }
}
