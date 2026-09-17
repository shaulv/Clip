import XCTest
import SQLite3
@testable import Clip

/// The schema-migration ladder: `PRAGMA user_version` should only ever move
/// forward, a step that fails must roll back completely rather than leave a
/// half-applied schema, and a launch that already sits on the newest version
/// must be a true no-op.
///
/// Runs against `Database.shared`, which under `CLIP_QA_SANDBOX=1` (set on
/// the test host by the Clip.xcscheme Test action - see AppPaths.swift) opens
/// a throwaway sandbox database, never the user's real
/// ~/Library/Application Support/Clip/clip.sqlite.
final class DatabaseMigrationTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(AppPaths.isSandboxed,
                          "must run with CLIP_QA_SANDBOX=1 - see Clip.xcscheme's Test action")
    }

    func test_database_isOpen_inTheSandbox() {
        XCTAssertTrue(Database.shared.isOpen)
        // Belt and suspenders on the "no real user data" requirement: the
        // sandbox directory name must never be the production one.
        XCTAssertNotEqual(Database.shared.url.deletingLastPathComponent().lastPathComponent, "Clip")
    }

    func test_runningMigrationsTwice_onAnUpToDateSchema_isANoOp() {
        // The app (as test host) already ran migrations once at launch, so
        // this call has nothing pending - proves migrations do not reapply.
        let outcome = Database.shared.runMigrations()
        XCTAssertEqual(outcome, .upToDate)
    }

    func test_aFailingMigrationStep_rollsBack_andReportsFailure() {
        let versionBefore = currentSchemaVersion()

        Database.forceMigrationFailureForTesting = true
        defer { Database.forceMigrationFailureForTesting = false }

        let outcome = Database.shared.runMigrations()

        guard case .failed(let step, _) = outcome else {
            XCTFail("expected .failed, got \(outcome)")
            return
        }
        XCTAssertEqual(step, 2)
        // The whole point of the transaction-per-step design: a failed step
        // must leave user_version exactly where it started.
        XCTAssertEqual(currentSchemaVersion(), versionBefore)
    }

    func test_afterAFailedMigration_theNextCleanRun_stillReportsUpToDate() {
        Database.forceMigrationFailureForTesting = true
        _ = Database.shared.runMigrations()
        Database.forceMigrationFailureForTesting = false

        // With the bad step removed from the ladder again, there is nothing
        // above the current (unmoved) version left to apply.
        XCTAssertEqual(Database.shared.runMigrations(), .upToDate)
    }

    private func currentSchemaVersion() -> Int {
        // PRAGMA user_version is exactly what runMigrations reads and
        // advances; going through the public query surface here would just
        // reimplement runMigrations, so this reaches the same PRAGMA by hand.
        var db: OpaquePointer?
        sqlite3_open_v2(Database.shared.url.path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int(stmt, 0))
    }
}
