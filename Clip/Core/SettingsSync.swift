import Foundation
import AppKit
import Combine

/// Settings, on their own clock.
///
/// Items sync the moment they change, and should: a clip you cannot see on your
/// other Mac is the point of the feature. Settings are the opposite case.
/// Nobody changes a theme here and walks to another Mac within the minute, and a
/// shared server should not take a write every time somebody drags a slider -
/// which, on a color picker, is a write per frame.
///
/// So the rule is: **a change marks the snapshot dirty; a tick sends it.**
/// Between ticks any number of changes cost nothing, and a tick with nothing to
/// say sends nothing at all. At the recommended quarter hour, a Mac left running
/// all day sends at most a few dozen small requests, and only on the days
/// something actually changed.
@MainActor
final class SettingsSync: ObservableObject {

    static let shared = SettingsSync()

    /// One row per space: everybody's Macs write the same id, and the newest
    /// wins, exactly as the server already does for items.
    private static let rowID = "settings"

    @Published private(set) var lastPushedAt: Date?
    @Published private(set) var lastAppliedAt: Date?

    /// The cadence, which is itself a synced preference.
    @Published var cadence: SettingsSyncCadence {
        didSet {
            AppPaths.defaults.set(cadence.rawValue, forKey: "settingsSyncCadence")
            restartTimer()
            // Changing the cadence is itself a settings change - unless the
            // change came FROM another Mac, in which case marking it dirty would
            // push it straight back out and the two Macs would trade the same
            // value forever.
            if !isApplyingRemote { markDirty() }
        }
    }

    private var timer: Timer?
    private var dirty = false
    /// True while a document from another Mac is being written, so the writes it
    /// causes are not mistaken for local edits.
    private var isApplyingRemote = false

    /// What was last sent, so an unchanged document is never sent again.
    ///
    /// Stored under its own key: `settings.lastSent` still holds the version 1
    /// snapshot, and `SettingsDocument` reads that one to seed the very first
    /// set of per-key stamps on an upgraded install.
    private static let lastSentKey = "settings.lastSentDoc"
    private var lastSent: SettingsDocument?

    private init() {
        cadence = AppPaths.defaults.string(forKey: "settingsSyncCadence")
            .flatMap(SettingsSyncCadence.init(rawValue:)) ?? .fifteenMinutes
        if let json = Database.shared.preference(Self.lastSentKey),
           let data = json.data(using: .utf8) {
            lastSent = try? JSONDecoder().decode(SettingsDocument.self, from: data)
        }
    }

    // MARK: - Lifecycle

    func start() {
        restartTimer()
        // Anything at all could have changed while the app was not watching,
        // so the first tick after launch is a comparison, not an assumption.
        markDirty()

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            // Quit is the one moment "only when Clip quits" has to work, and
            // the one moment there is no time for an async sync. The snapshot
            // is staged here; the next launch or the next sync carries it.
            MainActor.assumeIsolated { SettingsSync.shared.markDirty() }
        }
    }

    /// Rebuilds the timer after the custom interval is edited.
    ///
    /// The cadence case does not change when the number behind it does, so
    /// `didSet` never fires and the old timer keeps its old period. Storing a
    /// new value and continuing to sync on the old one is the kind of bug
    /// nobody reports, because everything on screen looks right.
    func restartForCustomInterval() {
        guard cadence == .custom else { return }
        restartTimer()
        markDirty()
    }

    /// Something in Settings changed. Cheap on purpose: it sets a flag.
    func markDirty() { dirty = true }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard let interval = cadence.interval else { return }
        let t = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in await SettingsSync.shared.pushIfDue() }
        }
        // A quarter of the interval of slack, so several Macs waking on the
        // same clock do not all hit the server in the same second.
        t.tolerance = interval * 0.25
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// A tick: send the document if it has actually changed.
    func pushIfDue() async {
        guard SyncManager.shared.isConnected else { return }
        guard pendingDocument() != nil else { return }
        await SyncManager.shared.syncNow(reason: "settings")
    }

    /// Adopts a cadence that arrived from another Mac.
    ///
    /// The stored value has already been written; this is what makes the running
    /// timer agree with it. Without it the new cadence sits in preferences and
    /// the old period keeps firing, which is the kind of bug nobody reports
    /// because everything on screen looks right.
    func adoptStoredCadence() {
        let stored = AppPaths.defaults.string(forKey: "settingsSyncCadence")
            .flatMap(SettingsSyncCadence.init(rawValue:)) ?? .fifteenMinutes
        guard stored != cadence else {
            // The custom interval may have changed under an unchanged case.
            restartTimer()
            return
        }
        isApplyingRemote = true
        cadence = stored
        isApplyingRemote = false
    }

    // MARK: - The row

    /// The document to send, or nil when nothing has changed since the last one.
    ///
    /// The dirty flag is only a hint that it is worth *looking*. The comparison
    /// is what decides, because a flag set by a control the user then set back
    /// would otherwise cost a request for no change at all.
    private func pendingDocument() -> SettingsDocument? {
        let now = SettingsDocument.current()
        // A Mac holding nothing but first-run seeds has no opinion to push. See
        // `broadcastableEntries`: an unstamped value is the absence of a claim,
        // and sending it is how a new Mac overwrites a configured one.
        guard !now.broadcastableEntries.isEmpty else {
            dirty = false
            return nil
        }
        guard let lastSent else { return now }
        guard now.differs(from: lastSent) else {
            dirty = false
            return nil
        }
        return now
    }

    /// Drops the in-memory record of what was last pushed.
    ///
    /// Only the probe calls this, to stand a single process in for a Mac that
    /// has never held these settings. Clearing the stored preference alone is
    /// not enough: `lastSent` is read once at init and kept in memory.
    func forgetLastSentForTesting() {
        lastSent = nil
        lastPushedAt = nil
        lastAppliedAt = nil
        dirty = true
    }

    /// Whether a push would carry a settings row.
    ///
    /// Separate from `pendingRow()` because that one *records what it hands
    /// out*, and the QA bridge reads this on every state poll. Asking the
    /// question through `pendingRow()` therefore answered it and consumed the
    /// answer in the same breath: the row was marked sent without ever being
    /// put in a request, and the real push that followed found nothing pending.
    var hasPendingRow: Bool { pendingDocument() != nil }

    /// The sync row for this document, if one is due. Called by `SyncClient`
    /// while it assembles a push.
    ///
    /// `updated_at` is the newest stamp the document carries rather than "now":
    /// claiming the present moment for a change made an hour ago would let a
    /// stale Mac win a race it should lose.
    func pendingRow() -> [String: Any]? {
        guard let document = pendingDocument(),
              let payload = document.payloadJSON() else { return nil }

        remember(document)
        // The stamp of the newest entry actually being SENT, not of the newest
        // entry this Mac holds: the payload drops unstamped and forbidden keys,
        // and a row whose `updated_at` outran its own contents would win races
        // on behalf of settings it is not carrying.
        let sentAt = document.broadcastableEntries.values.map(\.t).max()
            ?? document.updatedAt.timeIntervalSince1970
        return [
            "entity": "settings",
            "id": Self.rowID,
            "updated_at": sentAt,
            "deleted": false,
            "payload": payload
        ]
    }

    /// A settings row from another Mac, merged key by key.
    ///
    /// This is the whole point of the version 2 document. The old code compared
    /// two whole snapshots and took the newer one entire, so a Mac that changed
    /// the theme and a Mac that changed the sort order could not both keep their
    /// change: whichever pushed second overwrote the other's field with its own
    /// stale copy. Merging per key means each setting is decided on its own
    /// clock, and only the keys that actually moved are written.
    func applyRemote(_ row: [String: Any]) {
        guard let payload = row["payload"] as? String,
              let remote = SettingsDocument.decode(payload: payload,
                                                   device: row["device"] as? String ?? "")
        else { return }

        var local = SettingsDocument.current()
        let changed = local.merge(remote)
        guard !changed.isEmpty else {
            // Nothing to do, but the exchange still tells us this Mac and the
            // server agree, so the next tick need not re-send.
            remember(local)
            return
        }

        isApplyingRemote = true
        local.apply(keys: changed)
        isApplyingRemote = false

        // The applied values are this Mac's values now, carrying the stamps they
        // arrived with. Recording that is what stops the next `current()` from
        // reading them back as fresh local edits and pushing them straight out.
        local.rememberAsLocal()
        lastAppliedAt = remote.updatedAt
        remember(local)
    }

    private func remember(_ document: SettingsDocument) {
        lastSent = document
        lastPushedAt = document.updatedAt
        dirty = false
        if let data = try? JSONEncoder().encode(document),
           let json = String(data: data, encoding: .utf8) {
            Database.shared.setPreference(Self.lastSentKey, json)
        }
    }

    /// Sends now, whatever the cadence says. The Sync Now button's counterpart.
    func pushNow() async {
        guard SyncManager.shared.isConnected else { return }
        markDirty()
        await SyncManager.shared.syncNow(reason: "settings now")
    }
}
