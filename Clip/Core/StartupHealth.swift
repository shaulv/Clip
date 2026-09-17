import Foundation
import AppKit

/// Runs once per launch, between `AppPaths.secureStorage()` and
/// `Migration.runIfNeeded()`, and answers one question before anything else
/// touches the user's data: is this install, and this update, safe to use.
///
/// Version stamp, pre-upgrade backup, schema migrations, the data-directory
/// audit - all of it lands here as one list of `Finding`s, which both
/// `NoticeCenter` (so the person sees it) and the Diagnostics window (so it
/// is not forgotten the moment the notice expires) read from.
@MainActor
enum StartupHealth {

    struct Finding {
        enum Severity: String { case info, fixed, warning, integrity }
        let severity: Severity
        let title: String
        let detail: String
        let remedy: String?
        let action: NoticeCenter.Action?
    }

    /// What the most recent run found, for `DiagnosticsReport` and the probe.
    private(set) static var lastFindings: [Finding] = []
    /// How long `run()` took, in milliseconds - the startup cost budget this
    /// milestone is measured against.
    private(set) static var lastRunMilliseconds: Double = 0

    static let versionPreferenceKey = "app.lastRunVersion"
    static let versionDefaultsKey = "lastRunVersion"
    static let installStampPreferenceKey = "app.lastInstallStamp"
    static let installStampDefaultsKey = "lastInstallStamp"
    private static let lastBackupDayKey = "app.lastBackupDay"

    #if CLIP_TESTING
    /// Stands in for `CFBundleShortVersionString`/`CFBundleVersion`, so a
    /// probe can force a version change without rebuilding the app.
    static var versionOverrideForTesting: String?
    /// Stands in for the bundle/executable install stamp, so a probe can
    /// simulate a reinstall without replacing the binary on disk.
    static var installStampOverrideForTesting: String?
    #endif

    /// A finding raised after `run()` already returned - used by
    /// `Migration.runIfNeeded()`, which runs after this by design (3.1) but
    /// whose own summary still belongs in the same Diagnostics list.
    static func recordAdditionalFinding(_ finding: Finding) {
        lastFindings.append(finding)
    }

    @discardableResult
    static func run() -> [Finding] {
        let start = Date()
        var findings: [Finding] = []
        var fixedCount = 0

        let (short, currentStamp) = currentVersion()
        let previousStamp = Database.shared.preference(versionPreferenceKey)
            ?? AppPaths.defaults.string(forKey: versionDefaultsKey)
        let isVersionChange = previousStamp != nil && previousStamp != currentStamp

        let currentInstall = currentInstallStamp()
        let previousInstall = Database.shared.preference(installStampPreferenceKey)
            ?? AppPaths.defaults.string(forKey: installStampDefaultsKey)
        let isReinstall = previousInstall != nil && previousInstall != currentInstall

        // 3.3: one backup per calendar day, independent of whether the
        // version changed - the daily habit that makes "restore to yesterday"
        // possible even between updates.
        if shouldBackupToday() {
            if Database.shared.snapshotBackup(tag: "daily") != nil {
                fixedCount += 1
            } else {
                // Used to fall straight through to markBackedUpToday(): a
                // failed daily backup was indistinguishable from a
                // successful one, and the day's only attempt was gone until
                // tomorrow with nobody told.
                findings.append(Finding(
                    severity: .warning, title: "Could not make today's backup",
                    detail: "Today's automatic backup did not complete.",
                    remedy: "Clip will try again tomorrow. A manual backup is available in Settings.",
                    action: nil))
            }
            markBackedUpToday()
        }

        // M8.2: "each time we install clip, make sure to delete the last
        // accessibility entry so you refresh it to the new code." Only when
        // the grant is not already working: resetting one that already
        // works would make someone answer the system prompt again for
        // nothing, and `package.sh --install` already does this same reset
        // for a fresh install from the DMG - this covers whoever updates
        // some other way or reinstalls the same version.
        if (isVersionChange || isReinstall), !AccessibilityGate.isTrusted {
            AccessibilityGate.resetAndAskAgainOnVersionChange()
        }

        // 3.3: a pre-upgrade backup runs BEFORE 3.4's migrations, so a
        // migration that turns out to be wrong is still a restore away.
        if isVersionChange {
            if let url = Database.shared.snapshotBackup(tag: "preupgrade-\(sanitizedTag(previousStamp ?? "unknown"))") {
                fixedCount += 1
                findings.append(Finding(
                    severity: .fixed, title: "Backed up before updating",
                    detail: "\(url.lastPathComponent), before updating from \(previousStamp ?? "an earlier version") to \(short).",
                    remedy: nil, action: nil))
            } else {
                findings.append(Finding(
                    severity: .warning, title: "Could not back up before updating",
                    detail: "Continuing the update without a pre-upgrade backup.",
                    remedy: "A restore point from just before this update will not exist.",
                    action: nil))
            }
        }

        // 3.4: schema migrations, attempted every launch (a no-op when
        // nothing is pending).
        let migrationOutcome = Database.shared.runMigrations()
        switch migrationOutcome {
        case .upToDate:
            break
        case .migrated(let steps) where steps > 0:
            fixedCount += 1
            findings.append(Finding(
                severity: .fixed, title: "Database schema updated",
                detail: "Applied \(steps) update\(steps == 1 ? "" : "s").",
                remedy: nil, action: nil))
        case .migrated:
            break
        case .failed(let step, let detail):
            findings.append(Finding(
                severity: .integrity, title: "A database update failed",
                detail: "Step \(step) could not be applied: \(detail).",
                remedy: "Your data was not changed; the reconcile that trims deleted items is paused until this is resolved.",
                action: NoticeCenter.Action(title: "Restore backup…") { presentRestorePicker() }))
        }

        // 3.2: stamp both stores, but only once a migration failure has not
        // left the schema in between two versions.
        if !migrationOutcome.isFailure {
            Database.shared.setPreference(versionPreferenceKey, currentStamp)
            Database.shared.setPreference(installStampPreferenceKey, currentInstall)
            AppPaths.defaults.set(currentStamp, forKey: versionDefaultsKey)
            AppPaths.defaults.set(currentInstall, forKey: installStampDefaultsKey)
        }

        // 3.8: a directory or permission failure captured while
        // `AppPaths.secureStorage()` ran, just before this.
        if let dirError = AppPaths.lastDirectoryError {
            findings.append(Finding(
                severity: .integrity, title: "Clip's data folder could not be created",
                detail: "\(dirError.path): \(dirError.detail).",
                remedy: "Clip cannot store anything until this folder can be created.",
                action: NoticeCenter.Action(title: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: dirError.path).deletingLastPathComponent()])
                }))
        }
        if let permError = AppPaths.lastPermissionError {
            findings.append(Finding(
                severity: .warning, title: "Could not lock down a data file",
                detail: "\(permError.path): \(permError.detail).",
                remedy: "Other users on this Mac may be able to read it.",
                action: NoticeCenter.Action(title: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: permError.path)])
                }))
        }

        // 3.7: report only at launch - never move anything without the
        // person asking, EXCEPT the one category below that is not a file to
        // reclaim at all.
        let audit = AppPaths.audit()

        // M5 REVISED (02/09 user decision): file-backed clips are
        // local-only, so an item whose image is missing is not "a clip
        // waiting to be fetched from sync" any more - there is no sync copy
        // to fetch, because the bytes were never pushed. The original still
        // exists on whatever Mac actually copied it; THIS Mac's pointer to
        // it is simply dead, and removing it here carries no tombstone -
        // tombstoning it would tell that other Mac to delete the item it
        // still legitimately has.
        let dangling = audit.filter { $0.category == .degradedMedia }
        if !dangling.isEmpty {
            let ids = dangling.compactMap {
                UUID(uuidString: $0.id.replacingOccurrences(of: "item-media-", with: ""))
            }
            // WITH a tombstone (02/09, user): the broken clip is deleted on
            // every Mac and on the server, not only here.
            for id in ids { HistoryStore.shared.delete(id, recordDeletion: true) }
            let count = ids.count
            let verb = count == 1 ? "was" : "were"
            let noun = count == 1 ? "clip" : "clips"
            let message = "\(count) \(noun) whose image was no longer on this Mac \(verb) removed."
            findings.append(Finding(
                severity: .fixed,
                title: "Removed clips with missing images",
                detail: message, remedy: nil, action: nil))
            NoticeCenter.shared.report(message, kind: .transient, key: "startup.health.danglingImagesRemoved")
        }
        // Reclaimable old files are listed in Settings > Privacy > Storage
        // and in Diagnostics. They are not announced at launch: the user
        // asked for that banner to go (02/09), and a superseded install is
        // housekeeping, not a condition anyone must act on.
        _ = audit.filter { $0.category != .degradedMedia }

        lastFindings = findings

        // Every finding goes to NoticeCenter: fixed findings are summarised
        // into ONE transient line rather than one notice per tidy-up, so a
        // routine update does not read like a list of problems.
        if fixedCount > 0 {
            NoticeCenter.shared.report(
                "Clip updated to \(short) and checked its data: \(fixedCount) thing\(fixedCount == 1 ? "" : "s") tidied.",
                kind: .transient, key: "startup.health.fixed")
        }
        for finding in findings where finding.severity == .warning {
            NoticeCenter.shared.report(
                "\(finding.title). \(finding.detail)", remedy: finding.remedy,
                kind: .persistent, key: "startup.health.\(finding.title)", action: finding.action)
        }
        for finding in findings where finding.severity == .integrity {
            NoticeCenter.shared.report(
                "\(finding.title). \(finding.detail)", remedy: finding.remedy,
                kind: .integrity, key: "startup.health.\(finding.title)", action: finding.action)
        }

        // M28: the keys survived a reinstall and the connections did not.
        //
        // Hopped to the next main-loop turn rather than run inline, for two
        // reasons. It reads `AIService.shared`, whose `init` loads the
        // provider rows, and this method runs BEFORE `Migration.runIfNeeded()`
        // - forcing that load here would read the database a step early. And
        // the launch gate that skips the whole self-repair
        // (`!AIService.shared.providers.isEmpty || SyncManager.shared.space != nil`,
        // false on exactly the install this is for) has not run yet either.
        // By the next turn the boot is complete and both are settled.
        //
        // It only ever OFFERS. Nothing is read from the Keychain here.
        DispatchQueue.main.async { KeyRecovery.offerIfNeeded() }

        lastRunMilliseconds = Date().timeIntervalSince(start) * 1000
        Database.shared.log("startup",
            "Health check ran in \(String(format: "%.1f", lastRunMilliseconds)) ms, \(findings.count) finding(s)")
        return findings
    }

    // MARK: - Version

    private static func currentVersion() -> (short: String, stamp: String) {
        #if CLIP_TESTING
        if let override = versionOverrideForTesting {
            return (override, override)
        }
        #endif
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return (short, "\(short) (\(build))")
    }

    private static func currentInstallStamp() -> String {
        #if CLIP_TESTING
        if let override = installStampOverrideForTesting {
            return override
        }
        #endif
        if let execURL = Bundle.main.executableURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
           let mod = attrs[.modificationDate] as? Date {
            return String(format: "%.0f", mod.timeIntervalSince1970)
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: Bundle.main.bundlePath),
           let mod = attrs[.modificationDate] as? Date {
            return String(format: "%.0f", mod.timeIntervalSince1970)
        }
        return "0"
    }

    private static func sanitizedTag(_ raw: String) -> String {
        // A backup's filename carries this tag; punctuation from a version
        // stamp like "2.0 (14)" would otherwise land inside a path.
        raw.map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
    }

    // MARK: - Daily backup

    private static func todayStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }

    private static func shouldBackupToday() -> Bool {
        Database.shared.preference(lastBackupDayKey) != todayStamp()
    }

    private static func markBackedUpToday() {
        Database.shared.setPreference(lastBackupDayKey, todayStamp())
    }

    // MARK: - Manual restore

    /// The file picker behind "Restore backup…" - the one action every
    /// `.integrity` database notice offers when no backup could be restored
    /// automatically.
    static func presentRestorePicker() {
        let panel = NSOpenPanel()
        panel.title = "Restore Clip's database from a backup"
        panel.message = "Choose a clip.sqlite.backup-* file."
        panel.directoryURL = AppPaths.support
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let chosen = panel.urls.first else { return }
        if Database.shared.restore(from: chosen) {
            NoticeCenter.shared.resolve("db.corrupt")
            NoticeCenter.shared.resolve("db.open")
            NoticeCenter.shared.report(
                "Clip's database was restored from \(chosen.lastPathComponent).", kind: .transient)
        }
        // A failed restore already reported `.restoreFailed` from inside
        // `Database.restore(from:)` itself.
    }
}
