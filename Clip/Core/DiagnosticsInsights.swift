import Foundation

/// One line per subsystem, in plain language, with the action that fixes it
/// when something needs fixing.
///
/// "diagnosis will give report for AI and developer or any human for
/// diagnosis and provide insights like what is connected and what fails and
/// what actions we can take." This is that summary - the first thing
/// `DiagnosticsView` shows and the first block `DiagnosticsReport.full()`
/// prints, before either gets to the raw per-subsystem dump. Every sentence
/// is cause and effect, never a bare code: `StorageDiagnosis.sqliteWords`
/// and the wording already used by `AIDiagnosis`/provider errors are reused
/// rather than re-invented here.
@MainActor
enum DiagnosticsInsights {

    enum Level {
        case ok, warning, danger

        var symbol: String {
            switch self {
            case .ok:      return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger:  return "xmark.octagon.fill"
            }
        }
    }

    struct Insight: Identifiable {
        let id: String
        let subsystem: String
        let level: Level
        let sentence: String
        let actionTitle: String?
        let action: (@MainActor () -> Void)?

        /// The text-report line: the sentence, plus what to do about it.
        var reportLine: String {
            "\(subsystem): \(sentence)" + (actionTitle.map { "  Action: \($0)" } ?? "")
        }
    }

    static func all() -> [Insight] {
        [accessibility(), pasteAndShortcuts(), ai(), sync(), keychain(), storage(), startupHealth()]
    }

    // MARK: - Accessibility

    private static func accessibility() -> Insight {
        guard AccessibilityGate.isTrusted else {
            return Insight(
                id: "accessibility", subsystem: "Accessibility", level: .danger,
                sentence: "Not granted yet. Clip can't paste until you turn this on. If System "
                        + "Settings already shows Clip switched on, that grant belongs to an "
                        + "older build of Clip.",
                actionTitle: "Reset Permission",
                action: { AccessibilityGate.resetAndAskAgain() })
        }
        return Insight(id: "accessibility", subsystem: "Accessibility", level: .ok,
                       sentence: "granted, shortcuts and the panel's own paste can reach other apps.",
                       actionTitle: nil, action: nil)
    }

    // MARK: - Paste and shortcuts

    private static func pasteAndShortcuts() -> Insight {
        let items = HistoryStore.shared.items
        let diagnostics = ShortcutManager.shared.itemDiagnostics
        let bound = diagnostics.count
        let refusedIDs = Set(diagnostics.filter { $0.value.registeredAt == nil }.keys)
        let refusedNames = items.filter { refusedIDs.contains($0.id) }.map(\.displayTitle)

        var sentence = bound == 0
            ? "no item has a shortcut assigned."
            : "\(bound - refusedNames.count) of \(bound) item shortcut\(bound == 1 ? "" : "s") registered"
        if !refusedNames.isEmpty {
            sentence += ", \(refusedNames.count) refused by macOS (\(refusedNames.joined(separator: ", ")))"
        }
        if bound > 0 { sentence += "." }
        sentence += " Last paste keystroke: \(PasteKeystroke.lastOutcome)."

        return Insight(
            id: "shortcuts", subsystem: "Paste and shortcuts",
            level: refusedNames.isEmpty ? .ok : .warning,
            sentence: sentence, actionTitle: "Open Shortcuts",
            action: { SettingsWindowController.shared.show(tab: .shortcuts) })
    }

    // MARK: - AI

    private static func ai() -> Insight {
        let providers = AIService.shared.providers
        guard !providers.isEmpty else {
            return Insight(id: "ai", subsystem: "AI", level: .ok,
                           sentence: "no connections configured.", actionTitle: nil, action: nil)
        }
        var parts: [String] = []
        var needsRepair = false
        var hasFailure = false
        for p in providers {
            if KeychainStore.needsRepairAccounts.contains(p.keychainAccount) {
                parts.append("\(p.name): key unreadable"); needsRepair = true
            } else if let err = p.lastError, !err.isEmpty {
                parts.append("\(p.name): \(err)"); hasFailure = true
            } else if p.isValidated {
                parts.append("\(p.name): validated")
            } else {
                parts.append("\(p.name): untested")
            }
        }
        let sentence = "\(providers.count) connection\(providers.count == 1 ? "" : "s") - "
                     + parts.joined(separator: "; ")
        let level: Level = needsRepair ? .danger : (hasFailure ? .warning : .ok)
        if needsRepair {
            return Insight(id: "ai", subsystem: "AI", level: level, sentence: sentence,
                           actionTitle: "Repair AI Key Access",
                           action: { AppDelegate.shared?.repairKeychainAccess() })
        }
        if hasFailure {
            return Insight(id: "ai", subsystem: "AI", level: level, sentence: sentence,
                           actionTitle: "Open AI Settings",
                           action: { SettingsWindowController.shared.show(tab: .ai) })
        }
        return Insight(id: "ai", subsystem: "AI", level: level, sentence: sentence,
                       actionTitle: nil, action: nil)
    }

    // MARK: - Sync

    private static func sync() -> Insight {
        let sm = SyncManager.shared
        guard sm.connection.isConnected else {
            return Insight(id: "sync", subsystem: "Sync", level: .ok,
                           sentence: "not connected. Nothing leaves this Mac until sync is turned on.",
                           actionTitle: "Open Sync Settings",
                           action: { SettingsWindowController.shared.show(tab: .sync) })
        }
        let localCount = HistoryStore.shared.items.count
        let remoteCount = sm.space?.items ?? 0
        var sentence = "\(sm.connection.title), \(sm.space?.deviceSummary ?? "this Mac only"). "
        sentence += "\(remoteCount) item\(remoteCount == 1 ? "" : "s") in the space vs "
                  + "\(localCount) on this Mac."
        if let last = lastSyncLogLine() { sentence += " \(last)" }
        if let error = sm.lastError, !error.isEmpty {
            sentence += " Last error: \(error)"
            return Insight(id: "sync", subsystem: "Sync", level: .warning, sentence: sentence,
                           actionTitle: "Full Resync",
                           action: { Task { await SyncManager.shared.fullResync() } })
        }
        return Insight(id: "sync", subsystem: "Sync", level: .ok, sentence: sentence,
                       actionTitle: nil, action: nil)
    }

    /// The most recent successful sync from the activity log, since
    /// `SyncManager` keeps no timestamp of its own - the log already has
    /// one, real, for every sync that actually ran.
    private static func lastSyncLogLine() -> String? {
        for (at, category, message) in Database.shared.recentLog(limit: 200)
        where category == "sync" && message.hasPrefix("Synced ") {
            let f = DateFormatter()
            f.dateFormat = "dd/MM HH:mm"
            return "Last synced \(f.string(from: at))."
        }
        return nil
    }

    // MARK: - Keychain

    /// Names every secret by what it is, and the failing one by WHY it fails
    /// and what fixes it. "3 accounts readable, 1 failing" next to two
    /// working AI connections (user, 03/09) read as "AI is broken" when the
    /// failing item was the sync token; the action offered was the AI repair.
    private static func keychain() -> Insight {
        let known = KeychainStore.knownAccounts
        let failing = KeychainStore.failingAccounts
        let readable = known.subtracting(failing)
        let providerKeys = readable.filter { $0.hasPrefix("provider.") }.count
        var readableParts: [String] = []
        if providerKeys > 0 {
            readableParts.append("\(providerKeys) AI connection key\(providerKeys == 1 ? "" : "s")")
        }
        for account in readable where !account.hasPrefix("provider.") {
            readableParts.append("the " + KeychainStore.subjectName(for: account))
        }
        let readableSentence = readableParts.isEmpty
            ? "no secrets are stored yet."
            : readableParts.joined(separator: " and ") + " readable."

        guard !failing.isEmpty else {
            return Insight(id: "keychain", subsystem: "Keychain", level: .ok,
                           sentence: readableSentence, actionTitle: nil, action: nil)
        }

        var failingParts: [String] = []
        for account in failing.sorted() {
            // Name the connection when it is one: "NVIDIA-main's API key",
            // not "the AI connection's API key".
            let providerName = AIService.shared.providers.first { $0.keychainAccount == account }?.name
            let subject = providerName.map { "\($0)'s API key" } ?? KeychainStore.subjectName(for: account)
            if KeychainStore.missingSecretAccounts.contains(account) {
                failingParts.append("the \(subject) is failing: Clip expects one to be saved, "
                                    + "but the Keychain has no item for it any more")
            } else {
                failingParts.append("the \(subject) is failing: the item is there, but this "
                                    + "build of Clip is not allowed to read it")
            }
        }
        let failingSentence = failingParts.joined(separator: "; ")
        let sentence = readableSentence + " " + failingSentence.prefix(1).uppercased()
                     + failingSentence.dropFirst() + "."

        // The action follows the subject: an AI key is repaired in place;
        // a sync token or server password is re-entered under Sync.
        let providerFailing = failing.contains { $0.hasPrefix("provider.") }
        if providerFailing {
            return Insight(id: "keychain", subsystem: "Keychain", level: .danger, sentence: sentence,
                           actionTitle: "Repair AI Key Access",
                           action: { AppDelegate.shared?.repairKeychainAccess() })
        }
        return Insight(id: "keychain", subsystem: "Keychain", level: .warning, sentence: sentence,
                       actionTitle: "Open Sync Settings",
                       action: { SettingsWindowController.shared.show(tab: .sync) })
    }

    // MARK: - Storage

    /// What each leftover file category is, in the words the Privacy pane
    /// already uses, so the line explains itself (user, 03/09: "I don't
    /// understand the storage warning").
    private static func describe(_ category: AppPaths.Orphan.Category, count: Int) -> String {
        let plural = count != 1
        switch category {
        case .media:                return "\(count) image\(plural ? "s" : "") no clip uses any more"
        case .degradedMedia:        return "\(count) clip\(plural ? "s" : "") whose image file is missing"
        case .staleTestFiles:       return "\(count) leftover test file\(plural ? "s" : "")"
        case .importedHistory:      return "an already imported history file"
        case .pinsJSON:             return "an old pins file that preferences replaced"
        case .previousVersion:      return "\(count) previous version\(plural ? "s" : "") past retention"
        case .corruptQuarantine:    return "\(count) quarantined cop\(plural ? "ies" : "y") of a damaged database"
        case .backupBeyondRetention: return "\(count) backup\(plural ? "s" : "") past retention"
        }
    }

    private static func storage() -> Insight {
        let open = Database.shared.isOpen
        let integrity = Database.shared.lastIntegrityResult
        let orphans = AppPaths.audit().filter { $0.category != .degradedMedia }
        var sentence = open
            ? "database open, last integrity check: \(integrity)."
            : "Database not open. Clip can't read or save clips until it is."
        if !orphans.isEmpty {
            var byCategory: [AppPaths.Orphan.Category: Int] = [:]
            for orphan in orphans { byCategory[orphan.category, default: 0] += 1 }
            let parts = byCategory.keys.sorted { $0.rawValue < $1.rawValue }
                .map { describe($0, count: byCategory[$0] ?? 0) }
            let bytes = orphans.reduce(Int64(0)) { $0 + $1.size }
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            sentence += " Nothing is wrong: \(parts.joined(separator: ", ")) take \(size) "
                      + "and are safe to reclaim. Reclaiming moves them into a dated folder inside "
                      + "Clip's data folder; nothing is deleted until you empty that folder."
        }
        // Leftover files are housekeeping, not a fault: the line stays green
        // and simply offers the button. Only a closed database is a problem.
        let level: Level = open ? .ok : .danger
        guard !orphans.isEmpty || !open else {
            return Insight(id: "storage", subsystem: "Storage", level: level, sentence: sentence,
                           actionTitle: nil, action: nil)
        }
        return Insight(id: "storage", subsystem: "Storage", level: level, sentence: sentence,
                       actionTitle: open ? "Reclaim in Privacy Settings" : "Open Privacy Settings",
                       action: { SettingsWindowController.shared.show(tab: .privacy) })
    }

    // MARK: - Startup health

    /// Says what the launch found, not how many things it found: "1 finding
    /// this launch" told nobody whether that was a routine daily backup or a
    /// failed migration (user, 03/09). A `fixed`/`info` finding is good news
    /// and keeps the line green; only a warning or an integrity finding
    /// turns it amber.
    private static func startupHealth() -> Insight {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
        let lastRun = Database.shared.preference(StartupHealth.versionPreferenceKey)
        let findings = StartupHealth.lastFindings
        var sentence: String
        if let lastRun, lastRun != version {
            sentence = "running \(version), updated from \(lastRun) at this launch."
        } else if lastRun == nil {
            sentence = "running \(version), first launch of this install."
        } else {
            sentence = "running \(version), same version as last launch."
        }
        if findings.isEmpty {
            sentence += " Nothing to report from startup."
        } else {
            let lines = findings.map { f -> String in
                let detail = f.detail.hasSuffix(".") ? f.detail : f.detail + "."
                return "\(f.title): \(detail)"
            }
            sentence += " At startup: " + lines.joined(separator: " ")
        }
        let needsAttention = findings.contains { $0.severity == .warning || $0.severity == .integrity }
        return Insight(id: "startup", subsystem: "Startup health",
                       level: needsAttention ? .warning : .ok,
                       sentence: sentence, actionTitle: nil, action: nil)
    }
}
