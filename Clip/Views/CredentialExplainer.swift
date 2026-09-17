import AppKit

/// Shown before any path that can raise a macOS password, Keychain, or
/// sign-in prompt: what is about to be asked, why, and what happens if the
/// person backs out - so the system's own prompt is never the first anyone
/// hears of it. "before we ask the user for credentials then we must show
/// him a popup with explanations" (M8.7).
///
/// Every interactive Keychain repair, the Google sign-in button, and the
/// account-deletion action are required to call `confirm(reason:)` and stop
/// if it returns false. A grep gate in the probe (section 137, V9) checks
/// this holds: every `allowInteraction: true` call site and every sign-in or
/// delete entry point is reached only through here, with a written reason
/// for the ones that are allowed to be internal (the delete-then-add inside
/// `KeychainStore.repairAccess()` itself, and the QA bridge's
/// `directRepairAccess` test command, which calls the interactive repair
/// directly on purpose so a headless run never blocks on a real dialog).
///
/// An `NSAlert`, not a SwiftUI sheet: the three entry points this gates are
/// an `@objc` method reachable from a menu item and a notice action, a
/// button inside `SettingsSyncPane`, and a destructive confirm already
/// backed by its own `NSAlert` - none of them already sit inside a SwiftUI
/// presentation this could attach a `.sheet` to, and every other one-off
/// confirmation in this app (`StartupHealth.presentRestorePicker`,
/// `AppDelegate.presentIntegrityAlert`) is an `NSAlert` for the same reason.
@MainActor
enum CredentialExplainer {

    /// `String`-backed so a probe can read which reason a call used
    /// (`invocationsForTesting`) without a second, parallel mapping to
    /// stringify it.
    enum Reason: String {
        case keychainRepair
        case keyRecovery
        case googleSignIn
        case deleteAccount

        var title: String {
            switch self {
            case .keychainRepair: return "Clip will ask macOS to re-read your saved keys"
            case .keyRecovery:    return "Clip will read the API keys already saved on this Mac"
            case .googleSignIn:   return "Clip will open your browser to sign in with Google"
            case .deleteAccount:  return "Clip will ask the sync server to delete your account"
            }
        }

        var body: String {
            switch self {
            case .keychainRepair:
                return """
                What happens: macOS may ask for your password so \
                Clip can re-read the API keys and sync token already saved on \
                this Mac, then store them again under this build's signature.

                Why: a rebuild changes Clip's code signature, and macOS ties \
                Keychain access to that signature. The keys are still there. \
                Clip just can't read them until this runs once.

                If you cancel: nothing is read or changed. The keys stay \
                exactly as they are, still unreadable, and the notice \
                offering this repair stays up.
                """
            case .keyRecovery:
                return """
                What happens: macOS may ask for your password so \
                Clip can read the API keys already saved in your Keychain \
                under this app, and use them to re-create the connections \
                they belong to.

                Why: your keys survived the reinstall. Clip stores them under \
                a fixed name that doesn't change when the app is removed, \
                but Clip's own list of connections went with its database. \
                Reading the keys lets Clip put those connections back instead \
                of asking you to paste keys you have already given it.

                If you cancel: nothing is read and nothing is changed. No \
                connection is created, your keys stay exactly where they are, \
                and you can do this later from Settings > AI.
                """
            case .googleSignIn:
                return """
                What happens: your browser opens to Google's own sign-in \
                page, where you approve Clip's request to connect a sync \
                account.

                Why: this is how Clip connects sync without ever seeing your \
                Google password. Google hands Clip a token, not your \
                credentials.

                If you cancel: nothing changes here. No browser opens, and no \
                account is connected.
                """
            case .deleteAccount:
                return """
                What happens: Clip asks the sync server to delete your \
                account and everything it holds, for every Mac signed in to \
                it.

                Why: this is the only way to remove the synced copy of your \
                data from the server, rather than only disconnecting this Mac.

                If you cancel: nothing is deleted. Your account and its \
                synced data stay exactly as they are.
                """
            }
        }
    }

    #if CLIP_TESTING
    /// Skips the modal under test - a probe cannot click a real `NSAlert` -
    /// and answers as though "Continue" had been pressed unless a test
    /// forces otherwise. `invocationsForTesting` records which reason each
    /// call used, so a probe can prove the RIGHT gate ran, not merely that
    /// some gate did.
    nonisolated(unsafe) static var forcedAnswer: Bool?
    nonisolated(unsafe) private(set) static var invocationsForTesting: [Reason] = []

    static func resetForTesting() {
        forcedAnswer = nil
        invocationsForTesting = []
    }
    #endif

    /// Presents the explanation and returns whether the person chose to
    /// continue. Suspends until they answer.
    @discardableResult
    static func confirm(reason: Reason) async -> Bool {
        #if CLIP_TESTING
        invocationsForTesting.append(reason)
        if let forced = forcedAnswer { return forced }
        // Never a real modal under a headless or sandboxed run: there is
        // nobody there to click it, and it would hang the harness the same
        // way an un-suppressed Keychain prompt does (see `TestIsolation`).
        guard TestIsolation.sendsRealKeystrokes else { return true }
        #endif
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = reason.title
        alert.informativeText = reason.body
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
