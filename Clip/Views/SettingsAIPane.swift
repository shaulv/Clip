import SwiftUI

/// Connections to models: many of them, one main, one backup, each with health.
struct AIPane: View {
    /// Settings surfaces come from the chosen theme, not the system's own
    /// neutral greys: see `SettingsHero`'s note (user, 07/09).
    @EnvironmentObject private var settingsTheme: ThemeManager
    private var st: AppTheme { settingsTheme.settingsTheme }
    @StateObject private var ai = AIService.shared
    @EnvironmentObject var router: SettingsRouter
    @State private var editing: AIProvider?
    @State private var editingKey = ""
    @State private var isNew = false
    /// What the last key-recovery run said, drawn inline under Connections
    /// rather than in an alert - this pane is a real window, so the result
    /// belongs where the person is already looking (M28).
    @State private var recoveryMessage: String?
    @State private var isRecovering = false

    @ObservedObject private var prefs = PreferencesModel.shared
    @ObservedObject private var notices = NoticeCenter.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    /// M2/2.7: whichever AI-key notice is up, so the pane says so at the top
    /// instead of a person having to notice a connection quietly stopped
    /// working. Any account under "provider." covers every connection, not
    /// just the main one.
    private var keyRepairNotice: NoticeCenter.Notice? {
        notices.pending.first {
            guard let key = $0.key else { return false }
            return (key.hasPrefix("keychain.needsRepair.") || key.hasPrefix("keychain.missing."))
                && key.contains("provider.")
        }
    }

    var body: some View {
        // A single unconditional side-effecting statement, not a branch of
        // the view builder below: a `let` as the ENTIRE content of an
        // `if`/`else` arm has nothing for `buildBlock` to see as a view.
        let _ = { SettingsProbe.aiRepairBannerText = keyRepairNotice.map(Self.bannerText) ?? "" }()
        // The recovery result as DRAWN, not as returned: a check that reads
        // the outcome object proves the call ran, and a check that reads this
        // proves the pane actually put it in front of the person (M28).
        let _ = { SettingsProbe.aiRecoveryMessage = recoveryMessage ?? "" }()
        page
            .sheet(item: $editing) { provider in editor(provider) }
    }

    // MARK: - The page

    /// One page (user, 03/09 evening): the hero, the master switch, and -
    /// only while the switch is on - the connections and which of them is
    /// used. Off hides all of it; nothing is lost, the connections and keys
    /// are kept.
    private var page: some View {
        SettingsHub(icon: "sparkles", title: "AI",
                    purpose: "Let Clip rewrite, translate, or summarize what you copy, using a connection you provide.",
                    groups: [], onSelectRow: { _ in }) {
            VStack(alignment: .leading, spacing: Spacing.section) {
                featuresCard
                if prefs.aiFeaturesEnabled {
                    connectionsCard
                    usedCard
                }
            }
        }
    }

    /// The master switch and its explanation, as a card at the top.
    private var featuresCard: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if let notice = keyRepairNotice {
                repairBanner(notice)
            }
            Text("""
                Clip can improve prompts, write titles and tags, explain code and \
                build themes. Turn this off and all of it disappears (the AI \
                settings, the buttons, the menu items) until you turn it back on \
                here.
                """)
                .font(.caption).foregroundStyle(SettingsPalette.note)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Enable AI features", isOn: $prefs.aiFeaturesEnabled)
                .toggleStyle(.switch)
            if !prefs.aiFeaturesEnabled {
                Text("AI is off. Your connections and API keys are kept.")
                    .font(.caption).foregroundStyle(SettingsPalette.note)
            }
        }
        .padding(Spacing.related)
        .background(st.cardBackground, in: RoundedRectangle(cornerRadius: SettingsAppleMetrics.cardRadius, style: .continuous))
    }

    /// A titled card with its note directly under the title, the hub-page
    /// twin of `ExplainedSection` (which needs a `Form`).
    private func sectionCard<Content: View>(_ title: String, note: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: Spacing.related) {
                Text(note)
                    .font(.caption).foregroundStyle(SettingsPalette.note)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                content()
            }
            .padding(Spacing.related)
            .background(st.cardBackground, in: RoundedRectangle(cornerRadius: SettingsAppleMetrics.cardRadius, style: .continuous))
        }
    }

    // MARK: - Connections

    private var connectionsCard: some View {
        sectionCard("Connections", note: """
            Add as many as you like, including several of the same provider. \
            A connection must pass a test before it can be made main or backup. \
            Your key is stored in the macOS Keychain, never in Clip's database and \
            never synced. A model is contacted only when you invoke a feature. \
            There is no background activity, and nothing you copy is ever sent \
            automatically.
            """) {
            ForEach(ai.providers) { provider in
                connectionRow(provider)
                Divider()
            }
            HStack {
                Button {
                    begin(editing: AIProvider(name: "New connection", kind: .openaiCompatible),
                          isNew: true)
                } label: {
                    Label("Add Connection…", systemImage: "plus")
                }
                recoverButton
                Spacer()
                if let progress = ai.checkProgress {
                    // Which one, and how far through. A named connection
                    // and a count is the difference between "working" and
                    // "hung", and the sweep now has a way out.
                    ProgressView().controlSize(.small)
                    Text("Testing \(progress.name) (\(progress.index) of \(progress.total))")
                        .font(.caption).foregroundStyle(SettingsPalette.note)
                    Button("Stop") { ai.cancelCheckAll() }
                } else {
                    Button {
                        ai.beginCheckAll()
                    } label: {
                        Label("Test all", systemImage: "arrow.clockwise")
                    }
                    .disabled(ai.providers.isEmpty)
                }
            }
            if let recoveryMessage {
                Text(recoveryMessage)
                    .font(.caption).foregroundStyle(SettingsPalette.note)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Recovering keys the app forgot but the Keychain did not (M28)

    /// Always here, not only when the app happens to notice.
    ///
    /// The launch notice fires exactly once, on exactly the launch where the
    /// app has no connections and the Keychain does have keys. Someone who
    /// dismissed it, or who added one connection and then wondered where the
    /// other two went, has no way back to it - so the same action lives here,
    /// beside where a key would otherwise be typed in by hand, and can be run
    /// whenever they want.
    ///
    /// Never disabled on a guess about whether there is anything to find:
    /// answering that question means reading the Keychain, which is the one
    /// thing that must not happen before the person asks. A greyed-out button
    /// with no explanation reads as broken code; a button that runs and says
    /// "no saved API keys were found" is the honest version.
    private var recoverButton: some View {
        Button {
            Task { @MainActor in
                isRecovering = true
                let outcome = await KeyRecovery.recover()
                isRecovering = false
                recoveryMessage = outcome.message
            }
        } label: {
            Label("Recover keys from Keychain…", systemImage: "key.horizontal")
        }
        .disabled(isRecovering)
        .help("Re-creates connections from API keys already saved on this Mac. "
            + "After a reinstall, or if a connection went missing.")
    }

    private var usedCard: some View {
        sectionCard("Which connection is used", note: """
            Clip asks the main connection first. If it is down, the backup answers \
            instead, so a model outage does not stop you working.
            """) {
            if ai.providers.isEmpty {
                Text("No connections yet. Add one under Connections to use the AI features.")
                    .font(.caption).foregroundStyle(SettingsPalette.note)
            } else {
                Picker("Main", selection: roleBinding(.primary)) {
                    Text("None").tag("")
                    ForEach(ai.providers.filter(\.isValidated)) { Text($0.name).tag($0.id) }
                }
                .settingsFieldHover(cornerRadius: 6)
                Picker("Backup", selection: roleBinding(.backup)) {
                    Text("None").tag("")
                    ForEach(ai.providers.filter { $0.isValidated && $0.role != .primary }) {
                        Text($0.name).tag($0.id)
                    }
                }
                .settingsFieldHover(cornerRadius: 6)
                if let used = ai.lastUsedProviderName {
                    LabeledContent("Last answered by", value: used)
                }
                if ai.didFailOver {
                    Label("The main connection failed; the backup answered.",
                          systemImage: "arrow.triangle.branch")
                        .font(.caption).foregroundStyle(SettingsPalette.warning)
                }
            }
        }
    }

    // MARK: - The repair banner

    /// What the banner says, for `SettingsProbe` and the row itself - kept as
    /// one pure function so the two can never say different things.
    fileprivate static func bannerText(for notice: NoticeCenter.Notice) -> String {
        let text = notice.remedy.map { "\(notice.message) \($0)" } ?? notice.message
        return text + (notice.action.map { " [\($0.title)]" } ?? "")
    }

    private func repairBanner(_ notice: NoticeCenter.Notice) -> some View {
        Section {
            Label(notice.message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(SettingsPalette.danger)
            if let remedy = notice.remedy {
                Text(remedy).font(.caption2).foregroundStyle(SettingsPalette.note)
            }
            if let action = notice.action {
                Button(action.title) { action.run() }
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Rows

    private func connectionRow(_ p: AIProvider) -> some View {
        HStack(spacing: 10) {
            Image(systemName: healthSymbol(p.health))
                .foregroundStyle(healthColor(p.health))
                .help(p.health.title)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(p.name)
                    if p.role != .unused {
                        Text(p.role.title.uppercased())
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text("\(p.kind.title) · \(p.model)")
                    .font(.caption).foregroundStyle(SettingsPalette.note)
                if p.health == .down, let error = p.lastError {
                    Text(error).font(.caption2).foregroundStyle(SettingsPalette.danger).lineLimit(2)
                }
            }

            Spacer()

            Button("Test") { Task { _ = await ai.validate(p) } }.buttonStyle(.link)
            Button("Edit") { begin(editing: p) }.buttonStyle(.link)
            Button("Remove") { ai.removeProvider(p.id) }.buttonStyle(.link)
        }
        .padding(.vertical, 2)
        // M8.4: a composite row (health icon, name, role badge, detail,
        // three link buttons) - the hover wash goes over the whole row.
        .settingsHover(cornerRadius: 6)
    }

    private func healthSymbol(_ h: ProviderHealth) -> String {
        switch h {
        case .ready:    return "checkmark.circle.fill"
        case .down:     return "exclamationmark.triangle.fill"
        case .untested: return "circle.dashed"
        }
    }

    private func healthColor(_ h: ProviderHealth) -> Color {
        switch h {
        case .ready:    return .green
        case .down:     return .red
        case .untested: return .secondary
        }
    }

    private func roleBinding(_ role: ProviderRole) -> Binding<String> {
        Binding(
            get: { ai.providers.first { $0.role == role }?.id ?? "" },
            set: { id in
                if id.isEmpty {
                    if let current = ai.providers.first(where: { $0.role == role }) {
                        ai.setRole(.unused, for: current.id)
                    }
                } else {
                    ai.setRole(role, for: id)
                }
            }
        )
    }

    // MARK: - Editor

    private func begin(editing provider: AIProvider, isNew: Bool = false) {
        self.isNew = isNew
        editingKey = provider.apiKey ?? ""
        editing = provider
    }

    private func editor(_ provider: AIProvider) -> some View {
        ProviderEditor(provider: provider, key: $editingKey, isNew: isNew) { saved, key, makeMain in
            if isNew { ai.addProvider(saved, key: key) } else { ai.updateProvider(saved, key: key) }
            Task {
                let result = await ai.validate(saved)
                if case .success = result, makeMain {
                    ai.setRole(ai.primaryProvider == nil ? .primary : .backup, for: saved.id)
                }
            }
            editing = nil
        } onCancel: {
            editing = nil
        }
    }
}

/// Adding a connection is a series of choices, not a form full of typing.
private struct ProviderEditor: View {
    @State var provider: AIProvider
    @Binding var key: String
    let isNew: Bool
    let onSave: (AIProvider, String, Bool) -> Void
    let onCancel: () -> Void

    @StateObject private var ai = AIService.shared
    @StateObject private var directory = ModelDirectory.shared
    @State private var serviceID = "nvidia"
    @State private var useCustomModel = false
    @State private var modelSearch = ""
    @State private var testedOnly = false
    @State private var testMessage: String?
    @State private var testOK = false
    @State private var makeMain = true

    /// Curated plus whatever the provider just told us it has.
    private var models: [CatalogModel] {
        ModelCatalog.merged(for: provider)
    }

    /// After the search box and the tested-only filter.
    private var visibleModels: [CatalogModel] {
        var list = models
        if testedOnly {
            list = list.filter {
                ModelCatalog.isTested($0.id, kind: provider.kind, endpoint: provider.endpoint)
            }
        }
        let q = modelSearch.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { $0.id.lowercased().contains(q) || $0.title.lowercased().contains(q) }
        }
        return list
    }

    private func label(for model: CatalogModel) -> String {
        var text = model.label
        if ModelCatalog.isTested(model.id, kind: provider.kind, endpoint: provider.endpoint) {
            text += "  ✓ tested"
        }
        if model.isFree { text += "  · free" }
        return text
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ExplainedSection("Provider", note: """
                    Pick the service you have an account with. Everything below fills \
                    itself in, so you shouldn't have to type a model ID yourself.
                    """) {
                    SettingsTextField("Name", text: $provider.name, prompt: "e.g. OpenAI, work")

                    Picker("Provider", selection: $provider.kind) {
                        ForEach(ProviderKind.allCases) { Text($0.title).tag($0) }
                    }
                    .settingsFieldHover(cornerRadius: 6)
                    .onChange(of: provider.kind) { _, kind in
                        provider.endpoint = kind.endpointHint
                        selectFirstModel()
                        testMessage = nil; testOK = false
                    }

                    if provider.kind == .openaiCompatible {
                        Picker("Service", selection: $serviceID) {
                            ForEach(ModelCatalog.compatibleServices) { service in
                                Text(service.note.isEmpty ? service.title
                                                          : "\(service.title) (\(service.note))")
                                    .tag(service.id)
                            }
                        }
                        .settingsFieldHover(cornerRadius: 6)
                        .onChange(of: serviceID) { _, id in
                            if let s = ModelCatalog.compatibleServices.first(where: { $0.id == id }),
                               !s.endpoint.isEmpty {
                                provider.endpoint = s.endpoint
                                if provider.name.isEmpty || provider.name == "New connection" {
                                    provider.name = s.title
                                }
                            }
                            selectFirstModel()
                            testMessage = nil; testOK = false
                        }
                        if serviceID == "custom" {
                            SettingsTextField("Address", text: $provider.endpoint,
                                              prompt: "https://api.example.com/v1", monospaced: true)
                        }
                    }
                }

                ExplainedSection("Model", note: """
                    Refresh to list every model this key can actually reach, then \
                    filter to the ones Clip has tested. Models are retired without \
                    notice, so picking beats typing.
                    """) {
                    // The search lives INSIDE the dropdown, not beside it.
                    //
                    // A row of its own asked the reader to understand a filter
                    // before they had seen the thing being filtered, and it
                    // filtered a list that was not on screen at the time. In the
                    // dropdown it is where searching is actually wanted: the
                    // moment the list of ninety models is in front of you.
                    ModelPicker(
                        models: visibleModels,
                        selection: $provider.model,
                        search: $modelSearch,
                        testedOnly: $testedOnly,
                        isLoading: directory.isLoading,
                        label: label(for:),
                        refresh: { Task { await directory.refresh(for: provider) } },
                        canRefresh: !(provider.kind.needsKey && key.isEmpty))

                    if let error = directory.lastError {
                        Text(error).font(.caption).foregroundStyle(SettingsPalette.danger)
                    }

                    Toggle("Type it in myself (the exact model ID)", isOn: $useCustomModel)
                    if useCustomModel {
                        SettingsTextField("Model ID", text: $provider.model, prompt: "e.g. gpt-5", monospaced: true)
                    }

                    if ModelCatalog.isTested(provider.model, kind: provider.kind,
                                             endpoint: provider.endpoint) {
                        Label("Tested by Clip", systemImage: "checkmark.seal")
                            .font(.caption).foregroundStyle(SettingsPalette.success)
                    }
                    if let chosen = models.first(where: { $0.id == provider.model }), chosen.isReasoning {
                        Text("This is a reasoning model: it thinks before answering, so replies take a bit longer. Clip handles that automatically.")
                            .font(.caption).foregroundStyle(SettingsPalette.note)
                    }
                }

                if provider.kind.needsKey {
                    ExplainedSection("API key", note: keyNote) {
                        SettingsSecureField("API key", text: $key, prompt: "Paste the key from your provider")
                        if let url = ModelCatalog.keyURL(for: provider.kind, endpoint: provider.endpoint) {
                            Link("Get a key", destination: URL(string: url)!)
                                .font(.caption)
                        }
                    }
                }

                ExplainedSection("Test", note: "A connection has to answer once before Clip will rely on it.") {
                    Toggle("Use this connection once it passes", isOn: $makeMain)
                    if let testMessage {
                        Label(testMessage, systemImage: testOK ? "checkmark.circle.fill"
                                                               : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(testOK ? .green : .red)
                    }
                }
            }
            .formStyle(.grouped)
                .scrollContentBackground(.hidden)

            HStack {
                Button("Test Connection") { runTest() }
                    .disabled(ai.isWorking || (provider.kind.needsKey && key.isEmpty))
                if ai.isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(provider, key, makeMain) }
                    .buttonStyle(.borderedProminent)
                    .disabled(provider.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || provider.model.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
        .onAppear {
            if isNew { selectFirstModel() }
            if let match = ModelCatalog.compatibleServices.first(where: { $0.endpoint == provider.endpoint }) {
                serviceID = match.id
            }
        }
    }

    private var keyNote: String {
        "Stored in the macOS Keychain, never in Clip's database and never synced."
    }

    private func selectFirstModel() {
        if let first = ModelCatalog.models(for: provider.kind, endpoint: provider.endpoint).first {
            provider.model = first.id
            useCustomModel = false
        }
    }

    /// Saving first is deliberate: validation reads the key from the Keychain,
    /// which is the same path a real request takes.
    private func runTest() {
        if isNew { ai.addProvider(provider, key: key) } else { ai.updateProvider(provider, key: key) }
        Task {
            switch await ai.validate(provider) {
            case .success(let reply):
                testOK = true
                testMessage = "Connected. The model replied “\(reply.prefix(50))”."
            case .failure(let error):
                testOK = false
                testMessage = error.localizedDescription
            }
        }
    }
}


/// The model dropdown, with its own search.
///
/// Not a `Picker`: a `Picker` on macOS renders an `NSMenu`, and a menu cannot
/// hold a text field. This is a button that opens a popover - the shape a
/// searchable dropdown has to take here - and it does the three things the row
/// of controls beside the old picker was doing, in the place where they are
/// wanted.
struct ModelPicker: View {
    let models: [CatalogModel]
    @Binding var selection: String
    @Binding var search: String
    @Binding var testedOnly: Bool
    let isLoading: Bool
    let label: (CatalogModel) -> String
    let refresh: () -> Void
    let canRefresh: Bool

    @State private var open = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        LabeledContent("Model") {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(currentLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(SettingsPalette.note)
                }
            }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11)).foregroundStyle(SettingsPalette.note)
                        TextField("Search models", text: $search, prompt: Text("Type to filter"))
                            .textFieldStyle(.roundedBorder).settingsFieldHover()
                            .focused($searchFocused)
                        Button {
                            refresh()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(isLoading || !canRefresh)
                        .help("Ask the provider what this key can actually reach")
                        if isLoading { ProgressView().controlSize(.small) }
                    }

                    Toggle("Only models Clip has tested", isOn: $testedOnly)
                        .toggleStyle(.checkbox)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    if models.isEmpty {
                        Text(search.isEmpty
                             ? "No models listed yet. Press the refresh button."
                             : "Nothing matches “\(search)”.")
                            .font(.caption).foregroundStyle(SettingsPalette.note)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(models) { model in
                                    row(model)
                                }
                            }
                        }
                        .frame(height: min(CGFloat(models.count) * 26 + 8, 260))
                        Text("\(models.count) model\(models.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(SettingsPalette.note)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
                .frame(width: 420)
                // Typing is what the popover is for, so the field has the
                // keyboard the moment it opens.
                .onAppear { DispatchQueue.main.async { searchFocused = true } }
            }
        }
    }

    private var currentLabel: String {
        if let model = models.first(where: { $0.id == selection }) { return label(model) }
        return selection.isEmpty ? "Choose a model" : selection
    }

    private func row(_ model: CatalogModel) -> some View {
        Button {
            selection = model.id
            open = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.id == selection ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10))
                    .foregroundStyle(model.id == selection ? Color.accentColor : SettingsPalette.note)
                Text(label(model))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // M8.4: `.plain`-styled popover row, no native chrome.
        .settingsHover(cornerRadius: 5)
    }
}
