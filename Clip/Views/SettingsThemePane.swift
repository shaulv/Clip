import SwiftUI
import AppKit

/// Lets the QA bridge open and close the theme editor sheet the same way a
/// click on "New theme" and Cancel do, without reaching into `ThemePane`'s
/// own `@State` - which QABridge, outside the view hierarchy, cannot touch
/// directly. Each counter only needs to CHANGE; the value itself carries no
/// meaning.
@MainActor
final class ThemeEditorBridge: ObservableObject {
    static let shared = ThemeEditorBridge()
    @Published var openRequested = 0
    @Published var closeRequested = 0
    private init() {}
}

/// Themes' own sub-pages (M14). The theme grid itself ("Your themes") stays
/// directly on the hub per the M14 plan - it is the tab's whole point, and
/// Apple-style progressive disclosure would otherwise hide the one thing
/// everyone opens this tab to do behind a chevron on every visit (the same
/// exception Diagnostics' own Insights list gets). "Theme builder" is the
/// one remaining cluster: starting a new theme, from scratch or from a
/// description - the M14 plan calls this "Theme builder entry; Generation
/// settings", but reading the pane there is no separate "generation
/// settings" content beyond the "Describe a theme" entry point itself
/// (its own sheet, `describeSheet`, is unchanged) - so this is one page,
/// not two.
/// No sub-pages any more (user, 03/09): "the items from theme builder tab move
/// to the theme main tab and at the top so the user can select a theme or
/// add or generate in one screen". The enum stays so the M14 hub machinery
/// treats Themes as a hub with zero chevron rows.
enum ThemesPage: CaseIterable, Identifiable, SettingsSubpageID {
    // Uninhabited on purpose: Themes is a hub with zero chevron rows.
    typealias RawValue = String
    init?(rawValue: String) { nil }
    var rawValue: String { switch self {} }
    var id: String { rawValue }
    var title: String { rawValue }
    var symbol: String { "paintbrush.pointed" }
}

/// Built-in presets, the user's own themes, and the builder.
struct ThemePane: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var router: SettingsRouter
    @StateObject private var customs = CustomThemeStore.shared
    @StateObject private var ai = AIService.shared
    @ObservedObject private var editorBridge = ThemeEditorBridge.shared

    /// The theme a Delete press is waiting for confirmation on. Deleting is
    /// the one action here that cannot be undone by pressing the other one.
    @State private var deleting: CustomTheme?
    /// What the last export or restore has to say, if anything.
    @State private var fileNotice: String?
    @State private var describing = false
    @State private var description = ""
    @State private var aiError: String?

    private let columns = [GridItem(.flexible(), spacing: Spacing.comfortable),
                           GridItem(.flexible(), spacing: Spacing.comfortable)]

    /// Copies a theme into Yours under a "(copy)" name and selects it, so the
    /// duplicate is the thing you are looking at rather than something you have
    /// to go and find.
    private func duplicate(_ source: CustomTheme) {
        let copy = source.duplicated(
            named: CustomTheme.copyName(for: source.name,
                                        existing: customs.themes.map(\.name)))
        customs.save(copy)
        theme.themeID = "custom:\(copy.id)"
    }

    /// The row of actions under a theme card: small, borderless, laid out in
    /// the order they are reached for.
    private func actionRow<Content: View>(@ViewBuilder _ content: () -> Content)
        -> some View {
        HStack(spacing: Spacing.related) {
            content()
        }
        .font(Typography.label)
        .buttonStyle(.plain)
        .foregroundStyle(SettingsPalette.note)
        .padding(.horizontal, 2)
        // V6a: a plain-styled control still answers the pointer.
        .settingsHover(cornerRadius: SettingsPalette.rowHoverRadius)
    }

    /// Writes one theme, or every theme, to a file the user picks.
    private func exportThemes(_ themes: [CustomTheme]) {
        guard !themes.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.nameFieldStringValue = themes.count == 1
            ? "\(themes[0].name).\(ThemeFile.fileExtension)"
            : "Clip themes.\(ThemeFile.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ThemeFile.data(for: themes).write(to: url, options: .atomic)
            fileNotice = themes.count == 1
                ? "Exported \(themes[0].name)."
                : "Backed up \(themes.count) themes."
        } catch {
            fileNotice = "Could not write that file: \(error.localizedDescription)"
        }
    }

    /// Reads a theme file and lands what is in it as new themes.
    private func importThemes() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let incoming = try ThemeFile.read(try Data(contentsOf: url))
            let landed = customs.adopt(incoming)
            // Nothing is overwritten, so the honest report is what arrived and
            // under which name - a restored theme whose name collided is now
            // called something else, and being told beats finding out.
            fileNotice = landed.count == 1
                ? "Restored \(landed[0].name)."
                : "Restored \(landed.count) themes."
        } catch {
            fileNotice = error.localizedDescription
        }
    }

    var body: some View {
        hub
        // Opening the Themes pane is the moment a stuck preview would be
        // noticed, and the moment it can be cleared safely.
        .onAppear { theme.dropOrphanedPreview() }
        // M17: "New theme"/"Edit…"/"Generate" open the builder's own window
        // (`ThemeBuilderWindowController`) - no sheet any more. The QA
        // bridge's open/close counters (M7's own `ThemeEditorBridge`) route
        // to the SAME window calls, so a probe exercises the real path
        // rather than a stand-in.
        .onChange(of: editorBridge.openRequested) { _, _ in
            openBuilder(CustomTheme.from(theme.theme, name: "My theme"))
        }
        .onChange(of: editorBridge.closeRequested) { _, _ in
            ThemeBuilderWindowController.shared.close()
        }
        // Deleting is the one action on this screen that cannot be taken back
        // by pressing something else, so it says what is lost first.
        .alert("Delete \(deleting?.name ?? "this theme")?",
               isPresented: Binding(get: { deleting != nil },
                                    set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let theme = deleting {
                    customs.remove(theme.id)
                    fileNotice = "Deleted \(theme.name)."
                }
                deleting = nil
            }
        } message: {
            Text("This theme is removed from this Mac. Export it first if you "
                 + "want to keep a copy.")
        }
        .alert("Themes", isPresented: Binding(get: { fileNotice != nil },
                                              set: { if !$0 { fileNotice = nil } })) {
            Button("OK") { fileNotice = nil }
        } message: {
            Text(fileNotice ?? "")
        }
    }

    // MARK: - Hub

    private var hub: some View {
        // One screen: pick a theme, add one, or generate one, with nothing
        // behind a chevron (user, 03/09).
        SettingsHub(icon: "paintpalette", title: "Themes",
                    purpose: "Choose how Clip looks, or build a theme of your own.",
                    groups: [], onSelectRow: { _ in }) {
            VStack(alignment: .leading, spacing: Spacing.group) {
                header
                themeGrid
            }
        }
    }

    /// "Your themes" - the M14 plan's named exception, kept as the hub's
    /// own first group rather than behind a chevron.
    private var themeGrid: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            LazyVGrid(columns: columns, spacing: Spacing.comfortable) {
                // A system-following theme's dark form is kept in `presets`
                // (so it is still audited and resolvable by id) but is not a
                // thing the user picks directly - it is reached automatically
                // through the light form's own card, labelled "Follows
                // System" there.
                ForEach(AppTheme.presets.filter { !$0.hiddenFromPicker }) { preset in
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        ThemeCard(preset: preset, selected: theme.themeID == preset.id)
                        // A built-in cannot be edited, deleted or exported -
                        // it is not the user's to change - but it can be the
                        // starting point for one that is, which is what
                        // "duplicate any theme" has to mean. One action, laid
                        // out, so the rule is visible instead of being a thing
                        // you discover by right-clicking and finding less.
                        actionRow { Button("Duplicate") {
                            duplicate(CustomTheme.from(preset, name: preset.name))
                        } }
                    }
                    .contextMenu {
                        Button("Duplicate") { duplicate(CustomTheme.from(preset, name: preset.name)) }
                    }
                }
            }

            HStack(spacing: Spacing.tight) {
                Text("Yours").font(.headline)
                Spacer()
                // Backup and restore for the whole set, beside the heading they
                // belong to rather than in the Export tab: a theme is not data
                // history, and looking for it there is a search.
                if !customs.themes.isEmpty {
                    Button("Back Up All\u{2026}") { exportThemes(customs.themes) }
                        .controlSize(.small)
                }
                Button("Restore\u{2026}") { importThemes() }
                    .controlSize(.small)
            }
            if !customs.themes.isEmpty {
                LazyVGrid(columns: columns, spacing: Spacing.comfortable) {
                    ForEach(customs.themes) { custom in
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            ThemeCard(preset: custom.appTheme,
                                      selected: theme.themeID == "custom:\(custom.id)")
                            // Laid out, not hidden in a context menu: every
                            // one of these was already possible and none of
                            // them was findable.
                            actionRow {
                                Button("Edit\u{2026}") { openBuilder(custom) }
                                Button("Duplicate") { duplicate(custom) }
                                Button("Export\u{2026}") { exportThemes([custom]) }
                                Spacer(minLength: 0)
                                Button("Delete") { deleting = custom }
                                    .foregroundStyle(SettingsPalette.danger)
                            }
                        }
                        .contextMenu {
                            Button("Edit\u{2026}") { openBuilder(custom) }
                            Button("Duplicate") { duplicate(custom) }
                            Button("Export\u{2026}") { exportThemes([custom]) }
                            Divider()
                            Button("Delete", role: .destructive) { deleting = custom }
                        }
                    }
                }
            } else {
                Text("Duplicate a built-in theme above to start one of your own.")
                    .font(Typography.label)
                    .foregroundStyle(SettingsPalette.note)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Opens the builder window on `draft`, wiring Save/Cancel back into
    /// this pane's own store and preview - the same two closures the old
    /// sheet's `onSave`/`onCancel` parameters carried.
    private func openBuilder(_ draft: CustomTheme) {
        ThemeBuilderWindowController.shared.open(draft, themeManager: theme, onSave: { saved in
            customs.save(saved)
            theme.endPreview(keep: "custom:\(saved.id)")
        }, onCancel: {
            theme.endPreview()
        })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack {
                SecondaryButton("New Theme", systemImage: "paintbrush.pointed") {
                    openBuilder(CustomTheme.from(theme.theme, name: "My theme"))
                }

                // Only offered when a model is actually connected.
                if ai.isAvailable {
                    SecondaryButton("Describe a Theme", systemImage: "sparkles") {
                        describing = true
                    }
                }
                Spacer()
            }
            if let aiError {
                Text(aiError).font(.caption).foregroundStyle(SettingsPalette.danger)
            }
        }
        .sheet(isPresented: $describing) { describeSheet }
        .onAppear { if SettingsProbe.themeDescribeOpen { describing = true } }
    }

    /// Free text in, a full custom theme out — dropped straight into the builder
    /// so the user reviews and adjusts before anything is saved.
    ///
    /// M9 9.3, the user's own words: "use markdown editor for the prompt so
    /// the user could paste huge text and see it clearly" - the fixed 90pt
    /// `TextEditor` this replaces clipped a brand brief after a couple of
    /// paragraphs; `MarkdownPromptEditor` grows to a cap with internal scroll.
    private var describeSheet: some View {
        VStack(alignment: .leading, spacing: Spacing.related) {
            Text("Describe the theme you want").font(.headline)
            Text("For example: “warm dark terminal, amber accents, very rounded” or “clean light paper with a soft blue highlight”.")
                .font(.caption).foregroundStyle(SettingsPalette.note)
            MarkdownPromptEditor(text: $description,
                                  placeholder: "warm dark terminal, amber accents, very rounded…",
                                  theme: theme.settingsTheme, minHeight: 220, maxHeight: 420,
                                  testID: "m9_describePrompt", showsPreview: true,
                                  showsAI: true)
            HStack {
                if ai.isWorking { ProgressView().controlSize(.small) }
                Spacer()
                SecondaryButton("Cancel") { describing = false }
                PrimaryButton("Generate",
                              isDisabled: description.trimmingCharacters(in: .whitespaces).isEmpty
                                          || ai.isWorking) { generate() }
            }
        }
        // The document editor's own popup chrome (`DetailView`): the card
        // radius, the same 20pt inset, a hairline border and the panel's own
        // background - so writing a theme description looks and feels like
        // writing anything else in Clip rather than like a system dialog.
        .padding(Spacing.group)
        .frame(width: 680)
        .background(theme.settingsTheme.panelBackground,
                    in: RoundedRectangle(cornerRadius: theme.settingsTheme.radiusContainer,
                                         style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.settingsTheme.radiusContainer, style: .continuous)
            .strokeBorder(theme.settingsTheme.border))
    }

    private func generate() {
        aiError = nil
        Task {
            do {
                let generated = try await ai.generateTheme(from: description)
                describing = false
                description = ""
                openBuilder(generated)          // review before saving
            } catch {
                aiError = AIDiagnosis.read(error).message
            }
        }
    }
}

