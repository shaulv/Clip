import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// What can be exported. Each scope is independent, so any combination works.
enum ExportScope: String, CaseIterable, Identifiable {
    case prompts, notes, skills, designs, files, clips
    case preferences, themes, shortcuts, versions, activityLog

    var id: String { rawValue }

    var title: String {
        switch self {
        case .prompts:     return "Prompts"
        case .notes:       return "Notes"
        case .skills:      return "Skills"
        case .designs:     return "Design documents"
        case .files:       return "Files and folders"
        case .clips:       return "Plain clips"
        case .preferences: return "Preferences"
        case .themes:      return "Custom themes"
        case .shortcuts:   return "Shortcuts"
        case .versions:    return "Version history"
        case .activityLog: return "Activity log"
        }
    }

    var detail: String {
        switch self {
        case .prompts:     return "Saved prompts with tags, hotkeys and use counts"
        case .notes:       return "Everything in the Notes tab"
        case .skills:      return "Markdown skill documents"
        case .designs:     return "DESIGN.md documents in the Design tab"
        case .files:       return "File and folder references"
        case .clips:       return "Ordinary clipboard history"
        case .preferences: return "Every setting, including your AI connection addresses (never your keys)"
        case .themes:      return "Themes you built or generated"
        case .shortcuts:   return "Your key bindings"
        case .versions:    return "Every past revision of every item"
        case .activityLog: return "Recent diagnostic events"
        }
    }

    /// Content scopes group separately from configuration scopes in the UI.
    var isContent: Bool {
        switch self {
        case .prompts, .notes, .skills, .files, .clips: return true
        default: return false
        }
    }
}

/// Backup's own sub-pages (M14): one cluster of one concern each - what
/// leaves the Mac, what's read back in, and the separate design-document
/// importer, which the pane's own file comment already calls "the other
/// half of Export" but which is a genuinely different action from either.
enum ExportPage: String, CaseIterable, Identifiable, SettingsSubpageID {
    // Two, not four (user, 05/09). "Back up everything" and "Export" were one
    // question - how do I get my data out - asked twice, and the pair below
    // them repeated it for the way back in. Each page now holds the whole of
    // its direction: the one-press file first, the picked-apart version under
    // it, in the same place.
    case backUp, restore
    var id: String { rawValue }
    var title: String {
        switch self {
        case .backUp:         return "Back up everything"
        case .restore:        return "Restore from a backup"
        }
    }
    var symbol: String {
        switch self {
        case .backUp:        return "externaldrive.badge.timemachine"
        case .restore:       return "clock.arrow.circlepath"
        }
    }
}

struct ExportPane: View {
    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var router: SettingsRouter
    @State private var selected: Set<ExportScope> = [.prompts, .notes, .skills]
    @State private var separateFiles = false
    @State private var result: String?
    @State private var failed = false
    @State private var importSettings = true
    @State private var importResult: String?
    @State private var importFailed = false

    // Back up and restore
    @State private var backupResult: String?
    @State private var backupFailed = false
    @State private var restoreResult: String?
    @State private var restoreFailed = false
    /// The file being restored, and what it says it holds. Set only after a
    /// successful `inspect`, which is what puts the preview on screen before
    /// anything is written.
    @State private var pending: PendingRestore?

    struct PendingRestore: Identifiable {
        let id = UUID()
        let url: URL
        let manifest: BackupArchive.Manifest
        var modes: [BackupArchive.Section: BackupArchive.RestoreMode]
        /// What this file would have to change to fit this Mac, read before
        /// anything is written.
        var adaptations: [BackupArchive.Adaptation] = []
        /// The ones the user said yes to. Empty means every adaptation is
        /// discarded, which is the safe default: this Mac stays as it is.
        var approved: Set<String> = []
    }

    /// The clusters the last restore reported, if it was not clean.
    @State private var restoreFailures: [BackupArchive.FailureCluster] = []

    var body: some View {
        Group {
            switch router.page(for: .export).flatMap(ExportPage.init(rawValue:)) {
            case nil:                 hub
            case .backUp:             backUpSubpage
            case .restore:            restoreSubpage
            }
        }
    }

    // MARK: - Hub

    private var hub: some View {
        SettingsHub(icon: "arrow.up.arrow.down.square", title: "Backup",
                    purpose: "Save everything Clip holds to one file, or bring it back. Or pick out just the parts you want as plain text.",
                    groups: [
            SettingsHubGroup(id: "everything", rows: [
                .init(id: ExportPage.backUp.rawValue, symbol: ExportPage.backUp.symbol,
                      title: ExportPage.backUp.title, summary: "One file, all your data"),
                .init(id: ExportPage.restore.rawValue, symbol: ExportPage.restore.symbol,
                      title: ExportPage.restore.title, summary: "Shows you what is in it first"),
            ])
        ], onSelectRow: { id in router.openSubpage(id, in: .export) })
    }

    // MARK: - Back up everything

    private var backUpSubpage: some View {
        subpage(.backUp) {
            Form {
                ExplainedSection("Back up everything", note: """
                    One file with everything: clips, notes, prompts, skills, designs, your \
                    images and files, settings, themes, shortcuts, tabs and AI connections.

                    API keys stay in the macOS Keychain. Paste them back after restoring.
                    """) {
                    LabeledContent("Items") { Text("\(store.items.count)") }
                    LabeledContent("Custom themes") { Text("\(CustomThemeStore.shared.themes.count)") }
                    LabeledContent("AI connections") { Text("\(AIService.shared.providers.count)") }
                    HStack {
                        PrimaryButton("Back Up…") { runBackup() }
                        Spacer()
                    }
                    if let backupResult {
                        Label(backupResult,
                              systemImage: backupFailed ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(backupFailed ? SettingsPalette.danger : SettingsPalette.success)
                    }
                }

                // The picked-apart version of the same question, under the
                // one-press answer rather than beside it as a rival row.
                exportSections
            }
            .formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Restore from a backup

    private var restoreSubpage: some View {
        subpage(.restore) {
            Form {
                ExplainedSection("Restore from a backup", note: """
                    Shows you what is in the file before anything is written. Your current \
                    data is backed up first, so a restore you did not mean can be undone.
                    """) {
                    HStack {
                        SecondaryButton("Restore…") { chooseRestore() }
                        Spacer()
                    }
                    if let restoreResult {
                        Label(restoreResult,
                              systemImage: restoreFailed ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(restoreFailed ? SettingsPalette.danger : SettingsPalette.success)
                    }
                    // Grouped by reason, never one line per item: a file with
                    // a thousand clips and three bad rows says three things.
                    ForEach(restoreFailures) { cluster in
                        Label(cluster.text, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(SettingsPalette.danger)
                    }
                }

                importSections
            }
            .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            .sheet(item: $pending) { item in restoreSheet(item) }
        }
    }

    private func restoreSheet(_ item: PendingRestore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restore from \(item.manifest.createdAtText)")
                .font(.headline)
            Text("Choose what to bring back. Nothing is written until you confirm.")
                .font(.caption)
                .foregroundStyle(SettingsPalette.note)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(BackupArchive.Section.allCases.filter(item.manifest.has)) { section in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(section.title)
                                Spacer()
                                Text("\(item.manifest.count(section))")
                                    .font(.caption)
                                    .foregroundStyle(SettingsPalette.note)
                            }
                            Text(section.detail)
                                .font(.caption)
                                .foregroundStyle(SettingsPalette.note)
                            Picker("", selection: Binding(
                                get: { pending?.modes[section] ?? section.defaultMode },
                                set: { pending?.modes[section] = $0 }
                            )) {
                                ForEach(BackupArchive.RestoreMode.allCases) { mode in
                                    if mode != .replace || section.supportsReplace {
                                        Text(mode.title).tag(mode)
                                    }
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 320)

            if !item.adaptations.isEmpty {
                Divider()
                Text("Needs your decision")
                    .font(.subheadline.weight(.semibold))
                Text("These cannot be restored as they are without changing "
                     + "something on this Mac. Nothing here is changed unless "
                     + "you approve it.")
                    .font(.caption)
                    .foregroundStyle(SettingsPalette.note)
                ForEach(item.adaptations) { adaptation in
                    Toggle(isOn: Binding(
                        get: { pending?.approved.contains(adaptation.id) ?? false },
                        set: { on in
                            if on { pending?.approved.insert(adaptation.id) }
                            else { pending?.approved.remove(adaptation.id) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(adaptation.title)
                            Text(adaptation.detail)
                                .font(.caption)
                                .foregroundStyle(SettingsPalette.note)
                        }
                    }
                }
            }

            Text("Your current data is saved to a file first, so this can be undone.")
                .font(.caption)
                .foregroundStyle(SettingsPalette.note)

            HStack {
                Spacer()
                SecondaryButton("Cancel") { pending = nil }
                PrimaryButton("Restore") { runRestore(item) }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func subpage<Content: View>(_ page: ExportPage, @ViewBuilder content: @escaping () -> Content) -> some View {
        SettingsSubpage(tab: .export, title: page.title, router: router, content: content)
    }

    // MARK: - Export

    /// The selective half of "get my data out": which parts, in what shape.
    /// Sections, not a page of its own - see `ExportPage`.
    @ViewBuilder
    private var exportSections: some View {
        Group {
                ExplainedSection("Content", note: """
                    Choose any combination. Each selection is written as a plain text \
                    file you can open and keep.
                    """) {
                    ForEach(ExportScope.allCases.filter(\.isContent)) { scope in
                        row(scope)
                    }
                }

                ExplainedSection("Configuration", note: "Your settings, themes and bindings.") {
                    ForEach(ExportScope.allCases.filter { !$0.isContent }) { scope in
                        row(scope)
                    }
                }

                Section {
                    HStack {
                        GhostButton("Select All", size: .small) { selected = Set(ExportScope.allCases) }
                        GhostButton("Select None", size: .small) { selected = [] }
                        Spacer()
                    }
                    Toggle("Write one file per selection", isOn: $separateFiles)
                    Text(separateFiles
                         ? "Each selection is saved as its own file in the folder you choose."
                         : "Everything selected is saved into a single file.")
                        .font(.caption).foregroundStyle(SettingsPalette.note)
                }

                ExplainedSection("Export", note: "API keys are never exported. They stay in the macOS Keychain.") {
                    HStack {
                        PrimaryButton("Export…", isDisabled: selected.isEmpty) { export() }
                        Spacer()
                    }
                    if let result {
                        Label(result, systemImage: failed ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(failed ? SettingsPalette.danger : SettingsPalette.success)
                    }
                }
        }
    }

    // MARK: - Import a file instead

    /// Reading a file back in without the full restore ceremony. A section of
    /// the restore page, not a rival row on the hub.
    @ViewBuilder
    private var importSections: some View {
        Group {
                ExplainedSection("Import a file instead", note: """
                    Reads a file Clip exported. Items you already have are recognized \
                    automatically and replaced only when the file's copy is newer, so \
                    importing twice changes nothing.

                    This is the other half of Export, not a connection: no server, no \
                    account, no effect on how this Mac syncs. Do it as often as you like.
                """) {
                    Toggle("Also restore settings, themes and shortcuts", isOn: $importSettings)
                    HStack {
                        SecondaryButton("Import…") { runImport() }
                        Spacer()
                    }
                    if let importResult {
                        Label(importResult, systemImage: importFailed ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(importFailed ? SettingsPalette.danger : SettingsPalette.success)
                    }
                }
        }
    }

    private func row(_ scope: ExportScope) -> some View {
        Toggle(isOn: Binding(
            get: { selected.contains(scope) },
            set: { on in if on { selected.insert(scope) } else { selected.remove(scope) } }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(scope.title)
                    Spacer()
                    Text("\(count(scope))").foregroundStyle(SettingsPalette.note).font(.caption)
                }
                Text(scope.detail).font(.caption).foregroundStyle(SettingsPalette.note)
            }
        }
        // M8.4: a composite row (title, count, detail) wrapped around a
        // bare Toggle - the hover wash goes behind the whole row, matching
        // PrivacyPane's ignored-apps rows and ExportPane's own drag list.
        .settingsHover(cornerRadius: 6)
    }

    private func count(_ scope: ExportScope) -> Int {
        switch scope {
        case .prompts:     return store.count(ofRole: .prompt)
        case .notes:       return store.count(ofRole: .note)
        case .skills:      return store.count(ofRole: .skill)
        case .designs:     return store.count(ofRole: .design)
        case .files:       return store.fileCount
        case .clips:       return store.count(ofRole: .clip)
        case .themes:      return CustomThemeStore.shared.themes.count
        case .shortcuts:   return ShortcutAction.allCases.count
        case .preferences: return 1
        case .versions:    return store.items.reduce(0) { $0 + Database.shared.versionCount(for: $1.id) }
        case .activityLog: return Database.shared.recentLog(limit: 2000).count
        }
    }

    // MARK: - Back up and restore

    private func runBackup() {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withFullDate])
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clip-backup-\(stamp).\(BackupArchive.fileExtension)"
        panel.allowedContentTypes = [.data]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let manifest = try BackupArchive.write(to: url, store: store)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size])
                .flatMap { $0 as? NSNumber }?.int64Value ?? 0
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            backupFailed = false
            backupResult = """
                Backed up \(manifest.count(.history)) items and \(size) to \
                \(url.lastPathComponent).
                """
            if let dropSummary = manifest.dropSummary {
                backupResult = (backupResult ?? "") + " " + dropSummary
            }
        } catch {
            backupFailed = true
            backupResult = error.localizedDescription
            NoticeCenter.shared.report(.exportWriteFailed(path: url.path,
                                                          detail: error.localizedDescription))
        }
    }

    /// Step one of a restore: read the manifest and show it. Nothing is written.
    private func chooseRestore() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let manifest = try BackupArchive.inspect(url)
            var modes: [BackupArchive.Section: BackupArchive.RestoreMode] = [:]
            for section in BackupArchive.Section.allCases where manifest.has(section) {
                modes[section] = section.defaultMode
            }
            restoreResult = nil
            restoreFailed = false
            restoreFailures = []
            let adaptations = (try? BackupArchive.adaptations(in: url, modes: modes)) ?? []
            pending = PendingRestore(url: url, manifest: manifest, modes: modes,
                                     adaptations: adaptations)
        } catch {
            // The file was never opened for writing, so a failure here has
            // touched nothing at all.
            restoreFailed = true
            restoreResult = error.localizedDescription
        }
    }

    /// Step two: the person has seen what is in the file and chosen.
    private func runRestore(_ item: PendingRestore) {
        let modes = pending?.modes ?? item.modes
        let approved = pending?.approved ?? item.approved
        pending = nil
        do {
            let summary = try BackupArchive.restore(item.url, modes: modes,
                                                    store: store, approved: approved)
            restoreFailed = summary.verdict == "failed"
            restoreFailures = summary.failures
            // The ordinary case - and it is 99.9% of them - is a count and
            // nothing else. Everything the restore COULD have said belongs to
            // the case where something actually went wrong.
            if summary.isClean {
                let n = summary.itemsAdded + summary.itemsUpdated
                restoreResult = "Restored \(n) item\(n == 1 ? "" : "s")."
            } else {
                restoreResult = summary.verdict == "failed"
                    ? "Nothing was restored."
                    : summary.text
            }
        } catch {
            restoreFailed = true
            restoreFailures = []
            restoreResult = error.localizedDescription
        }
    }

    // MARK: - Writing

    private func export() {
        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter.string(from: Date(),
                                                timeZone: .current,
                                                formatOptions: [.withFullDate])
        if separateFiles {
            let open = NSOpenPanel()
            open.canChooseDirectories = true
            open.canChooseFiles = false
            open.canCreateDirectories = true
            open.prompt = "Export Here"
            guard open.runModal() == .OK, let dir = open.url else { return }
            writeSeparate(into: dir, stamp: stamp)
            return
        }
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "clip-export-\(stamp).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(payload(for: selected), to: url, describing: "\(selected.count) selections")
    }

    private func writeSeparate(into dir: URL, stamp: String) {
        var written = 0
        var lastReason: String?
        for scope in ExportScope.allCases where selected.contains(scope) {
            let url = dir.appendingPathComponent("clip-\(scope.rawValue)-\(stamp).json")
            if let reason = Self.writeQuietly(payload(for: [scope]), to: url) {
                lastReason = reason
            } else {
                written += 1
            }
        }
        failed = written != selected.count
        result = failed
            ? "Wrote \(written) of \(selected.count) files.\(lastReason.map { " (\($0))" } ?? "")"
            : "Wrote \(written) files to \(dir.lastPathComponent)."
    }

    private func write(_ payload: [String: Any], to url: URL, describing what: String) {
        if let reason = Self.writeQuietly(payload, to: url) {
            failed = true
            result = "Could not write \(url.lastPathComponent): \(reason)"
            NoticeCenter.shared.report(.exportWriteFailed(path: url.path, detail: reason))
        } else {
            failed = false
            result = "Exported \(what) to \(url.lastPathComponent)."
        }
    }

    /// Writes `payload` to `url`. Returns `nil` on success, or the reason it
    /// failed - `writeQuietly` used to swallow that reason outright and hand
    /// back only a `Bool`, so "Could not write clip-export.json" was the
    /// entire message whether the disk was full, the folder had gone away,
    /// or Clip simply lacked permission there.
    ///
    /// Static and store-free so a probe can drive the exact write a real
    /// export takes without going through an `NSSavePanel`.
    @discardableResult
    static func writeQuietly(_ payload: [String: Any], to url: URL) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return "The data for this export could not be encoded."
        }
        do {
            try data.write(to: url)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Design library import (used by the Design tab's own import, not by a Settings page)

    /// What to tell the person about a design-library import, distinguishing
    /// the three different reasons "nothing was added" can mean. Before this
    /// they all read as the identical "No design documents found in that
    /// folder" - which is simply wrong when the folder could not be opened
    /// at all, or when it held files that looked like candidates but none
    /// could be read as a design document; both used to be reported as if
    /// the folder had been empty.
    static func designImportMessage(folder: URL, store: HistoryStore) -> (failed: Bool, message: String) {
        let outcome = DesignLibraryImport.run(folder: folder, store: store)
        guard outcome.imported == 0 && outcome.skipped == 0 else {
            return (false, outcome.summary)
        }
        switch DesignLibraryImport.scanProblem(folder) {
        case .unreadable:
            return (true, "Clip could not read that folder. Check that it is still there and that Clip has permission to open it.")
        case .empty:
            return (true, "That folder is empty.")
        case .noCandidates, .none:
            if outcome.rejected.isEmpty {
                return (true, "That folder has files, but none of them look like a design document, a folder named for a brand that contains a DESIGN.md file.")
            } else {
                let n = outcome.rejected.count
                return (true, "Found \(n) candidate file\(n == 1 ? "" : "s"), but none could be read as a design document.")
            }
        }
    }

    // MARK: - Import

    private func runImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ImportError.notClip
            }
            guard root["application"] as? String == "Clip" else { throw ImportError.notClip }

            let outcome = Self.apply(root, into: store, importSettings: importSettings)
            importFailed = outcome.unreadable > 0
            importResult = outcome.summary
        } catch {
            importFailed = true
            importResult = (error as? ImportError)?.message ?? error.localizedDescription
        }
    }

    private enum ImportError: Error {
        case notClip
        var message: String { "That file was not exported by Clip." }
    }

    /// What one import did, counted separately from what one import COULD
    /// NOT read - see `apply(_:into:importSettings:)` below for why those
    /// two used to be the same number.
    struct ImportOutcome {
        var added = 0
        var updated = 0
        /// Decoded fine, but not newer than what is already here - a
        /// legitimate no-op, not a problem.
        var skipped = 0
        /// Failed to decode at all. This is the number that used to be
        /// folded into `skipped`, so a corrupt row and an up-to-date row
        /// read as the identical "skipped" and there was no way to tell
        /// "nothing to do" apart from "this could not be read".
        var unreadable = 0
        var extras: [String] = []

        var summary: String {
            var parts = ["Added \(added)", "updated \(updated)", "skipped \(skipped)"]
            if !extras.isEmpty { parts.append("plus " + extras.joined(separator: ", ")) }
            var text = parts.joined(separator: ", ") + "."
            if unreadable > 0 {
                text += " \(unreadable) item\(unreadable == 1 ? "" : "s") couldn't be read."
            }
            return text
        }
    }

    /// Merges an export back in.
    ///
    /// Matching on id and comparing timestamps means a re-import is a no-op
    /// rather than a duplicate storm, and an older backup never silently
    /// overwrites work done since.
    ///
    /// Static and store-free (a `HistoryStore` is passed in rather than read
    /// from `@EnvironmentObject`) so this is the same function whether it
    /// runs from the real Import button or from the emergency-snapshot
    /// recovery action a failed quit leaves behind - one import path, not
    /// two that can drift apart.
    @discardableResult
    static func apply(_ root: [String: Any], into store: HistoryStore, importSettings: Bool) -> ImportOutcome {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var outcome = ImportOutcome()
        for key in ["prompts", "notes", "skills", "designs", "clips", "files"] {
            guard let rows = root[key] as? [[String: Any]] else { continue }
            for row in rows {
                guard let data = try? JSONSerialization.data(withJSONObject: row),
                      let item = try? decoder.decode(ClipboardItem.self, from: data) else {
                    outcome.unreadable += 1
                    continue
                }
                if let existing = store.item(item.id) {
                    if item.timestamp > existing.timestamp {
                        store.update(item.id) { $0 = item }
                        outcome.updated += 1
                    } else {
                        outcome.skipped += 1
                    }
                } else {
                    store.add(item)
                    outcome.added += 1
                }
            }
        }

        if importSettings {
            if let themes = root["themes"] as? [[String: Any]] {
                var n = 0
                for row in themes {
                    guard let data = try? JSONSerialization.data(withJSONObject: row),
                          let theme = try? JSONDecoder().decode(CustomTheme.self, from: data) else { continue }
                    CustomThemeStore.shared.save(theme)
                    n += 1
                }
                if n > 0 { outcome.extras.append("\(n) theme\(n == 1 ? "" : "s")") }
            }
            if let shortcuts = root["shortcuts"] as? [String: String] {
                var n = 0
                for (raw, combo) in shortcuts {
                    guard let action = ShortcutAction(rawValue: raw) else { continue }
                    // A clash with something already bound is left alone.
                    if ShortcutRegistry.shared.assign(combo, to: action) == nil { n += 1 }
                }
                if n > 0 { outcome.extras.append("\(n) shortcut\(n == 1 ? "" : "s")") }
            }
            if let prefs = root["preferences"] as? [String: Any] {
                applyPreferences(prefs)
                outcome.extras.append("preferences")
            }
        }

        return outcome
    }

    /// Writes preferences from a scope export back.
    ///
    /// Driven from the key list rather than a hand-written run of `if let`
    /// assignments, which is what this used to be - and it had already drifted:
    /// `preferencesDictionary` wrote `launchAtLogin` and `density` into every
    /// export and this function read back neither, so those two silently did not
    /// restore. Two lists that must agree and are maintained by hand eventually
    /// do not, so there is now one.
    private static func applyPreferences(_ prefs: [String: Any]) {
        let defaults = AppPaths.defaults
        var touched = false

        for (key, value) in prefs {
            // `aiConnections` is a summary for a person to read, not a
            // restorable preference: it is written without ids, so there is
            // nothing to write back onto. The backup archive carries the real
            // `aiProviders` document instead.
            guard key != "aiConnections" else { continue }
            let store = SettingsRegistry.store(for: key)
                ?? SettingsRegistry.machineLocal.first { $0.key == key }?.store
            guard case .defaults(let kind)? = store else { continue }
            guard !SettingsRegistry.neverLeaves.contains(where: { key.contains($0) }) else { continue }

            switch (kind, value) {
            case (.bool, let v as Bool):     defaults.set(v, forKey: key); touched = true
            case (.int, let v as Int):       defaults.set(v, forKey: key); touched = true
            case (.string, let v as String): defaults.set(v, forKey: key); touched = true
            default: continue
            }
        }

        guard touched else { return }
        PreferencesModel.shared.reloadFromDefaults()
        let theme = ThemeManager.shared
        if let v = prefs["themeID"] as? String, !v.isEmpty { theme.themeID = v }
        if let v = prefs["density"] as? String, let d = GalleryDensity(rawValue: v) { theme.density = d }
        if let v = prefs["initialTabID"] as? String, !v.isEmpty { theme.initialTabID = v }
        HistoryStore.shared.reloadViewPreferences()
    }

    // MARK: - Payload

    private func payload(for scopes: Set<ExportScope>) -> [String: Any] {
        var out: [String: Any] = [
            "application": "Clip",
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "scopes": scopes.map(\.rawValue).sorted()
        ]

        func items(_ role: ItemRole) -> [[String: Any]] {
            store.items.filter { $0.role == role }.map(Self.dictionary)
        }

        for scope in scopes {
            switch scope {
            case .prompts: out["prompts"] = items(.prompt)
            case .notes:   out["notes"] = items(.note)
            case .skills:  out["skills"] = items(.skill)
            case .designs: out["designs"] = items(.design)
            case .clips:   out["clips"] = items(.clip)
            case .files:
                out["files"] = store.items
                    .filter { $0.kind == .file || $0.kind == .folder }
                    .map(Self.dictionary)
            case .themes:
                out["themes"] = CustomThemeStore.shared.themes.compactMap { theme -> [String: Any]? in
                    guard let d = try? JSONEncoder().encode(theme),
                          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                    else { return nil }
                    return o
                }
            case .shortcuts:
                out["shortcuts"] = ShortcutAction.allCases.reduce(into: [String: String]()) {
                    $0[$1.rawValue] = ShortcutRegistry.shared.shortcut(for: $1)
                }
            case .preferences:
                out["preferences"] = preferencesDictionary()
            case .versions:
                out["versions"] = store.items.reduce(into: [String: Any]()) { acc, item in
                    let vs = Database.shared.versions(for: item.id)
                    guard !vs.isEmpty else { return }
                    acc[item.id.uuidString] = vs.map {
                        ["body": $0.body, "note": $0.note,
                         "createdAt": ISO8601DateFormatter().string(from: $0.createdAt)]
                    }
                }
            case .activityLog:
                out["activityLog"] = Database.shared.recentLog(limit: 2000).map {
                    ["at": ISO8601DateFormatter().string(from: $0.0),
                     "category": $0.1, "message": $0.2]
                }
            }
        }
        return out
    }

    static func dictionary(_ item: ClipboardItem) -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(item),
              var o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ["id": item.id.uuidString] }
        // Binary RTF is noise in a human-readable export.
        o.removeValue(forKey: "richText")
        return o
    }

    /// Every preference, minus anything secret.
    private func preferencesDictionary() -> [String: Any] {
        let p = PreferencesModel.shared
        var out: [String: Any] = [
            "launchAtLogin": p.launchAtLogin,
            "pasteAutomatically": p.pasteAutomatically,
            "numberShortcuts": p.numberShortcuts,
            "showFooter": p.showFooter,
            "historyLimit": p.historyLimit,
            "clearOnQuit": p.clearOnQuit,
            "pollIntervalMS": p.pollIntervalMS,
            "maxTextKB": p.maxTextKB,
            "respectConcealedTypes": p.respectConcealedTypes,
            "ignoredApps": p.ignoredApps,
            "statusIcon": p.statusIcon,
            "showInDock": p.showInDock,
            "showCopyConfirmation": p.showCopyConfirmation,
            "themeID": ThemeManager.shared.themeID,
            "density": ThemeManager.shared.density.rawValue,
            "initialTabID": ThemeManager.shared.initialTabID
        ]
        // Endpoints and model names are useful to keep; keys are not exported.
        out["aiConnections"] = AIService.shared.providers.map {
            ["name": $0.name, "kind": $0.kind.rawValue,
             "endpoint": $0.endpoint, "model": $0.model, "isActive": $0.isActive]
        }
        return out
    }
}
