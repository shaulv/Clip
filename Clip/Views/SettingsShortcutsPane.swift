import SwiftUI
import AppKit

/// Every binding in one table, each rebindable, each validated.
///
/// The point of the conflict UI here: a clash never just says "in use". It names
/// the owner and offers a button that takes you straight to it — the other row
/// in this table, or the item that holds the hotkey.
/// Shortcuts' own sub-pages (user, 03/09 evening): the three tables the
/// pane used to stack, one per page, with the two maintenance buttons on
/// the hub itself.
struct ShortcutsPane: View {
    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var router: SettingsRouter
    @EnvironmentObject var theme: ThemeManager
    @StateObject private var registry = ShortcutRegistry.shared
    @StateObject private var ai = AIService.shared

    private var t: AppTheme { theme.settingsTheme }

    @State private var recordingAction: ShortcutAction?
    @State private var drafts: [ShortcutAction: String] = [:]
    @State private var conflict: (ShortcutAction, ShortcutConflict)?
    @State private var highlighted: ShortcutAction?
    @State private var recordingItem: UUID?
    @State private var itemDrafts: [UUID: String] = [:]
    @State private var itemErrors: [UUID: String] = [:]

    /// The one copy of this sentence. QABridge exposes it as
    /// `m8b_itemShortcutsEmptyText` rather than typing it a second time in
    /// Swift, so `run_m8_first_run_and_menu`'s V7 gate reads the string this
    /// pane actually renders instead of a literal that could drift from it.
    static let noItemShortcutsText = "No item has a shortcut yet. Open an item and press Record."

    var body: some View {
        Group {
            flatPage
        }
        .alert(item: Binding(
            get: { conflict.map { ConflictAlert(action: $0.0, conflict: $0.1) } },
            set: { if $0 == nil { conflict = nil } }
        )) { alert in
            conflictAlert(alert)
        }
    }

    // MARK: - The one page (user, 03/09 night): hero, the two maintenance
    // buttons, then all three tables inline - nothing behind a chevron.

    private var flatPage: some View {
        Form {
            SettingsHero(icon: "keyboard", title: "Shortcuts",
                         purpose: "Every key Clip answers to, from any app, inside the panel, and per item, each rebindable.")
                .listRowInsets(EdgeInsets(top: Spacing.tight, leading: 0, bottom: Spacing.related, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            maintenanceCard
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: Spacing.related, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            systemWideSection
            inPanelSection
            itemsSection
        }
        .formStyle(.grouped)
    }

    /// The same report as the menu-bar item, and the one-click reset.
    /// Settings is where a person goes when a shortcut fails, not a right-click.
    private var maintenanceCard: some View {
        HStack(spacing: Spacing.tight + 2) {
            SecondaryButton("Shortcut Diagnostics…") { AppDelegate.shared?.showShortcutDiagnostics() }
            SecondaryButton("Restore All Defaults") {
                registry.resetAll()
                drafts = [:]
            }
            Spacer()
        }
    }

    // MARK: - Sub-pages

    private var systemWideSection: some View {
        Group {
            ExplainedSection("System-wide", note: """
                These work from any app and need at least one modifier key. \
                If a combination is taken, Clip says what already owns it.
                """) {
                ForEach(globalActions) { row($0) }
                globalActionsAINote
            }
        }
    }

    private var inPanelSection: some View {
        Group {
            ExplainedSection("While the panel is open", note: """
                In-panel commands may use a bare key. Arrow keys are reserved for \
                moving between items and their action buttons.
                """) {
                ForEach(panelActions) { row($0) }
            }
        }
    }

    private var itemsSection: some View {
        Group {
            // M8.5, 02/09: ALWAYS present now, not just when non-empty - an
            // absent section answered "do I have any of these" with silence,
            // which is not an answer. Sorted by title so the row order does
            // not depend on when each shortcut happened to be assigned.
            ExplainedSection("Item shortcuts", note: "These paste one specific item from anywhere.") {
                if itemsWithShortcuts.isEmpty {
                    Text(Self.noItemShortcutsText)
                        .font(.caption).foregroundStyle(SettingsPalette.note)
                } else {
                    ForEach(itemsWithShortcuts) { item in
                        itemShortcutRow(item)
                    }
                }
            }
        }
    }

    /// The two paste-action keys need a working connection to do anything;
    /// the recorder stays usable so the combination can be set up ahead of
    /// time, but the pane says so with the one sentence every AI surface
    /// uses - pressing either key while this is up reports the same thing.
    private var globalActionsAINote: some View {
        Group {
            if !ai.isAvailable {
                Text(AIGate.sentence)
                    .font(.caption).foregroundStyle(SettingsPalette.warning)
            }
        }
    }

    private var globalActions: [ShortcutAction] { ShortcutAction.allCases.filter(\.isGlobal) }
    private var panelActions: [ShortcutAction] { ShortcutAction.allCases.filter { !$0.isGlobal } }
    private var itemsWithShortcuts: [ClipboardItem] {
        store.items.filter { !($0.shortcut ?? "").isEmpty }
            .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    // MARK: - Item shortcut row (M8.5)

    /// Kind icon, title (click reveals the item in the panel), the
    /// combination in monospaced, a live status from
    /// `ShortcutManager.itemDiagnostics`, and Remove.
    private func itemShortcutRow(_ item: ClipboardItem) -> some View {
        HStack(alignment: .center) {
            Image(systemName: item.isPrompt ? "sparkles" : item.kind.symbol)
                .foregroundStyle(SettingsPalette.note)
            // Title over where the item lives (user, 03/09 night: the panel
            // tabs that show it); the pair is one tap target that reveals it.
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayTitle).lineLimit(1)
                Text(Self.location(for: item))
                    .font(.caption).foregroundStyle(SettingsPalette.note).lineLimit(1)
                if let error = itemErrors[item.id] {
                    Text(error).font(.caption).foregroundStyle(SettingsPalette.danger).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { revealItem(item.id) }
            Spacer()
            // Edit in place: the same recorder the action rows use.
            ShortcutRecorder(
                value: Binding(get: { itemDrafts[item.id] ?? item.shortcut ?? "" },
                               set: { applyItem($0, to: item.id) }),
                isRecording: Binding(get: { recordingItem == item.id },
                                     set: { recordingItem = $0 ? item.id : nil }))
            .frame(width: 150, height: 26)
            itemStatusText(item)
                .font(.caption)
            ClipLink("Remove", size: .small) { store.setShortcut(nil, for: item.id) }
        }
        // M8.4: the shared hover wash goes over the whole composite row -
        // the row, not the content inside it.
        .settingsRowHover()
        .id(item.id)
    }

    /// Commits a recorded combination straight to the item - `setShortcut`
    /// validates and registers in one call - and, when it is refused, keeps
    /// the old key and says why on the row itself. Empty clears.
    private func applyItem(_ combo: String, to id: UUID) {
        itemDrafts[id] = combo
        if let reason = store.setShortcut(combo.isEmpty ? nil : combo, for: id) {
            itemErrors[id] = reason
            itemDrafts[id] = nil        // roll the field back to the live binding
        } else {
            itemErrors[id] = nil
            itemDrafts[id] = nil
        }
    }

    /// "In Prompts and All" - the visible panel tabs whose category holds
    /// the item, All named last; a match found only in hidden tabs says so.
    /// Static and shared with QABridge (`m8b_itemShortcutRows.location`),
    /// so the words a person reads and the words a probe asserts on come
    /// from the one function.
    @MainActor
    static func location(for item: ClipboardItem) -> String {
        let tabs = TabConfiguration.shared.tabs
        func names(_ specs: [TabSpec]) -> [String] {
            let matching = specs.filter { $0.category.contains(item) }
            return matching.filter { $0.category != .all }.map(\.title)
                 + matching.filter { $0.category == .all }.map(\.title)
        }
        let visible = names(tabs.filter(\.isVisible))
        if !visible.isEmpty { return "In " + visible.joined(separator: " and ") }
        let hidden = names(tabs.filter { !$0.isVisible })
        if !hidden.isEmpty { return "In a hidden tab: " + hidden.joined(separator: ", ") }
        return "Not shown in any tab"
    }

    /// "registered / refused by macOS with the OSStatus words" - sourced
    /// from `ShortcutManager.itemStatusWord`, not re-derived here: two
    /// places computing "is this shortcut actually live" from different
    /// sources is how M0's own hotkey bug went unnoticed for three rounds
    /// of fixes.
    private func itemStatusText(_ item: ClipboardItem) -> Text {
        let (registered, word) = ShortcutManager.shared.itemStatusWord(item.id)
        let capitalized = word.prefix(1).uppercased() + word.dropFirst()
        return Text(capitalized)
            .foregroundStyle(registered ? SettingsPalette.success : SettingsPalette.danger)
    }

    // MARK: - Row

    private func row(_ action: ShortcutAction) -> some View {
        let current = registry.shortcut(for: action)
        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                Text(action.detail).font(.caption).foregroundStyle(SettingsPalette.note)
            }
            Spacer()
            if current != action.defaultShortcut {
                ClipLink("Reset", size: .small) {
                    registry.reset(action)
                    drafts[action] = nil
                }
            }
            // Having no shortcut here is a legitimate, finished choice - not
            // every action needs to be reachable from outside the panel - so
            // clearing one needs a control of its own next to it, not just a
            // reset back to whatever default it started with. Same visible
            // button the per-item shortcut editor already uses, via
            // `ShortcutField`, so "remove this shortcut" looks and behaves
            // identically everywhere a shortcut can be edited.
            if !current.isEmpty {
                GhostButton("Clear", size: .small, isDestructive: true, theme: t) {
                    apply("", to: action)
                }
                .help("Remove this shortcut. Nothing changes until you press Save.")
            }
            ShortcutRecorder(
                value: Binding(
                    get: { drafts[action] ?? registry.shortcut(for: action) },
                    set: { apply($0, to: action) }
                ),
                isRecording: Binding(
                    get: { recordingAction == action },
                    set: { recordingAction = $0 ? action : nil }
                )
            )
            .frame(width: 150, height: 26)
        }
        // M8.4: the shared hover wash, distinct from the accent-tinted
        // "this row owns the clashing shortcut" flash below - that flash
        // means something specific (a conflict was just resolved to here)
        // and must not be confused with "the pointer happens to be over
        // this row right now". `settingsRowHover` (06/09) covers the ROW,
        // not just the content: the wash used to stop wherever this row's
        // controls happened to end.
        .settingsRowHover()
        .listRowBackground(highlighted == action
                           ? Color.accentColor.opacity(0.18) : Color.clear)
        .id(action)
    }

    private func apply(_ combo: String, to action: ShortcutAction) {
        drafts[action] = combo
        if let c = registry.assign(combo, to: action) {
            conflict = (action, c)
            drafts[action] = nil        // roll the field back to the live binding
        }
    }

    // MARK: - Conflict

    private struct ConflictAlert: Identifiable {
        let action: ShortcutAction
        let conflict: ShortcutConflict
        var id: String { action.rawValue + conflict.message }
    }

    private func conflictAlert(_ alert: ConflictAlert) -> Alert {
        // Where the clash lives decides what "go to it" means.
        switch alert.conflict.owner {
        case .action(let other):
            return Alert(
                title: Text("That shortcut is taken"),
                message: Text("\(alert.conflict.message)\n\nChange that one first, or pick a different combination."),
                primaryButton: .default(Text("Show “\(other.title)”")) { reveal(other) },
                secondaryButton: .cancel(Text("OK"))
            )
        case .item(let id, let name):
            return Alert(
                title: Text("That shortcut is taken"),
                message: Text(alert.conflict.message),
                primaryButton: .default(Text("Show “\(name)”")) { revealItem(id) },
                secondaryButton: .cancel(Text("OK"))
            )
        case .pasteAction(_, let name):
            return Alert(
                title: Text("That shortcut is taken"),
                message: Text(alert.conflict.message),
                primaryButton: .default(Text("Show “\(name)”")) { SettingsRouter.shared.tab = .pasteActions },
                secondaryButton: .cancel(Text("OK"))
            )
        case .system:
            return Alert(title: Text("That shortcut is not available"),
                         message: Text(alert.conflict.message),
                         dismissButton: .default(Text("OK")))
        }
    }

    /// Flashes the owning row so the user can see which binding to change.
    private func reveal(_ action: ShortcutAction) {
        highlighted = action
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if highlighted == action { highlighted = nil }
        }
    }

    /// Opens the panel on the item that owns the hotkey.
    /// Opens the panel on the item this row belongs to, in a tab that actually
    /// contains it.
    ///
    /// It used to select the item and open the detail overlay without touching
    /// the tab, so an item the active tab does not hold was selected and
    /// invisible - the panel opened on a list it was not in (user, 06/09:
    /// "show and highlight the item in the panel, if it's in a tab then show
    /// in a tab and if not then show in All").
    private func revealItem(_ id: UUID) {
        guard let item = store.item(id) else { return }
        let home = TabConfiguration.shared.visible
            .first { $0.id != "all" && $0.category.contains(item) }
        store.activeTabID = home?.id ?? "all"
        PanelController.shared.open(from: .hotkey)
        // After the open, not before: selecting drives the list's own
        // scroll-to-selection, and a selection made before the list exists
        // scrolls nothing.
        DispatchQueue.main.async { store.select(id) }
    }
}
