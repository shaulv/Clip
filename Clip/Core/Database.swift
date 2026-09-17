import Foundation
import SQLite3

/// The local store: items, every past version of them, preferences, an activity
/// log and AI provider config.
///
/// **Why SQLite and not JSON or SwiftData.** The old `history.json` was rewritten
/// whole on every change — fine for a flat list, wrong the moment each item
/// carries a version history. SQLite gives cheap partial writes, real
/// transactions, and makes "restore version 4 of this prompt" a single query.
/// It ships with macOS (`libsqlite3`), so it adds no dependency; SwiftData would
/// have meant rewriting every model and observation path for no extra power.
///
/// **What is deliberately NOT here:** API keys. Those live in the Keychain
/// (`KeychainStore`). A database file is backed up and synced; a secret in it
/// leaks with it.
final class Database {

    static let shared = Database()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "app.clip.database")

    /// SQLite needs to be told a Swift string is transient, or it keeps a
    /// pointer to memory we are about to free.
    private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    var url: URL { AppPaths.database }

    /// Whether a connection is held. False means every write is being dropped;
    /// `StorageDiagnosis` has already said so if that is the case.
    var isOpen: Bool { db != nil }
    /// The last `PRAGMA quick_check` verdict, filled in on open and by every
    /// restore (M3.3/M3.5); "not checked" until the first open runs.
    private(set) var lastIntegrityResult = "not checked"

    /// How many write failures this launch has seen, so the activity log gets
    /// exactly one row for a whole episode instead of one per failed write.
    /// `NoticeCenter` still hears about every single one, in place, through
    /// its own `key` de-duplication; this counter only throttles the disk
    /// write, which would otherwise try to log into the very table that is
    /// failing to accept writes.
    private var writeFailureCount = 0

    private init() {
        open()
        createSchema()
    }

    private func open() {
        let rc = sqlite3_open_v2(url.path, &db,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                                 nil)
        if rc != SQLITE_OK {
            db = nil
            let path = url.path
            // Reported off the main actor deliberately with `async`, not
            // `sync`: this runs inside `Database.shared`'s own `init()`, so a
            // synchronous call back into anything that touches `Database.shared`
            // again (`NoticeCenter.report` calls `Database.shared.log`) would
            // find the static `let` still in the middle of being built and
            // deadlock on Swift's own once-per-static-property lock.
            DispatchQueue.main.async {
                NoticeCenter.shared.report(.cannotOpenDatabase(path: path, code: rc))
            }
            return
        }
        // WAL keeps reads non-blocking while a write is in flight.
        exec("PRAGMA journal_mode = WAL;")
        // The write-ahead log is created by SQLite itself, with the process
        // umask, after this connection opens. Locking the database down at
        // launch is not enough on its own: the WAL holds the most recent
        // writes, which are the most recent things the user copied.
        AppPaths.secureStorage()
        exec("PRAGMA foreign_keys = ON;")
        exec("PRAGMA synchronous = NORMAL;")

        // M3.5: a database that opens but is not readable must not be allowed
        // to run empty - that is data loss with a delay, because the very
        // next save (or a reconcile against zero decoded rows) would be
        // read as "the user deleted everything".
        verifyIntegrityAndRecoverIfNeeded()
    }

    /// `PRAGMA quick_check` right after opening. Not `ok`: try the newest
    /// backup before accepting an empty, working database.
    private func verifyIntegrityAndRecoverIfNeeded() {
        let result = (query("PRAGMA quick_check;").first?.values.first as? String) ?? "unknown"
        lastIntegrityResult = result
        guard result != "ok" else { return }

        let damagedPath = url.path
        if let backup = Self.newestBackup(), restore(from: backup) {
            let backupName = backup.lastPathComponent
            DispatchQueue.main.async {
                NoticeCenter.shared.report(.databaseCorrupt(
                    path: damagedPath, detail: "A backup from \(backupName) was restored."))
            }
            return
        }

        // No usable backup, or the restore itself failed `quick_check`: stay
        // closed rather than serve an app that looks fine and remembers
        // nothing.
        queue.sync {
            if db != nil { sqlite3_close(db); db = nil }
        }
        DispatchQueue.main.async {
            NoticeCenter.shared.report(
                .databaseCorrupt(path: damagedPath, detail: "No backup could be restored."),
                action: NoticeCenter.Action(title: "Restore backup…") {
                    StartupHealth.presentRestorePicker()
                })
        }
    }

    private func createSchema() {
        exec("""
        CREATE TABLE IF NOT EXISTS items (
            id            TEXT PRIMARY KEY,
            payload       TEXT NOT NULL,       -- the ClipboardItem as JSON
            kind          TEXT NOT NULL,
            timestamp     REAL NOT NULL,
            is_pinned     INTEGER NOT NULL DEFAULT 0,
            pinned_index  INTEGER NOT NULL DEFAULT 0,
            is_prompt     INTEGER NOT NULL DEFAULT 0,
            use_count     INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS items_ts     ON items(timestamp DESC);
        CREATE INDEX IF NOT EXISTS items_prompt ON items(is_prompt);

        CREATE TABLE IF NOT EXISTS item_versions (
            version_id  INTEGER PRIMARY KEY AUTOINCREMENT,
            item_id     TEXT NOT NULL,
            body        TEXT NOT NULL,
            title       TEXT,
            note        TEXT,                  -- what produced this version
            created_at  REAL NOT NULL,
            FOREIGN KEY(item_id) REFERENCES items(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS versions_item ON item_versions(item_id, created_at DESC);

        CREATE TABLE IF NOT EXISTS preferences (
            key    TEXT PRIMARY KEY,
            value  TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS activity_log (
            log_id      INTEGER PRIMARY KEY AUTOINCREMENT,
            at          REAL NOT NULL,
            category    TEXT NOT NULL,
            message     TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS log_at ON activity_log(at DESC);

        CREATE TABLE IF NOT EXISTS ai_providers (
            id           TEXT PRIMARY KEY,
            name         TEXT NOT NULL,
            kind         TEXT NOT NULL,        -- anthropic | openai | gemini | ...
            endpoint     TEXT,
            model        TEXT NOT NULL,
            is_active    INTEGER NOT NULL DEFAULT 0,
            validated_at REAL
        );

        CREATE TABLE IF NOT EXISTS custom_themes (
            id       TEXT PRIMARY KEY,
            name     TEXT NOT NULL,
            payload  TEXT NOT NULL,
            created_at REAL NOT NULL
        );

        -- Deleting a row locally tells the other Macs nothing: to them the item
        -- simply never changed, so it lives on for ever and comes back here the
        -- next time the cursor is reset. A deletion has to be a fact that can be
        -- sent, which means it has to outlive the row it removed.
        CREATE TABLE IF NOT EXISTS tombstones (
            id         TEXT PRIMARY KEY,
            deleted_at REAL NOT NULL
        );
        """)
    }

    // MARK: - Primitives
    //
    // Each public method takes the serial queue for the duration of one
    // statement. The `_`-prefixed twins assume the queue is already held, which
    // is what makes `transaction` genuinely atomic: BEGIN, the work and COMMIT
    // all happen inside a single `queue.sync`, so a debounced background save
    // can never interleave and nest a transaction inside another one.

    @discardableResult
    func exec(_ sql: String) -> Bool { queue.sync { _exec(sql) } }

    @discardableResult
    func run(_ sql: String, _ params: [Any?] = []) -> Bool { queue.sync { _run(sql, params) } }

    func query(_ sql: String, _ params: [Any?] = []) -> [[String: Any]] {
        queue.sync { _query(sql, params) }
    }

    /// Runs `work` as one atomic unit. `work` must call only `_`-prefixed
    /// methods; calling a public one would deadlock on the serial queue.
    func transaction(_ work: () -> Void) {
        queue.sync {
            guard _exec("BEGIN IMMEDIATE;") else {
                // Could not take the write lock; do the work unbatched rather
                // than silently dropping it.
                work()
                return
            }
            work()
            _exec("COMMIT;")
        }
    }

    /// Reports a write failure to `NoticeCenter` and, once per launch, to the
    /// on-disk activity log.
    ///
    /// Both `_exec` and `_run` run ON `queue` already (their callers reach
    /// them through `queue.sync`), so this must never call back into anything
    /// that does `queue.sync` itself - that would be a serial queue asked to
    /// run a second block while the first has not finished, which deadlocks.
    /// `DispatchQueue.main.async` returns immediately, letting the current
    /// unit of work on `queue` finish, and the notice + the one log write
    /// happen afterwards, on the main actor, from outside `queue` entirely.
    private func reportWriteFailure(code: Int32, detail: String) {
        writeFailureCount += 1
        let count = writeFailureCount
        let text = count > 1 ? "\(detail) (\(count) write failures this launch)" : detail
        DispatchQueue.main.async {
            NoticeCenter.shared.report(.writeFailed(code: code, detail: text))
            if count == 1 {
                Database.shared.log("storage", "write failed: code \(code) - \(detail)")
            }
        }
    }

    @discardableResult
    fileprivate func _exec(_ sql: String) -> Bool {
        guard let db else { return false }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let detail = err.map { String(cString: $0) } ?? "unknown SQLite error"
            if let err { sqlite3_free(err) }
            reportWriteFailure(code: sqlite3_errcode(db), detail: detail)
            return false
        }
        return true
    }

    @discardableResult
    fileprivate func _run(_ sql: String, _ params: [Any?] = []) -> Bool {
        guard db != nil, let stmt = prepare(sql, params) else { return false }
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            reportWriteFailure(code: rc, detail: "SQL step failed: \(sql)")
            return false
        }
        return true
    }

    fileprivate func _query(_ sql: String, _ params: [Any?] = []) -> [[String: Any]] {
        guard db != nil, let stmt = prepare(sql, params) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT:   row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_NULL:    break
                default:
                    if let c = sqlite3_column_text(stmt, i) { row[name] = String(cString: c) }
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func prepare(_ sql: String, _ params: [Any?]) -> OpaquePointer? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            reportWriteFailure(code: sqlite3_errcode(db),
                               detail: "prepare failed: \(sql) - \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case nil:                sqlite3_bind_null(stmt, idx)
            case let v as String:    sqlite3_bind_text(stmt, idx, v, -1, TRANSIENT)
            case let v as Int:       sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Bool:      sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as Double:    sqlite3_bind_double(stmt, idx, v)
            case let v as Date:      sqlite3_bind_double(stmt, idx, v.timeIntervalSince1970)
            default:                 sqlite3_bind_text(stmt, idx, String(describing: p!), -1, TRANSIENT)
            }
        }
        return stmt
    }
}

// MARK: - Backups and restore (M3.3)
//
// `VACUUM INTO` rather than copying `clip.sqlite` on disk: copying the file
// while the write-ahead log holds pages the main file does not loses exactly
// the most recent things the user copied. `VACUUM INTO` produces one
// consistent file regardless of what is still in the WAL.

extension Database {

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }

    /// Every backup this code, or a hand-made one from before this existed,
    /// left behind - newest first.
    static func backupCandidates() -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: AppPaths.support, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        return files.filter {
            let n = $0.lastPathComponent
            return n.hasPrefix("clip.sqlite.backup-") || n.hasPrefix("clip.sqlite.before-")
        }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let db_ = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return da > db_
        }
    }

    static func newestBackup() -> URL? { backupCandidates().first }

    /// Writes one consistent snapshot, tagged so its purpose (`preupgrade`,
    /// `daily`, `prereconcile`, …) is legible in a file listing. Retention
    /// runs after every write: the newest 3 with this same tag, plus
    /// anything under 7 days regardless of tag, survive; the rest are MOVED
    /// (never deleted) into a dated `Reclaimed-*` folder - the same house
    /// rule `AppPaths.reclaim` uses everywhere else.
    @discardableResult
    func snapshotBackup(tag: String) -> URL? {
        queue.sync { _snapshotBackup(tag: tag) }
    }

    private func _snapshotBackup(tag: String) -> URL? {
        guard db != nil else { return nil }
        let dest = AppPaths.support.appendingPathComponent(
            "clip.sqlite.backup-\(tag)-\(Self.timestamp())")
        let escaped = dest.path.replacingOccurrences(of: "'", with: "''")
        guard _exec("VACUUM INTO '\(escaped)';") else {
            DispatchQueue.main.async {
                NoticeCenter.shared.report(.backupFailed(
                    detail: "Could not write \(dest.lastPathComponent)."))
            }
            return nil
        }
        AppPaths.restrict(dest, to: 0o600)
        _pruneBackups(tag: tag)
        return dest
    }

    private func _pruneBackups(tag: String) {
        let matching = Self.backupCandidates().filter {
            $0.lastPathComponent.contains("backup-\(tag)-")
        }
        let keepNewest = Set(matching.prefix(3).map(\.path))
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        let fm = FileManager.default
        let toMove = matching.filter { url in
            guard !keepNewest.contains(url.path) else { return false }
            let mtime = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            if let mtime, mtime > cutoff { return false }
            return true
        }
        guard !toMove.isEmpty else { return }
        _ = AppPaths.reclaim(toMove)
    }

    /// Closes the current connection (if any), moves whatever file is at
    /// `url` aside to `clip.sqlite.corrupt-<ts>` - never deleted - copies
    /// `backup` into place, reopens, and runs `quick_check` again. Returns
    /// whether the restored copy is actually usable.
    @discardableResult
    func restore(from backup: URL) -> Bool {
        queue.sync { _restore(from: backup) }
    }

    private func _restore(from backup: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backup.path) else {
            DispatchQueue.main.async {
                NoticeCenter.shared.report(.restoreFailed(
                    detail: "\(backup.lastPathComponent) no longer exists."))
            }
            return false
        }
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
        if fm.fileExists(atPath: url.path) {
            let corrupt = url.deletingLastPathComponent()
                .appendingPathComponent("clip.sqlite.corrupt-\(Self.timestamp())")
            try? fm.removeItem(at: corrupt)
            try? fm.moveItem(at: url, to: corrupt)
        }
        do {
            try fm.copyItem(at: backup, to: url)
        } catch {
            DispatchQueue.main.async {
                NoticeCenter.shared.report(.restoreFailed(detail: error.localizedDescription))
            }
            return false
        }

        let openStatus = sqlite3_open_v2(
            url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard openStatus == SQLITE_OK, db != nil else {
            db = nil
            DispatchQueue.main.async {
                NoticeCenter.shared.report(.restoreFailed(detail: "The restored copy could not be opened."))
            }
            return false
        }
        _ = _exec("PRAGMA journal_mode = WAL;")
        _ = _exec("PRAGMA foreign_keys = ON;")
        _ = _exec("PRAGMA synchronous = NORMAL;")
        let check = (_query("PRAGMA quick_check;").first?.values.first as? String) ?? "unknown"
        lastIntegrityResult = check
        AppPaths.secureStorage()
        if check != "ok" {
            DispatchQueue.main.async {
                NoticeCenter.shared.report(.restoreFailed(
                    detail: "The restored copy failed its own integrity check."))
            }
        }
        return check == "ok"
    }

    #if CLIP_TESTING
    /// Closes the live connection so a probe can corrupt the file underneath
    /// it exactly the way a real filesystem fault would, then reopen it
    /// through the normal path (`reopenForTesting`) to exercise recovery.
    func closeForTesting() {
        queue.sync {
            if db != nil { sqlite3_close(db); db = nil }
        }
    }
    /// Re-runs the real `open()` path - including `verifyIntegrityAndRecoverIfNeeded`
    /// - against whatever is on disk right now, then `createSchema()` exactly
    /// as `init()` does. Needed because a probe can remove the sandbox file
    /// entirely (`discardCorruptSandboxDatabase`) and reopen onto a brand
    /// new, schema-less file - `init()` is the only caller of `open()` that
    /// happens once and is followed by `createSchema()` for free; every
    /// other reopen has to ask for it explicitly.
    func reopenForTesting() {
        open()
        createSchema()
    }
    #endif
}

// MARK: - Schema migrations (M3.4)

extension Database {

    enum MigrationOutcome: Equatable {
        case upToDate
        case migrated(steps: Int)
        case failed(step: Int32, detail: String)

        var isFailure: Bool { if case .failed = self { true } else { false } }
    }

    /// Whether a migration failed this launch. Checked by `reconcileItems`:
    /// a schema that did not finish landing is not a database a reconcile
    /// should be allowed to delete anything from.
    private(set) static var migrationsFailedThisLaunch = false

    #if CLIP_TESTING
    /// Injects one migration (version 2) whose SQL is deliberately invalid,
    /// so a probe can prove the failure path - rollback, unchanged
    /// `user_version`, an `.integrity` notice - without waiting for a real
    /// future schema change.
    static var forceMigrationFailureForTesting = false
    #endif

    /// The schema version ladder. Version 1 is today's schema, already
    /// created by `createSchema()`'s `CREATE TABLE IF NOT EXISTS` - its SQL
    /// here is empty, and it exists only so `PRAGMA user_version` has
    /// somewhere to land on a database that predates versioning. Every
    /// future column is a new entry appended here, never edited into
    /// `createSchema()` after the fact.
    private static var migrations: [(version: Int32, sql: [String])] {
        var list: [(version: Int32, sql: [String])] = [(1, [])]
        #if CLIP_TESTING
        if forceMigrationFailureForTesting {
            list.append((2, ["THIS IS NOT VALID SQL AND MUST FAIL;"]))
        }
        #endif
        return list
    }

    /// Runs whatever migrations have not landed yet, each inside its own
    /// transaction. A failing step rolls back and leaves `user_version`
    /// exactly where it was - it never partially applies a step.
    @discardableResult
    func runMigrations() -> MigrationOutcome {
        queue.sync {
            guard db != nil else { return .upToDate }
            let currentVersion = Int32((_query("PRAGMA user_version;").first?["user_version"] as? Int) ?? 0)
            let pending = Self.migrations
                .filter { $0.version > currentVersion }
                .sorted { $0.version < $1.version }
            guard !pending.isEmpty else { return .upToDate }

            var applied = 0
            for step in pending {
                guard _exec("BEGIN IMMEDIATE;") else {
                    Self.migrationsFailedThisLaunch = true
                    return .failed(step: step.version, detail: "could not begin a transaction")
                }
                var ok = true
                for sql in step.sql where ok {
                    ok = _exec(sql)
                }
                if ok { ok = _exec("PRAGMA user_version = \(step.version);") }
                if ok {
                    _exec("COMMIT;")
                    applied += 1
                } else {
                    _exec("ROLLBACK;")
                    Self.migrationsFailedThisLaunch = true
                    return .failed(step: step.version, detail: "a schema statement failed")
                }
            }
            return .migrated(steps: applied)
        }
    }
}

// MARK: - Items

extension Database {

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func saveItem(_ item: ClipboardItem) { queue.sync { _saveItem(item) } }

    fileprivate func _saveItem(_ item: ClipboardItem) {
        guard let data = try? Self.encoder.encode(item),
              let json = String(data: data, encoding: .utf8) else { return }
        _run("""
            INSERT INTO items (id, payload, kind, timestamp, is_pinned, pinned_index, is_prompt, use_count)
            VALUES (?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                payload=excluded.payload, kind=excluded.kind, timestamp=excluded.timestamp,
                is_pinned=excluded.is_pinned, pinned_index=excluded.pinned_index,
                is_prompt=excluded.is_prompt, use_count=excluded.use_count;
            """,
            [item.id.uuidString, json, item.kind.rawValue, item.timestamp,
             item.isPinned, item.pinnedIndex, item.isPrompt, item.useCount])
    }

    func saveItems(_ items: [ClipboardItem]) {
        transaction { for i in items { _saveItem(i) } }
    }

    /// One transaction that makes the stored items match a change set.
    ///
    /// Deletions belong here rather than in a separate call: a save and the
    /// removals that go with it are one change to the library, and splitting
    /// them across two transactions leaves a window where the database holds a
    /// state the app was never in.
    func applyChanges(saving items: [ClipboardItem], deleting ids: [UUID]) {
        transaction {
            for item in items { _saveItem(item) }
            for id in ids { _ = _run("DELETE FROM items WHERE id = ?;", [id.uuidString]) }
        }
    }

    /// Makes the stored items exactly the given set, and reports how many rows
    /// were removed for not belonging.
    ///
    /// The caller cannot track this on its own, because it is not the only
    /// writer: `addVersion` inserts an item row so its foreign key has
    /// something to point at, which means rows can exist that the in-memory
    /// list never knew about. Reconciling against what the database actually
    /// holds cannot drift, whoever wrote it. It costs one query for the id
    /// column, which is nothing beside the whole-library rewrite this replaced.
    ///
    /// **M3.6 safety valve.** `keep` is built from whatever the caller
    /// currently holds in memory, which is usually `loadItems()`'s own
    /// output. A decoder regression that makes `loadItems()` return `[]`
    /// against a populated table used to reach here as "the user deleted
    /// everything" and tombstone every row - a transient decode bug becoming
    /// a permanent, server-propagated delete. Refuses instead when `keep` is
    /// empty against a non-empty table, or when what it would remove is more
    /// than `max(10, 5% of rows)`. A reconcile that IS going to remove real
    /// rows gets a backup first, so a wrong `keep` set stays recoverable.
    @discardableResult
    func reconcileItems(with keep: Set<UUID>) -> Int {
        guard !Self.migrationsFailedThisLaunch else { return 0 }

        let stored = query("SELECT id FROM items;").compactMap { row in
            (row["id"] as? String).flatMap(UUID.init(uuidString:))
        }
        let total = stored.count
        let toRemove = stored.filter { !keep.contains($0) }
        guard total > 0, !toRemove.isEmpty else { return 0 }

        let threshold = max(10, Int((Double(total) * 0.05).rounded(.up)))
        let looksLikeADecodeCollapse = keep.isEmpty
        if looksLikeADecodeCollapse || toRemove.count > threshold {
            DispatchQueue.main.async {
                NoticeCenter.shared.report(.reconcileRefused(unreadable: toRemove.count, total: total))
            }
            return 0
        }

        snapshotBackup(tag: "prereconcile")

        var removed = 0
        transaction {
            for id in toRemove {
                _ = _run("DELETE FROM items WHERE id = ?;", [id.uuidString])
                // Tombstoned, for the same reason a trim is: a row that
                // disappears here is gone locally and still alive on the
                // server, so without this it is pulled back on the next full
                // sync and the counts never converge.
                _recordTombstone(id)
                removed += 1
            }
        }
        return removed
    }

    #if CLIP_TESTING
    /// One-shot test hook: the next `loadItems()` returns `[]` regardless of
    /// what the table holds, standing in for a decoder regression that fails
    /// to read every row - without actually corrupting anything.
    static var forceEmptyLoadOnceForTesting = false
    #endif

    func loadItems() -> [ClipboardItem] {
        #if CLIP_TESTING
        if Self.forceEmptyLoadOnceForTesting {
            Self.forceEmptyLoadOnceForTesting = false
            return []
        }
        #endif
        return query("SELECT payload FROM items ORDER BY timestamp DESC;").compactMap { row in
            guard let json = row["payload"] as? String, let data = json.data(using: .utf8) else { return nil }
            return try? Self.decoder.decode(ClipboardItem.self, from: data)
        }
    }

    func deleteItem(_ id: UUID) {
        run("DELETE FROM items WHERE id = ?;", [id.uuidString])
    }

    func deleteAllItems() {
        exec("DELETE FROM items;")
    }

    // MARK: Tombstones

    /// Remembers that an item was deleted, so sync can pass it on.
    ///
    /// `OR IGNORE`, not `OR REPLACE`: a deletion happened once, at one moment,
    /// and that moment must not move. Refreshing the time made the tombstone look
    /// newer than the copy the server already had, so the server accepted it
    /// again, gave it a new sequence number, and handed it back on the next pull
    /// - every sync moving the same twenty-seven rows for ever while reporting
    /// that it had done work.
    func recordTombstone(_ id: UUID) {
        run("INSERT OR IGNORE INTO tombstones (id, deleted_at) VALUES (?, ?);",
            [id.uuidString, Date().timeIntervalSince1970])
    }

    /// The same write, for callers already inside a transaction.
    ///
    /// `run` takes the queue, and `reconcileItems` is already holding it - so
    /// calling the public version from in there would deadlock rather than
    /// record anything.
    private func _recordTombstone(_ id: UUID) {
        _ = _run("INSERT OR IGNORE INTO tombstones (id, deleted_at) VALUES (?, ?);",
                 [id.uuidString, Date().timeIntervalSince1970])
    }

    /// Every deletion still worth telling other Macs about.
    func tombstones() -> [(id: UUID, deletedAt: Date)] {
        query("SELECT id, deleted_at FROM tombstones ORDER BY deleted_at;").compactMap { row in
            guard let raw = row["id"] as? String, let id = UUID(uuidString: raw) else { return nil }
            let when = (row["deleted_at"] as? Double) ?? 0
            return (id: id, deletedAt: Date(timeIntervalSince1970: when))
        }
    }

    /// Forgets deletions older than the grace period.
    ///
    /// Kept for a month rather than dropped on the first successful sync: a Mac
    /// that was switched off for a fortnight still has to learn what went, and a
    /// tombstone it never received is an item that quietly comes back.
    func pruneTombstones(olderThan days: Double = 30) {
        run("DELETE FROM tombstones WHERE deleted_at < ?;",
            [Date().addingTimeInterval(-days * 86400).timeIntervalSince1970])
        // Trim the local-only registry to match: an id whose tombstone row is
        // gone can never be looked up again, so keeping it here for ever would
        // only be a slow leak with no reader left.
        let remaining = Set(tombstones().map { $0.id.uuidString })
        let trimmed = localOnlyTombstoneIDs.intersection(remaining)
        if trimmed.count != localOnlyTombstoneIDs.count {
            setPreference("sync.localOnlyTombstones", trimmed.sorted().joined(separator: ","))
        }
    }

    // MARK: Local-only tombstones

    /// A deletion tombstone for an item that was `isLocalOnly` (image, video,
    /// file, folder - anything that names a path specific to this Mac).
    ///
    /// The item behind this id was never pushed in the first place (M5
    /// REVISED: file-backed clips are local-only), so a deletion of it is not
    /// news anywhere else - the other Macs never heard of it to begin with.
    /// `tombstones()` cannot say this on its own: by the time a deletion is
    /// recorded the item is already gone, and its kind with it. This small
    /// side table is the only place that memory survives to push time.
    func markLocalOnlyTombstone(_ id: UUID) {
        var ids = localOnlyTombstoneIDs
        ids.insert(id.uuidString)
        setPreference("sync.localOnlyTombstones", ids.sorted().joined(separator: ","))
    }

    func isLocalOnlyTombstone(_ id: UUID) -> Bool {
        localOnlyTombstoneIDs.contains(id.uuidString)
    }

    private var localOnlyTombstoneIDs: Set<String> {
        let raw = preference("sync.localOnlyTombstones") ?? ""
        return Set(raw.split(separator: ",").map(String.init))
    }

    // MARK: Versions

    /// Records a version. Skips a write when the body is identical to the most
    /// recent one, so re-saving without editing doesn't pile up duplicates.
    /// Records a version, writing the parent item row first.
    ///
    /// `item_versions.item_id` is a foreign key into `items`. Item saves are
    /// debounced, so without this the row would not exist yet and SQLite would
    /// silently reject every version of a newly captured or created item.
    func addVersion(for item: ClipboardItem, body: String, title: String?, note: String) {
        transaction {
            // The duplicate check has to happen inside the same transaction, or
            // two quick edits can both see "no latest" and write twice.
            let latest = _query("""
                SELECT body FROM item_versions WHERE item_id = ?
                ORDER BY created_at DESC, version_id DESC LIMIT 1;
                """, [item.id.uuidString]).first?["body"] as? String
            guard latest != body else { return }
            _saveItem(item)
            _run("INSERT INTO item_versions (item_id, body, title, note, created_at) VALUES (?,?,?,?,?);",
                 [item.id.uuidString, body, title, note, Date()])
        }
    }

    func versions(for itemID: UUID) -> [ItemVersion] {
        query("""
              SELECT version_id, body, title, note, created_at FROM item_versions
              WHERE item_id = ? ORDER BY created_at DESC, version_id DESC;
              """, [itemID.uuidString]).compactMap { row in
            guard let vid = row["version_id"] as? Int,
                  let body = row["body"] as? String,
                  let at = row["created_at"] as? Double else { return nil }
            return ItemVersion(id: vid, body: body,
                               title: row["title"] as? String,
                               note: row["note"] as? String ?? "",
                               createdAt: Date(timeIntervalSince1970: at))
        }
    }

    func versionCount(for itemID: UUID) -> Int {
        (query("SELECT COUNT(*) AS n FROM item_versions WHERE item_id = ?;",
               [itemID.uuidString]).first?["n"] as? Int) ?? 0
    }

    /// Writes a revision back with the date it originally had.
    ///
    /// `addVersion` stamps `Date()` itself, which is right for an edit happening
    /// now and wrong for a restore: a backup replayed onto a clean Mac would show
    /// every past revision as having been made in the same second, and a revision
    /// list whose dates are fiction is worse than no revision list.
    ///
    /// De-duplicated on the exact triple rather than on "is this the newest
    /// body", because a restore replays revisions in an order `addVersion`'s
    /// latest-body check was never designed for - restoring the same archive
    /// twice would otherwise double every revision.
    ///
    /// Returns true when a row was actually inserted.
    @discardableResult
    func restoreVersion(itemID: UUID, body: String, title: String?, note: String,
                        createdAt: Date) -> Bool {
        var inserted = false
        transaction {
            let existing = _query("""
                SELECT version_id FROM item_versions
                WHERE item_id = ? AND body = ? AND created_at = ? LIMIT 1;
                """, [itemID.uuidString, body, createdAt]).first
            guard existing == nil else { return }
            _run("INSERT INTO item_versions (item_id, body, title, note, created_at) VALUES (?,?,?,?,?);",
                 [itemID.uuidString, body, title, note, createdAt])
            inserted = true
        }
        return inserted
    }

    // MARK: Preferences and log

    func setPreference(_ key: String, _ value: String) {
        run("INSERT INTO preferences (key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
            [key, value])
    }

    func preference(_ key: String) -> String? {
        query("SELECT value FROM preferences WHERE key = ?;", [key]).first?["value"] as? String
    }

    func log(_ category: String, _ message: String) {
        transaction {
            _run("INSERT INTO activity_log (at, category, message) VALUES (?,?,?);",
                 [Date(), category, message])
            // Keep the log bounded; it is a diagnostic aid, not an archive.
            _exec("DELETE FROM activity_log WHERE log_id NOT IN (SELECT log_id FROM activity_log ORDER BY at DESC LIMIT 2000);")
        }
    }

    func recentLog(limit: Int = 200) -> [(Date, String, String)] {
        query("SELECT at, category, message FROM activity_log ORDER BY at DESC LIMIT ?;", [limit])
            .compactMap { row in
                guard let at = row["at"] as? Double,
                      let c = row["category"] as? String,
                      let m = row["message"] as? String else { return nil }
                return (Date(timeIntervalSince1970: at), c, m)
            }
    }
}

#if CLIP_TESTING
extension Database {
    /// Drives a real, deliberately invalid statement through `_exec` on the
    /// database's own queue, so a probe can prove `.writeFailed` notices are
    /// produced by an actual SQLite failure rather than by a stubbed path.
    func forceWriteFailureForTesting() {
        _ = exec("INSERT INTO this_table_does_not_exist_at_all (x) VALUES (1);")
    }

    /// Lets a probe run the next write-failure episode from a clean count, so
    /// "logged once per episode" can be tested more than once in one launch.
    func resetWriteFailureCountForTesting() { writeFailureCount = 0 }
}
#endif

/// One saved revision of an item's text.
struct ItemVersion: Identifiable, Equatable {
    let id: Int
    let body: String
    let title: String?
    let note: String
    let createdAt: Date

    var preview: String {
        let t = body.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 90 ? String(t.prefix(90)) + "…" : t
    }
}
