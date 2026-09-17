import Foundation
import AppKit

/// One file holding everything Clip has: a zip with a manifest at its root.
///
/// **Why a zip and not the single JSON the scope export writes.**
///
/// The history is not all text. Images, files and rich text live as real files
/// in `AppPaths.media`, and a JSON-only backup either drops them - which is what
/// the scope export does - or base64s them into a document no text editor can
/// open and no reasonable amount of memory can hold. A zip stores them as files.
///
/// A manifest at the root is what makes "show the person what is in this file
/// BEFORE writing anything" cheap: the preview reads one small entry, not a
/// gigabyte of media. And the archive stays inspectable - somebody can unzip
/// their own backup and read it - which matters, because a backup format only
/// the app can open is a backup you cannot verify and therefore cannot trust.
///
/// Sections are separate entries rather than one blob, which is what lets a
/// restore be chosen section by section instead of taken whole.
enum BackupArchive {

    /// Bumped when the archive's shape changes. A newer archive is refused by an
    /// older app rather than half-read.
    static let schemaVersion = 1
    static let fileExtension = "clipbackup"

    // MARK: - What an archive holds

    enum Section: String, CaseIterable, Identifiable {
        case history, media, versions, settingsSynced, settingsLocal
        case syncSettings, themes, shortcuts, tabs, pasteActions, activityLog

        var id: String { rawValue }

        /// The entry name inside the archive. `media` is a directory.
        var fileName: String {
            switch self {
            case .media: return "Media"
            default:     return "\(rawValue).json"
            }
        }

        var title: String {
            switch self {
            case .history:        return "Clips, notes, prompts and skills"
            case .media:          return "Images and files"
            case .versions:       return "Version history"
            case .settingsSynced: return "Your settings"
            case .settingsLocal:  return "This Mac's own settings"
            case .syncSettings:   return "Server and sync settings"
            case .themes:         return "Custom themes"
            case .shortcuts:      return "Shortcuts"
            case .tabs:           return "Tabs"
            case .pasteActions:   return "Paste actions"
            case .activityLog:    return "Activity log"
            }
        }

        var detail: String {
            switch self {
            case .history:
                return "Everything in your history, with tags, pins and dates."
            case .media:
                return "The image and file data your clips point at."
            case .versions:
                return "Every past revision of every item, with its original date."
            case .settingsSynced:
                return "Behavior, appearance, privacy and your AI connections. Never your API keys."
            case .settingsLocal:
                return """
                    Window position, history limit and launch at login. These describe \
                    the Mac they came from, so they are skipped unless you ask for them.
                    """
            case .syncSettings:
                return "The address of your sync server, so a new Mac does not have to be told it again. Never your sync token."
            case .themes:         return "Themes you built or generated."
            case .shortcuts:      return "Your key bindings."
            case .tabs:           return "Your tab layout."
            case .pasteActions:   return "Your paste actions, languages and styles."
            case .activityLog:    return "Recent diagnostic events. Useful for support, not needed to restore."
            }
        }

        /// What a restore does to this section by default.
        ///
        /// Machine-local settings default to `skip` because they describe the
        /// Mac the backup came from, and the activity log because it is a
        /// diagnostic record of a different machine's launches.
        var defaultMode: RestoreMode {
            switch self {
            case .settingsLocal, .activityLog: return .skip
            default: return .merge
            }
        }

        /// Version history is written back but never replaces: see
        /// `Database.restoreVersion`.
        var supportsReplace: Bool {
            switch self {
            case .versions, .media, .activityLog: return false
            default: return true
            }
        }
    }

    enum RestoreMode: String, CaseIterable, Identifiable {
        case skip, merge, replace
        var id: String { rawValue }
        var title: String {
            switch self {
            case .skip:    return "Skip"
            case .merge:   return "Merge"
            case .replace: return "Replace"
            }
        }
    }

    // MARK: - The manifest

    struct Manifest: Codable {
        var application: String = "Clip"
        var schemaVersion: Int = BackupArchive.schemaVersion
        var createdAt: Date = Date()
        var appVersion: String = ""
        /// Always false. There is no opt-in, deliberately: see `SettingsRegistry`.
        var includesSecrets: Bool = false
        /// Section raw value to how many things it holds.
        var counts: [String: Int] = [:]
        var sections: [String] = []
        /// Names of custom themes that could not be encoded, so a backup that
        /// drops one says so instead of the old silent `compactMap`.
        var droppedThemes: [String] = []
        /// Names of media files that could not be copied into the archive, so
        /// a backup that drops one says so instead of the old best-effort loop.
        var droppedMedia: [String] = []

        enum CodingKeys: String, CodingKey {
            case application, schemaVersion, createdAt, appVersion
            case includesSecrets, counts, sections, droppedThemes, droppedMedia
        }

        var createdAtText: String {
            let f = DateFormatter()
            f.dateStyle = .long
            f.timeStyle = .short
            return f.string(from: createdAt)
        }

        func count(_ section: Section) -> Int { counts[section.rawValue] ?? 0 }
        func has(_ section: Section) -> Bool { sections.contains(section.rawValue) }

        /// One sentence per section that dropped something, or nil when
        /// everything the backup tried to include made it in. Named, not just
        /// counted: "1 theme could not be included: Nord copy." names what to
        /// go and look for.
        var dropSummary: String? {
            var lines: [String] = []
            if !droppedThemes.isEmpty {
                lines.append("\(droppedThemes.count) theme\(droppedThemes.count == 1 ? "" : "s") "
                    + "could not be included: \(droppedThemes.joined(separator: ", ")).")
            }
            if !droppedMedia.isEmpty {
                lines.append("\(droppedMedia.count) file\(droppedMedia.count == 1 ? "" : "s") "
                    + "could not be included: \(droppedMedia.joined(separator: ", ")).")
            }
            return lines.isEmpty ? nil : lines.joined(separator: " ")
        }
    }

    enum BackupError: LocalizedError {
        case notAnArchive
        case noManifest
        case wrongApplication
        case tooNew(Int)
        case toolFailed(String)
        case cannotWrite(String)

        var errorDescription: String? {
            switch self {
            case .notAnArchive:
                return "That file is not a Clip backup. It could not be opened as an archive at all."
            case .noManifest:
                return "That file is not a Clip backup: it has no manifest."
            case .wrongApplication:
                return "That backup was not written by Clip."
            case .tooNew(let v):
                return """
                    That backup was written by a newer version of Clip (format \(v)). \
                    Update Clip and try again. Restoring it with this version could \
                    read it wrongly.
                    """
            case .toolFailed(let detail):
                return "The archive could not be read: \(detail)"
            case .cannotWrite(let detail):
                return "The backup could not be written: \(detail)"
            }
        }
    }

    // MARK: - Zipping, with the tools macOS already has

    /// Runs `ditto` or `unzip` and returns stderr on failure.
    ///
    /// `Process` rather than a zip library: the app is not sandboxed (see
    /// `Clip.entitlements`), already shells out in three other places, and
    /// `ditto` is the tool macOS itself uses for this. A bundled zip dependency
    /// would be a framework to sign, and signing is the part of this project
    /// that has cost the most time.
    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        let errPipe = Pipe()
        let outPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = outPipe
        do { try task.run() } catch {
            throw BackupError.toolFailed(error.localizedDescription)
        }
        // Read before waiting: a pipe that fills up deadlocks a process that is
        // still writing to it, and a large archive listing does fill it up.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let detail = String(data: errData, encoding: .utf8) ?? "exit \(task.terminationStatus)"
            throw BackupError.toolFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    /// A scratch directory outside the app's own storage.
    private static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Writing a backup

    /// Writes every section to `url`. Returns the manifest that was written.
    @MainActor
    static func write(to url: URL, store: HistoryStore) throws -> Manifest {
        let staging = try scratch()
        defer { try? FileManager.default.removeItem(at: staging) }

        var manifest = Manifest()
        let info = Bundle.main.infoDictionary ?? [:]
        manifest.appVersion = "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"

        func put(_ section: Section, _ payload: Any, count: Int) throws {
            let target = staging.appendingPathComponent(section.fileName)
            guard let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
                throw BackupError.cannotWrite("\(section.fileName) could not be encoded.")
            }
            do { try data.write(to: target) } catch {
                throw BackupError.cannotWrite(error.localizedDescription)
            }
            manifest.sections.append(section.rawValue)
            manifest.counts[section.rawValue] = count
        }

        // History: every item, whatever its role, in one file. The scope export
        // splits by role because a person choosing "just my prompts" wants a
        // readable file; a backup wants completeness and one place to look.
        let items = store.items.map(ExportPane.dictionary)
        try put(.history, items, count: items.count)

        // Versions, keyed by item id, each carrying its original date.
        var versions: [String: Any] = [:]
        var versionCount = 0
        for item in store.items {
            let vs = Database.shared.versions(for: item.id)
            guard !vs.isEmpty else { continue }
            versionCount += vs.count
            versions[item.id.uuidString] = vs.map {
                ["body": $0.body, "title": $0.title as Any, "note": $0.note,
                 "createdAt": $0.createdAt.timeIntervalSince1970]
            }
        }
        try put(.versions, versions, count: versionCount)

        // Settings, split by bucket so the taxonomy is visible in the archive
        // itself and a restore can offer the two separately.
        let synced = settingsDictionary(SettingsRegistry.synced.map(\.key))
        try put(.settingsSynced, synced, count: synced.count)

        let local = settingsDictionary(SettingsRegistry.machineLocal.map(\.key))
        try put(.settingsLocal, local, count: local.count)

        // The server address, which cannot usefully travel over the server.
        // This is the channel that gets it to a new Mac. Never the token.
        let sync = syncSettingsDictionary()
        try put(.syncSettings, sync, count: sync.count)

        let themes = CustomThemeStore.shared.themes.compactMap { theme -> [String: Any]? in
            guard let d = try? JSONEncoder().encode(theme),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else {
                // Named, not silently skipped: see `Manifest.droppedThemes`.
                manifest.droppedThemes.append(theme.name)
                return nil
            }
            return o
        }
        try put(.themes, themes, count: themes.count)

        let shortcuts = ShortcutAction.allCases.reduce(into: [String: String]()) {
            $0[$1.rawValue] = ShortcutRegistry.shared.shortcut(for: $1)
        }
        try put(.shortcuts, shortcuts, count: shortcuts.count)

        let tabs = Database.shared.preference("tabs") ?? ""
        try put(.tabs, ["tabs": tabs], count: tabs.isEmpty ? 0 : 1)

        var paste: [String: String] = [:]
        for key in ["pasteActions", "pasteLanguages", "pasteStyles", "pasteLanguagePair"] {
            if let v = Database.shared.preference(key), !v.isEmpty { paste[key] = v }
        }
        try put(.pasteActions, paste, count: paste.count)

        let log = Database.shared.recentLog(limit: 2000).map {
            ["at": $0.0.timeIntervalSince1970, "category": $0.1, "message": $0.2] as [String: Any]
        }
        try put(.activityLog, log, count: log.count)

        // Media last: it is the only section that is files rather than JSON.
        let mediaSource = AppPaths.media
        let mediaTarget = staging.appendingPathComponent(Section.media.fileName, isDirectory: true)
        var mediaCount = 0
        if let files = try? FileManager.default.contentsOfDirectory(
            at: mediaSource, includingPropertiesForKeys: nil), !files.isEmpty {
            try? FileManager.default.createDirectory(at: mediaTarget, withIntermediateDirectories: true)
            for file in files {
                let dest = mediaTarget.appendingPathComponent(file.lastPathComponent)
                if (try? FileManager.default.copyItem(at: file, to: dest)) != nil {
                    mediaCount += 1
                } else {
                    // Named, not silently omitted: see `Manifest.droppedMedia`.
                    manifest.droppedMedia.append(file.lastPathComponent)
                }
            }
            manifest.sections.append(Section.media.rawValue)
            manifest.counts[Section.media.rawValue] = mediaCount
        }

        // The manifest is written last, so a staging directory that failed
        // half way through never produces a readable archive.
        let manifestData = try JSONEncoder.backup.encode(manifest)
        do {
            try manifestData.write(to: staging.appendingPathComponent("manifest.json"))
        } catch {
            throw BackupError.cannotWrite(error.localizedDescription)
        }

        try? FileManager.default.removeItem(at: url)
        // No --keepParent: the manifest must sit at the archive root, not inside
        // a directory named after a temporary folder.
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", staging.path, url.path])

        // Owner-only, like the database it came from. `ditto` writes with the
        // process umask, which normally means 0644, and this one file holds
        // every password its owner has ever copied: on a Mac with more than
        // one account, 0644 in Documents or on the Desktop is readable by all
        // of them. The database (0600) and the store (0700) were already
        // careful; the archive, which travels further than either, was not.
        // `Database.snapshotBackup` has always done this for its own snapshots
        // through the same helper.
        AppPaths.restrict(url, to: 0o600)
        return manifest
    }

    /// Every named key and its current value, as text, for the archive.
    @MainActor
    private static func settingsDictionary(_ keys: [String]) -> [String: String] {
        var out: [String: String] = [:]
        let live = SettingsDocument.liveValues()
        for key in keys {
            if let v = live[key] { out[key] = v; continue }
            // Machine-local keys are not in the synced live map, so they are read
            // directly. A key with no stored value is simply absent, which is
            // right: restoring "unset" means leaving the default alone.
            if let value = AppPaths.defaults.object(forKey: key) {
                out[key] = SettingsDocument.text(from: value)
            } else if let value = Database.shared.preference(key), !value.isEmpty {
                out[key] = value
            }
        }
        return out
    }

    /// The sync server's address and shape - never its credential.
    ///
    /// `sync.tokenService` and `sync.tokenFingerprint` are deliberately absent:
    /// the first names the Keychain service holding a working credential and the
    /// second is a digest of it, and neither belongs in a file a person emails
    /// to themselves.
    private static func syncSettingsDictionary() -> [String: String] {
        var out: [String: String] = [:]
        for key in ["syncBaseURL", "sync.serviceKind", "sync.space", "sync.merge"] {
            if let v = Database.shared.preference(key), !v.isEmpty { out[key] = v }
        }
        return out
    }

    // MARK: - Reading a backup, without writing anything

    /// Reads just the manifest. Nothing is extracted and nothing is written.
    ///
    /// This is what makes the restore flow safe: a corrupt, truncated or foreign
    /// file fails here, which is before the first byte of the person's own data
    /// has been touched.
    static func inspect(_ url: URL) throws -> Manifest {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BackupError.notAnArchive
        }
        let json: String
        do {
            json = try run("/usr/bin/unzip", ["-p", url.path, "manifest.json"])
        } catch {
            // `unzip` fails the same way for "not a zip" and "truncated", and
            // both mean the same thing to the person holding the file.
            throw BackupError.notAnArchive
        }
        guard let data = json.data(using: .utf8), !data.isEmpty else {
            throw BackupError.noManifest
        }
        guard let manifest = try? JSONDecoder.backup.decode(Manifest.self, from: data) else {
            throw BackupError.noManifest
        }
        guard manifest.application == "Clip" else { throw BackupError.wrongApplication }
        guard manifest.schemaVersion <= schemaVersion else {
            throw BackupError.tooNew(manifest.schemaVersion)
        }
        return manifest
    }

    // MARK: - Restoring

    /// One reason several entries failed, with a few of them named.
    ///
    /// A restore of a thousand clips that hits three bad rows must not print a
    /// thousand lines, and must not print one number with no reason either -
    /// "3 entries could not be read" is unactionable. A cluster is the middle:
    /// what went wrong, how many it happened to, and enough examples to go and
    /// look.
    struct FailureCluster: Identifiable {
        var id: String { "\(section.rawValue)|\(reason)" }
        let section: Section
        let reason: String
        var count = 0
        var examples: [String] = []

        var text: String {
            let head = "\(count) \(section.title.lowercased()) - \(reason)"
            return examples.isEmpty ? head : head + " (" + examples.prefix(3).joined(separator: ", ") + ")"
        }
    }

    /// Something the restore would have to change to fit THIS Mac.
    ///
    /// Until now these were applied silently or skipped silently - a shortcut
    /// in the backup that is already taken here was "left alone", with nobody
    /// told. Neither is the user's call to make on their behalf, so each one is
    /// surfaced before anything is written and carries its own decision.
    struct Adaptation: Identifiable, Equatable {
        let id: String
        let section: Section
        /// What would change, in one line.
        let title: String
        /// Why it has to change, and what happens either way.
        let detail: String
    }

    struct RestoreSummary {
        var itemsAdded = 0
        var itemsUpdated = 0
        var itemsSkipped = 0
        var unreadable = 0
        var mediaRestored = 0
        var versionsRestored = 0
        var settingsApplied = 0
        var themes = 0
        var shortcuts = 0
        /// Everything that failed, grouped by why.
        var failures: [FailureCluster] = []
        /// Adaptations the user approved, and the ones they discarded.
        var adaptationsApplied = 0
        var adaptationsDiscarded = 0
        /// Where the pre-restore safety copy went.
        var safetyCopy: URL?
        /// True when a safety copy was requested but `writeSafetyCopy` came
        /// back nil - the restore then proceeds with no way back if the
        /// incoming file turns out to be the wrong one. Used to be silent:
        /// `summary.safetyCopy` stayed nil and `text` simply omitted the
        /// "your previous data is in..." line, so a failed safety copy read
        /// exactly like a successful restore that just did not mention one.
        var safetyCopyFailed = false

        /// True when every entry in the file landed - the ordinary case, and
        /// the one that gets a count and nothing else.
        var isClean: Bool { failures.isEmpty && unreadable == 0 && !safetyCopyFailed }

        /// The whole result in one word, for the UI to lead with.
        var verdict: String {
            if isClean { return "restored" }
            let restored = itemsAdded + itemsUpdated + themes + shortcuts + settingsApplied
            return restored > 0 ? "partial" : "failed"
        }

        mutating func fail(_ section: Section, _ reason: String, example: String? = nil) {
            if let i = failures.firstIndex(where: { $0.section == section && $0.reason == reason }) {
                failures[i].count += 1
                if let example, failures[i].examples.count < 3 { failures[i].examples.append(example) }
            } else {
                failures.append(FailureCluster(section: section, reason: reason, count: 1,
                                               examples: example.map { [$0] } ?? []))
            }
            unreadable += 1
        }

        var text: String {
            var parts: [String] = []
            parts.append("Restored \(itemsAdded + itemsUpdated) item\(itemsAdded + itemsUpdated == 1 ? "" : "s")")
            if versionsRestored > 0 { parts.append("\(versionsRestored) revision\(versionsRestored == 1 ? "" : "s")") }
            if mediaRestored > 0 { parts.append("\(mediaRestored) file\(mediaRestored == 1 ? "" : "s")") }
            if themes > 0 { parts.append("\(themes) theme\(themes == 1 ? "" : "s")") }
            if shortcuts > 0 { parts.append("\(shortcuts) shortcut\(shortcuts == 1 ? "" : "s")") }
            if settingsApplied > 0 { parts.append("\(settingsApplied) settings") }
            var out = parts.joined(separator: ", ") + "."
            if itemsSkipped > 0 { out += " \(itemsSkipped) already up to date." }
            if unreadable > 0 {
                out += " \(unreadable) item\(unreadable == 1 ? "" : "s") could not be read."
            }
            if let safetyCopy {
                out += " Your previous data is in \(safetyCopy.lastPathComponent)."
            } else if safetyCopyFailed {
                out += " Could not make a safety copy of your previous data before restoring."
            }
            return out
        }
    }

    /// Where the automatic pre-restore copy is kept.
    static var backupsDirectory: URL {
        let dir = AppPaths.support.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// Writes the current state to `Backups/` so a restore can be undone.
    ///
    /// A restore that turns out to be the wrong file is otherwise unrecoverable,
    /// and "are you sure" is not a recovery plan.
    @MainActor
    static func writeSafetyCopy(store: HistoryStore) -> URL? {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmm"
        let url = backupsDirectory
            .appendingPathComponent("clip-before-restore-\(stamp.string(from: Date())).\(fileExtension)")
        guard (try? write(to: url, store: store)) != nil else { return nil }
        AppPaths.restrict(url, to: 0o600)
        return url
    }

    /// A stable id for one adaptation, so a decision taken in the sheet still
    /// names the same thing when the restore runs.
    static func adaptationID(_ section: Section, _ key: String) -> String {
        "\(section.rawValue):\(key)"
    }

    /// Everything this file would have to change to fit this Mac, read before
    /// a single byte is written.
    ///
    /// Only the shortcuts today, because that is the only place the restore
    /// really rewrites a local decision. Anything else that starts adapting
    /// belongs here rather than inside `restore`, so the user still sees it
    /// first.
    @MainActor
    static func adaptations(in url: URL, modes: [Section: RestoreMode]) throws -> [Adaptation] {
        guard (modes[.shortcuts] ?? Section.shortcuts.defaultMode) != .skip else { return [] }
        let extracted = try scratch()
        defer { try? FileManager.default.removeItem(at: extracted) }
        try run("/usr/bin/ditto", ["-x", "-k", url.path, extracted.path])
        let file = extracted.appendingPathComponent(Section.shortcuts.fileName)
        guard let data = try? Data(contentsOf: file),
              let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
        else { return [] }

        return map.compactMap { raw, combo in
            guard let action = ShortcutAction(rawValue: raw),
                  let clash = ShortcutRegistry.shared.conflict(for: combo, assigning: action)
            else { return nil }
            return Adaptation(
                id: adaptationID(.shortcuts, raw),
                section: .shortcuts,
                title: "\(action.title): \(Shortcut.display(combo))",
                detail: clash.message + " Approve to give it to the restored "
                      + "shortcut, or discard to keep this Mac as it is.")
        }
        .sorted { $0.title < $1.title }
    }

    /// Applies a backup. Call `inspect` first: this assumes the manifest is
    /// already known good. `approved` carries the adaptations the user said
    /// yes to - anything not in it is left as this Mac already has it.
    @MainActor
    static func restore(_ url: URL, modes: [Section: RestoreMode],
                        store: HistoryStore, takeSafetyCopy: Bool = true,
                        approved: Set<String> = []) throws -> RestoreSummary {
        var summary = RestoreSummary()

        // Before anything is written.
        if takeSafetyCopy {
            summary.safetyCopy = writeSafetyCopy(store: store)
            summary.safetyCopyFailed = summary.safetyCopy == nil
        }

        let extracted = try scratch()
        defer { try? FileManager.default.removeItem(at: extracted) }
        try run("/usr/bin/ditto", ["-x", "-k", url.path, extracted.path])

        func json(_ section: Section) -> Any? {
            let file = extracted.appendingPathComponent(section.fileName)
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        func mode(_ section: Section) -> RestoreMode { modes[section] ?? .skip }

        // Media first: an item restored before the file it points at would
        // render as a broken thumbnail for however long the copy took.
        if mode(.media) != .skip {
            let source = extracted.appendingPathComponent(Section.media.fileName, isDirectory: true)
            if let files = try? FileManager.default.contentsOfDirectory(
                at: source, includingPropertiesForKeys: nil) {
                for file in files {
                    let dest = AppPaths.media.appendingPathComponent(file.lastPathComponent)
                    if FileManager.default.fileExists(atPath: dest.path) {
                        if mode(.media) == .merge { continue }
                        try? FileManager.default.removeItem(at: dest)
                    }
                    if (try? FileManager.default.copyItem(at: file, to: dest)) != nil {
                        AppPaths.restrict(dest, to: 0o600)
                        summary.mediaRestored += 1
                    }
                }
            }
        }

        if mode(.history) != .skip, let rows = json(.history) as? [[String: Any]] {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if mode(.history) == .replace { store.clearAll(recordDeletions: false) }
            for row in rows {
                guard let data = try? JSONSerialization.data(withJSONObject: row),
                      let item = try? decoder.decode(ClipboardItem.self, from: data) else {
                    summary.fail(.history, "could not be read",
                                 example: (row["title"] as? String)
                                       ?? (row["id"] as? String) ?? "unnamed")
                    continue
                }
                if let existing = store.item(item.id) {
                    if item.timestamp > existing.timestamp {
                        store.update(item.id) { $0 = item }
                        summary.itemsUpdated += 1
                    } else {
                        summary.itemsSkipped += 1
                    }
                } else {
                    store.add(item)
                    summary.itemsAdded += 1
                }
            }
        }

        if mode(.versions) != .skip, let byItem = json(.versions) as? [String: Any] {
            for (rawID, value) in byItem {
                guard let id = UUID(uuidString: rawID),
                      let rows = value as? [[String: Any]] else { continue }
                for row in rows {
                    guard let body = row["body"] as? String,
                          let at = row["createdAt"] as? Double else { continue }
                    if Database.shared.restoreVersion(
                        itemID: id, body: body, title: row["title"] as? String,
                        note: row["note"] as? String ?? "",
                        createdAt: Date(timeIntervalSince1970: at)) {
                        summary.versionsRestored += 1
                    }
                }
            }
        }

        if mode(.themes) != .skip, let rows = json(.themes) as? [[String: Any]] {
            for row in rows {
                guard let data = try? JSONSerialization.data(withJSONObject: row),
                      let theme = try? JSONDecoder().decode(CustomTheme.self, from: data) else {
                    summary.fail(.themes, "could not be read",
                                 example: (row["name"] as? String) ?? "unnamed")
                    continue
                }
                CustomThemeStore.shared.save(theme)
                summary.themes += 1
            }
        }

        if mode(.shortcuts) != .skip, let map = json(.shortcuts) as? [String: String] {
            for (raw, combo) in map {
                guard let action = ShortcutAction(rawValue: raw) else { continue }
                // A clash used to be "left alone", silently. It is a change to
                // fit THIS Mac either way - take the backup's binding and this
                // Mac loses the one it has, or keep this Mac's and the backup's
                // is dropped - so it is the user's decision, taken before any
                // of this ran, and only carried out here.
                if let clash = ShortcutRegistry.shared.conflict(for: combo, assigning: action) {
                    let id = adaptationID(.shortcuts, raw)
                    if approved.contains(id) {
                        ShortcutRegistry.shared.forceAssign(combo, to: action)
                        summary.shortcuts += 1
                        summary.adaptationsApplied += 1
                    } else {
                        summary.adaptationsDiscarded += 1
                        _ = clash
                    }
                    continue
                }
                if ShortcutRegistry.shared.assign(combo, to: action) == nil { summary.shortcuts += 1 }
            }
        }

        if mode(.tabs) != .skip, let map = json(.tabs) as? [String: String],
           let tabs = map["tabs"], !tabs.isEmpty {
            Database.shared.setPreference("tabs", tabs)
            TabConfiguration.shared.reload()
        }

        if mode(.pasteActions) != .skip, let map = json(.pasteActions) as? [String: String] {
            for (key, value) in map where !value.isEmpty {
                Database.shared.setPreference(key, value)
            }
            PasteActionStore.shared.reload()
        }

        if mode(.syncSettings) != .skip, let map = json(.syncSettings) as? [String: String] {
            for (key, value) in map where !value.isEmpty {
                // Defence in depth: nothing secret is written here even if a
                // hand-edited archive claims to carry one.
                guard !SettingsRegistry.neverLeaves.contains(where: { key.contains($0) }) else { continue }
                Database.shared.setPreference(key, value)
            }
        }

        summary.settingsApplied += applySettings(json(.settingsSynced) as? [String: String],
                                                 mode: mode(.settingsSynced),
                                                 allowed: SettingsRegistry.syncedKeys)
        summary.settingsApplied += applySettings(json(.settingsLocal) as? [String: String],
                                                 mode: mode(.settingsLocal),
                                                 allowed: SettingsRegistry.machineLocalKeys)

        // The activity log is a record of another Mac's launches. It is carried
        // so a support conversation can read it, and never written into this
        // Mac's own log, which would make the two indistinguishable.

        Database.shared.log("backup", "Restored from \(url.lastPathComponent)")
        return summary
    }

    /// Writes settings from an archive, by the registry's declared types.
    ///
    /// Driven from `SettingsRegistry` rather than a hand-written list of `if let`
    /// assignments. The old import had exactly that list, and it had already
    /// drifted: it wrote `launchAtLogin` and `density` into the file and never
    /// read either back, so those two settings silently did not restore.
    @MainActor
    @discardableResult
    private static func applySettings(_ values: [String: String]?, mode: RestoreMode,
                                      allowed: Set<String>) -> Int {
        guard mode != .skip, let values else { return 0 }
        var applied = 0
        var touchedDefaults = false

        for (key, raw) in values where allowed.contains(key) {
            guard !SettingsRegistry.neverLeaves.contains(where: { key.contains($0) }) else { continue }
            let store = SettingsRegistry.store(for: key)
                ?? SettingsRegistry.machineLocal.first { $0.key == key }?.store
            switch store {
            case .defaults(let kind):
                switch kind {
                case .bool:
                    AppPaths.defaults.set(raw == "1" || raw.lowercased() == "true", forKey: key)
                case .int:
                    if let n = Int(raw) { AppPaths.defaults.set(n, forKey: key) }
                case .string:
                    AppPaths.defaults.set(raw, forKey: key)
                }
                touchedDefaults = true
                applied += 1
            case .database:
                Database.shared.setPreference(key, raw)
                applied += 1
            case .customThemes:
                if let data = raw.data(using: .utf8),
                   let incoming = try? JSONDecoder().decode([CustomTheme].self, from: data) {
                    for theme in incoming { CustomThemeStore.shared.save(theme) }
                    applied += 1
                }
            case .pinnedOrder:
                let ids = raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
                if !ids.isEmpty { HistoryStore.shared.applyPinnedOrder(ids); applied += 1 }
            case .none:
                continue
            }
        }

        if touchedDefaults {
            PreferencesModel.shared.reloadFromDefaults()
            let theme = ThemeManager.shared
            if let v = values["themeID"], !v.isEmpty { theme.themeID = v }
            if let v = values["density"], let d = GalleryDensity(rawValue: v) { theme.density = d }
            if let v = values["initialTabID"], !v.isEmpty { theme.initialTabID = v }
            HistoryStore.shared.reloadViewPreferences()
            ShortcutRegistry.shared.reload()
            SettingsSync.shared.adoptStoredCadence()
        }
        return applied
    }
}


extension JSONEncoder {
    /// Dates as seconds, so a manifest reads the same on any locale.
    static var backup: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
}

extension JSONDecoder {
    static var backup: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}

extension BackupArchive.Manifest {
    /// Decoded field by field on purpose. Swift's synthesised decoder ignores a
    /// property's default value and throws on a missing key, so adding
    /// `droppedThemes` made every archive written before it undecodable, and
    /// `restore` then refused every backup a person already had on disk. The two
    /// fields carrying the archive's identity stay required, so a foreign or
    /// truncated manifest is still rejected rather than defaulted into looking
    /// valid. Everything else is metadata and may be absent.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        application = try c.decode(String.self, forKey: .application)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? createdAt
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? ""
        includesSecrets = try c.decodeIfPresent(Bool.self, forKey: .includesSecrets) ?? false
        counts = try c.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:]
        sections = try c.decodeIfPresent([String].self, forKey: .sections) ?? []
        droppedThemes = try c.decodeIfPresent([String].self, forKey: .droppedThemes) ?? []
        droppedMedia = try c.decodeIfPresent([String].self, forKey: .droppedMedia) ?? []
    }
}
