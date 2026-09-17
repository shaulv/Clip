import SwiftUI

/// What the paste action menu contains, in what order, and the two languages
/// the one-key translation goes between.
///
/// Built on the Tabs pane's pattern on purpose: a list with a drag handle, a
/// switch per row and a restore-defaults footer is already the answer to "which
/// of these do I want, and in what order" in this app, and a second answer to
/// the same question is a second thing to learn.
/// Paste Actions' own sub-pages (M14): the menu itself, the two inputs that
/// feed specific actions (translation's own language pair, and the style
/// list "Rewrite in a style" draws from), and the two system-wide keys that
/// trigger the feature without a panel on screen. The M14 plan's own
/// candidate label for the third page was "Defaults" - reading the actual
/// pane, that content is `keysSection` ("Keys"), so this keeps the pane's
/// own existing header word rather than the plan's generic guess.
enum PasteActionsPage: String, CaseIterable, Identifiable, SettingsSubpageID {
    case actions, languagesAndStyles, keys
    var id: String { rawValue }
    var title: String {
        switch self {
        case .actions:            return "Actions"
        case .languagesAndStyles: return "Languages and styles"
        case .keys:               return "Keys"
        }
    }
    var symbol: String {
        switch self {
        case .actions:            return "list.bullet"
        case .languagesAndStyles: return "globe"
        case .keys:               return "keyboard"
        }
    }
}

struct PasteActionsPane: View {
    /// Settings surfaces come from the chosen theme, not the system's own
    /// neutral greys: see `SettingsHero`'s note (user, 07/09).
    @EnvironmentObject private var settingsTheme: ThemeManager
    private var st: AppTheme { settingsTheme.settingsTheme }
    @ObservedObject private var store = PasteActionStore.shared
    @ObservedObject private var registry = ShortcutRegistry.shared
    @StateObject private var ai = AIService.shared
    @EnvironmentObject var router: SettingsRouter

    @State private var newLanguage = ""
    @State private var newStyle = ""
    @State private var showingCustom = false
    @State private var customTitle = ""
    @State private var customInstruction = ""
    @State private var problem: String?

    var body: some View {
        Group {
            switch router.page(for: .pasteActions).flatMap(PasteActionsPage.init(rawValue:)) {
            case nil:                    hub
            case .actions:                actionsSubpage
            case .languagesAndStyles:     languagesAndStylesSubpage
            case .keys:                   keysSubpage
            }
        }
        .sheet(isPresented: $showingCustom) { customSheet }
        .alert("That did not work", isPresented: Binding(
            get: { problem != nil }, set: { if !$0 { problem = nil } }
        )) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: - Hub

    private var hub: some View {
        SettingsHub(icon: "text.badge.plus", title: "Paste Actions",
                    purpose: "Run a quick action on what you're about to paste, right from the menu. Drag and drop to change the order.",
                    groups: [
            SettingsHubGroup(id: "pasteActions", rows: [
                .init(id: PasteActionsPage.actions.rawValue, symbol: PasteActionsPage.actions.symbol,
                      title: PasteActionsPage.actions.title, summary: "\(store.enabled.count) in the menu"),
                .init(id: PasteActionsPage.languagesAndStyles.rawValue,
                      symbol: PasteActionsPage.languagesAndStyles.symbol,
                      title: PasteActionsPage.languagesAndStyles.title),
                .init(id: PasteActionsPage.keys.rawValue, symbol: PasteActionsPage.keys.symbol,
                      title: PasteActionsPage.keys.title),
            ])
        ], onSelectRow: { id in router.openSubpage(id, in: .pasteActions) }) {
            // These need a model connection - shown once, on the hub, rather
            // than repeated on both sub-pages a missing connection affects.
            if !ai.isAvailable {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("These need a model connection.")
                        Text("Everything here can be arranged now and works the moment AI is on.")
                            .font(.caption).foregroundStyle(SettingsPalette.note)
                    }
                    Spacer()
                    Button("Open AI Settings") { SettingsRouter.shared.tab = .ai }
                }
                .padding(Spacing.comfortable)
                .background(st.cardBackground,
                            in: RoundedRectangle(cornerRadius: SettingsAppleMetrics.cardRadius, style: .continuous))
            }
        }
    }

    private func subpage<Content: View>(_ page: PasteActionsPage, @ViewBuilder content: @escaping () -> Content) -> some View {
        SettingsSubpage(tab: .pasteActions, title: page.title, router: router, content: content)
    }

    // MARK: - Actions

    private var actionsSubpage: some View {
        subpage(.actions) {
            VStack(spacing: 0) {
                List {
                    actionsSection
                }
                Divider()
                HStack {
                    Button("Restore Defaults") { store.resetToDefaults() }
                    Spacer()
                    Text("\(store.enabled.count) in the menu")
                        .font(.caption).foregroundStyle(SettingsPalette.note)
                }
                .padding(12)
            }
        }
    }

    // MARK: - Languages and styles

    private var languagesAndStylesSubpage: some View {
        subpage(.languagesAndStyles) {
            List {
                translateSection
                stylesSection
            }
        }
    }

    // MARK: - Keys

    private var keysSubpage: some View {
        subpage(.keys) {
            List {
                keysSection
            }
        }
    }

    // MARK: - The two keys

    private var keysSection: some View {
        Section {
            keyRow(.pasteTranslated)
            keyRow(.pasteWithActions)
            Text("Both work from any app, with no panel on screen. The result is pasted where you were typing.")
                .font(.caption).foregroundStyle(SettingsPalette.note)
        } header: {
            Text("Keys")
        }
    }

    private func keyRow(_ action: ShortcutAction) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                Text(action.detail)
                    .font(.caption).foregroundStyle(SettingsPalette.note)
            }
            Spacer()
            Text(Shortcut.display(registry.shortcut(for: action)))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsPalette.note)
            // Changed where every other binding is changed. Two places to edit
            // a shortcut is two places for them to disagree.
            Button("Change") { SettingsRouter.shared.tab = .shortcuts }
        }
    }

    // MARK: - Auto translate

    private var translateSection: some View {
        Section {
            HStack {
                Text("Between")
                Picker("", selection: Binding(
                    get: { store.pair.first },
                    set: { store.setPair(first: $0, second: store.pair.second) }
                )) {
                    ForEach(store.languages, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 150)
                .settingsFieldHover(cornerRadius: 6)

                Text("and")
                Picker("", selection: Binding(
                    get: { store.pair.second },
                    set: { store.setPair(first: store.pair.first, second: $0) }
                )) {
                    ForEach(store.languages, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 150)
                .settingsFieldHover(cornerRadius: 6)
                Spacer()
            }
            Text("One key, either direction. Clip works out which language the text is in and gives you the other one, so the same shortcut takes you both ways.")
                .font(.caption).foregroundStyle(SettingsPalette.note)

            DisclosureGroup("Languages in the submenu (\(store.languages.count))") {
                ForEach(store.languages, id: \.self) { language in
                    HStack {
                        Text(language)
                        if language == store.pair.first || language == store.pair.second {
                            Text("in the pair")
                                .font(.caption).foregroundStyle(SettingsPalette.note)
                        }
                        Spacer()
                        // The two in the pair have no remove button rather than
                        // a disabled one: the reason is visible in the row next
                        // to it, so a greyed control would be asking a question
                        // already answered.
                        if language != store.pair.first, language != store.pair.second,
                           store.languages.count > 2 {
                            Button("Remove") { store.removeLanguage(language) }
                                .buttonStyle(.link)
                        }
                    }
                }
                HStack {
                    TextField("Add a language", text: $newLanguage, prompt: Text("e.g. Spanish"))
                        .textFieldStyle(.roundedBorder).settingsFieldHover()
                        .onSubmit(addLanguage)
                    Button("Add", action: addLanguage)
                        .disabled(newLanguage.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } header: {
            Text("Translation")
        }
    }

    private func addLanguage() {
        problem = store.addLanguage(newLanguage)
        if problem == nil { newLanguage = "" }
    }

    // MARK: - The action list

    private var actionsSection: some View {
        Section {
            ForEach(store.actions) { action in
                actionRow(action)
            }
            .onMove { offsets, destination in move(offsets, destination) }

            Button {
                customTitle = ""
                customInstruction = ""
                showingCustom = true
            } label: {
                Label("Add a custom action", systemImage: "plus")
            }
        } header: {
            // The note goes under the title, never in a footer: a caption below
            // a list of eighteen rows is read after the decision it was meant
            // to inform. Every other pane in this app follows the same rule.
            VStack(alignment: .leading, spacing: 2) {
                Text("Menu")
                // Two lines on purpose: a grouped-Form header clips one long
                // line to an ellipsis (seen 04/09), and the instruction is
                // the part that must survive.
                Text("Tick an action to put it in the menu, then drag and drop to change the order.")
                    .font(.caption).foregroundStyle(SettingsPalette.note)
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                Text("Turn an action off and it disappears from the menu instead of sitting there grayed out.")
                    .font(.caption).foregroundStyle(SettingsPalette.note)
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func actionRow(_ action: PasteAction) -> some View {
        HStack(alignment: .center, spacing: Spacing.related) {
            actionLeadingInfo(action)
            actionTrailingControls(action)
        }
        .padding(.vertical, Spacing.tight)
        .settingsHover(cornerRadius: 6)
    }

    private func actionLeadingInfo(_ action: PasteAction) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: action.symbol)
                .frame(width: 20)
                .foregroundStyle(SettingsPalette.note)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(action.kind == .custom
                     ? (action.instruction ?? "")
                     : action.kind.detail)
                    .font(.caption)
                    .foregroundStyle(SettingsPalette.note)
                    .lineLimit(2)
                    .truncationMode(.tail)
                if action.kind.hasSubmenu {
                    Text("\(store.submenu(for: action).count) in submenu")
                        .font(.caption)
                        .foregroundStyle(SettingsPalette.note)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(0)
    }

    private func actionTrailingControls(_ action: PasteAction) -> some View {
        HStack(spacing: 8) {
            if action.isRemovable {
                Button("Delete") { store.remove(action.id) }
                    .buttonStyle(.link)
            }

            if let shortcut = action.shortcut, !shortcut.isEmpty {
                GhostButton("Clear", size: .small, isDestructive: true, theme: st) {
                    if let err = store.setShortcut(nil, for: action.id) {
                        problem = err
                    }
                }
                .help("Remove this shortcut.")
            }

            ShortcutRecorder(
                value: Binding(
                    get: { action.shortcut ?? "" },
                    set: { new in
                        let err = store.setShortcut(new.isEmpty ? nil : new, for: action.id)
                        if err != nil { problem = err }
                    }
                ),
                isRecording: .constant(false)
            )
            .frame(width: 120, height: 24)

            Toggle("", isOn: Binding(
                get: { action.isEnabled },
                set: { store.setEnabled(action.id, $0) }
            ))
            .labelsHidden()
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    private func move(_ offsets: IndexSet, _ destination: Int) {
        var all = store.actions
        all.move(fromOffsets: offsets, toOffset: destination)
        store.replaceAll(all)
    }

    // MARK: - Styles

    private var stylesSection: some View {
        Section {
            ForEach(store.styles, id: \.self) { style in
                HStack {
                    Text(style)
                    Spacer()
                    if store.styles.count > 1 {
                        Button("Remove") { store.removeStyle(style) }
                            .buttonStyle(.link)
                    }
                }
            }
            HStack {
                TextField("Add a style", text: $newStyle, prompt: Text("e.g. Formal"))
                    .textFieldStyle(.roundedBorder).settingsFieldHover()
                    .onSubmit(addStyle)
                Button("Add", action: addStyle)
                    .disabled(newStyle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Styles for Rewrite in a Style")
        }
    }

    private func addStyle() {
        problem = store.addStyle(newStyle)
        if problem == nil { newStyle = "" }
    }

    // MARK: - Custom action

    private var customSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A custom paste action")
                .font(.headline)
            Text("The name appears in the menu. The instruction is what the model is told to do with whatever you are pasting. It is added to a rule that the reply must be the text alone, so it lands cleanly in your document.")
                .font(.caption).foregroundStyle(SettingsPalette.note)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Name, as it appears in the menu", text: $customTitle, prompt: Text("e.g. Make it shorter"))
                .textFieldStyle(.roundedBorder).settingsFieldHover()
            // The same editor every other prose field uses, so an instruction
            // written here gets the preview and the AI menu a document does.
            MarkdownPromptEditor(text: $customInstruction,
                                 placeholder: "Rewrite this as a one-paragraph post\u{2026}",
                                 theme: ThemeManager.shared.theme,
                                 minHeight: 110, maxHeight: 220,
                                 showsPreview: true, showsAI: true)

            Text("For example: “Rewrite this as a one-paragraph LinkedIn post, no hashtags.”")
                .font(.caption).foregroundStyle(SettingsPalette.note)

            HStack {
                Button("Cancel") { showingCustom = false }
                Spacer()
                Button("Add") {
                    if let why = store.addCustom(title: customTitle,
                                                 instruction: customInstruction) {
                        problem = why
                    } else {
                        showingCustom = false
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}
