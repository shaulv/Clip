import Foundation
import AppKit
import Combine
import CryptoKit
import IOKit
import Security

/// A sync space: one shared pool of history, addressed by one token.
struct SyncSpace: Codable, Equatable {
    var id: String
    /// False locks the space to the Macs already using it.
    var shared: Bool
    var devices: Int
    var items: Int
    var deletionRequestedAt: Date?

    var deviceSummary: String {
        devices <= 1 ? "This Mac only" : "\(devices) Macs"
    }
}

/// One Mac on a sync token.
struct SyncDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let lastSeen: Date

    /// True for the Mac asking the question.
    @MainActor var isThisMac: Bool { id == SyncManager.shared.deviceID }

    var lastSeenText: String {
        guard lastSeen.timeIntervalSince1970 > 0 else { return "never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: lastSeen, relativeTo: Date())
    }
}

enum SyncError: LocalizedError {
    case noToken
    case server(String)

    var errorDescription: String? {
        switch self {
        case .noToken: return "This Mac is not connected to a sync token yet."
        case .server(let message): return message
        }
    }
}

/// Owns the sync token, the space it addresses, and which way data flows.
///
/// There is no account here, and no sign-in. Sign-up, passwords and OAuth were
/// all removed because every one of them was a way for sync to fail before it
/// ever synced anything: a Google client id the user had to register, an email
/// to verify, a password to recover. What is left is the only part that was ever
/// load-bearing - a secret this Mac holds, which addresses a pool of data. Paste
/// the same token on a second Mac and the two are one.
///
/// Rules this type exists to keep:
/// - The token lives in the Keychain. Never in the database, never in
///   `UserDefaults`, never in a log line.
/// - The server is told the token and nothing else about who you are.
/// - Data never moves in a direction the user did not choose. `mergeOnSync` is
///   asked before the first sync and honoured on every one after it.
@MainActor
final class SyncManager: NSObject, ObservableObject {

    static let shared = SyncManager()

    /// Which server this Mac is talking to.
    ///
    /// The two sync methods do not share an address, and that separation is the
    /// whole of this type. Before it existed, `baseURL` was one preference, so
    /// signing in with Google sent your clipboard to whatever the user happened
    /// to have typed into the Server field - which is either nowhere, or their
    /// own server holding an account it knows nothing about.
    ///
    /// Persisted, because it has to survive a relaunch: the token in the
    /// Keychain belongs to one of these two worlds and is meaningless in the
    /// other.
    enum ServiceKind: String {
        /// Clip's own service. Compiled in, never configured, never displayed.
        case official
        /// The user's own server, from Settings.
        case personal
    }

    private(set) var serviceKind: ServiceKind {
        get {
            ServiceKind(rawValue: Database.shared.preference("sync.serviceKind") ?? "")
                ?? .personal
        }
        set { Database.shared.setPreference("sync.serviceKind", newValue.rawValue) }
    }

    /// Points this Mac at one service or the other.
    ///
    /// Called before the first request of a sign-in or a token connection, so
    /// every request that follows - claim, sync, delete - goes to the right
    /// place. Nothing else may set it.
    private func useService(_ kind: ServiceKind) {
        guard serviceKind != kind else { return }
        serviceKind = kind
        Database.shared.log("sync", "Now using the \(kind.rawValue) service")
    }

    /// How this Mac is connected, and the rule that only one way is possible.
    ///
    /// The three ways to sync are not three settings, they are three states of
    /// one thing, and two of them are exclusive. A Mac signed in with Google and
    /// also holding a pasted token would be syncing two pools at once through
    /// one cursor - which is not a feature with a confusing UI, it is data loss
    /// with a plausible explanation. So the switch is explicit: disconnect one
    /// before the other becomes available.
    ///
    /// Importing a backup is deliberately NOT a mode. It is a one-off action
    /// that merges a file into what is already here, works whether or not
    /// anything is connected, and can be done as many times as you like.
    enum Connection: Equatable {
        case none
        case google(email: String)
        case token

        var isConnected: Bool { self != .none }

        var title: String {
            switch self {
            case .none:              return "Not syncing"
            case .google(let email): return "Signed in as \(email)"
            case .token:             return "Connected with a sync token"
            }
        }
    }

    /// Which of the two exclusive modes is in force.
    ///
    /// Derived from what is actually true rather than stored as a fourth copy
    /// of the truth: a stored mode that disagrees with the token in the Keychain
    /// is a bug that presents as the app lying about its own state.
    var connection: Connection {
        guard token != nil, space != nil else { return .none }
        if let account = GoogleAuth.shared.account { return .google(email: account.email) }
        return .token
    }

    @Published private(set) var space: SyncSpace?
    @Published private(set) var syncState: SyncState = .idle
    @Published var lastError: String?

    /// Every Mac on this token, as the server last reported them. Empty until
    /// something asks - the count in the space summary is what the sync status
    /// line uses, and it is cheaper.
    @Published private(set) var devices: [SyncDevice] = []
    /// True while the list is being read, so the section can say so rather than
    /// looking empty.
    @Published private(set) var isLoadingDevices = false
    /// What the last device action said went wrong.
    @Published var deviceError: String?
    /// When the list was last read from the server, so a refresh that finds
    /// nothing new still says it happened.
    @Published private(set) var devicesCheckedAt: Date?

    /// Combine this Mac's items with the token's, rather than replacing them.
    ///
    /// Persisted, because it governs every sync and not just the first: the user
    /// decided once which way their data flows, and a silent change of direction
    /// would be the most destructive thing this app could do.
    @Published var mergeOnSync: Bool = true {
        didSet { Database.shared.setPreference("sync.merge", mergeOnSync ? "1" : "0") }
    }

    enum SyncState: Equatable {
        case idle, syncing, synced(Date), failed(String)
    }

    /// How many changes the last sync moved, for the pane to report.
    @Published private(set) var lastChangeCount = 0

    // MARK: - Surfacing failures beyond Settings
    //
    // Before this, a sync failure was only discoverable by opening
    // Settings > Sync - `syncState` and `lastError` above are read there, and
    // nowhere else. Someone whose token expired, or whose network dropped for
    // an afternoon, believed every clip they copied was backed up when none
    // of them were, because nothing on screen ever said otherwise.
    //
    // The two properties below are what the menu bar badge (`AppDelegate`)
    // and the panel's own notice row (`NoticeCenter`, via `NoticeBar`) read.
    // They are deliberately NOT the same lifecycle as `syncState`: `syncState`
    // is "what the last attempt did" and flips back and forth constantly as
    // the automatic sync retries; these are "is there something a person
    // should go look at right now", which is a coarser, stickier question.

    /// True from the moment a failure clears the noise threshold below, until
    /// the next sync that actually succeeds. Drives the menu-bar badge, which
    /// has to stay up for as long as the underlying problem does - unlike the
    /// panel's `NoticeCenter` row, which clears itself after 12 seconds by
    /// design so it is never read as "current" long after the fact.
    @Published private(set) var hasVisibleFailure = false

    /// The plain-language sentence behind the badge, read by the menu-bar
    /// tooltip. Independent of `NoticeCenter.current`, which may have already
    /// expired or moved on to an unrelated message by the time this is read.
    @Published private(set) var visibleFailureMessage: String?

    /// Failed attempts in a row, reset by any success. Not persisted: a
    /// relaunch is a fresh start for the question "is this still happening".
    private var consecutiveFailures = 0

    /// How many consecutive failures turn a quiet retry into something a
    /// person is told about.
    ///
    /// Reasoning: automatic sync retries on a 60-second timer, on every
    /// debounced list change, and whenever Clip becomes active - so a single
    /// dropped Wi-Fi packet or a five-second network blip fails one attempt
    /// and clears itself on the very next one, well before a person could act
    /// on being told about it. Three in a row is roughly two minutes of
    /// sustained failure at the timer's own cadence (more often than that if
    /// the user is actively copying, which triggers extra attempts sooner) -
    /// long enough that "it will fix itself" has stopped being a reasonable
    /// bet, short enough that nobody's clips go unbacked-up for long while
    /// this stays quiet. Auth failures and rejected items skip the count
    /// entirely (see `diagnose`) because retrying an expired token or a
    /// row the server already refused cannot self-heal - waiting for three
    /// more identical failures would just be three more minutes of silence
    /// about a problem that was already certain.
    private static let failureThreshold = 3

    /// Turns whatever went wrong into a sentence a person can act on, and
    /// says whether it is certain enough to skip the noise threshold above.
    ///
    /// Mirrors `AIDiagnosis.read(_:)`: the raw error is written for a
    /// developer (`SyncError.server` embeds the HTTP status verbatim), and
    /// nobody using the app should ever have to read an HTTP code to know
    /// what to do.
    private func diagnose(_ error: Error) -> (message: String, remedy: String?, immediate: Bool) {
        let raw = error.localizedDescription

        if case SyncError.noToken = error {
            return ("This Mac lost its sync connection.",
                    "Reconnect under Settings > Sync.", true)
        }
        // The service said the credential itself is bad. No retry fixes this.
        if raw.contains("returned 401") || raw.contains("returned 403")
            || raw.localizedCaseInsensitiveContains("not valid") {
            return ("Clip's sync connection was rejected.",
                    "Reconnect under Settings > Sync.", true)
        }
        // A row the server would not accept. Populated by the sync that just
        // ran (`SyncClient.sync(merge:)` calls through to `applyRemote`), so
        // this is about the attempt that just finished, not a stale one.
        if !SyncClient.shared.lastSkipped.isEmpty {
            let count = SyncClient.shared.lastSkipped.count
            return ("\(count) item\(count == 1 ? "" : "s") could not be synced and "
                    + "\(count == 1 ? "was" : "were") skipped.",
                    "Open Settings > Sync for details.", true)
        }
        // Everything left - offline, DNS, a 500 from the service, a timeout -
        // is presumed transient until it repeats. Named plainly rather than
        // with the underlying transport error, which is written for a
        // developer, not the person who just wants their clips backed up.
        return ("Clip has not been able to sync.",
                "Check your connection. If this continues, open Settings > Sync.", false)
    }

    /// One failed attempt. Reports it and lights the badge only once it
    /// clears `failureThreshold`, or immediately when `diagnose` says the
    /// cause cannot self-heal.
    private func noteSyncFailure(_ error: Error) {
        consecutiveFailures += 1
        let reading = diagnose(error)
        guard reading.immediate || consecutiveFailures >= Self.failureThreshold else { return }
        NoticeCenter.shared.report(reading.message, remedy: reading.remedy,
                                   kind: .persistent, key: "sync.failure",
                                   action: NoticeCenter.Action(title: "Open Sync settings") {
                                       SettingsWindowController.shared.show(tab: .sync)
                                   },
                                   stillNeeded: { SyncManager.shared.hasVisibleFailure })
        hasVisibleFailure = true
        visibleFailureMessage = reading.message
    }

    /// One sync that actually worked. The badge and the streak both end here,
    /// whatever put them up.
    private func noteSyncSuccess() {
        consecutiveFailures = 0
        NoticeCenter.shared.resolve("sync.failure")
        hasVisibleFailure = false
        visibleFailureMessage = nil
    }

    // MARK: - Syncing without being asked
    //
    // The pane promises "Clip keeps this Mac up to date until you disconnect".
    // Until now the only thing that synced anything was the Sync Now button, so
    // that sentence was false, and a button doing invisible work is exactly what
    // "I click sync and nothing happens" looks like from the outside.
    //
    // Three triggers, one funnel:
    //   - a change to the list, debounced, so a burst of copying is one sync;
    //   - a timer, so another Mac's changes arrive without touching anything;
    //   - becoming the active app, which is when you are about to look.

    private var timer: Timer?
    private var debounce: DispatchWorkItem?
    private var observation: AnyCancellable?
    private var isSyncing = false

    private static let interval: TimeInterval = 60
    private static let quietPeriod: TimeInterval = 4

    /// Called once at launch.
    func startAutomaticSync() {
        observation = HistoryStore.shared.$items
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleSync() }

        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncNow(reason: "timer") }
        }
        timer.tolerance = Self.interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.syncNow(reason: "activated") }
        }
    }

    /// Syncs once the list has been quiet for a moment.
    private func scheduleSync() {
        guard isConnected else { return }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.syncNow(reason: "changed") }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quietPeriod, execute: work)
    }

    var isConnected: Bool { token != nil && space != nil }

    // MARK: - The token

    private let tokenKey = "sync.token"

    /// The token itself, readable only because *this Mac* holds it. The server
    /// keeps a hash and could not hand it back if it wanted to.
    var token: String? {
        get { KeychainStore.get(tokenKey) }
        set {
            if let newValue {
                KeychainStore.markConfigured(tokenKey)
                let status = KeychainStore.set(newValue, for: tokenKey)
                if status != errSecSuccess {
                    NoticeCenter.shared.report(
                        "The sync token could not be saved.",
                        remedy: "Clip will try again automatically, or reconnect under "
                              + "Settings > Sync.",
                        kind: .persistent, key: "keychain.needsRepair.\(tokenKey)")
                }
            } else {
                KeychainStore.remove(tokenKey)
            }
        }
    }

    /// A fingerprint of the token (SHA-256, first 8 bytes, hex) - never the
    /// token itself - written to the preferences table on connect. It is
    /// what tells "this Mac used to hold a token and it is gone" apart from
    /// "this Mac never connected", which a bare `token == nil` cannot: both
    /// read identically otherwise, and only one of them is worth a notice.
    private static let tokenFingerprintKey = "sync.tokenFingerprint"

    private static func fingerprint(of token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func rememberTokenFingerprint(_ token: String) {
        Database.shared.setPreference(Self.tokenFingerprintKey, Self.fingerprint(of: token))
    }

    /// Runs once at launch. A fingerprint with no readable token behind it
    /// means the token was lost - not merely "never connected", which leaves
    /// no fingerprint at all and is met with silence, exactly as the user
    /// asked: nothing to say when there was never anything to lose.
    func checkTokenContinuityAtLaunch() async {
        let saved = Database.shared.preference(Self.tokenFingerprintKey) ?? ""
        guard !saved.isEmpty else { return }
        KeychainStore.markConfigured(tokenKey)
        guard token == nil else { return }
        _ = await KeychainStore.selfRepair(reason: "launch-token-continuity", accounts: [tokenKey])
        // `KeychainStore.get` (via `token` above) already posted the notice
        // if this is still unreadable; nothing further to do here either way.
    }

    /// A stable id for this Mac, so the space can count and lock its devices.
    /// Not an identity: it says "the same Mac as last time" and nothing more.
    ///
    /// Derived from the hardware, hashed. The previous version minted a random
    /// UUID and kept it in this app's own database, which made "the same Mac"
    /// mean "the same database": a reinstall, a rebuilt database or a restored
    /// settings file produced a brand-new Mac, and the old one stayed in the
    /// space for ever. That is what "I have one Mac and it says two" was.
    ///
    /// The raw platform id never leaves this machine - it is salted and hashed
    /// first, so what the server holds identifies the Mac only to somebody who
    /// already has the Mac.
    var deviceID: String {
        #if CLIP_TESTING
        // One process has to be able to stand in for a second Mac - it is the
        // only way to test that two devices converge. A hardware-derived id
        // cannot be impersonated by writing a preference, so the seam is
        // explicit rather than a side effect of where the id was stored.
        if let override = Self.deviceIDOverrideForTesting, !override.isEmpty {
            return override
        }
        #endif
        if let hardware = Self.hardwareDeviceID {
            // Recorded as well as returned, so `previousDeviceID` below can
            // tell the server which row this Mac used to be.
            if Database.shared.preference("sync.deviceID") != hardware {
                let old = Database.shared.preference("sync.deviceID") ?? ""
                if !old.isEmpty, old != hardware {
                    Database.shared.setPreference("sync.deviceID.previous", old)
                }
                Database.shared.setPreference("sync.deviceID", hardware)
            }
            return hardware
        }
        // No platform id (a virtualised Mac, a locked IORegistry): fall back to
        // what is stored, and only mint one if there is nothing at all.
        if let existing = Database.shared.preference("sync.deviceID"), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        Database.shared.setPreference("sync.deviceID", generated)
        return generated
    }

    #if CLIP_TESTING
    /// Stands in for "this is a different Mac" - see `deviceID`.
    static var deviceIDOverrideForTesting: String?
    #endif

    /// The id this Mac used before it started deriving one from the hardware,
    /// so the server can rename that row instead of leaving a phantom beside
    /// the real one. Cleared once the server has acknowledged it.
    var previousDeviceID: String? {
        let value = Database.shared.preference("sync.deviceID.previous") ?? ""
        return value.isEmpty ? nil : value
    }

    func clearPreviousDeviceID() {
        Database.shared.setPreference("sync.deviceID.previous", "")
    }

    /// `IOPlatformUUID`, salted and hashed. `nil` when IOKit has nothing to say.
    private static var hardwareDeviceID: String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(
            service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String, !raw.isEmpty else { return nil }
        // Salted with a constant of this app's own, so the value cannot be
        // matched against the same hardware id collected by anything else.
        let digest = SHA256.hash(data: Data(("clip.device.v1:" + raw).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    var deviceName: String { Host.current().localizedName ?? "Mac" }

    /// The service this Mac's token was issued by.
    ///
    /// A token means nothing anywhere else - it is a row in one service's
    /// database. When the app's default service changed, the token already in the
    /// Keychain kept being sent to the new one, which rightly refused it, and
    /// every sync from then on failed with "that sync token is not valid" once a
    /// minute for ever. The user's report was "I click sync and nothing happens".
    private(set) var tokenService: String {
        get { Database.shared.preference("sync.tokenService") ?? "" }
        set { Database.shared.setPreference("sync.tokenService", newValue) }
    }

    /// True when the token was issued by a service this Mac no longer talks to.
    var tokenBelongsElsewhere: Bool {
        // Only ever a question about the user's own server. On the official
        // service the address is fixed and not theirs to change, so a mismatch
        // is impossible - and checking anyway would put the official address
        // into an error message, which is the one place it must not appear.
        guard serviceKind == .personal else { return false }
        guard token != nil, !tokenService.isEmpty else { return false }
        return tokenService != (SyncClient.shared.personalURL?.absoluteString ?? "")
    }

    private override init() {
        super.init()
        migrateServiceKindIfNeeded()
        mergeOnSync = Database.shared.preference("sync.merge") != "0"
        if let json = Database.shared.preference("sync.space"), !json.isEmpty,
           let data = json.data(using: .utf8),
           let saved = try? JSONDecoder().decode(SyncSpace.self, from: data) {
            space = saved
        }
        // A claimed space is exactly when a missing or unreadable token is
        // worth a sentence rather than silence - see `KeychainStore.get`.
        if space != nil { KeychainStore.markConfigured(tokenKey) }
        // A remembered space with no token AND no record of one ever having
        // been here is a stale leftover, not a repairable failure - there is
        // nothing to repair. But a fingerprint present means a token WAS
        // here (see `rememberTokenFingerprint`), so a Keychain problem gets
        // a chance to heal instead of this quietly discarding the claim,
        // which is exactly how a re-signing failure used to read as "empty
        // connections, no token" instead of a fixable condition.
        if token == nil, (Database.shared.preference(Self.tokenFingerprintKey) ?? "").isEmpty {
            space = nil
        }
    }

    /// Moves an already-signed-in Mac onto the official service, where that is
    /// provably the same place its data already lives.
    ///
    /// Anyone who signed in with Google before the two services were separated
    /// is recorded as `.personal`, because that was the only kind there was.
    /// Leaving them there would mean their sign-in keeps following the Server
    /// field, which is the behaviour this whole change removes.
    ///
    /// The migration is deliberately narrow: it happens **only** when the
    /// personal address and the official one are the same, which is the one
    /// case where switching cannot move anybody's data. If someone signed in
    /// against a different personal server, their space lives in that database
    /// and flipping them to the official service would silently point them at
    /// an account that does not exist there. Those are left alone; signing out
    /// and back in puts them right, and says so when it fails in the meantime.
    private func migrateServiceKindIfNeeded() {
        guard serviceKind == .personal, GoogleAuth.shared.account != nil else { return }
        guard let personal = SyncClient.shared.personalURL,
              let official = OfficialService.url,
              personal.absoluteString == official.absoluteString else { return }
        serviceKind = .official
        Database.shared.log("sync", "Moved this Google sign-in onto the official service")
    }

    // MARK: - Connecting

    /// Creates a brand new sync space and connects this Mac to it.
    ///
    /// The token comes back exactly once. There is no "email me my token" and
    /// there cannot be: only its hash is stored.
    @discardableResult
    func createToken() async -> String? {
        lastError = nil
        // A token is always the user's own server. Creating one while the app
        // was pointed at the official service would mint a token in Clip's
        // database that the user believes is in theirs.
        useService(.personal)
        guard SyncClient.shared.isConfigured else {
            lastError = "Set up your sync server first, under Server below."
            return nil
        }
        do {
            try await SyncService.shared.ensureRunning()
            let (newToken, newSpace) = try await SyncClient.shared.createSpace()
            token = newToken
            space = newSpace
            tokenService = SyncClient.shared.baseURL?.absoluteString ?? ""
            rememberTokenFingerprint(newToken)
            // A new space is empty, so there is nothing here to be replaced by.
            // Leaving a "replace" choice from a previous token in place meant the
            // first sync uploaded nothing and this Mac silently stopped backing up.
            mergeOnSync = true
            // A brand new space is empty, so the whole history has to go up -
            // not just whatever changed since the last push to some other token.
            Database.shared.setPreference("syncCursor", "0")
            Database.shared.setPreference("syncPushedAt", "0")
            persist()
            Database.shared.log("sync", "Created a new sync space")
            await syncNow()
            return newToken
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Connects this Mac to an existing token.
    ///
    /// `merge` is the whole decision. On, this Mac's items join the token's pool
    /// and both Macs end up with everything. Off, the pool replaces what is here.
    /// The caller is responsible for having said which, in those words, first.
    @discardableResult
    func connect(token candidate: String, merge: Bool) async -> Bool {
        lastError = nil
        let cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            lastError = "Paste the sync token first."
            return false
        }
        // Only Google blocks a token. The three methods are mutually exclusive,
        // and switching BETWEEN them needs a deliberate disconnect - but
        // pasting a different token while a token is connected is not a switch
        // of method, and the code below already restores the previous token if
        // the new one is refused.
        //
        // This used to be `connection == .none`, which refused a token-to-token
        // change as well and told the user "This Mac is signed in with Google"
        // when it was not signed in with Google at all. An error message that
        // names the wrong cause sends someone looking for a Google session that
        // does not exist.
        if case .google = connection {
            lastError = "This Mac is signed in with Google. Sign out first, then paste the token."
            return false
        }
        useService(.personal)
        guard SyncClient.shared.isConfigured else {
            lastError = "Set up your sync server first, under Server below."
            return false
        }
        do {
            try await SyncService.shared.ensureRunning()
            let previous = token
            token = cleaned
            do {
                space = try await SyncClient.shared.claim()
                tokenService = SyncClient.shared.baseURL?.absoluteString ?? ""
                mergeOnSync = merge
                rememberTokenFingerprint(cleaned)
                persist()
            } catch {
                // A rejected token must not displace a working one.
                token = previous
                throw error
            }

            // Either way the cursor restarts, so the whole pool is pulled rather
            // than whatever happened to be new since some other token's sync.
            Database.shared.setPreference("syncCursor", "0")
            // A new connection has to offer this Mac's whole history again.
            Database.shared.setPreference("syncPushedAt", "0")
            if !merge {
                // Said plainly in the sheet before this point: the local copy goes.
                //
                // `recordDeletions: false` is load-bearing. These items are being
                // cleared to make room for the token's copy; tombstoning them
                // would push "delete all of this" to the server on the very next
                // push, so asking to *receive* everything would destroy it for
                // every Mac instead.
                HistoryStore.shared.clearAll(recordDeletions: false)
                Database.shared.log("sync", "Local items replaced by the token's data")
            }
            await syncNow()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Signing in with Google

    /// Signs in and connects this Mac to the space that account owns.
    ///
    /// `merge` carries the same weight it does for a pasted token, and for the
    /// same reason: on a second Mac, "combine" and "replace" are the difference
    /// between having everything and losing half of it. The caller is
    /// responsible for having asked, in those words, first.
    @discardableResult
    func signInWithGoogle(merge: Bool) async -> Bool {
        lastError = nil
        // The exclusivity rule, enforced here rather than only in the UI. A
        // second entry point that skipped the check would be exactly the bug
        // the rule exists to prevent.
        guard connection == .none else {
            lastError = "This Mac is already connected. Disconnect first, then sign in."
            return false
        }
        // Clip's own service, from here on. Set before the first request, so
        // the sign-in, the claim and every sync after it agree on where they
        // are going. Nothing about the user's own server is read or touched.
        useService(.official)
        guard SyncClient.shared.isConfigured else {
            lastError = "Clip's service is unavailable in this build."
            return false
        }
        guard let grant = await GoogleAuth.shared.signIn() else {
            lastError = GoogleAuth.shared.lastError
            return false
        }
        do {
            try await SyncService.shared.ensureRunning()
            let previous = token
            let result = try await SyncClient.shared.signInWithGoogle(grant: grant)
            token = result.token
            do {
                space = try await SyncClient.shared.claim()
            } catch {
                token = previous
                throw error
            }
            tokenService = SyncClient.shared.baseURL?.absoluteString ?? ""
            mergeOnSync = merge
            rememberTokenFingerprint(result.token)
            GoogleAuth.shared.remember(email: result.email, name: result.name, picture: result.picture)
            persist()

            Database.shared.setPreference("syncCursor", "0")
            Database.shared.setPreference("syncPushedAt", "0")
            if !merge {
                // Said plainly in the sheet before this point. `recordDeletions:
                // false` for the same reason as the token path: these items are
                // making room, not being deleted everywhere.
                HistoryStore.shared.clearAll(recordDeletions: false)
                Database.shared.log("sync", "Local items replaced by the account\u{27}s data")
            }
            Database.shared.log("sync", "Signed in with Google")
            await syncNow()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Deletes the account and the data it holds on Clip's service.
    ///
    /// Three properties this has to keep, in order of how badly getting one
    /// wrong would go:
    ///
    /// 1. **Nothing local is touched.** Every clip, prompt, note and skill on
    ///    this Mac stays exactly where it is. Deleting an account is a statement
    ///    about a server, not about this computer, and a user who wanted their
    ///    local history gone would be looking in Privacy.
    /// 2. **It is recoverable for 30 days.** The server soft-deletes and purges
    ///    later, and the account mapping is deliberately kept, so signing in
    ///    again within the grace period lands on the same space and cancels the
    ///    deletion. Removing the mapping immediately would make the grace period
    ///    a lie: the data would still exist and be unreachable for ever.
    /// 3. **This Mac signs out afterwards**, because staying connected to a
    ///    space that is scheduled to disappear is a sync that will fail on a
    ///    timer and confuse everybody.
    ///
    /// Returns the purge date, or nil if the request failed.
    @discardableResult
    func deleteAccount() async -> String? {
        guard case .google = connection else { return nil }
        lastError = nil
        guard let purgeAt = await deleteSpace() else { return nil }
        await signOutOfGoogle(unlinkAccount: false)
        Database.shared.log("sync", "Account deletion requested; purge on \(purgeAt)")
        return purgeAt
    }

    /// Signs out. The space and everything in it stay exactly where they are.
    ///
    /// The Keychain token is deliberately left alone - the user's own rule:
    /// "the token is stored in the laptop and is not deleted with an app
    /// deletion or account disconnection". Only the local claim, the fact
    /// that this Mac currently belongs to a space, is cleared. See
    /// `forgetTokenOnThisMac` for the separate, explicit removal.
    func signOutOfGoogle(unlinkAccount: Bool) async {
        if unlinkAccount, isConnected {
            // Only when asked. Signing out on a laptop must not detach the
            // account from its data for every other Mac.
            try? await SyncClient.shared.forgetGoogle()
        } else if isConnected {
            try? await SyncClient.shared.forgetDevice()
        }
        GoogleAuth.shared.forget()
        space = nil
        // Nothing is claimed any more, so a Keychain problem with this
        // account is no longer worth a sentence - silence until reconnected.
        KeychainStore.markUnconfigured(tokenKey)
        tokenService = ""
        syncState = .idle
        // Back to the user's own world, so the Server settings describe
        // something real again rather than an official address they cannot see.
        useService(.personal)
        persist()
        Database.shared.log("sync", unlinkAccount
            ? "Signed out and unlinked the Google account; the saved token stays on this Mac"
            : "Signed out; the saved token stays on this Mac")
    }

    /// Stops syncing and keeps everything already here - including the
    /// token, on this Mac's own Keychain.
    ///
    /// The token stays valid for the user's other Macs, and it stays valid
    /// for THIS one too: disconnecting clears the local claim (the cursor,
    /// which space this Mac thinks it belongs to), never the saved secret.
    /// That used to not be true - `disconnect` deleted the Keychain item,
    /// which is the most direct way "the connections settings are empty
    /// with no token" could happen - and it is the user's explicit rule now:
    /// a saved token survives an account disconnection. Pasting the token
    /// back reconnects; `forgetTokenOnThisMac` is the separate, confirmed
    /// action for actually removing it.
    /// Reads the Macs on this token.
    func refreshDevices() async {
        guard token != nil else { devices = []; return }
        isLoadingDevices = true
        deviceError = nil
        defer { isLoadingDevices = false }
        do {
            devices = try await SyncClient.shared.devices()
            devicesCheckedAt = Date()
        } catch {
            deviceError = error.localizedDescription
        }
    }

    /// Signs another Mac out, after the person proves the account.
    ///
    /// The Google sign-in is not decoration: the sync token is a shared secret
    /// by design, so holding it cannot be what authorises evicting the other
    /// holder. The server checks the account, not just the token - this side
    /// only collects the proof and reports what came back.
    func signOut(device: SyncDevice) async {
        deviceError = nil
        guard !device.isThisMac else {
            deviceError = "Use Disconnect to remove the Mac you are using."
            return
        }
        guard let grant = await GoogleAuth.shared.signIn() else {
            deviceError = GoogleAuth.shared.lastError
                ?? "That needs a Google sign-in to go ahead."
            return
        }
        do {
            try await SyncClient.shared.forgetDevice(device.id, proof: grant)
            await refreshDevices()
            if let space = try? await SyncClient.shared.claim() { self.space = space }
        } catch {
            deviceError = error.localizedDescription
        }
    }

    func disconnect() async {
        if isConnected {
            try? await SyncClient.shared.forgetDevice()
        }
        // A remembered account with no token is a pane that says "signed in as"
        // directly above a Connect button.
        GoogleAuth.shared.forget()
        space = nil
        KeychainStore.markUnconfigured(tokenKey)
        tokenService = ""
        syncState = .idle
        persist()
        Database.shared.log("sync", "Disconnected; the saved token stays on this Mac, local items kept")
    }

    /// Removes the saved token from this Mac's Keychain. A separate,
    /// explicit action from `disconnect` - the caller is responsible for
    /// having confirmed it, the way every other destructive action in this
    /// pane is confirmed first.
    func forgetTokenOnThisMac() {
        token = nil
        KeychainStore.markUnconfigured(tokenKey)
        Database.shared.setPreference(Self.tokenFingerprintKey, "")
        Database.shared.log("sync", "The saved sync token was removed from this Mac")
    }

    /// Locks or unlocks the space to the Macs already using it.
    func setSharing(_ shared: Bool) async {
        guard isConnected else { return }
        do {
            space = try await SyncClient.shared.setSharing(shared)
            persist()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Restoring on a fresh install

    /// True when this Mac holds a usable sync credential even though its
    /// Keychain is the only trace left of a previous install - the whole
    /// reason the credential is the ONLY thing that lives there: deleting
    /// the app, or disconnecting an account and reinstalling, never touches
    /// it.
    ///
    /// Prefers `sync.tokenFingerprint` (a preference a later generation of
    /// this work, M2.6, writes alongside the Keychain token) when present,
    /// so "never connected" and "lost credential" can read differently the
    /// moment that lands. Until then this falls back to "the token itself is
    /// readable", which today is exactly true: there is nothing else yet to
    /// distinguish the two cases.
    var hasRestorableAccount: Bool {
        if let fingerprint = Database.shared.preference("sync.tokenFingerprint"),
           !fingerprint.isEmpty {
            return true
        }
        return token != nil
    }

    /// Offers to bring an account's items back on a Mac that currently has
    /// none of its own.
    ///
    /// Called once, from `AppDelegate.applicationDidFinishLaunching`, right
    /// after `HistoryStore` has loaded from disk. A fresh install and "the
    /// user cleared everything and reopened Clip" look identical from here -
    /// an empty local library next to a Keychain that still remembers a
    /// space - and both deserve the same offer rather than silently starting
    /// empty beside data that was never actually gone.
    @MainActor
    func offerRestoreIfNeeded() {
        guard HistoryStore.shared.items.isEmpty, hasRestorableAccount else { return }
        let known = space?.items ?? 0
        let countPhrase = known > 0 ? "\(known) item\(known == 1 ? "" : "s")" : "your items"
        NoticeCenter.shared.report(
            "This Mac has a saved sync account. Restore \(countPhrase)?",
            kind: .persistent, key: "sync.restoreOffer",
            action: NoticeCenter.Action(title: "Restore") {
                Task { @MainActor in
                    if await SyncManager.shared.fullResync() != nil {
                        NoticeCenter.shared.resolve("sync.restoreOffer")
                    }
                }
            })
    }

    // MARK: - Syncing

    func syncNow(reason: String = "asked") async {
        // A space is claimed but the token cannot be read: this is not "not
        // connected", it is a repairable failure, and `isConnected` cannot
        // tell the two apart on its own. Repaired before the first real
        // attempt, so an ordinary sync tick is what heals it rather than
        // needing the user to notice and click something.
        if space != nil, token == nil {
            _ = await KeychainStore.selfRepair(reason: "sync", accounts: [tokenKey])
        }
        guard isConnected else { return }

        // Retrying a token the service will never accept just fills the log and
        // leaves the user watching a button that does nothing.
        if tokenBelongsElsewhere {
            let message = """
                This token was created for \(tokenService), and this Mac is now set \
                to \(SyncClient.shared.personalURL?.absoluteString ?? "nothing"). Disconnect \
                and create a new token, or switch the service back.
                """
            syncState = .failed(message)
            lastError = message
            // Already plain language, and never fixes itself by retrying -
            // it is exactly the class of failure the badge exists for.
            NoticeCenter.shared.report(message, kind: .persistent, key: "sync.failure",
                                       action: NoticeCenter.Action(title: "Open Sync settings") {
                                           SettingsWindowController.shared.show(tab: .sync)
                                       })
            hasVisibleFailure = true
            visibleFailureMessage = message
            return
        }
        // A timer tick during a slow sync must not start a second one: both
        // would push the same rows and race each other's cursor.
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        syncState = .syncing
        do {
            try await SyncService.shared.ensureRunning()
            let applied = try await SyncClient.shared.sync(merge: mergeOnSync)
            if let refreshed = try? await SyncClient.shared.claim() { space = refreshed }
            persist()
            lastChangeCount = applied
            lastError = nil
            syncState = .synced(Date())
            noteSyncSuccess()
            Database.shared.log("sync", "Synced \(applied) change(s) [\(reason)]")
        } catch {
            // Set both: the pane reads `syncState`, everything else reads
            // `lastError`, and a failure that only lands in one of them is a
            // failure somebody will miss.
            syncState = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            Database.shared.log("sync", "Sync failed [\(reason)]: \(error.localizedDescription)")
            noteSyncFailure(error)
        }
    }

    /// What a full resync found, so the result is a fact rather than a feeling.
    struct ResyncReport: Equatable {
        /// Syncable items only - `isLocalOnly` items (image, video, file,
        /// folder) never reach the server, so counting them here would make
        /// `localAfter` and `serverAfter` disagree by exactly the number of
        /// file-backed clips on this Mac, for ever. See `ClipboardItem.isLocalOnly`.
        var localBefore: Int
        var localAfter: Int
        var serverAfter: Int
        var pushed: Int
        var pulled: Int
        var skipped: [String]

        /// The one question the user is actually asking.
        var agrees: Bool { localAfter == serverAfter && skipped.isEmpty }

        var summary: String {
            if agrees {
                return "In step: \(localAfter) items on this Mac and \(serverAfter) on the server."
            }
            if !skipped.isEmpty {
                return """
                    \(localAfter) here, \(serverAfter) on the server. \(skipped.count) row\
                    \(skipped.count == 1 ? "" : "s") could not be read and were left for next time.
                    """
            }
            return "\(localAfter) here, \(serverAfter) on the server."
        }
    }

    @Published private(set) var lastResync: ResyncReport?

    /// Makes both sides agree, from a standing start.
    ///
    /// The ordinary sync is incremental: it sends what changed since a watermark
    /// and reads forward from a cursor. That is right for every normal case and
    /// useless for the one the user hit - 336 items here, 410 there, and no
    /// incremental pass will ever look at the difference, because both sides
    /// believe they are up to date.
    ///
    /// So this rewinds both markers to zero and does the whole exchange again:
    /// every local item and every tombstone up, everything on the server down,
    /// then it asks the server what it holds and reports the two numbers. It
    /// deletes nothing locally - the watermarks are what get reset, never the
    /// data.
    func fullResync() async -> ResyncReport? {
        guard isConnected else { return nil }
        guard !isSyncing else { return nil }
        isSyncing = true
        defer { isSyncing = false }

        // Local-only items (image, video, file, folder) never reach the
        // server, so they must never enter a count that is compared against
        // `serverAfter` - counting them here made "in step" impossible even
        // when every syncable item genuinely agreed.
        let localBefore = HistoryStore.shared.items.filter { !$0.isLocalOnly }.count
        syncState = .syncing
        do {
            try await SyncService.shared.ensureRunning()

            // Both markers, not one. Rewinding the cursor alone re-reads the
            // server without re-sending anything; rewinding the push watermark
            // alone re-sends without re-reading.
            Database.shared.setPreference("syncCursor", "0")
            Database.shared.setPreference("syncPushedAt", "0")

            // Merge, always, whatever the setting says: a resync that replaced
            // one side with the other would be a destructive operation wearing
            // the name of a repair.
            let pushed = try await SyncClient.shared.sync(merge: true)

            // Then read to exhaustion, since the cursor started at zero.
            let pulled = try await SyncClient.shared.sync(merge: true)

            let refreshed = try? await SyncClient.shared.claim()
            if let refreshed { space = refreshed }
            persist()

            let report = ResyncReport(
                localBefore: localBefore,
                localAfter: HistoryStore.shared.items.filter { !$0.isLocalOnly }.count,
                serverAfter: refreshed?.items ?? space?.items ?? 0,
                pushed: pushed,
                pulled: pulled,
                skipped: SyncClient.shared.lastSkipped.map { "\($0.seq): \($0.reason)" })
            lastResync = report
            lastChangeCount = pushed + pulled
            lastError = report.agrees ? nil : report.summary
            syncState = .synced(Date())
            // A resync the user asked for and is watching happen in Settings
            // still needs the badge cleared if it fixed things - the badge
            // does not know a resync ran rather than an ordinary sync.
            noteSyncSuccess()
            Database.shared.log("sync", "Full resync: \(report.summary)")
            return report
        } catch {
            syncState = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            Database.shared.log("sync", "Full resync failed: \(error.localizedDescription)")
            noteSyncFailure(error)
            return nil
        }
    }

    // MARK: - Deletion

    /// Deletes the space and everything in it, for every Mac using the token.
    /// The server keeps it for 30 days so a mistake is recoverable.
    func deleteSpace() async -> String? {
        guard isConnected else { return nil }
        lastError = nil
        do {
            let purgeAt = try await SyncClient.shared.requestDeletion()
            space?.deletionRequestedAt = Date()
            persist()
            Database.shared.log("sync", "Space deletion requested; purge on \(purgeAt)")
            return purgeAt
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func cancelDeletion() async {
        do {
            try await SyncClient.shared.cancelDeletion()
            space?.deletionRequestedAt = nil
            persist()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Storage

    private func persist() {
        if let space, let data = try? JSONEncoder().encode(space),
           let json = String(data: data, encoding: .utf8) {
            Database.shared.setPreference("sync.space", json)
        } else {
            Database.shared.setPreference("sync.space", "")
        }
    }
}

#if CLIP_TESTING
extension SyncManager {
    /// Drives `noteSyncFailure` with an error shaped exactly the way a real
    /// one is, for the kind named. This is what makes the noise threshold in
    /// `diagnose`/`noteSyncFailure` provable on demand: without it, proving
    /// "three consecutive generic failures light the badge, one auth failure
    /// does it immediately" means actually breaking a network three times and
    /// hoping the timing lines up.
    ///
    /// - "auth": a rejected credential (`diagnose` matches on "returned 401"),
    ///   surfaces after one failure.
    /// - "lostToken": `SyncError.noToken`, surfaces after one failure.
    /// - anything else: a transient transport error, needs `failureThreshold`
    ///   consecutive calls before it surfaces.
    func simulateSyncFailureForTesting(kind: String) {
        let error: Error
        switch kind {
        case "auth":
            error = SyncError.server("The sync service returned 401 Unauthorized.")
        case "lostToken":
            error = SyncError.noToken
        default:
            error = SyncError.server("Could not reach the sync service.")
        }
        noteSyncFailure(error)
    }

    /// The exact call a real successful sync makes. Clears the streak and the
    /// badge, whatever put them up.
    func simulateSyncSuccessForTesting() {
        noteSyncSuccess()
    }
}
#endif
