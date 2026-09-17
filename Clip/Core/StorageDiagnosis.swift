import Foundation
import SQLite3

/// What can go wrong between the app and its own files.
///
/// The storage layer had no sentence to say, which is why it said nothing:
/// fifty `guard … else { return }` and `try?` sites on user-triggered paths
/// failed into silence, and the person saw an app that accepted the action
/// and forgot it. `AIDiagnosis` is the model: a coarse classification, each
/// case naming the action that resolves it.
enum StorageFailure {
    case cannotOpenDatabase(path: String, code: Int32)
    case databaseCorrupt(path: String, detail: String)
    case writeFailed(code: Int32, detail: String)
    case migrationFailed(step: String, detail: String)
    case backupFailed(detail: String)
    case restoreFailed(detail: String)
    case reconcileRefused(unreadable: Int, total: Int)
    case directoryUnwritable(path: String, detail: String)
    case permissionsNotApplied(path: String)
    case mediaMissing(file: String)
    case mediaSaveFailed(detail: String)
    case mediaRemoveFailed(count: Int)
    case decodeFailed(entity: String, count: Int)
    case saveFailed(entity: String, detail: String)
    case exportWriteFailed(path: String, detail: String)
    case unsavedAtQuit(path: String)
}

enum StorageDiagnosis {

    struct Reading {
        let message: String
        let remedy: String?
        let kind: NoticeCenter.Kind
        /// Stable per condition, so the same failure reported twice replaces
        /// itself and the owner can `resolve` it.
        let key: String
        let action: NoticeCenter.Action?
    }

    static func read(_ failure: StorageFailure) -> Reading {
        switch failure {
        case .cannotOpenDatabase(let path, let code):
            return Reading(
                message: "Clip could not open its database, so nothing copied now will be kept.",
                remedy: "\(sqliteWords(code)). The file is at \(path).",
                kind: .integrity, key: "db.open", action: revealAction(path))
        case .databaseCorrupt(let path, let detail):
            return Reading(
                message: "Clip's database is damaged and was set aside.",
                remedy: "A backup was restored if one existed. \(detail) The damaged file is kept beside it at \(path).",
                kind: .integrity, key: "db.corrupt", action: revealAction(path))
        case .writeFailed(let code, let detail):
            return Reading(
                message: "Clip could not save to its database.",
                remedy: "\(sqliteWords(code)). \(detail)",
                kind: .persistent, key: "db.write", action: nil)
        case .migrationFailed(let step, let detail):
            return Reading(
                message: "Clip could not update its database for this version (\(step)).",
                remedy: "Your data was not changed. \(detail)",
                kind: .integrity, key: "db.migration", action: nil)
        case .backupFailed(let detail):
            return Reading(
                message: "Clip could not write a backup of its database.",
                remedy: detail, kind: .persistent, key: "db.backup", action: nil)
        case .restoreFailed(let detail):
            return Reading(
                message: "Clip could not restore the database from a backup.",
                remedy: detail, kind: .integrity, key: "db.restore", action: nil)
        case .reconcileRefused(let unreadable, let total):
            return Reading(
                message: "\(unreadable) of \(total) items could not be read. They were not deleted.",
                remedy: "They are kept in the database untouched. Open Diagnostics to see them.",
                kind: .integrity, key: "db.reconcile", action: nil)
        case .directoryUnwritable(let path, let detail):
            return Reading(
                message: "Clip cannot write to its data folder.",
                remedy: "\(detail) The folder is \(path).",
                kind: .integrity, key: "fs.directory", action: revealAction(path))
        case .permissionsNotApplied(let path):
            return Reading(
                message: "Clip could not lock down its data folder.",
                remedy: "Other users on this Mac may be able to read \(path).",
                kind: .persistent, key: "fs.permissions", action: revealAction(path))
        case .mediaMissing(let file):
            return Reading(
                message: "That image is no longer on disk.",
                remedy: "Its title was pasted instead. The file was \(file).",
                kind: .transient, key: "media.missing.\(file)", action: nil)
        case .mediaSaveFailed(let detail):
            return Reading(
                message: "Clip could not save a copied image.",
                remedy: "Text is still being kept. \(detail)",
                kind: .persistent, key: "media.save", action: nil)
        case .mediaRemoveFailed(let count):
            return Reading(
                message: "\(count) image file\(count == 1 ? "" : "s") could not be removed.",
                remedy: "They are still in Clip's Media folder.",
                kind: .persistent, key: "media.remove", action: revealAction(AppPaths.media.path))
        case .decodeFailed(let entity, let count):
            return Reading(
                message: "\(count) \(entity)\(count == 1 ? "" : "s") could not be read and \(count == 1 ? "was" : "were") left aside.",
                remedy: "Everything else loaded. Nothing was deleted.",
                kind: .persistent, key: "decode.\(entity)", action: nil)
        case .saveFailed(let entity, let detail):
            return Reading(
                message: "Your \(entity) change could not be saved.",
                remedy: detail, kind: .transient, key: "save.\(entity)", action: nil)
        case .exportWriteFailed(let path, let detail):
            return Reading(
                message: "Could not write \(URL(fileURLWithPath: path).lastPathComponent).",
                remedy: detail, kind: .transient, key: "export.write", action: nil)
        case .unsavedAtQuit(let path):
            return Reading(
                message: "Some clips could not be saved when Clip last quit.",
                remedy: "They were kept in a file and can be imported from Settings > Export.",
                kind: .integrity, key: "db.unsaved", action: revealAction(path))
        }
    }

    /// The SQLite result code in words a person can act on.
    static func sqliteWords(_ code: Int32) -> String {
        switch code & 0xff {
        case SQLITE_FULL: return "The disk is full"
        case SQLITE_READONLY: return "The database is read-only"
        case SQLITE_BUSY, SQLITE_LOCKED: return "Another process is holding the database"
        case SQLITE_CORRUPT, SQLITE_NOTADB: return "The database file is damaged"
        case SQLITE_PERM, SQLITE_AUTH: return "Clip does not have permission to use the file"
        case SQLITE_CANTOPEN: return "The file could not be opened"
        case SQLITE_IOERR: return "The disk reported an error"
        case SQLITE_NOMEM: return "The Mac ran out of memory"
        default: return "SQLite reported error \(code)"
        }
    }

    private static func revealAction(_ path: String) -> NoticeCenter.Action {
        NoticeCenter.Action(title: "Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }
}

import AppKit
