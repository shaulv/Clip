import Foundation
import AppKit

/// One setting, with its own clock.
///
/// The stamp is what lets two Macs change two different settings in the same
/// quarter hour and both keep their change. A document with a single timestamp
/// cannot do that: the second Mac to push overwrites the first Mac's field with
/// its own stale copy, and both users believe they changed a setting.
struct SettingsEntry: Codable, Equatable {
    /// The value, as text. Types are recovered from the registry on the way in,
    /// never guessed from the string.
    var v: String
    /// Seconds since 1970: the moment this Mac first saw this value.
    var t: Double
}

/// What a setting is, so a value can be written back as the type it was.
///
/// Version 1 inferred the type from whatever was already in `UserDefaults`,
/// which is fine until the key is unset locally - and then a `Bool` arrives as
/// the string "1", `@AppStorage` reads it as a `Bool` and gets `false`, and the
/// user has a setting they cannot change back. Declaring the type is three words
/// per key and removes the whole class of bug.
enum SettingKind {
    case bool, int, string
}

/// Where a setting lives, because they are not all in `UserDefaults`.
enum SettingStore {
    /// `AppPaths.defaults`: the real preferences file, or the sandbox's.
    case defaults(SettingKind)
    /// The `preferences` table in the app database.
    case database
    /// Not a stored preference at all: the custom themes table, encoded.
    case customThemes
    /// The pinned row's order, which needs `HistoryStore` to apply it.
    case pinnedOrder
}

/// The registry: every setting this app has, in exactly one bucket.
///
/// Written out rather than derived. `UserDefaults` for this app also holds
/// window frames, the panel origin and whatever AppKit decides to cache, and
/// syncing all of it would move this Mac's furniture onto another one. The cost
/// of the list is having to add to it; the cost of not having it is silently
/// syncing something that should never have travelled.
enum SettingsRegistry {

    // MARK: - Synced: the same on every Mac

    /// Facts about the person, not the machine.
    static let synced: [(key: String, store: SettingStore)] = [
        // Behaviour
        ("globalShortcut",            .defaults(.string)),
        ("pasteAutomatically",        .defaults(.bool)),
        ("numberShortcuts",           .defaults(.bool)),
        ("clearOnQuit",               .defaults(.bool)),
        ("deduplicate",               .defaults(.bool)),
        ("fetchLinkTitles",           .defaults(.bool)),
        ("pollIntervalMS",            .defaults(.int)),
        ("maxTextKB",                 .defaults(.int)),
        ("checkForUpdatesAutomatically", .defaults(.bool)),
        ("hasSeenOnboarding",         .defaults(.bool)),

        // Privacy posture. The most important of these to hold identical: a Mac
        // that quietly stopped honouring the concealed-pasteboard flag is a Mac
        // recording passwords.
        ("respectConcealedTypes",     .defaults(.bool)),
        ("ignoredApps",               .defaults(.string)),

        // Appearance
        ("showFooter",                .defaults(.bool)),
        ("showStatusItem",            .defaults(.bool)),
        ("statusIcon",                .defaults(.string)),
        ("showInDock",                .defaults(.bool)),
        ("keepStatusItemVisible",     .defaults(.bool)),
        ("animateStatusItemOnCopy",   .defaults(.bool)),
        ("showCopyConfirmation",      .defaults(.bool)),
        ("copyConfirmationSeconds",   .defaults(.int)),
        ("themeID",                   .defaults(.string)),
        ("settingsAppearance",        .defaults(.string)),
        ("density",                   .defaults(.string)),
        ("initialTabID",              .defaults(.string)),

        // View
        ("sortOrder",                 .defaults(.string)),
        ("searchMode",                .defaults(.string)),

        // AI, minus every secret. See `neverLeaves`.
        ("aiFeaturesEnabled",         .defaults(.bool)),
        ("aiEnabled",                 .defaults(.bool)),
        ("aiPromoDismissed",          .defaults(.bool)),

        // The cadence is itself a synced preference.
        ("settingsSyncCadence",       .defaults(.string)),
        ("settingsSyncCustomMinutes", .defaults(.int)),

        // Documents in the database
        ("tabs",                      .database),
        ("shortcutBindings",          .database),
        ("aiProviders",               .database),
        ("pasteActions",              .database),
        ("pasteLanguages",            .database),
        ("pasteStyles",               .database),
        ("pasteLanguagePair",         .database),
        ("sync.merge",                .database),

        // The themes table, encoded as one entry.
        ("customThemes",              .customThemes),

        // The pinned row's ORDER. Which items are pinned already arrives on the
        // item channel; this is the second opinion about the order they sit in.
        ("pinnedIDs",                 .pinnedOrder)
    ]

    static let syncedKeys: Set<String> = Set(synced.map(\.key))

    static func store(for key: String) -> SettingStore? {
        synced.first { $0.key == key }?.store
    }

    // MARK: - Machine local: deliberately not synced

    /// Kept as a list rather than "everything not in `synced`" so each exclusion
    /// carries its reason in code, where the next person to add a key will read
    /// it. The backup writes these into their own file so a restore can offer
    /// them separately, and skips them by default.
    static let machineLocal: [(key: String, store: SettingStore, reason: String)] = [
        ("historyLimitEnabled", .defaults(.bool), """
            Whether this Mac caps its history at all.
            """),
        ("historyLimit", .defaults(.int), """
            A retention cap, tied to this Mac's disk and this Mac's habits. \
            Trimming deliberately records no tombstone, so a cap no longer \
            deletes items for everybody - but syncing the cap itself still \
            makes the receiving Mac evict down to a number chosen for different \
            hardware, and that Mac's list is gone until a full resync. A cap is \
            a statement about one machine's storage, not about the person.
            """),
        ("launchAtLogin", .defaults(.bool), """
            Registers a login item with this Mac's LaunchServices. A Mac you \
            borrow for an afternoon should not start Clip at every boot because \
            your main Mac does. The stored flag and the actual registration are \
            separate pieces of state, so syncing the flag alone produces a Mac \
            that claims a login item it does not have.
            """),
        ("panelOrigin", .defaults(.string), """
            A point in this Mac's display coordinates. A position saved on a \
            27-inch iMac is off-screen on a 13-inch laptop.
            """),
        ("panelPlacement", .defaults(.string), """
            Travels with the origin as a pair: "use the remembered position" \
            means nothing on a Mac that has no remembered position.
            """)
    ]

    static let machineLocalKeys: Set<String> = Set(machineLocal.map(\.key))

    // MARK: - Never leaves this machine

    /// Secrets, and the names of the storage that holds them.
    ///
    /// These never sync and never export. Not "off by default": absent. The
    /// probe asserts that none of these strings appears in a built sync payload
    /// or in a backup archive, which is what turns the comment into a control.
    ///
    /// API keys are not listed as preference keys because they are not
    /// preferences - they live in the Keychain under `provider.<id>`, and
    /// `AIProvider`'s `CodingKeys` have no `apiKey` case, so encoding a provider
    /// structurally cannot emit one. That is the real guarantee; this list
    /// guards the database and defaults side of the same boundary.
    static let neverLeaves: [String] = [
        "sync.tokenService",     // which Keychain service holds the sync token
        "sync.tokenFingerprint", // a digest of it
        "provider.",             // Keychain account prefix for every API key
        "apiKey",
        "api_key",
        "refreshToken",
        "clientSecret"
    ]

    /// Per-machine bookkeeping: not secret, but another Mac's copy would be
    /// actively wrong here, so it never travels either.
    static let neverSyncedBookkeeping: [String] = [
        "sync.deviceID", "syncCursor", "syncPushedAt", "settings.lastSent",
        "settings.local", "syncBaseURL", "sync.serviceKind", "sync.space",
        "sync.localOnlyTombstones", "google.account", "unsavedSnapshotPath"
    ]

    /// True when a key must not appear in a synced payload, for any reason.
    static func isForbidden(_ key: String) -> Bool {
        if neverSyncedBookkeeping.contains(key) { return true }
        if machineLocalKeys.contains(key) { return true }
        return neverLeaves.contains { key.contains($0) }
    }
}


/// How this Mac is set up, as a bag of independently stamped settings.
///
/// **What is deliberately not here**, and must never be added: API keys, the
/// sync token, the device id, the panel's remembered position, and the history
/// cap. See `SettingsRegistry` for each one's reason.
struct SettingsDocument: Codable, Equatable {

    /// Bumped when the shape changes. Version 1 was a single-timestamp snapshot
    /// (`SettingsSnapshot`); version 2 stamps every key on its own.
    static let currentVersion = 2

    var version: Int = SettingsDocument.currentVersion
    /// The newest stamp in `entries`, so the row's `updated_at` and the
    /// document's own ordering agree.
    var updatedAt: Date = Date()
    /// Which Mac wrote this. Breaks stamp ties deterministically.
    var device: String = ""
    var entries: [String: SettingsEntry] = [:]

    // MARK: - Reading this Mac

    /// Where the per-key stamps are remembered between launches.
    static let recordKey = "settings.local"

    /// The live value of every synced key, as text.
    @MainActor
    static func liveValues() -> [String: String] {
        var out: [String: String] = [:]
        for (key, store) in SettingsRegistry.synced {
            switch store {
            case .defaults:
                guard let value = AppPaths.defaults.object(forKey: key) else { continue }
                out[key] = text(from: value)
            case .database, .pinnedOrder:
                guard let value = Database.shared.preference(key), !value.isEmpty else { continue }
                out[key] = value
            case .customThemes:
                if let data = try? JSONEncoder().encode(CustomThemeStore.shared.themes),
                   let json = String(data: data, encoding: .utf8) {
                    out[key] = json
                }
            }
        }
        return out
    }

    /// A `UserDefaults` value as the text that will be stored and compared.
    ///
    /// `String(describing:)` renders a `Bool` as "true"/"false" on one path and
    /// an `NSNumber` as "1"/"0" on another, which makes an unchanged setting look
    /// changed on every launch and pushes a document that says nothing.
    static func text(from value: Any) -> String {
        if let n = value as? NSNumber {
            // `Bool` bridges to `NSNumber`, so this catches both, and
            // `stringValue` gives "1"/"0" for a bool either way.
            return n.stringValue
        }
        if let s = value as? String { return s }
        return String(describing: value)
    }

    /// This Mac's remembered stamps.
    static func loadRecord() -> [String: SettingsEntry] {
        guard let json = Database.shared.preference(recordKey),
              let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: SettingsEntry].self, from: data)
        else { return [:] }
        return map
    }

    static func saveRecord(_ record: [String: SettingsEntry]) {
        guard let data = try? JSONEncoder().encode(record),
              let json = String(data: data, encoding: .utf8) else { return }
        Database.shared.setPreference(recordKey, json)
    }

    /// The current document, with every key stamped.
    ///
    /// Stamps are *observed*, not instrumented: this Mac remembers the last
    /// value it saw for each key, and a key whose live value differs from that
    /// record is stamped now. That is causally correct - "this Mac has held this
    /// value since at least then" - it needs no cooperation from any settings
    /// view, and it cannot miss a key a future pane adds, because the registry
    /// above is the single place a key is declared.
    ///
    /// The seed matters as much as the diff. A Mac with no record yet must not
    /// claim its factory defaults at `now`, or a freshly installed second Mac
    /// would push its blank settings over a configured one. So a first record is
    /// seeded at the version 1 migration point if there is one, and at zero
    /// otherwise: "I have no history of this setting, so I do not claim it."
    @MainActor
    static func current() -> SettingsDocument {
        let live = liveValues()
        var record = loadRecord()
        let isFirstRun = record.isEmpty
        let seed = isFirstRun ? migrationSeed() : 0
        let now = Date().timeIntervalSince1970

        for (key, value) in live {
            if let existing = record[key], existing.v == value { continue }
            record[key] = SettingsEntry(v: value, t: isFirstRun ? seed : now)
        }
        // A key with no live value has been returned to its default. That is a
        // change like any other, and its absence is the value, so the record
        // drops it and the document stops carrying it.
        for key in record.keys where live[key] == nil {
            record.removeValue(forKey: key)
        }
        saveRecord(record)

        var document = SettingsDocument()
        document.entries = record
        document.device = SyncManager.shared.deviceID
        document.updatedAt = Date(timeIntervalSince1970: record.values.map(\.t).max() ?? now)
        return document
    }

    /// Stamps one key as changed NOW, because the user just chose it.
    ///
    /// `current()` infers stamps by diffing against the last remembered value,
    /// which is right for everything the user changes through a control that
    /// writes a value. It is not enough for a choice that can also arrive from
    /// another Mac: between the click and the next `current()`, an incoming
    /// document stamped later wins and the choice is silently undone - the
    /// theme switching back being exactly that. An explicit claim closes the
    /// window.
    @MainActor
    static func claimNow(_ key: String) {
        guard SettingsRegistry.store(for: key) != nil else { return }
        var record = loadRecord()
        let live = liveValues()
        guard let value = live[key] else { return }
        record[key] = SettingsEntry(v: value, t: Date().timeIntervalSince1970)
        saveRecord(record)
    }

    /// The recorded stamp for one key, for the probe that proves a choice
    /// claims its own moment.
    @MainActor
    static func stampForTesting(_ key: String) -> Double {
        loadRecord()[key]?.t ?? 0
    }

    /// The stamp to seed a first record with.
    ///
    /// An install that already synced settings under version 1 has a
    /// `settings.lastSent` snapshot, and its timestamp is the honest answer to
    /// "since when has this Mac held these values". Without one, zero.
    private static func migrationSeed() -> Double {
        guard let json = Database.shared.preference("settings.lastSent"),
              let data = json.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(SettingsSnapshot.self, from: data)
        else { return 0 }
        return snapshot.updatedAt.timeIntervalSince1970
    }

    // MARK: - Merging

    /// Takes everything in `remote` that is newer than what this document holds.
    ///
    /// Per key, never wholesale. Returns the keys that actually changed, so the
    /// caller writes and reloads only those - applying all forty on every sync
    /// would rewrite the cadence that governs the sync itself.
    @discardableResult
    mutating func merge(_ remote: SettingsDocument) -> [String] {
        var changed: [String] = []
        for (key, incoming) in remote.entries {
            // Defence in depth. The sender should never have put these in; if a
            // future version does, the receiver still refuses them.
            guard SettingsRegistry.syncedKeys.contains(key) else { continue }
            guard !SettingsRegistry.isForbidden(key) else { continue }

            guard let mine = entries[key] else {
                entries[key] = incoming
                changed.append(key)
                continue
            }
            if incoming.v == mine.v { continue }
            if incoming.t > mine.t {
                entries[key] = incoming
                changed.append(key)
            } else if incoming.t == mine.t && remote.device > device {
                // Two Macs wrote in the same tick. The higher device id wins,
                // which both Macs compute identically, so they converge instead
                // of flip-flopping forever.
                entries[key] = incoming
                changed.append(key)
            }
        }
        if !changed.isEmpty {
            updatedAt = Date(timeIntervalSince1970: entries.values.map(\.t).max() ?? 0)
        }
        return changed
    }

    // MARK: - Writing this Mac

    /// Writes the named keys onto this Mac and reloads whatever reads them.
    @MainActor
    func apply(keys: [String]) {
        guard version <= SettingsDocument.currentVersion else {
            Database.shared.log("sync", "Ignored a settings document from a newer version of Clip")
            return
        }
        guard !keys.isEmpty else { return }

        var touchedDefaults = false
        var touchedTheme = false
        var touchedView = false
        var touchedTabs = false
        var touchedShortcuts = false
        var touchedPaste = false

        for key in keys {
            guard let entry = entries[key],
                  let store = SettingsRegistry.store(for: key) else { continue }
            switch store {
            case .defaults(let kind):
                write(entry.v, as: kind, to: key)
                touchedDefaults = true
                if key == "themeID" || key == "density" || key == "initialTabID" {
                    touchedTheme = true
                }
                if key == "sortOrder" || key == "searchMode" { touchedView = true }
            case .database:
                Database.shared.setPreference(key, entry.v)
                if key == "tabs" { touchedTabs = true }
                if key == "shortcutBindings" { touchedShortcuts = true }
                if key.hasPrefix("paste") { touchedPaste = true }
            case .customThemes:
                // Merged, never replaced: a theme made on this Mac and not yet
                // pushed must survive a document arriving from another one.
                if let data = entry.v.data(using: .utf8),
                   let incoming = try? JSONDecoder().decode([CustomTheme].self, from: data) {
                    for theme in incoming { CustomThemeStore.shared.save(theme) }
                }
            case .pinnedOrder:
                // Filtering to ids that still name a real item here is what
                // keeps a pin from being resurrected for something already
                // deleted, or an item that has not arrived on this Mac yet.
                let ids = entry.v.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
                if !ids.isEmpty { HistoryStore.shared.applyPinnedOrder(ids) }
            }
        }

        // The running app reads preferences through `@AppStorage`, which caches,
        // so writing `UserDefaults` above is not enough on its own: without this
        // the new settings sit on disk and change nothing until a relaunch.
        if touchedDefaults { PreferencesModel.shared.reloadFromDefaults() }
        if touchedTheme {
            let theme = ThemeManager.shared
            if let v = entries["themeID"]?.v, !v.isEmpty { theme.themeID = v }
            if let v = entries["settingsAppearance"]?.v,
               let a = ThemeManager.SettingsAppearance(rawValue: v) { theme.settingsAppearance = a }
            if let v = entries["density"]?.v, let d = GalleryDensity(rawValue: v) { theme.density = d }
            if let v = entries["initialTabID"]?.v, !v.isEmpty { theme.initialTabID = v }
        }
        if touchedView { HistoryStore.shared.reloadViewPreferences() }
        if touchedTabs { TabConfiguration.shared.reload() }
        if touchedShortcuts { ShortcutRegistry.shared.reload() }
        if touchedPaste { PasteActionStore.shared.reload() }

        // The cadence may have just changed under the timer that governs it.
        SettingsSync.shared.adoptStoredCadence()

        Database.shared.log("sync",
            "Applied \(keys.count) setting\(keys.count == 1 ? "" : "s") from another Mac")
    }

    private func write(_ raw: String, as kind: SettingKind, to key: String) {
        let defaults = AppPaths.defaults
        switch kind {
        case .bool:
            defaults.set(raw == "1" || raw.lowercased() == "true", forKey: key)
        case .int:
            if let n = Int(raw) { defaults.set(n, forKey: key) }
        case .string:
            defaults.set(raw, forKey: key)
        }
    }

    /// Records that this Mac now holds exactly these values, so the next
    /// `current()` does not read them back as fresh local changes and push them
    /// straight out again with new stamps.
    func rememberAsLocal() {
        var record = SettingsDocument.loadRecord()
        for (key, entry) in entries { record[key] = entry }
        SettingsDocument.saveRecord(record)
    }

    /// Everything except the clock, so "has anything actually changed?" is not
    /// answered "yes" by the passage of time.
    func differs(from other: SettingsDocument) -> Bool {
        entries != other.entries
    }

    /// The entries this Mac is entitled to broadcast.
    ///
    /// Two filters, and the second is the subtle one.
    ///
    /// Forbidden keys go first: nothing secret and nothing machine-local leaves,
    /// checked here rather than at the call site because this is the only place
    /// a payload is built, and a check the caller has to remember is a check
    /// that eventually is not made.
    ///
    /// Then every entry still carrying the first-run seed is dropped. A zero
    /// stamp means "this Mac has never observed this value change" - it is the
    /// absence of an opinion, not an opinion that the setting is at its default.
    /// Broadcasting it is how a freshly installed Mac reconfigures a configured
    /// one: the seed protects the merge on the way IN, but a row is still a row
    /// on the way out, and a server that takes the newest write it received
    /// rather than the newest write by stamp would hand those defaults to
    /// everybody. Verified as a real failure, not a hypothetical: a second
    /// device with its record cleared pushed a document of unstamped defaults
    /// that replaced the first device's settings row, and the setting under
    /// test never arrived.
    var broadcastableEntries: [String: SettingsEntry] {
        entries.filter {
            SettingsRegistry.syncedKeys.contains($0.key)
                && !SettingsRegistry.isForbidden($0.key)
                && $0.value.t > 0
        }
    }

    /// Encodes the payload, or nil when this Mac has nothing to claim.
    func payloadJSON() -> String? {
        let safeEntries = broadcastableEntries
        guard !safeEntries.isEmpty else { return nil }
        var safe = self
        safe.entries = safeEntries
        safe.updatedAt = Date(timeIntervalSince1970: safeEntries.values.map(\.t).max() ?? 0)
        guard let data = try? JSONEncoder().encode(safe) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}


// MARK: - Version 1 compatibility

/// Declared in an extension so the memberwise `SettingsDocument()` survives:
/// spelling an initialiser inside the struct suppresses it, and the only other
/// candidate is then the synthesised `init(from:)`.
extension SettingsDocument {

    /// Reads a version 1 snapshot as a stamped document.
    ///
    /// A v1 snapshot has one timestamp for everything, so every key it carries
    /// is stamped with it. That is exactly true and loses nothing: the sending
    /// Mac really did hold all of those values as of that moment.
    init(v1 snapshot: SettingsSnapshot, device: String) {
        self.init()
        self.version = SettingsDocument.currentVersion
        self.updatedAt = snapshot.updatedAt
        self.device = device
        let t = snapshot.updatedAt.timeIntervalSince1970

        for (key, value) in snapshot.preferences
        where SettingsRegistry.syncedKeys.contains(key) && !SettingsRegistry.isForbidden(key) {
            entries[key] = SettingsEntry(v: value, t: t)
        }
        func put(_ key: String, _ value: String) {
            guard !value.isEmpty else { return }
            entries[key] = SettingsEntry(v: value, t: t)
        }
        put("themeID", snapshot.themeID)
        put("density", snapshot.density)
        put("initialTabID", snapshot.initialTabID)
        put("customThemes", snapshot.customThemes)
        put("tabs", snapshot.tabs)
        put("shortcutBindings", snapshot.shortcutBindings)
        put("pinnedIDs", snapshot.pinnedIDs)
    }

    /// Decodes either shape from a sync row's payload.
    ///
    /// A Mac still on the old build keeps pushing version 1 snapshots, and they
    /// must keep working rather than being dropped as unreadable.
    static func decode(payload: String, device: String) -> SettingsDocument? {
        guard let data = payload.data(using: .utf8) else { return nil }
        if let document = try? JSONDecoder().decode(SettingsDocument.self, from: data),
           document.version >= 2, !document.entries.isEmpty {
            return document
        }
        if let snapshot = try? JSONDecoder().decode(SettingsSnapshot.self, from: data) {
            return SettingsDocument(v1: snapshot, device: device)
        }
        return nil
    }
}
