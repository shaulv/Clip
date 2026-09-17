import SwiftUI
import ServiceManagement
import AppKit

/// Shared card used by both preset and custom theme grids.
struct ThemeCard: View {
    let preset: AppTheme
    let selected: Bool
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                theme.themeID = preset.id
                if !preset.id.hasPrefix("custom:") {
                    theme.density = preset.defaultDensity
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 6) {
                    HStack {
                        Circle().fill(preset.accent).frame(width: 18, height: 18)
                        Spacer()
                        RoundedRectangle(cornerRadius: 6).fill(preset.cardBackground).frame(width: 80, height: 16)
                        RoundedRectangle(cornerRadius: 6).fill(preset.surfaceBackground).frame(width: 28, height: 16)
                    }
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 6).fill(preset.cardBackground).frame(height: 42)
                        RoundedRectangle(cornerRadius: 6).fill(preset.selectedBackground).frame(height: 42)
                        RoundedRectangle(cornerRadius: 6).fill(preset.surfaceBackground).frame(height: 42)
                    }
                }
                .padding(10)
                .background(preset.panelBackground, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? preset.accent : Color.black.opacity(0.06),
                                  lineWidth: selected ? 2 : 1))

                HStack(spacing: 8) {
                    Image(systemName: preset.symbol).foregroundStyle(preset.accent)
                    Text(preset.name).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(preset.accent) }
                }
                // Says in plain language which of the two things this theme
                // is: a fixed color set, or one that switches with the OS.
                // Named here rather than left to the swatch preview, which
                // only ever shows ONE of the two forms and cannot say so on
                // its own.
                if preset.followsSystemAppearance {
                    Label("Follows System: light in Light Mode, dark in Dark Mode",
                          systemImage: "circle.righthalf.filled")
                        .font(.system(size: 10))
                        .foregroundStyle(SettingsPalette.note)
                }
            }
            .padding(12)
            .background(theme.settingsTheme.cardBackground, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // M8.4: `.buttonStyle(.plain)` strips every bit of AppKit's own
        // button chrome, including hover - a theme card got none at all
        // before this.
        .settingsHover(cornerRadius: 14)
    }
}

// MARK: - General

/// General's own sub-pages (user, 03/09 evening): related settings
/// clustered - how Clip starts and where it opens, how it pastes, what it
/// keeps.
enum GeneralPage: String, CaseIterable, Identifiable, SettingsSubpageID {
    case startup, pasting, history, updates, appearance
    var id: String { rawValue }
    var title: String {
        switch self {
        case .startup:    return "Startup and opening"
        case .pasting:    return "Pasting"
        case .history:    return "History"
        case .updates:    return "Updates"
        case .appearance: return "Settings Dark/Light Mode"
        }
    }
    var symbol: String {
        switch self {
        case .startup:    return "power"
        case .pasting:    return "doc.on.clipboard"
        case .history:    return "clock.arrow.circlepath"
        case .updates:    return "arrow.down.circle"
        case .appearance: return "circle.lefthalf.filled"
        }
    }
}

struct GeneralPane: View {
    @EnvironmentObject var store: HistoryStore
    @ObservedObject private var prefs = PreferencesModel.shared
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var router: SettingsRouter
    @State private var loginError: String?
    @State private var confirmingClearUnpinned = false
    @State private var confirmingClearAll = false
    /// True once the user has moved the history stepper in this session.
    ///
    /// `.task(id:)` also runs on appear, and applying the cap because somebody
    /// opened the History page is not something they asked for.
    @State private var historyLimitTouched = false

    var body: some View {
        switch router.page(for: .general).flatMap(GeneralPage.init(rawValue:)) {
        case nil:         hub
        case .startup:    startupSubpage
        case .pasting:    pastingSubpage
        case .history:    historySubpage
        case .updates:    updatesSubpage
        case .appearance: appearanceSubpage
        }
    }

    // MARK: - Hub

    private var hub: some View {
        SettingsHub(icon: "gearshape", title: "General",
                    purpose: "How Clip starts, how it pastes, and how much it keeps.",
                    groups: [
            SettingsHubGroup(id: "general", rows: GeneralPage.allCases.map { page in
                .init(id: page.rawValue, symbol: page.symbol, title: page.title, summary: summary(for: page))
            })
        ], onSelectRow: { id in router.openSubpage(id, in: .general) })
    }

    // MARK: - Subpage: Settings Dark/Light Mode (M2)

    /// Whether this window follows the Mac's light and dark setting, or stays
    /// on one of them. Dedicated sub-page keeps the setting focused, explains
    /// that it only affects Settings, and routes to Themes for the clipboard panel.
    private var appearanceSubpage: some View {
        subpage(.appearance) {
            ExplainedSection("Settings window", note: """
                Choose how this Settings window looks. It does not change the \
                clipboard panel.
                """) {
                Picker("Settings window", selection: Binding(
                    get: { theme.settingsAppearance },
                    set: { theme.settingsAppearance = $0 }
                )) {
                    ForEach(ThemeManager.SettingsAppearance.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!theme.settingsAppearanceApplies)
                .help("Whether this Settings window follows your Mac's light and dark setting, or stays on one of them.")
                if !theme.settingsAppearanceApplies {
                    Text("The current theme (\(theme.theme.name)) only has a \(theme.theme.isDark ? "dark" : "light") appearance.")
                        .font(.caption)
                        .foregroundStyle(SettingsPalette.note)
                }
            }

            ExplainedSection("Clipboard panel theme", note: """
                To change the clipboard panel, choose a theme.
                """) {
                HStack {
                    Text("To change the clipboard panel, choose a theme.")
                        .font(.caption)
                        .foregroundStyle(SettingsPalette.note)
                    Spacer()
                    Button("Open Themes") {
                        router.tab = .themes
                    }
                }
            }
        }
    }

    private func summary(for page: GeneralPage) -> String {
        switch page {
        case .startup:
            let tab = TabConfiguration.shared.visible.first { $0.id == theme.initialTabID }?.title ?? "first tab"
            return (prefs.launchAtLogin ? "launches at login" : "opened by hand") + ", starts on \(tab)"
        case .pasting:
            return (prefs.pasteAutomatically ? "pastes when you choose" : "copies when you choose")
                 + (prefs.numberShortcuts ? ", ⌘1–⌘9 on" : "")
        case .history:
            return (prefs.historyLimitEnabled ? "keeps \(prefs.historyLimit) items" : "keeps everything")
                 + (prefs.clearOnQuit ? ", clears on quit" : "")
        case .updates:
            return prefs.checkForUpdatesAutomatically ? "checks automatically" : "manual check only"
        case .appearance:
            return theme.settingsAppearance.title
        }
    }

    private func subpage<Content: View>(_ page: GeneralPage, @ViewBuilder content: @escaping () -> Content) -> some View {
        SettingsSubpage(tab: .general, title: page.title, router: router) {
            Form { content() }.formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Startup and opening

    private var startupSubpage: some View {
        subpage(.startup) {
            ExplainedSection("Startup", note: "Clip can start itself when you log in.") {
                Toggle("Launch at login", isOn: Binding(
                    get: { prefs.launchAtLogin },
                    set: { prefs.launchAtLogin = $0; applyLaunchAtLogin($0) }
                ))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(SettingsPalette.danger)
                }
            }

            ExplainedSection("Opening", note: "Which tab the panel lands on.") {
                Picker("Open on", selection: $theme.initialTabID) {
                    ForEach(TabConfiguration.shared.visible) { Text($0.title).tag($0.id) }
                }
                .settingsFieldHover(cornerRadius: 6)
                Text("Each tab keeps its own layout and density, set in Tabs.")
                    .font(.caption).foregroundStyle(SettingsPalette.note)
            }
        }
    }

    // MARK: - Pasting

    private var pastingSubpage: some View {
        subpage(.pasting) {
            ExplainedSection("Pasting", note: """
                How Clip behaves when you choose an item.
                """) {
                Toggle("Paste automatically after choosing an item", isOn: $prefs.pasteAutomatically)
                Toggle("Use ⌘1–⌘9 to paste the first nine items", isOn: $prefs.numberShortcuts)
            }
        }
    }

    // MARK: - History

    private var historySubpage: some View {
        subpage(.history) {
            ExplainedSection("History", note: """
                Clip keeps everything by default. Set a limit and older items past it are removed from this Mac, including from the database. Pinned items, and anything saved as a prompt, note or skill, are exempt and always kept.
                """) {
                // Two controls, not a stepper with a magic "0 means keep
                // everything" value: unlimited is the default and has to read
                // as a deliberate state, not as the bottom of a number range.
                // The stepper stays visible but disabled when the cap is off,
                // so the number the user last chose is still in front of them
                // and turning the cap back on is one click, not a re-guess.
                Picker("Saving", selection: $prefs.historyLimitEnabled) {
                    Text("Keep everything").tag(false)
                    Text("Keep at most").tag(true)
                }
                .pickerStyle(.inline)
                Stepper(value: $prefs.historyLimit, in: 10...100_000, step: 10) {
                    Text("\(prefs.historyLimit) items")
                }
                .disabled(!prefs.historyLimitEnabled)
                // Lowering the cap has to act on the library that is already
                // here, not only on what arrives next. Without this the new
                // limit describes nothing until the next capture.
                //
                // But it must act ONCE, on the number the user stopped at. The
                // range is 10 to 100,000 in steps of 10, and this used to run
                // the trim on every `onChange` - so holding the down arrow from
                // 10,000 to 200 performed about 980 separate irreversible
                // trims, each deleting rows, on a control whose whole job is to
                // be held down. `.task(id:)` cancels and restarts on each tick,
                // so the sleep only ever completes after the stepper has been
                // still for a moment: one trim, at the value that is actually
                // on screen.
                .onChange(of: prefs.historyLimit) { _, _ in historyLimitTouched = true }
                .task(id: prefs.historyLimit) {
                    guard historyLimitTouched else { return }
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    guard !Task.isCancelled else { return }
                    HistoryStore.shared.applyHistoryLimitNow()
                }
                // Turning the cap on or off is one deliberate click, not a
                // repeat-key, so it applies immediately.
                .onChange(of: prefs.historyLimitEnabled) { _, _ in
                    HistoryStore.shared.applyHistoryLimitNow()
                }
                Stepper(value: $prefs.maxTextKB, in: 16...8192, step: 16) {
                    Text("Skip text larger than \(prefs.maxTextKB) KB")
                }
                Stepper(value: $prefs.pollIntervalMS, in: 100...2000, step: 50) {
                    Text("Check the clipboard every \(prefs.pollIntervalMS) ms")
                }
                .onChange(of: prefs.pollIntervalMS) { _, _ in ClipboardMonitor.shared.restart() }
                Toggle("Clear history when quitting", isOn: $prefs.clearOnQuit)
                // T3-M5 phase 2 (slice 5): `HistoryStore.deduplicate` already
                // existed and already gated the real fold (capture, and an
                // edit that turns one item into a copy of another), but had
                // no row anywhere in Settings - a preference nobody could
                // see or turn off. One home, next to the other history
                // behaviors it changes.
                Toggle("Combine copies of the same thing", isOn: Binding(
                    get: { store.deduplicate },
                    set: { store.deduplicate = $0 }
                ))
                Text("""
                    Copying the exact same text or image again keeps the one \
                    already in your history, instead of adding a second copy.
                    """)
                    .font(.caption).foregroundStyle(SettingsPalette.note)
            }

            ExplainedSection("Clear history", note: """
                Removes items from this Mac. Prompts, notes, skills and design
                documents are never touched: only clipboard history. This cannot
                be undone.
                """) {
                Button("Clear Unpinned…") { confirmingClearUnpinned = true }
                Button("Clear Everything…", role: .destructive) { confirmingClearAll = true }
            }
        }
        // Both are irreversible, so both ask. In the footer they did not: the
        // menu fired straight through.
        .confirmationDialog("Clear unpinned items?",
                            isPresented: $confirmingClearUnpinned, titleVisibility: .visible) {
            Button("Clear Unpinned", role: .destructive) { store.clearUnpinned() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pinned items stay. Prompts, notes, skills and design documents are not affected.")
        }
        .confirmationDialog("Clear the entire history?",
                            isPresented: $confirmingClearAll, titleVisibility: .visible) {
            Button("Clear Everything", role: .destructive) { store.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every clipboard item on this Mac is removed, pinned ones included. Prompts, notes, skills and design documents are kept. This cannot be undone.")
        }
    }

    // MARK: - Updates

    private var updatesSubpage: some View {
        subpage(.updates) {
            ExplainedSection("Updates", note: """
                Clip can check for a new version on its own, once a day, or \
                only when you ask. Either way nothing installs without your \
                say-so - you always see what changed before it does.
                """) {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { prefs.checkForUpdatesAutomatically },
                    set: { prefs.checkForUpdatesAutomatically = $0
                           UpdateController.shared.automaticallyChecksForUpdates = $0 }
                ))
                Button("Check for Updates…") { UpdateController.shared.checkForUpdates() }
                if let last = UpdateController.shared.lastUpdateCheckDate {
                    Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(SettingsPalette.note)
                }
            }
        }
    }

    /// Registering a login item can genuinely fail (sandbox, MDM), so surface it
    /// rather than leaving a toggle that lies.
    private func applyLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Could not change the login item: \(error.localizedDescription)"
        }
    }
}
