import Foundation

/// Where Clip keeps its data.
///
/// Automated runs write to a **separate directory**. The probe had been seeding,
/// clearing and generating into the user's real database — it left 31 junk
/// themes and three dead AI connections behind before that was noticed. A test
/// that can damage the thing it is testing is not a test.
enum AppPaths {

    /// Set by the probe. Interactive runs, even with the bridge enabled, use the
    /// real directory so what you configure is what you keep.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["CLIP_QA_SANDBOX"] == "1"
    }

    /// `CLIP_QA_SANDBOX_NAME` lets several sandboxed runs coexist (parallel
    /// lanes each get their own directory, bridge files and defaults suite).
    static var sandboxName: String {
        ProcessInfo.processInfo.environment["CLIP_QA_SANDBOX_NAME"] ?? "Clip-QA"
    }
    static var directoryName: String { isSandboxed ? sandboxName : "Clip" }

    // MARK: - Directory and permission failures (M3.8)
    //
    // `try?` on `createDirectory`/`setAttributes` used to drop the error on the
    // floor: a folder that could not be created left the app silently unable to
    // store anything, and a permission that could not be applied left the
    // database world-readable with nobody told either fact. Captured here so
    // `StartupHealth` can turn the first of each into a notice.

    /// The most recent directory-creation failure this launch, if any.
    private(set) static var lastDirectoryError: (path: String, detail: String)?
    /// The most recent permission (`setAttributes`) failure this launch.
    private(set) static var lastPermissionError: (path: String, detail: String)?

    #if CLIP_TESTING
    /// Redirects `support` under an unwritable parent, standing in for a real
    /// permissions problem without touching anything outside the sandbox.
    /// Cleared automatically once it has produced one failure, so a probe
    /// cannot leave every later section pointed at a folder that does not
    /// exist.
    static var forcedUnwritableParentForTesting: URL?
    /// Lets a probe read back and reset the captured errors between checks.
    static func resetCapturedErrorsForTesting() {
        lastDirectoryError = nil
        lastPermissionError = nil
    }
    #endif

    static var support: URL {
        #if CLIP_TESTING
        if let forced = forcedUnwritableParentForTesting {
            let dir = forced.appendingPathComponent(directoryName, isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            } catch {
                lastDirectoryError = (dir.path, cheapDescription(error))
            }
            return dir
        }
        #endif
        return realSandboxSupport
    }

    /// The true sandbox data folder, ignoring `forcedUnwritableParentForTesting`.
    ///
    /// `QABridge`'s own command/state files live under `support` too - so the
    /// first version of the H7 test broke its own remote control: forcing
    /// `support` onto a broken path redirected `QABridge`'s `qa-command.txt`
    /// and `qa-state.json` there as well, and a bridge that cannot read the
    /// command a probe just wrote can never process the command that would
    /// clear the override, let alone acknowledge it - the harness hangs
    /// forever with no way back in. The harness's own plumbing always uses
    /// this real path; only the APP-FACING `support` (the one the code under
    /// test reads) is ever redirected.
    static var realSandboxSupport: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(directoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            lastDirectoryError = (dir.path, cheapDescription(error))
        }
        restrict(dir, to: 0o700)
        return dir
    }

    static var media: URL {
        let dir = support.appendingPathComponent("Media", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            lastDirectoryError = (dir.path, cheapDescription(error))
        }
        restrict(dir, to: 0o700)
        return dir
    }

    /// Makes a path readable by its owner and nobody else.
    ///
    /// The database was being created at 0644 inside a 0755 directory, which
    /// means every process running on this Mac, and every other user account on
    /// it, could read it. For most apps that is careless. For this one it is
    /// serious: this file holds every string the user has ever copied, which
    /// includes passwords pasted out of a password manager, API keys, recovery
    /// codes and card numbers. The whole point of honouring the concealed
    /// pasteboard flag is undone if what does get stored is world-readable.
    ///
    /// Applied on every launch rather than only at creation, so installs that
    /// already have a 0644 database are repaired rather than left as they are.
    static func restrict(_ url: URL, to permissions: Int) {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { return }
        let current = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions])
            .flatMap { $0 as? NSNumber }?.intValue
        guard current != permissions else { return }
        do {
            try FileManager.default.setAttributes([.posixPermissions: permissions],
                                                  ofItemAtPath: path)
        } catch {
            lastPermissionError = (path, cheapDescription(error))
        }
    }

    /// A cheap, non-localized description of a filesystem error.
    ///
    /// `Error.localizedDescription` on an `NSCocoaErrorDomain` failure walks
    /// through `LaunchServices` to resolve the offending path's LOCALIZED
    /// DISPLAY NAME, which costs one or more sandbox-checked round trips.
    /// `AppPaths.support` is a computed property read on every poll tick and
    /// from dozens of call sites; while a real directory or permission
    /// failure is active, every one of those reads was recomputing that
    /// expensive string - turning one filesystem error into an app that
    /// could not keep up with its own 0.1 s test-bridge timer, let alone
    /// stay responsive for a person looking at the very alert this was
    /// meant to raise. `NSError.code`/`.domain` cost nothing beyond what the
    /// system already attached to the error.
    private static func cheapDescription(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }

    /// Locks down everything Clip stores. Called once at launch.
    ///
    /// SQLite creates the `-wal` and `-shm` companions itself, with the
    /// process umask, so they need the same treatment as the database. A
    /// private database beside a world-readable write-ahead log is not private:
    /// the WAL holds the most recent writes, which are the most recent things
    /// the user copied.
    static func secureStorage() {
        restrict(support, to: 0o700)
        restrict(media, to: 0o700)

        // EVERY file, not a list of the ones we remembered.
        //
        // The first version named `clip.sqlite` and its two companions, and
        // missed everything else in the folder: the backup copies taken before
        // each migration (which are complete copies of the same history), the
        // sync database, an old JSON export of the history from a previous
        // version, and a stale state file left behind by a test run before the
        // sandbox existed - that last one a plaintext dump including clipboard
        // contents. Every one of those is exactly as sensitive as the database
        // they were listed to protect.
        //
        // Walking the directory cannot miss a file that arrives later, which a
        // hardcoded list will do the moment anything new is written here.
        let manager = FileManager.default
        for directory in [support, media] {
            guard let files = try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for file in files {
                let isDirectory = (try? file.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory ?? false
                restrict(file, to: isDirectory ? 0o700 : 0o600)
            }
        }
    }

    static var database: URL { support.appendingPathComponent("clip.sqlite") }

    /// Keychain service, so sandboxed keys never collide with real ones.
    static var keychainService: String { isSandboxed ? "app.clip.ai.qa" : "app.clip.ai" }

    /// Where preferences live.
    ///
    /// The sandbox used to isolate the database, the media folder and the
    /// Keychain, but NOT `UserDefaults` - so an automated run wrote its test
    /// values straight into the real preferences. A probe that set
    /// `historyLimit` to 20 to check trimming left the user's history capped at
    /// 20 afterwards. That is the same class of mistake as the run that seeded
    /// into the live database, and the same answer: a test must not be able to
    /// damage the thing it is testing.
    ///
    /// The suite name is only ever used under `CLIP_QA_SANDBOX`, so an ordinary
    /// launch reads and writes exactly where it always did.
    static let defaults: UserDefaults = {
        let suiteName = sandboxName == "Clip-QA" ? "app.clip.qa" : "app.clip.qa.\(sandboxName)"
        guard isSandboxed, let suite = UserDefaults(suiteName: suiteName) else {
            return .standard
        }
        return suite
    }()

    // MARK: - Data-directory audit and reclaim (M3.7)

    /// One thing the audit found that nothing else in Clip is using.
    ///
    /// Never removed by the audit itself - `reclaim` MOVES what it lists into
    /// a dated folder inside Clip's own data directory, and a second,
    /// explicitly confirmed action empties that folder. The house rule this
    /// follows: a wrong predicate once stripped 77 files when 14 were in
    /// scope, and a move is the one mistake here that is still recoverable.
    struct Orphan: Identifiable {
        enum Category: String {
            case media               // Media/ file no item's imageFile names
            case degradedMedia       // an item's imageFile names nothing on disk
            case staleTestFiles
            case importedHistory     // history.json.imported, already absorbed
            case pinsJSON            // superseded by preferences.pinnedIDs
            case previousVersion     // previous-versions/ beyond retention
            case corruptQuarantine   // clip.sqlite.corrupt-*
            case backupBeyondRetention
        }
        let id: String
        let category: Category
        let url: URL
        let size: Int64
        let reason: String
    }

    private static func fileSize(_ url: URL, recursive: Bool = false) -> Int64 {
        let fm = FileManager.default
        guard recursive else {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let child as URL in e {
                if let n = (try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    total += Int64(n)
                }
            }
        }
        return total
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? .distantPast
    }

    /// Everything the app found lying around that nothing reads any more.
    ///
    /// Walks `support` and `media` once and classifies each finding; costs one
    /// directory listing plus one `loadItems()`, run at launch (report only)
    /// and again whenever Settings > Privacy is opened.
    static func audit() -> [Orphan] {
        var out: [Orphan] = []
        let fm = FileManager.default
        let items = Database.shared.loadItems()

        // Media referenced by no item, and items whose file is missing.
        let referenced = Set(items.compactMap(\.imageFile))
        if let mediaFiles = try? fm.contentsOfDirectory(
            at: media, includingPropertiesForKeys: [.fileSizeKey]) {
            for file in mediaFiles where !referenced.contains(file.lastPathComponent) {
                out.append(Orphan(id: file.path, category: .media, url: file,
                                  size: fileSize(file), reason: "Not referenced by any item"))
            }
        }
        for item in items {
            guard let name = item.imageFile,
                  !fm.fileExists(atPath: media.appendingPathComponent(name).path) else { continue }
            let target = media.appendingPathComponent(name)
            out.append(Orphan(id: "item-media-\(item.id.uuidString)", category: .degradedMedia,
                              url: target, size: 0,
                              reason: "“\(item.displayTitle)” points at a missing image"))
        }

        // stale-test-files-*, pins.json, history.json.imported.
        if let files = try? fm.contentsOfDirectory(
            at: support, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) {
            for file in files {
                let name = file.lastPathComponent
                let isDirectory = (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if name.hasPrefix("stale-test-files-") {
                    out.append(Orphan(id: file.path, category: .staleTestFiles, url: file,
                                      size: fileSize(file, recursive: isDirectory),
                                      reason: "Leftover test fixture"))
                } else if name == "pins.json" {
                    out.append(Orphan(id: file.path, category: .pinsJSON, url: file,
                                      size: fileSize(file),
                                      reason: "Superseded by the pins kept in preferences"))
                } else if name == "history.json.imported" {
                    out.append(Orphan(id: file.path, category: .importedHistory, url: file,
                                      size: fileSize(file),
                                      reason: "Already imported into the database"))
                } else if name.contains(".corrupt-") {
                    out.append(Orphan(id: file.path, category: .corruptQuarantine, url: file,
                                      size: fileSize(file),
                                      reason: "Set aside after Clip found it damaged"))
                }
            }
        }

        // previous-versions/ beyond the newest 2, or older than 30 days.
        let prevDir = support.appendingPathComponent("previous-versions", isDirectory: true)
        if let entries = try? fm.contentsOfDirectory(
            at: prevDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let sorted = entries.sorted { modificationDate($0) > modificationDate($1) }
            let cutoff = Date().addingTimeInterval(-30 * 86400)
            for (index, entry) in sorted.enumerated() where index >= 2 || modificationDate(entry) < cutoff {
                out.append(Orphan(id: entry.path, category: .previousVersion, url: entry,
                                  size: fileSize(entry, recursive: true),
                                  reason: index >= 2 ? "Superseded install (kept: newest 2)"
                                                     : "Superseded install, older than 30 days"))
            }
        }

        // Backups (code-written and the hand-made ones from before this
        // existed) beyond the newest 3, and older than 7 days.
        if let files = try? fm.contentsOfDirectory(
            at: support, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let backups = files.filter {
                let n = $0.lastPathComponent
                return n.hasPrefix("clip.sqlite.backup-") || n.hasPrefix("clip.sqlite.before-")
            }.sorted { modificationDate($0) > modificationDate($1) }
            let cutoff = Date().addingTimeInterval(-7 * 86400)
            for (index, url) in backups.enumerated() where index >= 3 && modificationDate(url) < cutoff {
                out.append(Orphan(id: url.path, category: .backupBeyondRetention, url: url,
                                  size: fileSize(url), reason: "Older backup, retention keeps the newest 3"))
            }
        }

        return out
    }

    /// Moves every listed file into one dated `Reclaimed-<ts>/` folder inside
    /// `support`. Never deletes - see `emptyReclaimed()` for the one place
    /// that does, which requires a second, explicit action.
    @discardableResult
    static func reclaim(_ orphans: [Orphan]) -> URL? {
        reclaim(orphans.map(\.url))
    }

    @discardableResult
    static func reclaim(_ urls: [URL]) -> URL? {
        guard !urls.isEmpty else { return nil }
        let dest = support.appendingPathComponent("Reclaimed-\(Self.reclaimTimestamp())", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        for url in urls {
            guard fm.fileExists(atPath: url.path) else { continue }
            let target = dest.appendingPathComponent(url.lastPathComponent)
            try? fm.moveItem(at: url, to: target)
        }
        restrict(dest, to: 0o700)
        return dest
    }

    /// Permanently removes every `Reclaimed-*` folder. The one place in this
    /// file that deletes anything: by the time this runs, the user has
    /// already had the chance to look inside.
    @discardableResult
    static func emptyReclaimed() -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)
        else { return 0 }
        var removed = 0
        for entry in entries where entry.lastPathComponent.hasPrefix("Reclaimed-") {
            if (try? fm.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }

    /// Whether any `Reclaimed-*` folder currently exists, so Settings can
    /// offer to empty it only when there is something in it.
    static func hasReclaimedFolder() -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)
        else { return false }
        return entries.contains { $0.lastPathComponent.hasPrefix("Reclaimed-") }
    }

    private static func reclaimTimestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }
}
