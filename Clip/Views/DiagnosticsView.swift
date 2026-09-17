import SwiftUI

/// Everything the app knows about its own health, in a window that stays
/// open and can be read line by line and referred back to - not the
/// `NSAlert` `AppDelegate.showDiagnostics()` used to put up, which vanished
/// the moment its one button was pressed.
///
/// Reuses `SettingsPalette` and `ExplainedSection` (`SettingsShell.swift`) so
/// this reads as part of the same app as Settings rather than a debug panel
/// bolted on beside it - no new colours, same row anatomy.
struct DiagnosticsView: View {
    @ObservedObject private var notices = NoticeCenter.shared
    @State private var justCopied = false
    @State private var justCopiedShortcuts = false

    var body: some View {
        Form {
            insightsSection

            openNoticesSection

            ExplainedSection("Storage") {
                monospace(DiagnosticsReport.storage())
            }
            ExplainedSection("Keychain") {
                monospace(DiagnosticsReport.keychain())
            }
            ExplainedSection("Sync") {
                monospace(syncText)
            }
            ExplainedSection("AI") {
                monospace(aiText)
            }
            ExplainedSection("Shortcuts") {
                monospace(ShortcutManager.shared.diagnosticReport(items: HistoryStore.shared.items))
                HStack {
                    Spacer()
                    ClipLink(justCopiedShortcuts ? "Copied" : "Copy", size: .small) { copyShortcutReport() }
                }
            }
            ExplainedSection("Activity log",
                              note: "The last 200 things Clip did to its own data, newest first.") {
                activityLogRows
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) { copyBar }
        // NOT `.frame(minWidth: 660, minHeight: 560)` any more (M8 bug fix,
        // 02/09): that made sense when this was the entire content of its
        // own `NSWindow` (`DiagnosticsWindowController`, deleted in M8.8).
        // Once this became one pane inside `SettingsShell`'s
        // `NavigationSplitView`, the same minWidth asked the split view for
        // more room than it had budgeted, and it answered by collapsing the
        // sidebar column instead of just scrolling this pane - "when
        // clicking diagnosis all the tabs vanish". `SettingsShell` already
        // sizes the whole window; a pane inside it must never re-demand a
        // width or height of its own.
    }

    // MARK: - Insights

    /// The first thing anyone reads here - a person, or an AI given the
    /// pasted report - before the raw per-subsystem dump below it: what is
    /// connected, what has failed, and the one action that fixes it.
    private var insightsSection: some View {
        ExplainedSection("Insights", note: """
            One line per subsystem: what is connected, what has failed, and \
            what to do about it. The sections below have the full detail.
            """) {
            ForEach(DiagnosticsInsights.all()) { insight in
                insightRow(insight)
            }
        }
    }

    private func insightRow(_ insight: DiagnosticsInsights.Insight) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: insight.level.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color(for: insight.level))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(insight.subsystem).font(.system(size: 12, weight: .semibold))
                Text(insight.sentence)
                    .font(.caption)
                    .foregroundStyle(SettingsPalette.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let title = insight.actionTitle, let action = insight.action {
                ClipLink(title, size: .small) { action() }
            }
        }
        .padding(.vertical, 2)
    }

    private func color(for level: DiagnosticsInsights.Level) -> Color {
        switch level {
        case .ok:      return SettingsPalette.success
        case .warning: return SettingsPalette.warning
        case .danger:  return SettingsPalette.danger
        }
    }

    // MARK: - Open notices

    private var openNoticesSection: some View {
        ExplainedSection("Open notices") {
            if notices.pending.isEmpty {
                Text("Nothing is wrong right now.")
                    .font(.caption)
                    .foregroundStyle(SettingsPalette.note)
            } else {
                ForEach(notices.pending) { notice in
                    noticeRow(notice)
                }
            }
        }
    }

    private func noticeRow(_ notice: NoticeCenter.Notice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(notice.kind.rawValue.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color(for: notice.kind))
                Text(notice.message)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            if let remedy = notice.remedy {
                Text(remedy)
                    .font(.caption)
                    .foregroundStyle(SettingsPalette.note)
            }
            HStack(spacing: 12) {
                if let action = notice.action {
                    ClipLink(action.title, size: .small) { action.run() }
                }
                // Data at risk cannot be waved away, matching NoticeBar's own
                // rule: the X is not drawn for an `.integrity` notice there
                // either.
                if notice.kind != .integrity {
                    ClipLink("Dismiss", size: .small) { NoticeCenter.shared.dismiss(notice.id) }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func color(for kind: NoticeCenter.Kind) -> Color {
        switch kind {
        case .integrity:  return SettingsPalette.danger
        case .persistent: return SettingsPalette.warning
        case .transient:  return SettingsPalette.note
        case .invitation: return .accentColor
        }
    }

    // MARK: - Sync / AI text

    private var syncText: String {
        var lines = ["state: \(SyncManager.shared.syncState)"]
        if let e = SyncManager.shared.lastError { lines.append("last error: \(e)") }
        return lines.joined(separator: "\n")
    }

    private var aiText: String {
        let providers = AIService.shared.providers
        guard !providers.isEmpty else { return "No AI connections yet." }
        return providers.map { p in
            "\(p.name): model \(p.model)" + (p.lastError.map { "  last error: \($0)" } ?? "")
        }.joined(separator: "\n")
    }

    private func monospace(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(SettingsPalette.note)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Activity log

    private var activityLogRows: some View {
        let rows = Database.shared.recentLog(limit: 200)
        return Group {
            if rows.isEmpty {
                Text("Nothing logged yet.")
                    .font(.caption)
                    .foregroundStyle(SettingsPalette.note)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 8) {
                        Text(Self.stamp(row.0))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(SettingsPalette.note)
                        Text("[\(row.1)]")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        Text(row.2)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd/MM HH:mm:ss"
        return f.string(from: date)
    }

    // MARK: - Copy report

    private var copyBar: some View {
        HStack {
            Spacer()
            PrimaryButton(justCopied ? "Copied" : "Copy Report") { copyReport() }
        }
        .padding(12)
        .background(.regularMaterial)
    }

    /// Just the shortcut report - the section people actually paste back
    /// when a hotkey stops working, without the storage, Keychain and
    /// activity-log text ahead of it in the combined report below.
    private func copyShortcutReport() {
        let text = ShortcutManager.shared.diagnosticReport(items: HistoryStore.shared.items)
        let pb = TestIsolation.board
        pb.clearContents()
        pb.setString(text, forType: .string)
        justCopiedShortcuts = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { justCopiedShortcuts = false }
    }

    private func copyReport() {
        let text = DiagnosticsReport.full()
        // `TestIsolation.board` is the real pasteboard outside a sandboxed
        // test run and a private one inside it - see `TestIsolation.swift`.
        // Using it here, rather than the system pasteboard directly, means
        // this button behaves identically to every other pasteboard write on
        // the paste path and never touches a person's real clipboard while a
        // probe is driving the app.
        let pb = TestIsolation.board
        pb.clearContents()
        pb.setString(text, forType: .string)
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { justCopied = false }
    }
}
