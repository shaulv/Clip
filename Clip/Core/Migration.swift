import Foundation

/// One-time move of data written under the app's former name, "Tessera".
///
/// Renaming the app changes two things the user never sees but would notice
/// immediately if they were dropped: the Application Support folder (history,
/// pins, saved images) and the `UserDefaults` suite (themes, shortcuts, every
/// preference), which is keyed by bundle identifier.
///
/// Runs before anything reads either store, and is a no-op once done.
enum Migration {

    private static let oldName = "Tessera"
    private static let newName = "Clip"
    private static let oldBundleIDs = ["com.tessera.app", "com.tessera.clipboard"]
    private static let doneKey = "migratedFromTessera"

    private static let dbKey = "importedJSONHistory"

    /// What the one-time import actually did. Every step here used to be a
    /// bare `try?`: a failure was indistinguishable from "there was nothing
    /// to do", and the seven places it could go wrong all failed into
    /// silence (M3.9).
    struct ImportSummary {
        var ran = false
        var importedItems = 0
        var failures: [String] = []
    }
    private(set) static var lastSummary = ImportSummary()

    static func runIfNeeded() {
        // A sandboxed test run starts empty; importing the user's history into
        // it would defeat the point of isolating them.
        guard !AppPaths.isSandboxed else { return }

        var summary = ImportSummary()
        if !AppPaths.defaults.bool(forKey: doneKey) {
            migrateSupportDirectory(into: &summary)
            migrateDefaults()
            AppPaths.defaults.set(true, forKey: doneKey)
        }
        importJSONHistoryIfNeeded(into: &summary)
        lastSummary = summary
        reportIfNeeded(summary)
    }

    /// One summary notice for the whole import, folded into
    /// `StartupHealth.lastFindings` too - `StartupHealth.run()` runs BEFORE
    /// this by design (3.1), so its own findings list is already returned by
    /// the time this has anything to say; appending here is how the
    /// Diagnostics window still shows both under one launch.
    private static func reportIfNeeded(_ summary: ImportSummary) {
        guard summary.ran else { return }
        MainActor.assumeIsolated {
            if summary.failures.isEmpty {
                guard summary.importedItems > 0 else { return }
                let message = "Imported \(summary.importedItems) item\(summary.importedItems == 1 ? "" : "s") from an earlier version."
                NoticeCenter.shared.report(message, kind: .transient, key: "migration.import")
                StartupHealth.recordAdditionalFinding(.init(
                    severity: .fixed, title: "Imported earlier data", detail: message,
                    remedy: nil, action: nil))
            } else {
                let message = "\(summary.failures.count) step\(summary.failures.count == 1 ? "" : "s") of importing your earlier data failed."
                let remedy = summary.failures.joined(separator: " ")
                NoticeCenter.shared.report(message, remedy: remedy, kind: .persistent, key: "migration.import.failed")
                StartupHealth.recordAdditionalFinding(.init(
                    severity: .warning, title: "Import from an earlier version had problems",
                    detail: message, remedy: remedy, action: nil))
            }
        }
    }

    /// Moves the old `history.json` into SQLite exactly once.
    ///
    /// The JSON file is renamed rather than deleted: if anything about the
    /// import is wrong, the user's entire history is still sitting there.
    private static func importJSONHistoryIfNeeded(into summary: inout ImportSummary) {
        guard !AppPaths.defaults.bool(forKey: dbKey) else { return }
        defer { AppPaths.defaults.set(true, forKey: dbKey) }

        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            summary.ran = true
            summary.failures.append("could not locate Application Support to look for history.json.")
            return
        }
        let dir = base.appendingPathComponent(newName, isDirectory: true)
        let json = dir.appendingPathComponent("history.json")
        guard fm.fileExists(atPath: json.path) else { return }
        summary.ran = true

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data: Data
        do {
            data = try Data(contentsOf: json)
        } catch {
            summary.failures.append("could not read history.json (\(error.localizedDescription)).")
            return
        }

        let items: [ClipboardItem]
        do {
            items = try decoder.decode([ClipboardItem].self, from: data)
        } catch {
            summary.failures.append("could not read the items in history.json (\(error.localizedDescription)).")
            return
        }
        guard !items.isEmpty else { return }

        Database.shared.saveItems(items)
        for item in items where !item.fullText.isEmpty {
            Database.shared.addVersion(for: item, body: item.fullText,
                                       title: item.title, note: "Imported")
        }
        summary.importedItems = items.count

        // Carry the pins across too.
        let pins = dir.appendingPathComponent("pins.json")
        if fm.fileExists(atPath: pins.path) {
            do {
                let pdata = try Data(contentsOf: pins)
                let ids = try JSONDecoder().decode([String].self, from: pdata)
                Database.shared.setPreference("pinnedIDs", ids.joined(separator: ","))
            } catch {
                summary.failures.append("imported the items, but not the pins (\(error.localizedDescription)).")
            }
        }

        do {
            try fm.moveItem(at: json, to: dir.appendingPathComponent("history.json.imported"))
        } catch {
            summary.failures.append("imported, but could not rename history.json (\(error.localizedDescription)).")
        }
        Database.shared.log("migration", "Imported \(items.count) items from history.json")
    }

    /// Moves ~/Library/Application Support/Tessera to .../Clip.
    ///
    /// If both exist the old one is left alone rather than merged — silently
    /// overwriting a populated new history would be worse than leaving a folder
    /// behind for the user to delete.
    private static func migrateSupportDirectory(into summary: inout ImportSummary) {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            summary.ran = true
            summary.failures.append("could not locate Application Support to look for earlier data.")
            return
        }

        let old = base.appendingPathComponent(oldName, isDirectory: true)
        let new = base.appendingPathComponent(newName, isDirectory: true)

        guard fm.fileExists(atPath: old.path) else { return }
        summary.ran = true
        if fm.fileExists(atPath: new.path) {
            // Only adopt the old history if the new folder has none yet.
            let newHistory = new.appendingPathComponent("history.json")
            guard !fm.fileExists(atPath: newHistory.path) else { return }
            for name in ["history.json", "pins.json", "Media"] {
                let src = old.appendingPathComponent(name)
                guard fm.fileExists(atPath: src.path) else { continue }
                do {
                    try fm.moveItem(at: src, to: new.appendingPathComponent(name))
                } catch {
                    summary.failures.append("could not move \(name) from the old data folder (\(error.localizedDescription)).")
                }
            }
            return
        }
        do {
            try fm.moveItem(at: old, to: new)
        } catch {
            summary.failures.append("could not move the old data folder (\(error.localizedDescription)).")
        }
    }

    /// Copies every preference from the old bundle identifier's domain.
    private static func migrateDefaults() {
        let defaults = AppPaths.defaults
        for bundleID in oldBundleIDs {
            guard let old = defaults.persistentDomain(forName: bundleID), !old.isEmpty else { continue }
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
    }
}
