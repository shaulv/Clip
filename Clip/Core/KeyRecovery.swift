import AppKit
import Foundation
import Security

/// Puts back the AI connections a reinstall lost, using the keys that never
/// went anywhere (M28).
///
/// ## What actually breaks, and why the existing repair does not cover it
///
/// `KeychainStore.repairAccess()` has existed since the 02/09 milestone and
/// is reachable from three places. It repairs ACCESS: a rebuild changes the
/// code signature, macOS ties Keychain access to that signature, and the
/// repair rewrites the items under the new one. It has never repaired
/// CONFIGURATION, and configuration is what a reinstall destroys.
///
/// The Keychain service name (`app.clip.ai`) is a constant, not something an
/// install generates, so uninstalling Clip removes nothing from the login
/// keychain: every API key is still sitting there. What goes with the app is
/// `~/Library/Application Support/Clip/clip.sqlite`, and with it the
/// `aiProviders` row that said which connections existed, what they were
/// called, which vendor each spoke to and which model. A connection's key is
/// stored under `provider.<uuid>`, and that uuid lived only in that row.
///
/// So after a reinstall `AIService.providers` is empty. That has three
/// consequences, and the third is the user's complaint:
///
/// 1. `KeychainStore.knownAccounts` is empty, so a Keychain miss reads as
///    "nothing was ever configured" rather than "the key is gone", and no
///    notice is raised.
/// 2. `AppDelegate.applicationDidFinishLaunching` gates the whole self-repair
///    on `!AIService.shared.providers.isEmpty || SyncManager.shared.space != nil`,
///    which is false, so nothing even looks.
/// 3. Even running the interactive repair by hand would report "N saved keys
///    now live in one Keychain item" and change nothing visible, because
///    nothing re-creates the rows that make those keys usable.
///
/// This type is the missing third thing: it reads what the store actually
/// holds and rebuilds the connections around it.
///
/// ## Two rules it is built to keep
///
/// **Nothing is read until a person asks.** An unexpected, silent read of the
/// Keychain is precisely what the interactive prompt exists to prevent, so
/// `scan()` never reads a secret's bytes and never prompts; it answers only
/// "is there something here, and can I see inside it without asking". The
/// offer that follows is a dismissible notice with a button. Only pressing
/// that button, through `CredentialExplainer`, allows a read.
///
/// **A refusal is an answer, not a retry.** This is an `LSUIElement` agent
/// app: a modal it did not ask for has nowhere to appear and the call never
/// returns. Every path here either runs with interaction off, or runs once
/// from a real click with an explanation already on screen, and reports what
/// happened. Nothing retries, and nothing loops.
enum KeyRecovery {

    // MARK: - What is there

    /// What a non-interactive look at the store found. No case here required
    /// reading a secret, so producing one can never prompt.
    enum Availability: Equatable {
        /// The store holds nothing for this app.
        case nothingStored
        /// These accounts are readable right now, without asking anyone.
        case readable([String])
        /// Something is stored, and this build cannot see inside it without
        /// the one interactive prompt. The count is unknown, and saying so is
        /// more honest than guessing it.
        case lockedButPresent
    }

    /// Looks, without reading. Safe to call at launch.
    static func scan() -> Availability {
        let (secrets, status) = KeychainStore.allStoredSecrets(allowInteraction: false)
        let accounts = providerAccounts(in: secrets)
        if !accounts.isEmpty { return .readable(accounts) }
        // Nothing readable. Two very different reasons, and the difference is
        // the whole message: an empty store has nothing to offer, while a
        // store that exists but will not open without permission is exactly
        // the case worth offering.
        if status != errSecSuccess, status != errSecItemNotFound, KeychainStore.hasStoredItems() {
            return .lockedButPresent
        }
        return .nothingStored
    }

    /// The accounts in a decoded store that represent an AI connection: not
    /// the sync token, not the server password, not this app's own metadata
    /// entries. Enumerated from what is actually there - no provider name is
    /// ever probed for or assumed.
    static func providerAccounts(in secrets: [String: String]) -> [String] {
        secrets.keys
            .filter { $0.hasPrefix("provider.") && !KeychainStore.isMetaAccount($0) }
            .filter { !(secrets[$0] ?? "").isEmpty }
            .sorted()
    }

    /// The accounts that would actually be restored: stored, and with no
    /// connection already configured against them.
    @MainActor
    static func recoverable(in secrets: [String: String]) -> [String] {
        let configured = Set(AIService.shared.providers.map(\.keychainAccount))
        return providerAccounts(in: secrets).filter { !configured.contains($0) }
    }

    // MARK: - Rebuilding a connection from what survived

    /// The descriptive half of a connection, stored beside its key so a
    /// reinstall can put the connection back rather than only the secret.
    struct Metadata: Codable, Equatable {
        var name: String
        var kind: String
        var endpoint: String
        var model: String

        init(_ provider: AIProvider) {
            name = provider.name
            kind = provider.kind.rawValue
            endpoint = provider.endpoint
            model = provider.model
        }

        var encoded: String {
            (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }

        static func decode(_ raw: String) -> Metadata? {
            guard let data = raw.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(Metadata.self, from: data)
        }
    }

    /// Which vendor a key belongs to, read from the key itself.
    ///
    /// This is not a guess about WHICH accounts exist - those are enumerated
    /// from the store. It is a reading of a key already found, and it only
    /// runs for a key stored before this build started saving metadata
    /// alongside it. Every vendor here publishes its prefix and stamps it on
    /// every key it issues, so the reading is a fact about the string rather
    /// than a hunch about the user.
    ///
    /// Order matters: `sk-ant-` is also `sk-`, so the longer prefix is tested
    /// first. Anything unrecognised becomes `.openaiCompatible`, which is the
    /// wire format most hosted APIs speak and the one the app already offers
    /// as the general case.
    static func inferredKind(fromKey key: String) -> ProviderKind {
        if key.hasPrefix("sk-ant-") { return .anthropic }
        if key.hasPrefix("AIza") { return .gemini }
        if key.hasPrefix("sk-proj-") || key.hasPrefix("sk-") { return .openai }
        return .openaiCompatible
    }

    /// Rebuilds one connection. Deliberately `.untested` and `.unused`: a
    /// recovered key is a key that has not answered a request on this
    /// install, and quietly promoting it to the main connection would be the
    /// silent reconfiguration this whole flow exists to avoid.
    static func rebuild(account: String, key: String, metadata: Metadata?) -> AIProvider {
        let id = String(account.dropFirst("provider.".count))
        if let metadata, let kind = ProviderKind(rawValue: metadata.kind) {
            return AIProvider(id: id, name: metadata.name, kind: kind,
                              endpoint: metadata.endpoint, model: metadata.model,
                              isActive: false, validatedAt: nil,
                              role: .unused, health: .untested)
        }
        let kind = inferredKind(fromKey: key)
        return AIProvider(id: id, name: kind.title, kind: kind,
                          isActive: false, validatedAt: nil,
                          role: .unused, health: .untested)
    }

    // MARK: - Doing it

    /// What a recovery run did, in the words the user is shown.
    struct Outcome: Equatable {
        var restored: [String] = []
        var alreadyConfigured: [String] = []
        /// The person, or macOS on their behalf, declined. Nothing was read
        /// and nothing was changed.
        var refused = false
        var message = ""
    }

    /// How many times `recover` has run this launch, and how many of those
    /// were refused - so a probe can prove a refusal stops rather than loops.
    #if CLIP_TESTING
    nonisolated(unsafe) private(set) static var runsForTesting = 0
    nonisolated(unsafe) private(set) static var lastOutcomeForTesting: Outcome?
    static func resetForTesting() {
        runsForTesting = 0
        lastOutcomeForTesting = nil
    }
    #endif

    /// Reads the store, once, and rebuilds every connection whose key is
    /// there and whose row is not.
    ///
    /// Only ever called from a real click: the launch notice's button, or the
    /// button in Settings > AI. `CredentialExplainer` runs first, so the
    /// system's own prompt is never the first anyone hears of this, and a
    /// "Not now" returns before a single byte is read.
    @MainActor
    @discardableResult
    static func recover() async -> Outcome {
        #if CLIP_TESTING
        runsForTesting += 1
        #endif
        var outcome = Outcome()

        guard await CredentialExplainer.confirm(reason: .keyRecovery) else {
            outcome.refused = true
            outcome.message = "Nothing was read and nothing was changed. Your keys are still "
                            + "saved on this Mac. You can do this later from Settings > AI."
            finish(outcome)
            return outcome
        }

        // The one authorised read. Interaction ON, because an explanation is
        // already on screen and someone is looking at it.
        let (secrets, status) = KeychainStore.allStoredSecrets(allowInteraction: true)
        guard status == errSecSuccess else {
            outcome.refused = true
            outcome.message = "macOS did not allow Clip to read the saved keys (\(statusName(status))), "
                            + "so nothing was changed. Your keys are still in your Keychain. "
                            + "Try again from Settings > AI and choose Allow when macOS asks."
            Database.shared.log("keychain", "Key recovery: the store refused the read (\(status))")
            finish(outcome)
            return outcome
        }

        let configured = Set(AIService.shared.providers.map(\.keychainAccount))
        let found = providerAccounts(in: secrets)
        guard !found.isEmpty else {
            outcome.message = "No saved API keys were found for Clip on this Mac. Add a "
                            + "connection below and its key will be saved to your Keychain."
            finish(outcome)
            return outcome
        }

        var restored: [AIProvider] = []
        for account in found {
            guard let key = secrets[account], !key.isEmpty else { continue }
            let metadata = secrets[KeychainStore.metaAccount(for: account)].flatMap(Metadata.decode)
            let name = metadata?.name ?? inferredKind(fromKey: key).title
            guard !configured.contains(account) else {
                outcome.alreadyConfigured.append(name)
                continue
            }
            let provider = rebuild(account: account, key: key, metadata: metadata)
            AIService.shared.addProvider(provider, key: key)
            restored.append(provider)
            outcome.restored.append(provider.name)
        }

        outcome.message = message(for: outcome)
        Database.shared.log("keychain",
            "Key recovery: \(outcome.restored.count) connection(s) rebuilt from the store, "
            + "\(outcome.alreadyConfigured.count) already configured")

        // A recovered connection has not answered a request on this install,
        // so it is untested until it does. Testing is a real network call the
        // person just asked for by pressing the button - but never from a
        // sandboxed run, which must not reach a vendor at all.
        if !restored.isEmpty, !TestIsolation.isActive {
            Task { @MainActor in
                for provider in restored { _ = await AIService.shared.validate(provider) }
            }
        }

        finish(outcome)
        return outcome
    }

    @MainActor
    private static func finish(_ outcome: Outcome) {
        #if CLIP_TESTING
        lastOutcomeForTesting = outcome
        #endif
        if !outcome.restored.isEmpty {
            NoticeCenter.shared.resolve(offerNoticeKey)
        }
    }

    /// The sentence the person reads afterwards, wherever they started from.
    /// One function so the notice, the Settings pane and the alert can never
    /// say different things about the same run.
    static func message(for outcome: Outcome) -> String {
        var parts: [String] = []
        if !outcome.restored.isEmpty {
            let n = outcome.restored.count
            parts.append("Found keys for \(list(outcome.restored)). "
                       + "\(n == 1 ? "That connection is" : "Those \(n) connections are") back under "
                       + "Connections, using the key already saved on this Mac. "
                       + "Press Test on \(n == 1 ? "it" : "each one") before it can be made main or backup.")
        }
        if !outcome.alreadyConfigured.isEmpty {
            parts.append("\(list(outcome.alreadyConfigured)) already "
                       + "\(outcome.alreadyConfigured.count == 1 ? "has a connection" : "have connections") set up, "
                       + "so \(outcome.alreadyConfigured.count == 1 ? "it was" : "they were") left alone.")
        }
        if parts.isEmpty {
            parts.append("No saved API keys were found for Clip on this Mac.")
        }
        return parts.joined(separator: "\n\n")
    }

    /// "A", "A and B", "A, B and C" - never a bare comma-joined run, because
    /// this lands in the middle of a sentence a person reads.
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    /// The few statuses a refused read actually returns, named rather than
    /// printed as a bare number: "-128" tells the person nothing.
    static func statusName(_ status: OSStatus) -> String {
        switch status {
        case errSecUserCanceled:          return "you canceled the prompt"
        case errSecAuthFailed:            return "the password was not accepted"
        case errSecInteractionNotAllowed: return "macOS would not show the prompt"
        case errSecItemNotFound:          return "nothing was found to read"
        default:                          return "error \(status)"
        }
    }

    // MARK: - The launch offer

    static let offerNoticeKey = "keychain.recovery.offer"

    /// The offer itself: a dismissible persistent notice carrying one button.
    ///
    /// Raised only when the app has NO configured connection and the store
    /// does have something. An app with a connection already set up has
    /// nothing to recover and is never interrupted.
    @MainActor
    static func offerIfNeeded() {
        guard AIService.shared.providers.isEmpty else { return }
        let message: String
        switch scan() {
        case .nothingStored:
            return
        case .readable(let accounts) where !accounts.isEmpty:
            let n = accounts.count
            message = "Clip found \(n) saved API key\(n == 1 ? "" : "s") on this Mac, "
                    + "but no AI connections are set up."
        case .readable:
            return
        case .lockedButPresent:
            message = "Clip found saved API keys on this Mac, but no AI connections are set up."
        }
        NoticeCenter.shared.report(
            message,
            remedy: "Recovering them re-creates those connections from the keys already in your "
                  + "Keychain, so you do not have to paste them again. Nothing is read until you "
                  + "choose this, and nothing is sent anywhere.",
            kind: .persistent, key: offerNoticeKey,
            action: NoticeCenter.Action(title: "Recover Keys") {
                Task { @MainActor in
                    let outcome = await recover()
                    presentOutcome(outcome)
                }
            },
            stillNeeded: { AIService.shared.providers.isEmpty })
        Database.shared.log("keychain", "Key recovery offered at launch: \(message)")
    }

    /// The result, for a run that started from the notice rather than from
    /// Settings (which shows it inline instead).
    ///
    /// Suppressed under test for the same reason every other `runModal()` in
    /// this app is: a headless harness has nobody to click it, and the call
    /// would never return.
    @MainActor
    static func presentOutcome(_ outcome: Outcome) {
        guard TestIsolation.sendsRealKeystrokes, !QABridge.isHeadless else { return }
        let alert = NSAlert()
        alert.messageText = outcome.restored.isEmpty
            ? (outcome.refused ? "Nothing was changed" : "No saved keys were found")
            : "Your connections are back"
        alert.informativeText = outcome.message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
