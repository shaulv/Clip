import Foundation
import Security

/// API keys live in the Keychain, never in the database or `UserDefaults`.
///
/// The database file is copied by Time Machine and any folder-sync tool; a
/// secret written there leaks wherever the file goes.
enum KeychainStore {

    private static var service: String { AppPaths.keychainService }

    /// Writes a secret and hands back what actually happened.
    ///
    /// `SecItemAdd`'s status used to be discarded entirely, which is how
    /// "repaired 2" could mean two writes that silently failed. Every caller
    /// now checks this and reports a notice on anything but success.
    @discardableResult
    static func set(_ value: String, for account: String) -> OSStatus {
        #if CLIP_TESTING
        // Forces exactly this write to fail, once, without touching
        // anything - so a caller's handling of a genuine `SecItemAdd`
        // failure (K2) is provable without needing a real one.
        if let forced = simulatedSetStatus.removeValue(forKey: account) {
            return forced
        }
        #endif
        // A sandboxed test run never touches the real Keychain. See
        // `TestIsolation`: the prompt it avoids cannot be answered in an agent
        // app, so the call never returns.
        cache[account] = value.isEmpty ? nil : value
        // A write is what a real repair does - re-adding an item gives it a
        // fresh access list containing only this build, so whatever made the
        // account fail before is gone the moment this succeeds.
        clearFailure(account)
        #if CLIP_TESTING
        simulatedStatus.removeValue(forKey: account)
        #endif
        if TestIsolation.isActive { TestIsolation.setSecret(value, for: account); return value.isEmpty ? errSecItemNotFound : errSecSuccess }
        // One Keychain item for every secret (user, 03/09 night: "store all
        // keys in one macOS keychain ... place his credentials once"). The
        // vault is read, this account changed, and the whole item re-added
        // under this build's access list. If the vault exists but this build
        // cannot read it, nothing is written: overwriting it blind would
        // throw away every other secret inside.
        let (vault, status) = loadVault()
        guard status == errSecSuccess || status == errSecItemNotFound else { return status }
        var accounts = vault
        if value.isEmpty { accounts.removeValue(forKey: account) } else { accounts[account] = value }
        return writeVault(accounts)
    }

    // MARK: - The vault: one Keychain item holding every account

    /// The account name of the single item. Every legacy per-account item
    /// (`provider.<id>`, `sync.token`, `server.databasePassword`) is folded
    /// into it by `migrateLegacyItemsIfNeeded()` on launch.
    static let vaultAccount = "clip.secrets"

    /// The decoded vault for this launch. `nil` = not loaded yet.
    private static var vaultCache: [String: String]?

    /// JSON in, JSON out - kept pure so the probe can prove the round trip
    /// without a Keychain (`vaultRoundTripForTesting`).
    static func encodeVault(_ accounts: [String: String]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["version": 1, "accounts": accounts],
                                     options: [.sortedKeys])) ?? Data()
    }

    static func decodeVault(_ data: Data) -> [String: String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = object["accounts"] as? [String: String] else { return nil }
        return accounts
    }

    /// Reads the one item without interaction. Returns the decoded accounts
    /// and the status (`errSecItemNotFound` when no vault exists yet).
    private static func loadVault(allowInteraction: Bool = false) -> ([String: String], OSStatus) {
        if let vaultCache { return (vaultCache, errSecSuccess) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        var out: CFTypeRef?
        let status = allowInteraction
            ? SecItemCopyMatching(query as CFDictionary, &out)
            : withoutInteraction { SecItemCopyMatching(query as CFDictionary, &out) }
        guard status == errSecSuccess, let data = out as? Data, let accounts = decodeVault(data) else {
            return ([:], status == errSecSuccess ? errSecDecode : status)
        }
        vaultCache = accounts
        return (accounts, errSecSuccess)
    }

    /// Replaces the one item (delete, then add - a fresh access list naming
    /// only this build) and verifies by reading it back.
    @discardableResult
    private static func writeVault(_ accounts: [String: String], allowInteraction: Bool = false) -> OSStatus {
        deleteRow(vaultAccount, allowInteraction: allowInteraction)
        vaultCache = nil
        guard !accounts.isEmpty else { return errSecSuccess }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultAccount,
            kSecValueData as String: encodeVault(accounts),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess { vaultCache = accounts }
        return status
    }

    /// Folds every legacy per-account item under this service into the vault,
    /// once. Items this build cannot read are left where they are and marked
    /// failing, so the interactive repair can still fold them in later;
    /// nothing is removed until the vault has been read back.
    static func migrateLegacyItemsIfNeeded() {
        guard !TestIsolation.isActive else { return }
        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var found: CFTypeRef?
        let listStatus = withoutInteraction { SecItemCopyMatching(listQuery as CFDictionary, &found) }
        Database.shared.log("keychain", "Vault migration: listed Keychain items under \(service) (status \(listStatus), \((found as? [[String: Any]])?.count ?? 0) row(s))")
        guard listStatus == errSecSuccess, let rows = found as? [[String: Any]] else { return }
        let legacy = rows.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0 != vaultAccount }
        guard !legacy.isEmpty else { return }

        let (existing, vaultStatus) = loadVault()
        guard vaultStatus == errSecSuccess || vaultStatus == errSecItemNotFound else {
            Database.shared.log("keychain", "Vault migration skipped: the vault item is not readable (\(vaultStatus))")
            return
        }
        var merged = existing
        var migrated: [String] = []
        var unreadable: [String] = []
        for account in legacy {
            if merged[account] != nil { migrated.append(account); continue }   // already folded in
            if let value = legacyRead(account) { merged[account] = value; migrated.append(account) }
            else { unreadable.append(account) }
        }
        if !unreadable.isEmpty {
            // Say so once, with the one action that fixes it: the interactive
            // repair reads each old item with the prompt allowed and folds it
            // into the vault, after which there is one item and one prompt.
            for account in unreadable {
                needsRepairAccounts.insert(account)
                failingAccounts.insert(account)
            }
            needsRepair = true
            let n = unreadable.count
            DispatchQueue.main.async {
                NoticeCenter.shared.report(
                    "\(n) saved key\(n == 1 ? "" : "s") need\(n == 1 ? "s" : "") one authorization to move into Clip's single Keychain item.",
                    remedy: "Click Repair and allow access when macOS asks. After this, Clip keeps every key in one item and asks once at most.",
                    kind: .persistent, key: "keychain.vault.migration",
                    action: repairAction(),
                    stillNeeded: { KeychainStore.needsRepair })
            }
        }
        guard !migrated.isEmpty else {
            Database.shared.log("keychain", "Vault migration: none of \(legacy.count) legacy item(s) is readable by this build; kept for the interactive repair")
            return
        }
        let status = writeVault(merged)
        vaultCache = nil
        let (readBack, readStatus) = loadVault()
        guard status == errSecSuccess, readStatus == errSecSuccess,
              migrated.allSatisfy({ readBack[$0] == merged[$0] }) else {
            Database.shared.log("keychain", "Vault migration: write not verified (\(status)/\(readStatus)); legacy items kept")
            return
        }
        for account in migrated { deleteRow(account, allowInteraction: false) }
        Database.shared.log("keychain", "Vault migration: \(migrated.count) secret(s) folded into one Keychain item"
                            + (unreadable.isEmpty ? "" : "; \(unreadable.count) unreadable item(s) kept for the interactive repair"))
    }

    // MARK: - Enumeration, for recovery (M28)

    /// The prefix a connection's descriptive metadata rides under, inside the
    /// same one Keychain item as its key.
    ///
    /// The key alone is not enough to rebuild a connection: `keychainAccount`
    /// is `provider.<uuid>`, and the uuid is meaningless without the name,
    /// kind, endpoint and model that lived in the database beside it. A
    /// reinstall keeps the Keychain and loses the database, so the metadata
    /// has to live where the key lives or recovery is reduced to guesswork.
    /// It rides in the same vault item, so it costs no extra prompt.
    static let metaPrefix = "meta."
    static func metaAccount(for account: String) -> String { metaPrefix + account }

    /// Whether an account name is one of the app's own book-keeping entries
    /// rather than a secret a person configured.
    static func isMetaAccount(_ account: String) -> Bool { account.hasPrefix(metaPrefix) }

    /// Everything the store holds, for the one caller that needs the whole
    /// set rather than an account whose name it already knows: recovery
    /// after a reinstall, when the Keychain is the only surviving record of
    /// what was configured.
    ///
    /// `allowInteraction` is false everywhere except the user-clicked
    /// recovery. With it false this cannot prompt and therefore cannot hang
    /// an agent app - the same rule every other read in this file follows.
    /// A sandboxed run never reaches `SecItem*` at all.
    static func allStoredSecrets(allowInteraction: Bool = false) -> (accounts: [String: String], status: OSStatus) {
        if TestIsolation.isActive { return (TestIsolation.allSecrets(), errSecSuccess) }
        if allowInteraction { vaultCache = nil }
        let (vault, status) = loadVault(allowInteraction: allowInteraction)
        guard status == errSecSuccess || status == errSecItemNotFound else { return ([:], status) }
        var accounts = vault
        // Items written before the vault existed, on an install whose
        // launch migration has not run or could not read them. They are the
        // whole point on the oldest installs, and folding them in here is
        // read-only: nothing is deleted, and `migrateLegacyItemsIfNeeded`
        // still owns the move.
        for account in legacyAccountNames() where accounts[account] == nil {
            if let value = allowInteraction ? interactiveLegacyRead(account) : legacyRead(account) {
                accounts[account] = value
            }
        }
        return (accounts, accounts.isEmpty ? status : errSecSuccess)
    }

    /// The account names of every per-account item under this service.
    ///
    /// Attributes only, never `kSecReturnData`: a query that does not ask for
    /// a secret's bytes is not access-checked against the item's ACL, so this
    /// answers "is there anything here" on a re-signed build where reading
    /// the values would prompt. That distinction is what lets the launch-time
    /// offer be honest about a store it cannot yet open.
    static func legacyAccountNames() -> [String] {
        guard !TestIsolation.isActive else { return [] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var found: CFTypeRef?
        let status = withoutInteraction { SecItemCopyMatching(query as CFDictionary, &found) }
        guard status == errSecSuccess, let rows = found as? [[String: Any]] else { return [] }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0 != vaultAccount }
    }

    /// Whether this service holds anything at all - the vault item, a legacy
    /// item, or both - answered without reading a single secret, so it can
    /// never prompt.
    static func hasStoredItems() -> Bool {
        if TestIsolation.isActive { return !TestIsolation.allSecrets().isEmpty }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var found: CFTypeRef?
        let status = withoutInteraction { SecItemCopyMatching(query as CFDictionary, &found) }
        return status == errSecSuccess && !((found as? [[String: Any]])?.isEmpty ?? true)
    }

    /// A legacy per-account item with the prompt allowed. Only ever reached
    /// from `allStoredSecrets` when its caller asked for interaction, which
    /// only the user-clicked recovery does, and which is gated by
    /// `CredentialExplainer` - the same single funnel `repairAccess()` uses.
    ///
    /// The sentence above deliberately does not spell out the argument as it
    /// would be written at a call site: the probe's V9/V9f gates find
    /// interactive Keychain paths by searching the source for that literal,
    /// and a comment that reads like a call site is a false positive that
    /// trains people to relax a security gate. Prose about a call, not a
    /// copy of one.
    private static func interactiveLegacyRead(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A legacy per-account item, read without interaction.
    private static func legacyRead(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        var out: CFTypeRef?
        let status = withoutInteraction { SecItemCopyMatching(query as CFDictionary, &out) }
        guard status == errSecSuccess, let data = out as? Data else {
            Database.shared.log("keychain", "Vault migration: \(KeychainStore.subjectName(for: account)) (\(account)) not readable without a prompt (status \(status))")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    #if CLIP_TESTING
    /// Proves the vault's JSON round trip and merge without a Keychain.
    static var vaultRoundTripForTesting: Bool {
        let sample = ["provider.a": "key-a", "sync.token": "tok", "server.databasePassword": "pw"]
        return decodeVault(encodeVault(sample)) == sample && decodeVault(Data("nonsense".utf8)) == nil
    }
    #endif

    // MARK: - Which accounts the app actually expects to hold a secret
    //
    // `get` needs to tell "no key configured" from "the key is gone" apart,
    // and that is a fact about the rest of the app (is there a provider row
    // for this account, is a sync space claimed) that this file cannot read
    // for itself: `get` runs on the request path, which is not always the
    // main actor, and `AIService.shared`/`SyncManager.shared` are. So the
    // owners register the accounts they expect, and this is consulted
    // synchronously.
    nonisolated(unsafe) private(set) static var knownAccounts: Set<String> = []

    static func markConfigured(_ account: String) { knownAccounts.insert(account) }

    /// `@MainActor` rather than hopped: every call site (`AIService`,
    /// `ServerConfig`, `SyncManager`) is already on the main actor, and
    /// resolving the notice synchronously there means the very next read of
    /// `NoticeCenter` - in the same function, often - already sees it gone.
    @MainActor
    static func markUnconfigured(_ account: String) {
        knownAccounts.remove(account)
        failingAccounts.remove(account)
        needsRepairAccounts.remove(account)
        missingSecretAccounts.remove(account)
        NoticeCenter.shared.resolve("keychain.needsRepair.\(account)")
        NoticeCenter.shared.resolve("keychain.missing.\(account)")
    }

    /// Secrets already read, for the life of the process.
    ///
    /// `apiKey` was reading the Keychain on **every** request, and every read is
    /// a chance for macOS to ask the user to authorise access - which under
    /// ad-hoc signing it does after each rebuild, and which an agent app cannot
    /// display. The user's complaint was exactly this: picking an AI action
    /// asked for their Mac password.
    ///
    /// In memory only, never written anywhere, gone when the app quits. It does
    /// not weaken the Keychain: the secret is in this process's memory the
    /// moment it is used for a request either way.
    /// A double optional on purpose: `nil` means "never looked", and
    /// `.some(nil)` means "looked, and there is nothing there".
    ///
    /// Caching the absence matters as much as caching the value. A provider with
    /// no key stored was re-read on every single request - which is a prompt
    /// every time under ad-hoc signing, for a secret that does not even exist.
    /// The state dump alone was doing this thousands of times a run.
    private static var cache: [String: String?] = [:]

    /// How many times the store behind the cache was consulted - the Keychain,
    /// or the sandbox's secrets file under test.
    ///
    /// Test-facing: "read once per launch" is a claim about behaviour, and only
    /// a count can check it.
    nonisolated(unsafe) static var backingStoreReads = 0
    /// Reads per account, so a test can count the ones it caused rather than
    /// every read in the process. The first version of that assertion counted
    /// the total and failed against correct code: the state dump reads several
    /// secrets of its own on every command.
    nonisolated(unsafe) static var readsByAccount: [String: Int] = [:]

    /// Why the last Keychain read did not produce a value, when it did not.
    ///
    /// `errSecInteractionNotAllowed` here is the whole of Problem 2: the item
    /// exists and holds the right key, and this build is simply not on its
    /// access list.
    nonisolated(unsafe) private(set) static var lastReadStatus: OSStatus = errSecSuccess
    /// True when a stored secret is unreachable because the app was re-signed.
    nonisolated(unsafe) private(set) static var needsRepair = false
    /// True when a *configured* account (a provider row, a claimed sync space)
    /// has nothing behind it any more - a different fact from "never set up",
    /// and one worth a different sentence.
    nonisolated(unsafe) private(set) static var missingSecret = false
    /// The account and status behind the most recent failure of either kind,
    /// so a repair can log and verify against something concrete.
    nonisolated(unsafe) private(set) static var lastFailure: (account: String, status: OSStatus, at: Date)?
    /// Every account currently failing, of either kind - what `selfRepair`
    /// works through when called with no account of its own.
    nonisolated(unsafe) private(set) static var failingAccounts: Set<String> = []
    /// Accounts failing because the item exists and is off-limits.
    nonisolated(unsafe) private(set) static var needsRepairAccounts: Set<String> = []
    /// Accounts failing because a configured secret is simply gone.
    nonisolated(unsafe) private(set) static var missingSecretAccounts: Set<String> = []

    #if CLIP_TESTING
    /// Forces the next `get` for this account to behave as though the
    /// backing store returned this status, without ever touching the real
    /// Keychain - even under `TestIsolation`, which otherwise answers every
    /// read from its own file. This is what lets a probe reproduce every
    /// Keychain failure mode without a re-signed binary.
    nonisolated(unsafe) static var simulatedStatus: [String: OSStatus] = [:]
    /// Makes the very next `get`, for any account, report as though the
    /// write that just happened silently did not take - so a probe can prove
    /// a repair counts a VERIFIED read-back rather than merely having
    /// attempted a write.
    nonisolated(unsafe) static var forceNextReadBackFailureForTesting = false
    /// How many times the interactive repair path actually ran. `selfRepair`
    /// must never move this on its own - only a person's own click on the
    /// notice's action, or the menu item, may.
    nonisolated(unsafe) static var interactiveRepairInvocationsForTesting = 0
    /// One-shot: the next `set` for this account returns exactly this status
    /// instead of writing anything, so K2's "caller checks the status" can be
    /// proved without a real `SecItemAdd` failure.
    nonisolated(unsafe) static var simulatedSetStatus: [String: OSStatus] = [:]

    /// Arms `simulatedStatus` for one account, and drops any cached read for
    /// it - without this, an account already read successfully this launch
    /// would keep answering from the cache and never see the simulated
    /// failure at all.
    static func simulateStatusForTesting(_ status: OSStatus, for account: String) {
        cache.removeValue(forKey: account)
        simulatedStatus[account] = status
    }

    /// Clears a simulated failure, standing in for "the underlying problem
    /// went away on its own" - stage 1 of a real repair.
    static func clearSimulatedStatusForTesting(_ account: String) {
        simulatedStatus.removeValue(forKey: account)
        cache.removeValue(forKey: account)
    }
    #endif

    /// Runs a Keychain call with the legacy ACL dialog switched OFF.
    ///
    /// This is the fix for the popup the user sees when they pick an AI
    /// action. The item was created on 29/08 by an ad-hoc signed build; the
    /// app was re-signed on 02/09 under "Clip Local Signing", and a Keychain
    /// ACL names the exact binary that created the item. The new binary is
    /// not on that list, so macOS asks - "Clip wants to use your confidential
    /// information stored in app.clip.ai in your keychain".
    ///
    /// Two separate switches, because the two prompt mechanisms are separate:
    /// `kSecUseAuthenticationUI` covers the modern data-protection path and
    /// `SecKeychainSetUserInteractionAllowed` covers the legacy file keychain,
    /// which is the one a `genp` item in login.keychain-db actually goes
    /// through. With interaction off the call returns
    /// `errSecInteractionNotAllowed` immediately instead of blocking.
    ///
    /// That last point is not a nicety. This is an `LSUIElement` agent app: a
    /// modal it did not ask for has nowhere to appear, and the call never
    /// returns. Silencing the prompt is what makes a hang impossible, not
    /// merely unlikely.
    private static func withoutInteraction<T>(_ body: () -> T) -> T {
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        return body()
    }

    static func get(_ account: String) -> String? {
        // The cache comes FIRST, before the test branch. With the branch first,
        // a sandboxed run never exercised the cache at all - so the assertion
        // about reading a secret once per launch was measuring a path the user
        // never takes, and passed with the cache deliberately removed.
        if let cached = cache[account] { return cached }
        #if CLIP_TESTING
        if let forced = simulatedStatus[account] {
            return classify(forced, account: account)
        }
        if forceNextReadBackFailureForTesting {
            forceNextReadBackFailureForTesting = false
            return classify(errSecInteractionNotAllowed, account: account)
        }
        #endif
        backingStoreReads += 1
        readsByAccount[account, default: 0] += 1
        if TestIsolation.isActive {
            guard let value = TestIsolation.secret(account) else {
                return classify(errSecItemNotFound, account: account)
            }
            cache[account] = value
            clearFailure(account)
            return value
        }
        // One item for every account: the vault is read once per launch
        // (interaction off, `kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip`
        // inside `loadVault`), and each account is answered from it. A vault
        // this build cannot read fails every account the same way, which is
        // exactly the fact the one interactive repair fixes in one prompt.
        let (vault, status) = loadVault()
        guard status == errSecSuccess else {
            return classify(status, account: account)
        }
        guard let value = vault[account] else {
            return classify(errSecItemNotFound, account: account)
        }
        lastReadStatus = status
        cache[account] = value
        clearFailure(account)
        return value
    }

    private static func clearFailure(_ account: String) {
        failingAccounts.remove(account)
        needsRepairAccounts.remove(account)
        missingSecretAccounts.remove(account)
        // Always resolve, never guarded on the flags: `set` clears the flags
        // on its own during a repair, and a guard here then returned before
        // the notice was taken down. The banner stayed up after a repair that
        // had worked (user report, 02/09/2026). Hopped because a read that
        // just succeeded may not be on the main actor.
        DispatchQueue.main.async {
            NoticeCenter.shared.resolve("keychain.needsRepair.\(account)")
            NoticeCenter.shared.resolve("keychain.missing.\(account)")
        }
    }

    /// Turns a failing `OSStatus` into the cached absence, plus - for every
    /// status but "not found" - a notice, and - for "not found" on an account
    /// this app actually expects to hold something - the same.
    ///
    /// Every status but `errSecSuccess` and `errSecItemNotFound` used to
    /// degrade to a cached `nil` with nothing said: `-25300` and every other
    /// status this app had not seen yet all read the same as "no key
    /// configured", which is exactly the message the user would see after a
    /// signature change made a real key unreadable
    /// (`errSecInteractionNotAllowed`, `errSecAuthFailed`).
    @discardableResult
    private static func classify(_ status: OSStatus, account: String) -> String? {
        lastReadStatus = status
        cache[account] = String?.none
        guard status != errSecItemNotFound else {
            // Absence is an answer for an account nobody configured. For one
            // this app DOES expect - a provider row, a claimed sync space -
            // it is a different fact: the key was there and now is not.
            if knownAccounts.contains(account) {
                missingSecret = true
                missingSecretAccounts.insert(account)
                failingAccounts.insert(account)
                lastFailure = (account, status, Date())
                let subject = subjectName(for: account)
                DispatchQueue.main.async {
                    NoticeCenter.shared.report(
                        "The saved \(subject) is gone.",
                        remedy: "Clip will try to repair it automatically. If it can't, "
                              + "open Settings and add it again, or right-click the menu "
                              + "bar icon and choose Repair AI Key Access.",
                        kind: .persistent, key: "keychain.missing.\(account)",
                        action: repairAction(),
                        stillNeeded: { KeychainStore.missingSecretAccounts.contains(account) })
                }
            }
            return nil
        }
        // Every other status: the item is there and this build cannot use it
        // (`errSecInteractionNotAllowed`, the ACL case after a re-sign, or
        // `errSecAuthFailed`), or the store itself refused the call. Both
        // have the same remedy, and neither should degrade to "no key
        // configured".
        needsRepair = true
        needsRepairAccounts.insert(account)
        failingAccounts.insert(account)
        lastFailure = (account, status, Date())
        let subject = subjectName(for: account)
        // Hopped rather than asserted: `get` is called from the request
        // path, which is not the main actor.
        DispatchQueue.main.async {
            NoticeCenter.shared.report(
                "Clip cannot read \(subject).",
                remedy: "The app was re-signed since it was stored. Clip will try to "
                      + "repair this automatically. If it can't, right-click the menu "
                      + "bar icon and choose Repair AI Key Access.",
                kind: .persistent, key: "keychain.needsRepair.\(account)",
                action: repairAction(),
                stillNeeded: { KeychainStore.needsRepairAccounts.contains(account) })
        }
        return nil
    }

    /// A name for the account a person would recognise, for the sentence
    /// that says something went wrong with it.
    ///
    /// Deliberately not looking up a provider's own name here: that lives on
    /// `AIService`, a main-actor type, and this runs on whatever thread
    /// called `get` - which the file already documents as not always the
    /// main actor. A generic noun is worth more than a precise one that can
    /// only be read safely from one thread.
    /// Plain words for what an account holds - "sync token", "server
    /// password", "AI connection's API key" - shared with `DiagnosticsInsights`.
    static func subjectName(for account: String) -> String {
        if account == syncTokenAccount { return "sync token" }
        if account == ServerConfig.keychainAccount { return "server password" }
        if account.hasPrefix("provider.") { return "AI connection's API key" }
        return "API key"
    }

    /// The account `SyncManager` stores the sync token under. Named here too
    /// so a message about it can be worded without importing `SyncManager`'s
    /// own private constant.
    static let syncTokenAccount = "sync.token"

    /// The action a "needs repair"/"missing" notice carries. Runs the
    /// existing interactive path - the one place a Keychain prompt is
    /// answerable, because a person just clicked something and is looking at
    /// the screen.
    private static func repairAction() -> NoticeCenter.Action {
        // The counter lives inside `repairAccess` itself, not here - this
        // closure is one of two ways to reach it (the menu item is the
        // other), and counting in both places would count one click twice.
        NoticeCenter.Action(title: "Repair now") {
            AppDelegate.shared?.repairKeychainAccess()
        }
    }

    /// A bare, non-interactive read straight from the backing store, ignoring
    /// any simulated failure. In production this is the exact query `get`
    /// already makes - so it repairs nothing a re-signed build could not
    /// already read, which is honest: only a person answering the one
    /// interactive prompt can fix an ACL mismatch. Under test it reads past
    /// `simulateKeychainStatus`'s override to the real sandboxed value, which
    /// is what makes a *transient* failure - the case this stage exists for -
    /// provable without a real re-signed binary.
    private static func rawBackingRead(_ account: String) -> String? {
        if TestIsolation.isActive { return TestIsolation.secret(account) }
        vaultCache = nil
        let (vault, status) = loadVault()
        guard status == errSecSuccess else { return nil }
        return vault[account]
    }

    /// What a self-repair actually did, counted by verified read-back rather
    /// than by attempt.
    struct RepairResult: Equatable {
        var repaired: Int = 0
        var failed: Int = 0
        var unreadable: [String] = []
        var stillMissing: [String] = []
    }

    /// Repairs every account currently failing, in three stages, stopping at
    /// the first that clears an account - or every account named, when the
    /// caller already knows which one matters.
    ///
    /// 1. Drop the negative cache entry and re-read: free, and covers a
    ///    transient failure the cache had already written off.
    /// 2. A bare non-interactive read straight from the backing store; if it
    ///    turns up a value, re-persist it under this build's identity so a
    ///    future read never needs interaction again. Zero prompts either way.
    /// 3. Never run here. An ACL mismatch after a re-sign can only be fixed
    ///    by a person answering the one interactive prompt an agent app can
    ///    show - from a real window, on an explicit click - so this only
    ///    posts the notice carrying that action and stops.
    @discardableResult
    static func selfRepair(reason: String, accounts named: [String] = []) async -> RepairResult {
        let accounts = named.isEmpty ? Array(failingAccounts) : named
        guard !accounts.isEmpty else { return RepairResult() }
        Database.shared.log("keychain", "Self-repair (\(reason)) started for \(accounts.count) account(s)")

        var repaired: [String] = []
        var stillFailing = accounts

        // Stage 1.
        stillFailing = stillFailing.filter { account in
            cache.removeValue(forKey: account)
            if get(account) != nil { repaired.append(account); return false }
            return true
        }

        // Stage 2.
        if !stillFailing.isEmpty {
            var stage2Remaining: [String] = []
            for account in stillFailing {
                if let value = rawBackingRead(account) {
                    set(value, for: account)
                    cache.removeValue(forKey: account)
                    if get(account) != nil { repaired.append(account); continue }
                }
                stage2Remaining.append(account)
            }
            stillFailing = stage2Remaining
        }

        for account in repaired { clearFailure(account) }
        if !repaired.isEmpty { await verifyAfterRepair(repaired) }

        let result = RepairResult(
            repaired: repaired.count, failed: stillFailing.count,
            unreadable: stillFailing.filter { needsRepairAccounts.contains($0) },
            stillMissing: stillFailing.filter { missingSecretAccounts.contains($0) })

        if stillFailing.isEmpty {
            Database.shared.log("keychain", "Self-repair (\(reason)): recovered all \(repaired.count)")
        } else {
            Database.shared.log("keychain", "Self-repair (\(reason)): \(stillFailing.count) account(s) still need the interactive repair")
        }
        return result
    }

    /// "Readable" and "accepted" are different questions - a key that reads
    /// fine can still be the wrong key. After any stage that recovered an
    /// account, this asks the real question: an AI connection is validated
    /// with a real request, the sync token with a real sync attempt.
    @MainActor
    private static func verifyAfterRepair(_ accounts: [String]) async {
        for account in accounts {
            if account == syncTokenAccount {
                await SyncManager.shared.syncNow(reason: "self-repair")
            } else if let provider = AIService.shared.providers.first(where: { $0.keychainAccount == account }) {
                _ = await AIService.shared.validate(provider)
            }
        }
    }

    /// Re-writes every stored secret under this build's signature.
    ///
    /// Called from a real, visible window on an explicit click, which is the
    /// only context where letting the Keychain put a dialog on screen is
    /// acceptable in an agent app - someone asked for it and is looking at
    /// the screen. Every other read runs with interaction off.
    ///
    /// Why delete-then-add rather than adding the new signature to the
    /// existing ACL: `SecItemAdd` gives the new item an access list containing
    /// exactly the process that created it, so a rewrite from the current
    /// binary produces the correct ACL with no deprecated `SecAccess` surgery
    /// and no window where the item has two owners. The secret never leaves
    /// the Keychain: it is read into memory and written straight back, which
    /// is precisely what happens on every ordinary request anyway.
    @discardableResult
    static func repairAccess() -> (repaired: Int, message: String) {
        #if CLIP_TESTING
        interactiveRepairInvocationsForTesting += 1
        #endif
        guard !TestIsolation.isActive else {
            return (0, "Not applicable to a sandboxed test run.")
        }
        // Interaction ON, deliberately: this is the one authorised prompt,
        // and it is answerable because an alert is already on screen. One
        // item, so one prompt - the whole point of the vault.
        vaultCache = nil
        var (accounts, status) = loadVault(allowInteraction: true)
        // Legacy per-account items this build could not fold in silently are
        // folded in now, with the prompt allowed.
        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var found: CFTypeRef?
        if SecItemCopyMatching(listQuery as CFDictionary, &found) == errSecSuccess,
           let rows = found as? [[String: Any]] {
            for row in rows {
                guard let account = row[kSecAttrAccount as String] as? String, account != vaultAccount else { continue }
                let readQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne
                ]
                var out: CFTypeRef?
                if SecItemCopyMatching(readQuery as CFDictionary, &out) == errSecSuccess,
                   let data = out as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty {
                    accounts[account] = value
                    deleteRow(account, allowInteraction: true)
                    status = errSecSuccess
                }
            }
        }
        guard status == errSecSuccess, !accounts.isEmpty else {
            return (0, "No saved keys were found for this app, so there is nothing to repair. "
                     + "Enter your API key in Settings and it will be stored under this build.")
        }

        var repaired = 0
        var failed = 0
        // Delete with interaction allowed (the delete is ACL-checked too),
        // then add: the new item's access list is this binary and nothing
        // else, so no later read can prompt. Verified by reading back every
        // account, not merely attempted.
        writeVault(accounts, allowInteraction: true)
        vaultCache = nil
        for (account, value) in accounts {
            cache.removeValue(forKey: account)
            if get(account) == value {
                repaired += 1
                clearFailure(account)
            } else {
                failed += 1
            }
        }
        if repaired > 0 {
            needsRepair = false; lastReadStatus = errSecSuccess
            DispatchQueue.main.async { NoticeCenter.shared.resolve("keychain.vault.migration") }
        }
        if needsRepairAccounts.isEmpty { needsRepair = false }
        if missingSecretAccounts.isEmpty { missingSecret = false }

        var message = "\(repaired) saved key\(repaired == 1 ? "" : "s") now live in one Keychain item "
            + "stored under this version of Clip. You will not be asked for them again."
        if failed > 0 {
            message += "\n\n\(failed) could not be read. Open Settings > AI and enter that key "
                     + "again. It will be stored correctly this time."
        }
        return (repaired, message)
    }

    static func remove(_ account: String) {
        cache.removeValue(forKey: account)
        if TestIsolation.isActive { TestIsolation.removeSecret(account); return }
        let (vault, status) = loadVault()
        guard status == errSecSuccess, vault[account] != nil else { return }
        var accounts = vault
        accounts.removeValue(forKey: account)
        writeVault(accounts)
    }

    /// The raw delete. `SecItemDelete` is ACL-checked exactly like a read, so
    /// on a re-signed build it is a second way to get the same popup - and a
    /// second way to hang, since `set` deletes before it adds. Off by default
    /// for that reason; only the explicit repair turns interaction on.
    private static func deleteRow(_ account: String, allowInteraction: Bool) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if allowInteraction {
            SecItemDelete(query as CFDictionary)
        } else {
            _ = withoutInteraction { SecItemDelete(query as CFDictionary) }
        }
    }
}

/// The wire format a provider speaks. Most vendors are OpenAI-compatible, which
/// is why that case covers so many services.
enum ProviderKind: String, CaseIterable, Identifiable, Codable {
    case anthropic, openai, gemini, openaiCompatible, ollama

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic:        return "Anthropic (Claude)"
        case .openai:           return "OpenAI (ChatGPT)"
        case .gemini:           return "Google Gemini"
        case .openaiCompatible: return "OpenAI-compatible"
        case .ollama:           return "Ollama (local)"
        }
    }

    /// A hint for the endpoint field; `openaiCompatible` covers NVIDIA NIM,
    /// Groq, OpenRouter, Together, Mistral and most other hosted APIs.
    var endpointHint: String {
        switch self {
        case .anthropic:        return "https://api.anthropic.com/v1/messages"
        case .openai:           return "https://api.openai.com/v1/chat/completions"
        case .gemini:           return "https://generativelanguage.googleapis.com/v1beta/models"
        case .openaiCompatible: return "https://integrate.api.nvidia.com/v1/chat/completions"
        case .ollama:           return "http://localhost:11434/v1/chat/completions"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic:        return "claude-sonnet-5"
        case .openai:           return "gpt-4o-mini"
        case .gemini:           return "gemini-2.0-flash"
        case .openaiCompatible: return "meta/llama-3.1-70b-instruct"
        case .ollama:           return "llama3.1"
        }
    }

    /// Ollama runs locally and needs no credential.
    var needsKey: Bool { self != .ollama }

    var suggestions: [String] {
        switch self {
        case .openaiCompatible:
            return ["NVIDIA NIM (free tier)", "Groq", "OpenRouter", "Together", "Mistral"]
        default: return []
        }
    }
}

/// One configured connection. The key itself is not a stored property — it is
/// fetched from the Keychain by `id` when a request is actually made.
/// What part a connection plays.
enum ProviderRole: String, Codable, CaseIterable, Identifiable {
    case primary, backup, unused
    var id: String { rawValue }
    var title: String {
        switch self {
        case .primary: return "Main"
        case .backup:  return "Backup"
        case .unused:  return "Not in use"
        }
    }
}

/// Whether a connection answered last time it was asked.
enum ProviderHealth: String, Codable {
    case untested, ready, down
    var title: String {
        switch self {
        case .untested: return "Untested"
        case .ready:    return "Ready"
        case .down:     return "Down"
        }
    }
}

struct AIProvider: Identifiable, Equatable, Codable {
    let id: String
    var name: String
    var kind: ProviderKind
    var endpoint: String
    var model: String
    var isActive: Bool
    var validatedAt: Date?

    // Added in v4.
    var role: ProviderRole = .unused
    var health: ProviderHealth = .untested
    var lastError: String?
    var lastCheckedAt: Date?

    var keychainAccount: String { "provider.\(id)" }
    var apiKey: String? { KeychainStore.get(keychainAccount) }
    var isValidated: Bool { validatedAt != nil }

    init(id: String = UUID().uuidString, name: String, kind: ProviderKind,
         endpoint: String? = nil, model: String? = nil,
         isActive: Bool = false, validatedAt: Date? = nil,
         role: ProviderRole = .unused, health: ProviderHealth = .untested) {
        self.id = id
        self.name = name
        self.kind = kind
        self.endpoint = endpoint ?? kind.endpointHint
        self.model = model ?? kind.defaultModel
        self.isActive = isActive
        self.validatedAt = validatedAt
        self.role = role
        self.health = health
    }

    // Tolerant decoding: connections saved before roles existed still load.
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, endpoint, model, isActive, validatedAt
        case role, health, lastError, lastCheckedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(ProviderKind.self, forKey: .kind)
        endpoint = try c.decode(String.self, forKey: .endpoint)
        model = try c.decode(String.self, forKey: .model)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        validatedAt = try c.decodeIfPresent(Date.self, forKey: .validatedAt)
        // An older "active" connection becomes the main one.
        role = try c.decodeIfPresent(ProviderRole.self, forKey: .role) ?? (isActive ? .primary : .unused)
        health = try c.decodeIfPresent(ProviderHealth.self, forKey: .health)
            ?? (validatedAt != nil ? .ready : .untested)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        lastCheckedAt = try c.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
    }
}

/// Anything that can answer a prompt. The protocol exists so tests can inject a
/// stub and exercise every AI feature without a key or a network.
protocol AIClient {
    func complete(system: String, user: String, maxTokens: Int) async throws -> String

    /// Ask for JSON at the API level rather than in the prompt.
    ///
    /// Telling a reasoning model to reply with only JSON is a request, and it
    /// declines: six theme descriptions in a row came back as "We need to output
    /// a single JSON object..." and ran out of budget before producing one.
    /// `response_format` is not a request.
    func complete(system: String, user: String, maxTokens: Int,
                  wantsJSON: Bool) async throws -> String
}

extension AIClient {
    /// Stubs and simple clients need not care; they answer the same either way.
    func complete(system: String, user: String, maxTokens: Int,
                  wantsJSON: Bool) async throws -> String {
        try await complete(system: system, user: user, maxTokens: maxTokens)
    }
}

enum AIError: LocalizedError {
    case notConfigured
    case missingKey
    /// The Keychain item is there and this build cannot use it - an ACL left
    /// over from before a re-sign, most often.
    case keyUnreadable(OSStatus)
    /// The Keychain item for a configured connection is simply gone.
    case keyMissing
    case http(Int, String)
    case malformed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured:      return "No AI connection is active."
        case .missingKey:         return "This connection has no API key saved."
        case .keyUnreadable:      return "Clip cannot read this connection's saved key."
        case .keyMissing:         return "The saved key for this connection is gone."
        case .http(let c, let m): return "The provider returned \(c). \(m)"
        case .malformed(let m):   return "Could not read the provider's reply. \(m)"
        case .cancelled:          return "Canceled."
        }
    }
}

/// Talks to a configured provider. One request per user action, nothing in the
/// background, no retries that the user did not ask for.
struct LiveAIClient: AIClient {
    let provider: AIProvider

    /// How long one request may take before it is given up on.
    ///
    /// A real feature can wait a minute: a reasoning model genuinely thinks for
    /// that long. A *connection test* cannot, and that is what made "Test all"
    /// look hung - three dead endpoints at 60 seconds each is three minutes
    /// behind one undifferentiated spinner, which is indistinguishable from a
    /// deadlock. The caller says which kind of request this is.
    var timeout: TimeInterval = 60

    func complete(system: String, user: String, maxTokens: Int = 1024) async throws -> String {
        try await complete(system: system, user: user, maxTokens: maxTokens, wantsJSON: false)
    }

    func complete(system: String, user: String, maxTokens: Int,
                  wantsJSON: Bool) async throws -> String {
        do {
            return try await send(system: system, user: user,
                                  maxTokens: maxTokens, wantsJSON: wantsJSON)
        } catch AIError.http(let code, let message) where code == 400 {
            // A server that does not understand one of these hints rejects the
            // whole request. Losing the feature to a hint it did not need would
            // be worse than one extra call, so try again plainly.
            Database.shared.log("ai", "a request hint was refused (\(message.prefix(60))); retrying without it")
            return try await send(system: system, user: user, maxTokens: maxTokens,
                                  wantsJSON: false, plain: true)
        }
    }

    private func send(system: String, user: String, maxTokens: Int,
                      wantsJSON: Bool, plain: Bool = false) async throws -> String {
        guard let url = URL(string: provider.endpoint) else {
            throw AIError.malformed("The endpoint is not a valid URL.")
        }
        var request = URLRequest(url: provider.kind == .gemini
            ? URL(string: "\(provider.endpoint)/\(provider.model):generateContent")! : url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        let key = provider.apiKey
        if provider.kind.needsKey {
            if KeychainStore.needsRepairAccounts.contains(provider.keychainAccount) {
                throw AIError.keyUnreadable(KeychainStore.lastReadStatus)
            }
            if KeychainStore.missingSecretAccounts.contains(provider.keychainAccount) {
                throw AIError.keyMissing
            }
            guard let key, !key.isEmpty else { throw AIError.missingKey }
        }

        switch provider.kind {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": provider.model,
                "max_tokens": maxTokens,
                "system": system,
                "messages": [["role": "user", "content": user]]
            ])
        case .gemini:
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": [["role": "user", "parts": [["text": user]]]],
                "generationConfig": ["maxOutputTokens": maxTokens]
            ])
        case .openai, .openaiCompatible, .ollama:
            if let key, !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            // Turning reasoning off is a *parameter*, not a request.
            //
            // `/no_think` in the system prompt is what this used to rely on, and
            // it does not survive a demanding prompt: with the theme brief
            // attached, the model reasoned until it hit the token ceiling and the
            // API mirrored that unfinished reasoning into `content`. The app then
            // showed the user "We need to output a single JSON object..." as
            // though it were the answer. Measured over six attempts: none
            // produced a theme.
            //
            // `chat_template_kwargs: {"thinking": false}` is the control this
            // family actually honours - same prompt, clean JSON, reasoning empty.
            let thinkingOff = !plain && Self.suppressesThinking(provider.model)
            let systemPrompt = thinkingOff ? "/no_think\n" + system : system
            var body: [String: Any] = [
                "model": provider.model,
                "max_tokens": maxTokens,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": user]
                ]
            ]
            if thinkingOff {
                body["chat_template_kwargs"] = ["thinking": false]
            }
            // `response_format` is for models that reason regardless. Sent
            // *together* with thinking disabled it measurably degraded the
            // answer - the object came back malformed - so it is one or the
            // other, not both.
            if wantsJSON && !thinkingOff {
                body["response_format"] = ["type": "json_object"]
                body["temperature"] = 0.4
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIError.malformed("No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIError.http(http.statusCode, Self.errorMessage(from: body))
        }
        return try Self.extractText(data, kind: provider.kind)
    }

    /// Pulls the assistant's text out of whichever envelope the vendor uses.
    private static func extractText(_ data: Data, kind: ProviderKind) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.malformed("The reply was not JSON.")
        }
        switch kind {
        case .anthropic:
            guard let content = root["content"] as? [[String: Any]] else { break }
            let text = content.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { return text }
        case .gemini:
            guard let candidates = root["candidates"] as? [[String: Any]],
                  let first = candidates.first,
                  let content = first["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { break }
            let text = parts.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { return text }
        case .openai, .openaiCompatible, .ollama:
            guard let choices = root["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any] else { break }
            let text = (message["content"] as? String).map(stripReasoning) ?? ""
            if !text.isEmpty { return text }
            // Reasoning models put their working in a separate field and can
            // spend the whole token budget there, leaving content empty. Saying
            // so is far more useful than returning nothing.
            if message["reasoning_content"] is String {
                throw AIError.malformed("The model spent its whole budget reasoning and returned no answer. Try a larger max tokens or a non-reasoning model.")
            }
        }
        throw AIError.malformed("No text field in the response.")
    }

    /// Models that narrate their reasoning unless told not to.
    static func suppressesThinking(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.contains("nemotron") || m.contains("qwq") || m.contains("deepseek-r")
    }

    /// Some models inline their chain of thought in `<think>` tags. That is
    /// working-out, not an answer, and must never reach the user's document.
    private static func stripReasoning(_ raw: String) -> String {
        var out = raw
        while let start = out.range(of: "<think>"),
              let end = out.range(of: "</think>", range: start.upperBound..<out.endIndex) {
            out.removeSubrange(start.lowerBound..<end.upperBound)
        }
        // An unterminated block means the answer never arrived.
        if let start = out.range(of: "<think>") { out.removeSubrange(start.lowerBound..<out.endIndex) }
        return stripNarratedPreamble(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Removes a chain-of-thought written as prose rather than tagged.
    ///
    /// Reasoning models sometimes open with "Here's a thinking process:" and a
    /// numbered plan before the real answer. That is working-out, and pasting it
    /// into the user's document would be worse than returning nothing.
    private static func stripNarratedPreamble(_ text: String) -> String {
        let markers = ["here's a thinking process", "here is a thinking process",
                       "let me think", "thinking process:", "my thought process",
                       "let's think step by step"]
        let lower = text.lowercased()
        guard markers.contains(where: { lower.hasPrefix($0) }) else { return text }

        // The answer is whatever follows the last clear separator.
        for separator in ["\n\n---\n\n", "\nFinal answer:", "\nAnswer:", "\nOutput:"] {
            if let range = text.range(of: separator, options: [.backwards, .caseInsensitive]) {
                let tail = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty { return tail }
            }
        }
        // Otherwise take the last non-empty paragraph, which is where these
        // models put the conclusion.
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return paragraphs.last ?? text
    }

    /// Vendors bury the useful part of an error at different depths.
    private static func errorMessage(from body: String) -> String {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return String(body.prefix(200)) }
        if let err = root["error"] as? [String: Any], let m = err["message"] as? String { return m }
        if let m = root["message"] as? String { return m }
        return String(body.prefix(200))
    }
}
