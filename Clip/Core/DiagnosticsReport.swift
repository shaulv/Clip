import Foundation
import AppKit

/// One copyable text about the app's own health, for a person or a developer
/// looking AFTER the fact. Before this the only place an error lived after
/// its notice expired was a SQLite table nobody could open from the app.
@MainActor
enum DiagnosticsReport {

    static func full() -> String {
        var out: [String] = []
        let info = Bundle.main.infoDictionary ?? [:]
        out.append("Clip \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))  "
                   + "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        out.append("Report made \(stamp(Date()))")
        out.append("")

        out.append("== Insights ==")
        for insight in DiagnosticsInsights.all() {
            out.append("  " + insight.reportLine)
        }
        out.append("")

        out.append("== Open notices ==")
        let pending = NoticeCenter.shared.pending
        if pending.isEmpty { out.append("  none") }
        for n in pending {
            out.append("  [\(n.kind.rawValue)] \(n.message)")
            if let r = n.remedy { out.append("      \(r)") }
            if let a = n.action { out.append("      action: \(a.title)") }
        }
        out.append("")

        out.append("== Menu bar ==")
        out.append("  crowding: \(AppDelegate.lastCrowdingReport)")
        out.append("")

        out.append("== Storage ==")
        out.append(storage())
        out.append("")

        out.append("== Startup health ==")
        out.append(startupHealth())
        out.append("")

        out.append("== Keychain ==")
        out.append(keychain())
        out.append("")

        out.append("== Sync ==")
        out.append("  state: \(String(describing: SyncManager.shared.syncState))")
        if let e = SyncManager.shared.lastError { out.append("  last error: \(e)") }
        out.append("")

        out.append("== AI connections ==")
        let providers = AIService.shared.providers
        if providers.isEmpty { out.append("  none") }
        for p in providers {
            out.append("  \(p.name): model \(p.model)"
                       + (p.lastError.map { "  last error: \($0)" } ?? ""))
        }
        out.append("")

        out.append("== Shortcuts ==")
        out.append(ShortcutManager.shared.diagnosticReport(items: HistoryStore.shared.items)
                    .split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
        out.append("")

        out.append("== Activity log (newest first, 200) ==")
        for (at, category, message) in Database.shared.recentLog(limit: 200) {
            out.append("  \(stamp(at))  \(category): \(message)")
        }
        return out.joined(separator: "\n")
    }

    static func storage() -> String {
        var out: [String] = []
        let fm = FileManager.default
        func line(_ label: String, _ url: URL) {
            let exists = fm.fileExists(atPath: url.path)
            var size = ""
            var mode = ""
            if exists, let attrs = try? fm.attributesOfItem(atPath: url.path) {
                if let n = attrs[.size] as? NSNumber { size = "  \(ByteCountFormatter.string(fromByteCount: n.int64Value, countStyle: .file))" }
                if let m = attrs[.posixPermissions] as? NSNumber { mode = "  mode \(String(m.intValue, radix: 8))" }
            }
            out.append("  \(label): \(url.path)\(exists ? "" : "  (missing)")\(size)\(mode)")
        }
        line("data folder", AppPaths.support)
        line("database", AppPaths.database)
        line("media", AppPaths.media)
        out.append("  database open: \(Database.shared.isOpen ? "yes" : "no")")
        out.append("  integrity: \(Database.shared.lastIntegrityResult)")
        return out.joined(separator: "\n")
    }

    static func startupHealth() -> String {
        var out: [String] = []
        out.append("  last check: \(String(format: "%.1f", StartupHealth.lastRunMilliseconds)) ms")
        let findings = StartupHealth.lastFindings
        if findings.isEmpty { out.append("  no findings") }
        for f in findings {
            out.append("  [\(f.severity.rawValue)] \(f.title): \(f.detail)")
            if let r = f.remedy { out.append("      \(r)") }
        }
        return out.joined(separator: "\n")
    }

    static func keychain() -> String {
        var out: [String] = []
        out.append("  service: \(AppPaths.keychainService)")
        out.append("  last read status: \(KeychainStore.lastReadStatus)")
        out.append("  needs repair: \(KeychainStore.needsRepair ? "yes" : "no")")
        // M28: whether keys are sitting here that no connection is using -
        // the reinstall case. Read without interaction, so opening
        // Diagnostics can never raise a Keychain prompt.
        switch KeyRecovery.scan() {
        case .nothingStored:
            out.append("  recoverable keys: none stored")
        case .readable(let accounts):
            let unconfigured = KeyRecovery.recoverable(in: KeychainStore.allStoredSecrets().accounts)
            out.append("  recoverable keys: \(accounts.count) stored, "
                     + "\(unconfigured.count) not yet set up as a connection")
        case .lockedButPresent:
            out.append("  recoverable keys: stored, but not readable without one authorization")
        }
        return out.joined(separator: "\n")
    }

    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy HH:mm:ss"
        f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
        return f.string(from: d)
    }
}
