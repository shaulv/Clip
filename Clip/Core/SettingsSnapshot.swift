import Foundation
import AppKit

/// How this Mac is set up, as one syncable document.
///
/// The Sync pane has claimed for a while that "tabs, themes, shortcuts and
/// preferences" sync. They did not: only items ever crossed the wire. This is
/// the thing that makes the sentence true.
///
/// **What is deliberately not here**, and must never be added:
/// - API keys. They live in the Keychain and are the one secret whose whole
///   value is that it never leaves this Mac.
/// - The sync token. A token that synced itself would put a working credential
///   in every backup of every device.
/// - The device id, the panel's remembered position, and anything else that is
///   true of this Mac rather than of this person. Syncing a window position
///   between a 27-inch iMac and a laptop puts the panel off-screen.
struct SettingsSnapshot: Codable, Equatable {

    /// Bumped when the shape changes, so an older Mac can refuse a newer
    /// snapshot rather than half-apply it.
    static let currentVersion = 1

    var version: Int = SettingsSnapshot.currentVersion
    var updatedAt: Date = Date()

    /// The `@AppStorage` preferences, by key.
    var preferences: [String: String] = [:]
    var themeID: String = ""
    var density: String = ""
    var initialTabID: String = ""
    /// Every custom theme, as a JSON array.
    ///
    /// These live in their own table rather than in a preference, so unlike the
    /// others this one is encoded here rather than copied across. Getting that
    /// wrong would have synced an empty string over a Mac full of themes.
    var customThemes: String = ""
    var tabs: String = ""
    var shortcutBindings: String = ""
    /// The pinned row's ORDER, as comma-joined UUIDs - the same format
    /// `HistoryStore` already writes to its own `pinnedIDs` preference.
    ///
    /// Which items are pinned already arrives through the ordinary item
    /// channel: `isPinned` and `pinnedIndex` live on `ClipboardItem` itself, so
    /// a pin set on one Mac reaches another the moment that item next syncs,
    /// and `HistoryStore.merge` rebuilds `pinnedIDs` from the merged items'
    /// flags. What that rebuild cannot recover is which item was pinned
    /// FIRST - it has no clock for that beyond the sort the merged list
    /// already happens to be in - so the pinned row can render in a different
    /// order than the Mac that pinned them. This field carries the order
    /// itself, on the settings channel's own cadence, as a second opinion
    /// `apply()` only trusts for ids that still name a real item here.
    var pinnedIDs: String = ""

    // MARK: - What travels

    /// Every preference key that is about the person, not the machine.
    ///
    /// Written out rather than derived: `UserDefaults` for this app also holds
    /// window frames, the panel origin and whatever AppKit decides to cache, and
    /// syncing all of it would move this Mac's furniture onto another one. The
    /// cost of the list is having to add to it; the cost of not having it is
    /// silently syncing something that should never have travelled.
    static let syncedKeys = [
        "globalShortcut", "launchAtLogin", "showStatusItem", "pasteAutomatically",
        "numberShortcuts", "showFooter", "historyLimit", "historyLimitEnabled", "clearOnQuit",
        "pollIntervalMS", "maxTextKB", "respectConcealedTypes", "ignoredApps",
        "statusIcon", "showInDock", "showCopyConfirmation", "copyConfirmationSeconds",
        "aiFeaturesEnabled", "fetchLinkTitles",
        "sortOrder", "searchMode", "settingsSyncCadence", "settingsSyncCustomMinutes"
    ]

    /// Reads the current state of this Mac.
    @MainActor
    static func current() -> SettingsSnapshot {
        var snapshot = SettingsSnapshot()
        let defaults = AppPaths.defaults
        for key in syncedKeys {
            guard let value = defaults.object(forKey: key) else { continue }
            snapshot.preferences[key] = String(describing: value)
        }
        snapshot.themeID = ThemeManager.shared.themeID
        snapshot.density = ThemeManager.shared.density.rawValue
        snapshot.initialTabID = ThemeManager.shared.initialTabID
        if let data = try? JSONEncoder().encode(CustomThemeStore.shared.themes),
           let json = String(data: data, encoding: .utf8) {
            snapshot.customThemes = json
        }
        snapshot.tabs = Database.shared.preference("tabs") ?? ""
        snapshot.shortcutBindings = Database.shared.preference("shortcutBindings") ?? ""
        snapshot.pinnedIDs = Database.shared.preference("pinnedIDs") ?? ""
        return snapshot
    }

    /// Writes a snapshot from another Mac onto this one.
    ///
    /// Types are recovered from the *current* value's type rather than stored,
    /// because `@AppStorage` reads a Bool as a Bool and a string "1" is not one.
    /// Anything whose type cannot be established is left alone: a preference
    /// that fails to apply is a nuisance, a preference that applies as the wrong
    /// type is a setting the user cannot change back.
    @MainActor
    func apply() {
        guard version <= SettingsSnapshot.currentVersion else {
            Database.shared.log("sync", "Ignored a settings snapshot from a newer version of Clip")
            return
        }
        let defaults = AppPaths.defaults
        for (key, raw) in preferences where SettingsSnapshot.syncedKeys.contains(key) {
            switch defaults.object(forKey: key) {
            case is Bool:
                defaults.set(raw == "1" || raw.lowercased() == "true", forKey: key)
            case is Int:
                if let n = Int(raw) { defaults.set(n, forKey: key) }
            case is Double:
                if let d = Double(raw) { defaults.set(d, forKey: key) }
            case is String, .none:
                // Unset locally: infer from the text, which is right for every
                // key in the list above.
                if raw == "0" || raw == "1", let n = Int(raw) { defaults.set(n, forKey: key) }
                else { defaults.set(raw, forKey: key) }
            default:
                continue
            }
        }
        // The running app reads these through `@AppStorage`, which caches, so
        // writing `UserDefaults` above is not enough on its own: without this
        // the new settings sit on disk and change nothing until a relaunch.
        PreferencesModel.shared.reloadFromDefaults()

        // Themes are merged, never replaced: a theme made on this Mac and not
        // yet pushed must survive a snapshot arriving from another one.
        if let data = customThemes.data(using: .utf8),
           let incoming = try? JSONDecoder().decode([CustomTheme].self, from: data) {
            for theme in incoming { CustomThemeStore.shared.save(theme) }
        }
        if !tabs.isEmpty { Database.shared.setPreference("tabs", tabs) }
        if !shortcutBindings.isEmpty {
            Database.shared.setPreference("shortcutBindings", shortcutBindings)
        }
        if !pinnedIDs.isEmpty {
            // Item-level `isPinned` already arrives on its own, through the
            // ordinary item channel, and `HistoryStore.merge` rebuilds
            // `pinnedIDs` from it - this only straightens out the ORDER.
            // Filtering to ids that still name a real item here is what keeps
            // a pin from being resurrected for something already deleted (or
            // an item that has not arrived yet on this Mac): an unknown id is
            // silently dropped rather than remembered for later, which is
            // right, because the next settings push from this Mac would
            // otherwise keep re-offering a ghost id forever.
            let incoming = pinnedIDs.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            HistoryStore.shared.applyPinnedOrder(incoming)
        }
        if !themeID.isEmpty { ThemeManager.shared.themeID = themeID }
        if let d = GalleryDensity(rawValue: density) { ThemeManager.shared.density = d }
        if !initialTabID.isEmpty { ThemeManager.shared.initialTabID = initialTabID }

        TabConfiguration.shared.reload()
        ShortcutRegistry.shared.reload()
        Database.shared.log("sync", "Applied settings from another Mac")
    }

    /// Everything except the timestamp, so "has anything actually changed?" is
    /// not answered "yes" by the clock.
    func differs(from other: SettingsSnapshot) -> Bool {
        var a = self, b = other
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        return a != b
    }
}


/// How often settings are pushed, separately from items.
///
/// Items sync on change, because a clip you cannot see on your other Mac is the
/// whole point of the feature. Settings do not: nobody changes a theme on one
/// Mac and walks to another within the minute, and a shared server does not
/// want a write every time somebody drags a slider - which, on a colour picker,
/// is a write per frame.
///
/// So the rule is: a change marks the snapshot dirty, and a tick sends it.
/// Between ticks any number of changes cost nothing, and a tick with nothing to
/// say sends nothing at all.
///
/// The range runs from one minute to a day, plus "only on quit" and a custom
/// interval. Fifteen minutes is the recommendation and the default; the shorter
/// end exists for people actively setting a Mac up, and the longer end for
/// people who simply want it to keep itself in step without thinking about it.
enum SettingsSyncCadence: String, CaseIterable, Identifiable, Codable {
    case everyMinute, fiveMinutes, fifteenMinutes, thirtyMinutes
    case hourly, sixHours, twelveHours, daily
    case custom, onQuit

    var id: String { rawValue }

    /// The custom interval, in minutes. Only meaningful for `.custom`.
    ///
    /// Stored beside the case rather than inside it so the enum stays a plain
    /// `String` raw value - which is what lets it ride the settings snapshot
    /// and the preferences file unchanged.
    static var customMinutes: Int {
        get {
            let stored = AppPaths.defaults.integer(forKey: "settingsSyncCustomMinutes")
            return stored > 0 ? stored : 45
        }
        set {
            AppPaths.defaults.set(Self.clampCustom(newValue),
                                      forKey: "settingsSyncCustomMinutes")
        }
    }

    /// One minute to one week.
    ///
    /// The floor is not fussiness: below a minute the timer costs more than the
    /// sync, and on a shared server a dozen Macs at ten seconds each is a
    /// denial of service somebody pays for.
    static func clampCustom(_ minutes: Int) -> Int { min(max(minutes, 1), 10_080) }

    var title: String {
        switch self {
        case .everyMinute:    return "Every minute"
        case .fiveMinutes:    return "Every 5 minutes"
        case .fifteenMinutes: return "Every 15 minutes (recommended)"
        case .thirtyMinutes:  return "Every 30 minutes"
        case .hourly:         return "Every hour"
        case .sixHours:       return "Every 6 hours"
        case .twelveHours:    return "Every 12 hours"
        case .daily:          return "Once a day"
        case .custom:         return "Custom…"
        case .onQuit:         return "Only when Clip quits"
        }
    }

    /// Nil means "no timer": the snapshot goes up when the app quits.
    var interval: TimeInterval? {
        switch self {
        case .everyMinute:    return 60
        case .fiveMinutes:    return 300
        case .fifteenMinutes: return 900
        case .thirtyMinutes:  return 1800
        case .hourly:         return 3600
        case .sixHours:       return 21_600
        case .twelveHours:    return 43_200
        case .daily:          return 86_400
        case .custom:         return TimeInterval(Self.customMinutes * 60)
        case .onQuit:         return nil
        }
    }

    /// Roughly how many requests a Mac left running all day would make.
    ///
    /// Only the ticks that carry a change send a body, so this is the ceiling
    /// rather than the expectation - and saying it as a number is what turns
    /// "every minute" from a free choice into an informed one.
    var dailyCeiling: Int? {
        guard let interval else { return nil }
        return max(1, Int(86_400 / interval))
    }

    var note: String {
        switch self {
        case .everyMinute:
            return """
                As close to instant as this gets. Worth it while you are setting a \
                second Mac up and want a theme to appear there immediately; heavy \
                for every day, and on a shared server it is the setting that costs \
                somebody money.
                """
        case .fiveMinutes:
            return """
                Fast enough that you will rarely notice a delay. Choose this if you \
                move between Macs constantly.
                """
        case .fifteenMinutes:
            return """
                The right answer for almost everybody. A theme or a shortcut changed \
                here shows up on your other Macs within a quarter of an hour.
                """
        case .thirtyMinutes, .hourly:
            return "Light, and still keeps up on its own. Send Settings Now is always immediate."
        case .sixHours, .twelveHours, .daily:
            return """
                For a Mac you use on its own. Your settings still travel, just not \
                promptly - use Send Settings Now when you want them to.
                """
        case .custom:
            return "Your own interval, between one minute and one week."
        case .onQuit:
            return """
                Nothing is sent while Clip is running. Your settings go up when you \
                quit and come down when another Mac starts. Lightest possible on the \
                server - and it means a Mac that never quits never sends.
                """
        }
    }
}
