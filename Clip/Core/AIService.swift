import Foundation
import SwiftUI
import Combine
import Security

/// Owns AI connections and every AI-powered feature.
///
/// Three rules this file exists to enforce:
/// 1. **Nothing runs without an active, validated connection.** `isAvailable`
///    gates all AI UI; when it is false the features do not exist on screen.
/// 2. **Only an explicit user action calls a model.** There is no polling, no
///    prefetch, no "while you were away" work.
/// 3. **Nothing is applied without consent.** Every feature returns a
///    *suggestion*; applying it is a separate, user-pressed step.
@MainActor
final class AIService: ObservableObject {

    static let shared = AIService()

    @Published private(set) var providers: [AIProvider] = []
    @Published var lastError: String?
    @Published var isWorking = false

    /// Swapped for a stub in tests so AI features can be exercised offline.
    var clientOverride: AIClient?

    private init() { loadProviders() }

    // MARK: - Availability

    var primaryProvider: AIProvider? {
        providers.first { $0.role == .primary && $0.isValidated }
    }
    var backupProvider: AIProvider? {
        providers.first { $0.role == .backup && $0.isValidated }
    }
    /// Kept for older call sites; the main connection is the active one.
    var activeProvider: AIProvider? { primaryProvider }

    /// Which connection answered the last request.
    @Published private(set) var lastUsedProviderName: String?
    /// Set when the main connection failed and the backup answered instead.
    @Published var didFailOver = false

    /// The single switch every AI surface checks.
    ///
    /// The master preference is folded in here rather than at each call site:
    /// there are a dozen places that ask, and one of them would have been missed.
    var isAvailable: Bool {
        guard PreferencesModel.shared.aiFeaturesEnabled else { return false }
        return clientOverride != nil || primaryProvider != nil || backupProvider != nil
    }

    // MARK: - Provider management

    /// Stores what a connection IS beside the key it uses, inside the same
    /// Keychain item (M28).
    ///
    /// The database row describing a connection does not survive a reinstall;
    /// the Keychain item does. Without this, a recovered key is an anonymous
    /// string under `provider.<uuid>` and the vendor, endpoint and model have
    /// to be inferred. With it, the connection comes back as it was. Written
    /// only when there is a key to sit beside - a local Ollama connection
    /// stores no secret, so it has no entry to hang metadata on and nothing
    /// to recover.
    ///
    /// Never a second Keychain item: it rides in the same vault, so it costs
    /// no extra authorisation prompt.
    private func storeRecoveryMetadata(_ provider: AIProvider) {
        guard provider.kind.needsKey else { return }
        let encoded = KeyRecovery.Metadata(provider).encoded
        guard !encoded.isEmpty else { return }
        KeychainStore.set(encoded, for: KeychainStore.metaAccount(for: provider.keychainAccount))
    }

    func addProvider(_ provider: AIProvider, key: String) {
        if provider.kind.needsKey {
            KeychainStore.markConfigured(provider.keychainAccount)
            reportIfKeychainFailed(KeychainStore.set(key, for: provider.keychainAccount),
                                   name: provider.name, account: provider.keychainAccount)
            storeRecoveryMetadata(provider)
        }
        providers.append(provider)
        // Covers a provider that arrives already validated - the QA bridge's
        // stub connection does this directly, without ever calling
        // `validate()` - so the same "first to validate is primary, second
        // is backup" rule applies here too, not only from `mark()` below.
        if provider.health == .ready { autoAssignRoleIfNeeded(for: provider.id) }
        persist()
    }

    func updateProvider(_ provider: AIProvider, key: String?) {
        if let key, provider.kind.needsKey {
            KeychainStore.markConfigured(provider.keychainAccount)
            reportIfKeychainFailed(KeychainStore.set(key, for: provider.keychainAccount),
                                   name: provider.name, account: provider.keychainAccount)
        }
        if let i = providers.firstIndex(where: { $0.id == provider.id }) { providers[i] = provider }
        // Renaming a connection or pointing it at a different model has to
        // update what recovery would put back, or a reinstall restores the
        // connection this one used to be.
        storeRecoveryMetadata(provider)
        persist()
    }

    func removeProvider(_ id: String) {
        let wasPrimary = providers.first(where: { $0.id == id })?.role == .primary
        if let p = providers.first(where: { $0.id == id }) {
            KeychainStore.remove(p.keychainAccount)
            // Removed with the key, not left behind: a connection the person
            // deleted must not come back from a recovery run, and an orphan
            // metadata entry is a description of something that no longer
            // exists.
            KeychainStore.remove(KeychainStore.metaAccount(for: p.keychainAccount))
            KeychainStore.markUnconfigured(p.keychainAccount)
        }
        providers.removeAll { $0.id == id }
        // A backup exists so a main connection going away does not silently
        // switch AI off for everyone using it - it steps up rather than
        // waiting for someone to notice and promote it by hand.
        if wasPrimary, let backup = providers.first(where: { $0.role == .backup }) {
            setRole(.primary, for: backup.id)   // already persists and notifies
        } else {
            persist()
        }
    }

    /// Exactly one connection is main and one is backup.
    func setRole(_ role: ProviderRole, for id: String) {
        for i in providers.indices {
            if providers[i].id == id {
                providers[i].role = role
            } else if role != .unused, providers[i].role == role {
                // Only one connection can hold each role.
                providers[i].role = .unused
            }
            providers[i].isActive = providers[i].role == .primary
        }
        persist()
        PreferencesModel.shared.aiEnabled = isAvailable
        NoticeCenter.shared.refreshInvitation()
    }

    /// Kept for older call sites: making a connection active makes it the main one.
    func makeActive(_ id: String) { setRole(.primary, for: id) }

    /// The user's own words: "when the user does his first connection then
    /// the main AI model to user fills up (only if the connection working),
    /// when we add a second connection that works then he goes to be the
    /// backup." No button for this - it happens the moment a connection
    /// proves itself, and only claims a role nobody has chosen yet, so a
    /// role set by hand in Settings is never overridden by a later test.
    private func autoAssignRoleIfNeeded(for id: String) {
        guard let i = providers.firstIndex(where: { $0.id == id }),
              providers[i].role == .unused else { return }
        if !providers.contains(where: { $0.role == .primary }) {
            providers[i].role = .primary
            providers[i].isActive = true
        } else if !providers.contains(where: { $0.role == .backup }) {
            providers[i].role = .backup
        }
    }

    /// Records what happened to a connection, so Settings can show it as down.
    private func mark(_ id: String, health: ProviderHealth, error: String?) {
        guard let i = providers.firstIndex(where: { $0.id == id }) else { return }
        providers[i].health = health
        providers[i].lastError = error
        providers[i].lastCheckedAt = Date()
        if health == .ready {
            providers[i].validatedAt = Date()
            autoAssignRoleIfNeeded(for: id)
        }
        persist()
    }

    /// `SecItemAdd`'s status used to be thrown away entirely; a failed write
    /// looked exactly like a successful one until the very next request
    /// found nothing there. Every caller that stores a key now checks this.
    private func reportIfKeychainFailed(_ status: OSStatus, name: String, account: String) {
        guard status != errSecSuccess else { return }
        // Keyed by the Keychain ACCOUNT, the same key `KeychainStore.clearFailure`
        // resolves, so a later successful write takes this notice down.
        NoticeCenter.shared.report(
            "The key for \(name) could not be saved.",
            remedy: "Clip will try again automatically, or paste it again here.",
            kind: .persistent, key: "keychain.needsRepair.\(account)")
    }

    // MARK: - Testing every connection

    /// Which connection the sweep is on, and how far through it is.
    ///
    /// One spinner for the whole sweep is what made this look stuck: with no
    /// name and no count, a slow connection and a hung app are the same
    /// picture. Published so the pane can say which one it is waiting on.
    struct CheckProgress: Equatable {
        var name: String
        var index: Int
        var total: Int
    }
    @Published private(set) var checkProgress: CheckProgress?

    private var checkTask: Task<Void, Never>?

    var isCheckingAll: Bool { checkProgress != nil }

    /// Re-tests every configured connection, one at a time, and updates health.
    ///
    /// Sequential was never the problem - this loop always was. What it lacked
    /// was a deadline per connection and any way to stop, so one unreachable
    /// endpoint held every other connection's result hostage.
    func checkAll() async {
        let all = providers
        guard !all.isEmpty else { return }
        for (index, provider) in all.enumerated() {
            if Task.isCancelled { break }
            checkProgress = CheckProgress(name: provider.name,
                                          index: index + 1, total: all.count)
            _ = await validate(provider)
        }
        checkProgress = nil
    }

    /// Starts the sweep as a cancellable task, so Stop can actually stop it.
    func beginCheckAll() {
        checkTask?.cancel()
        checkTask = Task { [weak self] in await self?.checkAll() }
    }

    func cancelCheckAll() {
        checkTask?.cancel()
        checkTask = nil
        checkProgress = nil
    }

    /// Sends a real request. A connection cannot become active until this passes,
    /// so the dropdown can never offer something that does not work.
    func validate(_ provider: AIProvider) async -> Result<String, Error> {
        isWorking = true
        defer { isWorking = false }
        do {
            // 25 seconds, not 60. A connection that cannot answer "ping" in
            // twenty-five is not one to rely on, and the point of a test is to
            // come back with an answer either way.
            var client = LiveAIClient(provider: provider)
            client.timeout = 25
            let reply = try await client
                .complete(system: "You are a connection test. Reply with the single word: ready.",
                          user: "ping", maxTokens: 512)
            mark(provider.id, health: .ready, error: nil)
            Database.shared.log("ai", "Validated \(provider.name)")
            return .success(reply.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            mark(provider.id, health: .down, error: error.localizedDescription)
            Database.shared.log("ai", "Validation failed for \(provider.name): \(error.localizedDescription)")
            return .failure(error)
        }
    }

    // MARK: - Storage

    /// Set when an encode failed, so the editor sheet can show it inline and
    /// stay open rather than closing on a change that was never written.
    @Published var lastPersistError: String?

    private func persist() {
        guard let data = try? JSONEncoder().encode(providers),
              let json = String(data: data, encoding: .utf8) else {
            let reading = StorageDiagnosis.read(
                .saveFailed(entity: "AI connection", detail: "Nothing changed was written."))
            lastPersistError = reading.message
            NoticeCenter.shared.report(reading.message, remedy: reading.remedy,
                                       kind: reading.kind, key: reading.key)
            return
        }
        lastPersistError = nil
        Database.shared.setPreference("aiProviders", json)
        PreferencesModel.shared.aiEnabled = isAvailable
        NoticeCenter.shared.refreshInvitation()
    }

    /// How many rows the last load could not read - not the secrets, which
    /// are untouched in the Keychain, just the JSON row describing them.
    @Published private(set) var quarantinedProviderCount = 0

    /// Decodes each connection on its own, so one bad row leaves the rest -
    /// and every Keychain key behind them - intact. The old all-or-nothing
    /// `try? JSONDecoder().decode([AIProvider].self, ...)` threw the whole
    /// array away on a single failure, which read as "the connections
    /// settings are empty" while every key was still sitting in the Keychain.
    private func loadProviders() {
        defer {
            // Every loaded connection is one this app now expects a key for,
            // so a Keychain miss for it reads as "the key is gone" rather
            // than "nothing was ever configured".
            for provider in providers { KeychainStore.markConfigured(provider.keychainAccount) }
        }
        guard let json = Database.shared.preference("aiProviders"), !json.isEmpty,
              let data = json.data(using: .utf8) else { return }
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            // Not even a readable array - nothing here parses at all.
            NoticeCenter.shared.report(.decodeFailed(entity: "AI connection", count: 1))
            return
        }
        var loaded: [AIProvider] = []
        var quarantined = 0
        let decoder = JSONDecoder()
        for row in rows {
            if let rowData = try? JSONSerialization.data(withJSONObject: row),
               let provider = try? decoder.decode(AIProvider.self, from: rowData) {
                loaded.append(provider)
            } else {
                quarantined += 1
            }
        }
        providers = loaded
        quarantinedProviderCount = quarantined
        if quarantined > 0 {
            NoticeCenter.shared.report(.decodeFailed(entity: "AI connection", count: quarantined),
                                       action: NoticeCenter.Action(title: "Show") {
                                           AppDelegate.shared?.showDiagnostics()
                                       })
        }
    }

    #if CLIP_TESTING
    /// Re-reads the connection rows from the database, as a fresh launch
    /// would. Lets a probe stage a reinstall - the rows gone, the Keychain
    /// untouched - through the real loader rather than by reaching into
    /// `providers` directly (M28).
    func reloadProvidersForTesting() {
        providers = []
        loadProviders()
        PreferencesModel.shared.aiEnabled = isAvailable
        NoticeCenter.shared.refreshInvitation()
    }
    #endif

    // MARK: - Features

    /// A proposed change. Nothing is written until the user accepts it.
    struct Suggestion: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let body: String
        /// Shown when the suggestion is a rewrite of existing text.
        var original: String?
    }

    /// Runs a request against the main connection, falling back to the backup.
    ///
    /// A backup is only useful if it is used automatically — asking the user to
    /// notice an outage and switch by hand defeats the point. The failover is
    /// surfaced afterwards so they know which model actually answered.
    /// Runs a prompt against the main connection, then the backup.
    ///
    /// `accept` decides whether a reply is *usable*, not merely present. Failover
    /// used to happen only when a call threw, so a 200 carrying "We need to
    /// output a single JSON object..." counted as success and the backup - a
    /// different model, which might well have complied - never got its turn.
    private func run(system: String, user: String, maxTokens: Int = 2048,
                     wantsJSON: Bool = false,
                     accept: ((String) -> Bool)? = nil) async throws -> String {
        isWorking = true
        didFailOver = false
        defer { isWorking = false }

        if let clientOverride {
            let out = try await clientOverride.complete(system: system, user: user,
                                                        maxTokens: maxTokens,
                                                        wantsJSON: wantsJSON)
            lastUsedProviderName = "Test client"
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let chain = [primaryProvider, backupProvider].compactMap { $0 }
        guard !chain.isEmpty else { throw AIError.notConfigured }

        var firstError: Error?
        var lastUnusable: String?

        for (index, provider) in chain.enumerated() {
            do {
                let client: AIClient
                #if CLIP_TESTING
                // A specific connection can be scripted to fail (a 401, say)
                // while another in the same chain succeeds - which the
                // global `clientOverride` above cannot do, since it answers
                // before the chain exists at all, and failover IS the chain.
                if let scripted = Self.providerClientOverrides[provider.id] {
                    client = scripted
                } else {
                    client = LiveAIClient(provider: provider)
                }
                #else
                client = LiveAIClient(provider: provider)
                #endif
                let out = try await client
                    .complete(system: system, user: user, maxTokens: maxTokens,
                              wantsJSON: wantsJSON)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if let accept, !accept(out) {
                    // The connection is working; this model is not doing the job.
                    // Do not mark it down - it answers other prompts fine.
                    lastUnusable = out
                    Database.shared.log("ai", "\(provider.name) returned nothing usable; trying the next connection")
                    continue
                }
                mark(provider.id, health: .ready, error: nil)
                lastUsedProviderName = provider.name
                didFailOver = index > 0
                if didFailOver {
                    // News, not a standing condition: the request still
                    // succeeded. Named so a person sees which connection
                    // actually answered, without having to open Settings.
                    NoticeCenter.shared.report(
                        "The main connection was down; \(provider.name) (backup) answered instead.",
                        kind: .transient)
                }
                return out
            } catch {
                // A key that cannot be read or is simply gone repairs itself
                // in the background - not on this request, which still has to
                // fail or fall over, but on the next one.
                if case AIError.keyUnreadable = error {
                    Task { await KeychainStore.selfRepair(reason: "AIService.run",
                                                          accounts: [provider.keychainAccount]) }
                } else if case AIError.keyMissing = error {
                    Task { await KeychainStore.selfRepair(reason: "AIService.run",
                                                          accounts: [provider.keychainAccount]) }
                }
                mark(provider.id, health: .down, error: error.localizedDescription)
                if firstError == nil { firstError = error }
            }
        }

        if let lastUnusable {
            throw AIError.malformed("""
                No connection returned a usable answer. The last reply began: \
                \(lastUnusable.prefix(120))
                """)
        }
        throw firstError ?? AIError.notConfigured
    }

    /// 1. Improve a prompt. Prompts only — this never touches ordinary clippings.
    func improvePrompt(_ text: String) async throws -> Suggestion {
        let body = try await run(system: """
            You improve prompts for large language models. Rewrite the user's prompt \
            so it is clearer, more specific and better structured. Keep the original \
            intent and language exactly. Preserve any {{placeholders}}. \
            Reply with the rewritten prompt only, no preamble, no commentary, no quotes.
            """, user: text)
        return Suggestion(title: "Improved prompt", body: body, original: text)
    }

    /// 2. Spelling and grammar.
    ///
    /// Returning nil means "nothing to fix", and that answer has to be **true**.
    /// The old prompt offered NO_CHANGES as an easy way out with no definition
    /// of what counted as a mistake, and models took it on text that plainly had
    /// some. Two changes: the prompt enumerates what a mistake is and forbids
    /// the shortcut when one is present, and the verdict is not taken on trust -
    /// if the model says NO_CHANGES it is asked once more, plainly, and any
    /// corrected text it returns beats its own earlier verdict.
    func proofread(_ text: String) async throws -> Suggestion? {
        let system = """
            You are a proofreader. Fix spelling, grammar, punctuation, subject-verb \
            agreement, verb tense, articles, plurals, capitalisation of proper nouns, \
            doubled words and missing words. Do not rewrite style, do not change \
            meaning, do not translate, do not reformat.

            Reply with exactly NO_CHANGES only if there is not a single such mistake \
            anywhere in the text. If even one exists, reply with the full corrected \
            text and nothing else.
            """
        let body = try await run(system: system, user: text)

        if body == "NO_CHANGES" {
            // Asked again with the escape hatch removed. If the second reply is
            // the text back unchanged, the verdict stands and was honest; if it
            // differs, the first answer was the model taking the easy option.
            let second = try await run(system: """
                Correct every spelling, grammar and punctuation mistake in the user's \
                text. Reply with the corrected text only - no commentary, no quotes, \
                no explanation. If it is already correct, reply with it unchanged.
                """, user: text)
            guard !second.isEmpty, second != text else { return nil }
            return Suggestion(title: "Spelling and grammar", body: second, original: text)
        }
        guard !body.isEmpty, body != text else { return nil }
        return Suggestion(title: "Spelling and grammar", body: body, original: text)
    }

    /// 3. A short name for an untitled prompt.
    func suggestTitle(for text: String) async throws -> Suggestion {
        let body = try await run(system: """
            Give a short title, at most five words, for the following text. \
            Reply with the title only — no quotes, no trailing period.
            """, user: text, maxTokens: 512)
        return Suggestion(title: "Suggested name", body: body)
    }

    /// 4. Tags for the prompt library.
    func suggestTags(for text: String) async throws -> [String] {
        let body = try await run(system: """
            Suggest three to six short lowercase tags for the following text. \
            Single words where possible. Reply as a comma-separated list only.
            """, user: text, maxTokens: 512)
        return body.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && $0.count < 24 }
    }

    /// 5. Translate into another language, saved as a new version.
    func translate(_ text: String, to language: String) async throws -> Suggestion {
        let body = try await run(system: """
            Translate the user's text into \(language). Preserve formatting, \
            line breaks and any {{placeholders}}. Reply with the translation only.
            """, user: text)
        return Suggestion(title: "Translated to \(language)", body: body, original: text)
    }

    /// 6. Plain-English explanation of a code clipping.
    func explainCode(_ text: String, language: String?) async throws -> Suggestion {
        let body = try await run(system: """
            Explain what this \(language ?? "") code does, in plain English, in at \
            most five sentences. Do not repeat the code back.
            """, user: text)
        return Suggestion(title: "What this code does", body: body)
    }

    /// 7. Turn a rough clipping into a reusable prompt template.
    func makeTemplate(from text: String) async throws -> Suggestion {
        let body = try await run(system: """
            Turn the user's text into a reusable prompt template. Replace the parts \
            that would change between uses with {{placeholders}} that have \
            descriptive names. Keep it concise. Reply with the template only.
            """, user: text)
        return Suggestion(title: "Reusable template", body: body, original: text)
    }

    /// 8. Summarise a long clipping.
    func summarise(_ text: String) async throws -> Suggestion {
        let body = try await run(system: """
            Summarise the user's text in at most three sentences. \
            Reply with the summary only.
            """, user: text)
        return Suggestion(title: "Summary", body: body)
    }

    /// 10. Turns a blob into a shape you can use.
    ///
    /// A pasted table, a log, an invoice, a wall of key-values - the thing
    /// people actually reach for and the one transformation none of the verbs
    /// above cover. One call, on request, never on capture.
    func extractStructure(_ text: String, as format: StructureFormat) async throws -> Suggestion {
        let body = try await run(system: """
            Convert the user's text to \(format.instruction). Infer the columns or \
            fields from the content. Reply with the converted data only - no \
            explanation, no markdown fence. If the text has no structure to \
            extract, reply with exactly: NONE
            """, user: text, maxTokens: 2000)
        guard body.trimmingCharacters(in: .whitespacesAndNewlines) != "NONE" else {
            throw AIError.malformed("There was no structure to pull out of that.")
        }
        return Suggestion(title: "As \(format.title)", body: body)
    }

    /// 11. What changed between two revisions, in one line.
    ///
    /// The diff itself is computed locally and for free; only the reading of it
    /// costs a call. Version history that needs archaeology is history nobody
    /// opens.
    func describeChange(from before: String, to after: String) async throws -> Suggestion {
        let body = try await run(system: """
            Two versions of the same text follow. Say in ONE sentence what \
            changed and why it might matter. Do not list every edit. Reply with \
            the sentence only.
            """, user: """
            BEFORE:
            \(before.prefix(4000))

            AFTER:
            \(after.prefix(4000))
            """, maxTokens: 300)
        return Suggestion(title: "What changed", body: body)
    }

    /// 12. Merges several items into one.
    ///
    /// The thing only a clipboard manager can offer, because the material is
    /// already filed here: three design systems into one token set, five
    /// prompts into the one that supersedes them.
    func compose(_ pieces: [String], instruction: String) async throws -> Suggestion {
        let numbered = pieces.enumerated()
            .map { "--- ITEM \($0.offset + 1) ---\n\($0.element.prefix(6000))" }
            .joined(separator: "\n\n")
        let body = try await run(system: """
            Several items follow. Produce ONE result that satisfies the user's \
            instruction, drawing on all of them. Keep what they agree on, resolve \
            what they contradict, and say nothing about the process. Reply with \
            the result only.
            """, user: """
            Instruction: \(instruction)

            \(numbered)
            """, maxTokens: 3000)
        return Suggestion(title: "Composed from \(pieces.count) item\(pieces.count == 1 ? "" : "s")", body: body)
    }

    /// 13. Rewrites text for the moment it is being pasted.
    ///
    /// The clipboard is the only place that knows both the content and where it
    /// is going, which is what makes this worth doing here rather than in a
    /// chat window.
    func transformForPaste(_ text: String, instruction: String) async throws -> Suggestion {
        let body = try await run(system: """
            Rewrite the user's text as instructed. Preserve meaning and any data \
            exactly. Reply with the rewritten text only - no preamble, no fence.
            """, user: """
            Instruction: \(instruction)

            \(text)
            """, maxTokens: 2000)
        return Suggestion(title: instruction, body: body)
    }

    /// 14. Titles a batch of items in one request.
    ///
    /// One call for twenty items, not twenty calls - and only when asked. This
    /// is the shape that keeps auto-titling off the capture path: the cost is
    /// bounded by a button press rather than by how much you copy.
    func titleBatch(_ items: [(id: String, text: String)]) async throws -> [String: String] {
        let listing = items.enumerated()
            .map { "\($0.offset + 1). \($0.element.text.prefix(400).replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n")
        let body = try await run(system: """
            Give each numbered item a short title, at most six words, describing \
            what it IS. Reply as a JSON object mapping the item number to its \
            title, and nothing else. Example: {"1":"Postgres backup script"}
            """, user: listing, maxTokens: Self.batchTokens(for: items.count),
            wantsJSON: true)

        let map = KeyedReply.parse(body)
        guard !map.isEmpty else { throw Self.unreadable("titles", body) }

        var out: [String: String] = [:]
        for (index, item) in items.enumerated() {
            if let title = map["\(index + 1)"], !title.isEmpty { out[item.id] = title }
        }
        return out
    }

    /// 15. One short description per item, in one request.
    ///
    /// The batched shape again: the cost of describing a library is a single
    /// call, not one per document. The numbering is the contract - the reply is
    /// keyed by position, and anything the model omits simply gets no proposal
    /// rather than a wrong one.
    func describeBatch(_ items: [(id: String, text: String)]) async throws -> [String: String] {
        try await keyedBatch(items, system: """
            Each numbered item is a document. For each, write ONE sentence saying what \
            the document is for and when someone would reach for it. Do not summarise \
            its contents; say what it is. Reply as a JSON object mapping the item \
            number to its sentence, and nothing else.
            """, characters: 1200, maxTokens: 2000)
    }

    /// 16. Three to six tags per item, in one request.
    func tagBatch(_ items: [(id: String, text: String)]) async throws -> [String: [String]] {
        let raw = try await keyedBatch(items, system: """
            Each numbered item is a piece of text. For each, give three to six short \
            lowercase tags, single words where possible, comma separated. Reply as a \
            JSON object mapping the item number to its comma-separated tags, and \
            nothing else.
            """, characters: 700, maxTokens: 1500)
        return raw.mapValues { value in
            value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty && $0.count < 24 }
        }
    }

    /// 17. A full review of one document, returned as the improved document.
    ///
    /// Deliberately one call for one document, and the UI says so before it
    /// runs: a review has to read the whole thing, and batching four documents
    /// into one request produces four shallow readings rather than one good one.
    func reviewDocument(_ text: String, kind: String) async throws -> Suggestion {
        let body = try await run(system: """
            You review \(kind) documents. Return the document IMPROVED, not a critique: \
            fix contradictions, sharpen vague instructions, add a section only where one \
            is plainly missing, and cut repetition. Preserve the author's voice, the \
            structure, any front matter keys and any {{placeholders}}. Change nothing \
            that is already clear. Reply with the full document only - no commentary, no \
            markdown fence around the whole thing.
            """, user: text, maxTokens: 4000)
        return Suggestion(title: "Reviewed", body: body, original: text)
    }

    /// The shared shape of every batched verb: number the items, ask for a
    /// JSON object keyed by number, map it back to ids.
    ///
    /// Written once because it was written twice already and the second copy
    /// dropped the "reply as JSON" flag, which is the difference between a
    /// parsed result and an exception.
    private func keyedBatch(_ items: [(id: String, text: String)],
                            system: String, characters: Int,
                            maxTokens: Int) async throws -> [String: String] {
        guard !items.isEmpty else { return [:] }
        let listing = items.enumerated()
            .map { "\($0.offset + 1). \($0.element.text.prefix(characters).replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n")
        let body = try await run(system: system, user: listing,
                                 maxTokens: max(maxTokens, Self.batchTokens(for: items.count)),
                                 wantsJSON: true)

        let map = KeyedReply.parse(body)
        guard !map.isEmpty else { throw Self.unreadable("answers", body) }

        var out: [String: String] = [:]
        for (index, item) in items.enumerated() {
            if let value = map["\(index + 1)"],
               !value.trimmingCharacters(in: .whitespaces).isEmpty {
                out[item.id] = value
            }
        }
        return out
    }

    /// 9b. Refines an existing theme from a follow-up instruction.
    ///
    /// Generating once and leaving the user to hand-tune is the wrong shape: the
    /// interesting requests are "warmer", "more contrast", "less blue" — small
    /// adjustments to what is already on screen. Passing the current theme back
    /// in means each round builds on the last instead of starting over.
    func refineTheme(_ current: CustomTheme, instruction: String) async throws -> CustomTheme {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(current),
              let json = String(data: data, encoding: .utf8) else {
            throw AIError.malformed("Could not read the current theme.")
        }
        let body = try await run(system: """
            You adjust an existing color theme for a macOS app. You are given the \
            current theme as JSON and an instruction. Apply the instruction, changing \
            only what it asks for and keeping everything else. Reply with ONLY the full \
            JSON object in the same shape, no markdown fence and no commentary.

            \(ThemeRules.fullTokenBrief)

            \(ThemeRules.promptBrief)
            """, user: "Current theme:\n\(json)\n\nInstruction: \(instruction)",
                 maxTokens: 3000, wantsJSON: true, accept: { Self.looksLikeTheme($0) })

        guard var refined = CustomTheme(json: Self.extractJSON(from: body)) else {
            throw AIError.malformed("The model did not return a usable theme.")
        }
        // Keep the identity so refining edits the same theme rather than cloning it.
        refined.id = current.id
        if refined.name.isEmpty { refined.name = current.name }
        return refined
    }

    /// 9. Build a theme from a free-text description.
    ///
    /// The reply is JSON so it can be turned straight into an `AppTheme`; the
    /// parser is defensive because models like to wrap JSON in prose or fences.
    func generateTheme(from description: String) async throws -> CustomTheme {
        let body = try await run(system: """
            You design color themes for a macOS app. Given a description, reply with \
            ONLY a JSON object, no markdown fence and no commentary, with these keys, \
            each a #RRGGBB hex string unless noted:
            name (short string), accent, accentSecondary, panelBackground, cardBackground, \
            cardHoverBackground, selectedBackground, surfaceBackground, textPrimary, \
            textSecondary, textTertiary, border, isDark (boolean), cornerRadius (number 4-20).

            \(ThemeRules.optionalTokenBrief)

            \(ThemeRules.fullTokenBrief)

            \(ThemeRules.promptBrief)
            """, user: description, maxTokens: 3000, wantsJSON: true,
                 accept: { Self.looksLikeTheme($0) })

        if let theme = CustomTheme(json: Self.extractJSON(from: body)) {
            return await repairIfNeeded(theme)
        }

        // One retry, and a much blunter prompt.
        //
        // The first attempt fails for reasons that are all recoverable: a
        // reasoning model spends its budget thinking and returns nothing, or it
        // answers in prose, or it wraps the object in another one. Giving up on
        // the first miss made the feature look broken when it was one retry away
        // from working. Asking again, with an example and the model's own reply
        // quoted back, is what makes it reliable rather than lucky.
        let retry = try await run(system: """
            Reply with a single JSON object and NOTHING else. No explanation, no \
            markdown fence, no <think> block. Start your reply with { and end it \
            with }.

            The exact shape, with example values:
            {"name":"Coral Dusk","accent":"#FF6B5A","accentSecondary":"#FFB199",\
            "panelBackground":"#1A1218","cardBackground":"#241A22",\
            "cardHoverBackground":"#2E222C","selectedBackground":"#3A2A36",\
            "surfaceBackground":"#201820","textPrimary":"#FFF5F2",\
            "textSecondary":"#D4B8B2","textTertiary":"#9A8480","border":"#3A2C36",\
            "isDark":true,"cornerRadius":14}

            \(ThemeRules.optionalTokenBrief)

            \(ThemeRules.fullTokenBrief)

            \(ThemeRules.promptBrief)
            """, user: """
            Theme description: \(description)

            Your previous reply could not be read as JSON. It began:
            \(body.prefix(200))
            """, maxTokens: 3000, wantsJSON: true, accept: { Self.looksLikeTheme($0) })

        guard let theme = CustomTheme(json: Self.extractJSON(from: retry)) else {
            // Say what actually came back. "Did not return a usable theme" sent
            // the last investigation looking at the parser instead of the model.
            let sample = retry.isEmpty
                ? "the model returned nothing at all"
                : "the reply began: \(retry.prefix(120))"
            throw AIError.malformed("""
                \(lastUsedProviderName ?? "The model") did not return a theme - \(sample). \
                A reasoning model often spends its whole budget thinking; try a \
                non-reasoning model for this.
                """)
        }
        return await repairIfNeeded(theme)
    }

    /// A cheap test for "this reply might be a theme".
    ///
    /// Deliberately not a full parse: it runs inside the failover loop to decide
    /// whether to try the next connection, and only has to tell a palette from a
    /// model narrating its intentions.
    static func looksLikeTheme(_ reply: String) -> Bool {
        let json = extractJSON(from: reply)
        guard json.contains("{"), json.contains("}") else { return false }
        return json.contains("accent") || json.contains("panelBackground")
            || json.contains("textPrimary")
    }

    /// Audits a generated theme and gives the model one chance to fix what fails.
    ///
    /// Asking nicely for contrast is not enough — models produce pretty,
    /// unreadable palettes. Measuring the result and handing back the specific
    /// failures turns "please be accessible" into a checkable requirement.
    private func repairIfNeeded(_ theme: CustomTheme) async -> CustomTheme {
        let report = ThemeRules.audit(theme.appTheme)
        guard !report.passes else { return theme }

        let failures = report.failures
            .map { "- \($0.pairing): \(String(format: "%.2f", $0.ratio)):1, needs \($0.required):1" }
            .joined(separator: "\n")
        guard let fixed = try? await refineTheme(theme, instruction: """
            These pairings fail their contrast requirement:
            \(failures)
            Adjust only the colors involved so every one passes. Keep the character \
            of the theme.
            """) else {
            // The repair attempt itself failed - a network error, a model
            // that returned nothing usable. Said out loud rather than
            // silently keeping the unreadable theme.
            NoticeCenter.shared.report(
                "This theme could not be fixed for contrast automatically.",
                remedy: "Adjust the colors by hand in the builder, or try again.",
                kind: .transient)
            return theme
        }

        // Keep the repair only if it actually helped.
        let after = ThemeRules.audit(fixed.appTheme)
        let improved = after.failures.count < report.failures.count
        let best = improved ? fixed : theme
        NoticeCenter.shared.report(
            improved ? "Theme adjusted for contrast." : "This theme could not be fixed for contrast automatically.",
            remedy: improved ? nil : "Adjust the colors by hand in the builder.",
            kind: .transient)
        // Whatever the model made of it, the palette still has to be readable.
        // Asking a second time produces a second opinion, not a guarantee.
        return ThemeDoctor.repaired(best)
    }

    /// Pulls the first balanced JSON object out of a reply that may be fenced.
    /// Enough room for one answer per item, plus the JSON around them.
    ///
    /// This was a flat 1500 whatever the batch size. Forty items is roughly
    /// 40 x 12 tokens of title plus the keys, quotes and braces, which lands
    /// close enough to 1500 that a batch of long titles gets CUT OFF - and a
    /// truncated JSON object does not parse, so the whole request failed and
    /// the user was told the reply "was not a list of titles" when in fact it
    /// was a list of titles with the end missing.
    static func batchTokens(for count: Int) -> Int {
        min(8000, max(1500, 60 * count + 400))
    }

    /// Says what came back, not just that it could not be used.
    ///
    /// "The reply was not a list of titles" is true and useless: it gives the
    /// user nothing to act on and does not say whether the model refused, went
    /// silent, or answered in prose. The first part of the reply usually makes
    /// it obvious.
    static func unreadable(_ wanted: String, _ body: String) -> AIError {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .malformed("""
                The model replied with nothing at all. Some reasoning models do \
                this when asked for JSON - try a different model for this action.
                """)
        }
        let snippet = trimmed.prefix(140).replacingOccurrences(of: "\n", with: " ")
        return .malformed("""
            The model did not send a usable list of \(wanted). It replied: \
            \(snippet)\(trimmed.count > 140 ? "…" : "")
            """)
    }

    static func extractJSON(from raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fence = s.range(of: "```") {
            s = String(s[fence.upperBound...])
            if s.lowercased().hasPrefix("json") { s = String(s.dropFirst(4)) }
            if let close = s.range(of: "```") { s = String(s[..<close.lowerBound]) }
        }
        guard let start = s.firstIndex(of: "{") else { return s }
        var depth = 0
        for i in s.indices[start...] {
            if s[i] == "{" { depth += 1 }
            if s[i] == "}" {
                depth -= 1
                if depth == 0 { return String(s[start...i]) }
            }
        }
        return String(s[start...])
    }
}

#if CLIP_TESTING
extension AIService {
    /// Writes the current connections back with one extra row that cannot
    /// decode, then reloads exactly the way a real launch would - so K7 can
    /// prove one bad row leaves the rest, and the Keychain keys behind them,
    /// intact, instead of the old all-or-nothing decode throwing every
    /// connection away.
    func quarantineRowForTesting() {
        var rows: [[String: Any]] = []
        if let data = try? JSONEncoder().encode(providers),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            rows = array
        }
        // Missing every required key (name, kind, endpoint, model): the
        // custom decoder throws on this no matter what JSONSerialization
        // does with the types, which a type-mismatch row cannot guarantee.
        rows.append(["id": "quarantine-probe-row"])
        if let data = try? JSONSerialization.data(withJSONObject: rows),
           let json = String(data: data, encoding: .utf8) {
            Database.shared.setPreference("aiProviders", json)
        }
        loadProviders()
    }

    /// Per-connection stand-ins, keyed by provider id. `run()`'s chain
    /// consults this before building a `LiveAIClient`, which is what lets a
    /// probe script one specific connection to fail (a 401, say) while
    /// another in the same chain succeeds - the global `clientOverride`
    /// cannot do this, since it answers before the chain is ever built.
    nonisolated(unsafe) static var providerClientOverrides: [String: AIClient] = [:]
}

/// A canned answer, or a specific HTTP failure, for exactly one connection -
/// so the main/backup failover in `AIService.run()` can be exercised without
/// a real network call.
struct ScriptedProviderClient: AIClient {
    enum Outcome {
        case reply(String)
        case http(Int, String)
    }
    let outcome: Outcome

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        try await complete(system: system, user: user, maxTokens: maxTokens, wantsJSON: false)
    }

    func complete(system: String, user: String, maxTokens: Int, wantsJSON: Bool) async throws -> String {
        switch outcome {
        case .reply(let text):          return text
        case .http(let code, let message): throw AIError.http(code, message)
        }
    }
}
#endif

/// The shapes `extractStructure` can produce.
enum StructureFormat: String, CaseIterable, Identifiable {
    case csv, json, markdownTable, keyValues

    var id: String { rawValue }

    var title: String {
        switch self {
        case .csv:           return "CSV"
        case .json:          return "JSON"
        case .markdownTable: return "a Markdown table"
        case .keyValues:     return "key and value lines"
        }
    }

    var instruction: String {
        switch self {
        case .csv:           return "CSV, with a header row"
        case .json:          return "a JSON array of objects"
        case .markdownTable: return "a Markdown table with a header row"
        case .keyValues:     return "lines of `key: value`"
        }
    }
}
