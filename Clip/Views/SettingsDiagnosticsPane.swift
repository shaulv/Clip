import SwiftUI

/// Diagnostics' own sub-pages (M14). Insights stays directly on the hub,
/// per the plan - it is the one-line-per-subsystem summary everything else
/// here is the full detail behind, and hiding it behind its own chevron
/// would make the hub say nothing until you had already opened something.
///
/// `Views/DiagnosticsView.swift` (the pre-M14 "everything in one Form" view,
/// M8.8) is deliberately left untouched rather than gutted: several
/// pre-existing probe sections outside this milestone's own ownership read
/// its exact source text (its own `.frame` history, its shortcut-report
/// wiring, that no `CLIP_TESTING` guard hides any of it in a shipped
/// build). This pane's sub-pages are a fresh, independent read of the same
/// underlying data (`DiagnosticsReport`, `DiagnosticsInsights`,
/// `ShortcutManager`, `Database.recentLog`, `NoticeCenter`) rather than
/// reaching into that file's own `private` sections - `DiagnosticsView`
/// itself is simply no longer embedded whole in Settings, the same kind of
/// deliberate structural change section 141's own probe documents and this
/// task's own rule expects ("update the assertion to the new intent").
enum DiagnosticsPage: String, CaseIterable, Identifiable, SettingsSubpageID {
    // T3-M5 phase 2: shortcuts/storage/keychain/sync/ai were five separate
    // read-only report dumps - MACRO 32 ("a settings tab holds configuration
    // controls only"). Their content is not lost: it is the union already
    // written by `DiagnosticsReport.full()`, reachable from the hub's single
    // "Copy Diagnostic Report" action. Repair and Open notices stay their
    // own sub-pages - both have real buttons, not just display.
    case repair, notices, activityLog
    var id: String { rawValue }
    var title: String {
        switch self {
        case .repair:      return "Repair"
        case .notices:     return "Open notices"
        case .activityLog: return "Activity log"
        }
    }
    var symbol: String {
        switch self {
        case .repair:      return "wrench.and.screwdriver"
        case .notices:     return "bell.badge"
        case .activityLog: return "list.bullet.rectangle"
        }
    }
}

/// Settings > Diagnostics (M8.8, restructured into a hub + sub-pages by M14).
struct SettingsDiagnosticsPane: View {
    /// Settings surfaces come from the chosen theme, not the system's own
    /// neutral greys: see `SettingsHero`'s note (user, 07/09).
    @EnvironmentObject private var settingsTheme: ThemeManager
    private var st: AppTheme { settingsTheme.settingsTheme }
    @EnvironmentObject var router: SettingsRouter
    @ObservedObject private var notices = NoticeCenter.shared
    @State private var justCopiedReport = false

    /// M9: there is no telemetry in this product, by deliberate choice -
    /// this copyable report is the only field signal that will ever exist
    /// for a stuck user's own machine, and until now nothing on the hub
    /// itself said so or offered it in one press. `DiagnosticsReport.full()`
    /// already existed (built for the now-orphaned `DiagnosticsView`, M8.8's
    /// pre-hub pane) - this is the same call, reachable from the one place a
    /// stuck user actually lands: Settings > Diagnostics, which the menu
    /// bar's own "Open Diagnostics" and every failure alert's "Open
    /// Diagnostics" button already point at.
    private func copyFullReport() {
        let text = DiagnosticsReport.full()
        let pb = TestIsolation.board
        pb.clearContents()
        pb.setString(text, forType: .string)
        justCopiedReport = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { justCopiedReport = false }
    }

    private var needsKeyRepair: Bool { KeychainStore.needsRepair }

    var body: some View {
        Group {
            switch router.page(for: .diagnostics).flatMap(DiagnosticsPage.init(rawValue:)) {
            case nil:              hub
            case .repair:          repairSubpage
            case .notices:         noticesSubpage
            case .activityLog:     activityLogSubpage
            }
        }
    }

    // MARK: - Hub

    private var hub: some View {
        SettingsHub(icon: "stethoscope", title: "Diagnostics",
                    purpose: "Check Clip's own health, and fix what it can fix itself.",
                    groups: [
            SettingsHubGroup(id: "health", rows: [
                .init(id: DiagnosticsPage.repair.rawValue, symbol: DiagnosticsPage.repair.symbol,
                      title: DiagnosticsPage.repair.title,
                      summary: needsKeyRepair ? "Needs repair" : "Nothing to repair",
                      tint: needsKeyRepair ? SettingsPalette.warning : .accentColor),
                .init(id: DiagnosticsPage.notices.rawValue, symbol: DiagnosticsPage.notices.symbol,
                      title: DiagnosticsPage.notices.title,
                      summary: notices.pending.isEmpty ? "None" : "\(notices.pending.count)"),
            ]),
            SettingsHubGroup(id: "reports", title: "Reports", rows: [
                .init(id: DiagnosticsPage.activityLog.rawValue, symbol: DiagnosticsPage.activityLog.symbol,
                      title: DiagnosticsPage.activityLog.title),
            ]),
        ], onSelectRow: { id in router.openSubpage(id, in: .diagnostics) }) {
            insightsCard
        }
    }

    /// "Insights" - the plan's named exception, drawn directly on the hub
    /// rather than behind a chevron: one line per subsystem, cause and
    /// effect, with the action that fixes it.
    private var insightsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(alignment: .firstTextBaseline) {
                Text("Insights").font(Typography.subheading).foregroundStyle(.primary)
                Spacer(minLength: Spacing.tight)
                // The single obvious place for the one signal this product
                // has - no telemetry, by choice, so this copy is it. Placed
                // at the top of the hub rather than tucked into one of the
                // seven reports below, so it never depends on knowing which
                // report has the answer.
                ClipLink(justCopiedReport ? "Copied" : "Copy Diagnostic Report", size: .small) {
                    copyFullReport()
                }
                .accessibilityIdentifier("diagnostics.copyFullReport")
            }
            .padding(.top, Spacing.tight)
            Text("""
                One line per subsystem: what is connected, what has failed, and \
                what to do about it. The reports below have the full detail.
                """)
                .font(Typography.caption).foregroundStyle(SettingsPalette.note)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                ForEach(DiagnosticsInsights.all()) { insight in
                    insightRow(insight)
                }
            }
            .padding(Spacing.comfortable)
            .background(st.cardBackground,
                        in: RoundedRectangle(cornerRadius: SettingsAppleMetrics.cardRadius, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func insightRow(_ insight: DiagnosticsInsights.Insight) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: insight.level.symbol)
                .font(.system(size: SettingsAppleMetrics.rowGlyphSize, weight: .semibold))
                .foregroundStyle(color(for: insight.level))
                .frame(width: SettingsAppleMetrics.rowGlyphSize + 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(insight.subsystem).font(Typography.labelStrong)
                Text(insight.sentence)
                    .font(Typography.caption)
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

    private func subpage<Content: View>(_ page: DiagnosticsPage, @ViewBuilder content: @escaping () -> Content) -> some View {
        SettingsSubpage(tab: .diagnostics, title: page.title, router: router, content: content)
    }

    // MARK: - Repair

    private var repairSubpage: some View {
        subpage(.repair) {
            Form {
                ExplainedSection("Repair", note: """
                    The same repairs the menu bar used to offer directly. Both \
                    explain what they are about to ask before anything runs, \
                    and the result appears in its own alert.
                    """) {
                    HStack(spacing: 10) {
                        // Routes through `AppDelegate.repairKeychainAccess()`,
                        // itself gated behind `CredentialExplainer` (M8.7) -
                        // this button does not ask twice, it reaches the one
                        // funnel every repair entry point already uses.
                        SecondaryButton("Repair AI Key Access…", isDisabled: !needsKeyRepair) {
                            AppDelegate.shared?.repairKeychainAccess()
                        }
                        if !needsKeyRepair {
                            Text("Nothing needs repair right now.")
                                .font(.caption)
                                .foregroundStyle(SettingsPalette.note)
                        }
                    }

                    Divider()

                    SecondaryButton("Reset Accessibility Permission") {
                        AccessibilityGate.resetAndAskAgain()
                    }
                    Text("""
                        Clears Clip's Accessibility grant on this Mac and asks for it \
                        again. Use this if System Settings shows Clip switched on but \
                        pasting still does nothing. That grant belongs to an older \
                        build of Clip.
                        """)
                        .font(.caption)
                        .foregroundStyle(SettingsPalette.note)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Open notices

    private var noticesSubpage: some View {
        subpage(.notices) {
            Form {
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
            .formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
    }

    private func noticeRow(_ notice: NoticeCenter.Notice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(notice.kind.rawValue.uppercased())
                    .font(Typography.micro)
                    .foregroundStyle(noticeColor(notice.kind))
                Text(notice.message)
                    .font(Typography.bodyStrong)
                Spacer(minLength: 0)
            }
            if let remedy = notice.remedy {
                Text(remedy).font(.caption).foregroundStyle(SettingsPalette.note)
            }
            HStack(spacing: 12) {
                if let action = notice.action {
                    ClipLink(action.title, size: .small) { action.run() }
                }
                if notice.kind != .integrity {
                    ClipLink("Dismiss", size: .small) { NoticeCenter.shared.dismiss(notice.id) }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func noticeColor(_ kind: NoticeCenter.Kind) -> Color {
        switch kind {
        case .integrity:  return SettingsPalette.danger
        case .persistent: return SettingsPalette.warning
        case .transient:  return SettingsPalette.note
        case .invitation: return .accentColor
        }
    }

    // MARK: - Activity log

    private var activityLogSubpage: some View {
        subpage(.activityLog) {
            Form {
                ExplainedSection("Activity log",
                                  note: "The last 200 things Clip did to its own data, newest first.") {
                    activityLogRows
                }
            }
            .formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
    }

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
                            .font(Typography.captionMono)
                            .foregroundStyle(SettingsPalette.note)
                        Text("[\(row.1)]")
                            .font(Typography.captionMonoStrong)
                        Text(row.2)
                            .font(Typography.captionMono)
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
}
