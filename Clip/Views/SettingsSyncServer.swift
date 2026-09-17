import SwiftUI
import AppKit

/// SyncPane's self-hosted server mechanics (T4-M3 split of
/// SettingsSyncPane.swift): the Server sub-page, creating or pasting a token,
/// the leftover-token card, the server address/credentials form, the setup-kit
/// export, carrying settings to another Mac, and the actions behind all of it.
/// Pure extraction: no behaviour or string changes, only the file boundary
/// moved (design-taste rule 12).
extension SyncPane {

    // MARK: - Sub-page: Server

    var serverSections: some View {
        Group {
            Group {
                if let notice = tokenRepairNotice {
                    repairBanner(notice)
                } else {
                    let _ = { SettingsProbe.syncRepairBannerText = "" }()
                }
                serviceSection
                // Connecting with a token happens here, on the same page as
                // the server it belongs to, once nothing is connected yet.
                if case .none = sync.connection {
                    if let leftover = sync.token {
                        leftoverTokenSection(leftover)
                    }
                    createTokenSection
                    pasteTokenSection
                }
                syncErrorSection
            }
        }
    }

    /// The last sync error, wherever a connection is being made.
    @ViewBuilder
    var syncErrorSection: some View {
        if let error = sync.lastError, !error.isEmpty {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(SettingsPalette.danger)
            }
        }
    }

    // MARK: - Not connected (Sync method: server, no token yet)

    var createTokenSection: some View {
        ExplainedSection("Sync with a token", note: """
            No account, nothing to sign up for. Clip gives you one token; \
            paste it into Clip on another Mac and the two stay in step.

            Treat it like a key. Anyone who has it can read and change what \
            it holds.
            """) {
            HStack {
                Button("Create a Sync Token") { Task { await create() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text("This Mac's \(store.items.count) item\(store.items.count == 1 ? "" : "s") will be uploaded to the new token.")
                .font(.caption).foregroundStyle(SettingsPalette.note)
        }
    }

    var pasteTokenSection: some View {
        ExplainedSection("Already have a token?", note: """
            Paste the token from your other Mac. Choose first what should \
            happen to the items already on this one. That decision cannot \
            be taken back afterwards.
            """) {
            // Same again: inside a grouped Form a field's title becomes its
            // LABEL, so the example token was printed beside an empty box
            // instead of inside it. The example is a prompt.
            LabeledContent("Token") {
                TextField("Token", text: $tokenDraft,
                          prompt: Text("CLIP-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder).settingsFieldHover()
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { Task { await connect() } }
            }

            Toggle("Combine this Mac's items with the token's", isOn: $combineOnConnect)

            Label(combineOnConnect ? Self.mergeWarning : Self.replaceWarning,
                  systemImage: combineOnConnect ? "arrow.triangle.merge" : "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(combineOnConnect ? Color.secondary : Color.orange)

            HStack {
                Button("Connect") { Task { await connect() } }
                    .buttonStyle(.bordered)
                    .disabled(busy || tokenDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
            }
        }
    }

    /// M2/2.6: this Mac holds a token from a previous connection, but is not
    /// currently claiming a space with it - either a plain disconnect, or an
    /// app deletion and reinstall. The user's own rule: "the token is stored
    /// in the laptop and is not deleted with an app deletion or account
    /// disconnection". Shown before "Sync with a token" so it reads as the
    /// obvious next step rather than something to notice on your own.
    func leftoverTokenSection(_ token: String) -> some View {
        ExplainedSection("This Mac has a saved token", note: """
            Saved from a previous connection and kept even though nothing is \
            connected right now. Deleting Clip, or disconnecting an account, \
            never removes it.
            """) {
            HStack(spacing: 8) {
                Text(revealed ? token : String(repeating: "•", count: 29))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button(revealed ? "Hide" : "Show") { revealed.toggle() }
                    .buttonStyle(.link)
            }
            HStack {
                Button("Reconnect With This Token") {
                    tokenDraft = token
                    Task { await connect() }
                }
                .buttonStyle(.bordered)
                .disabled(busy)
                Spacer()
                Button("Forget Token on This Mac…", role: .destructive) {
                    confirmingForgetToken = true
                }
            }
        }
    }

    /// Your own server: where it is, and how to get one.
    ///
    /// An earlier build shipped a default address, so an install nobody had
    /// configured still synced - into someone else's database. There is no
    /// default now, which makes this section the first thing a new install has
    /// to deal with, and the reason the setup kit sits right next to it.
    /// Plain-language explanation under a setting.
    ///
    /// Every field here is asking for something a person sets up once, in a
    /// control panel they may never have opened, and the field's name is the
    /// jargon for it rather than a description of it. "Database host" tells you
    /// what to type only if you already know. The sentence underneath is what
    /// makes this self-service instead of a form you have to be taught.
    /// A setting inside "Advanced": title, control, explanation.
    func advancedRow<Control: View>(_ title: String, help text: String,
                                            @ViewBuilder control: @escaping () -> Control) -> some View {
        VStack(alignment: .leading, spacing: Spacing.inline) {
            HStack(spacing: Spacing.tight) {
                Text(title)
                Spacer()
                control()
            }
            help(text)
        }
    }

    func help(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(SettingsPalette.note)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What to call the shared pool, in the words of whichever method is in use.
    ///
    /// "This token holds" is wrong and confusing for somebody who signed in with
    /// Google and has never seen a token - even though there is one behind the
    /// account.
    var poolNoun: String {
        if case .google = sync.connection { return "your account" }
        return "this token"
    }

    /// Everything about standing a server up.
    ///
    /// Only shown where it is operational. Signing in with Google needs a
    /// server address, because Google says who you are and your own server
    /// holds what you copied - but it does not need the database credentials,
    /// the setup kit, or a way to carry the server settings to another Mac,
    /// because signing in there does all of that. Those three were on screen
    /// under every method, which is a page of configuration to scroll past to
    /// reach the one control that applies.
    var serviceSection: some View {
        Group {
            serverSection
            setupKitSection
            otherMacsSection
        }
    }

    var serverSection: some View {
        Group {
            ExplainedSection("Server", note: """
                Your data, your database, your server. Clip writes the server's \
                configuration from these values, so you edit nothing by hand.
                """) {
                // Label as the field's own title, hint as its prompt. Nested in a
                // LabeledContent the hint was drawn twice - once inside the field
                // and once as text beside it - because both the wrapper and the
                // field were supplying a label.
                SettingsTextField("Address", text: $config.address,
                                  prompt: "https://example.com/clip-api", monospaced: true)
                help("The address Clip talks to: the link to the folder on your web host where you put Clip's files, the kind you would type into a browser. Any address works, no special name required.")

                SettingsTextField("Database host", text: $config.databaseHost, prompt: "localhost")
                help("Where the database lives, as seen from the server. On almost every web host it's the same machine as the site, so the answer is the word localhost. Your host's control panel will say if it is something else.")

                SettingsTextField("Database name", text: $config.databaseName, prompt: "the name you gave it")
                help("The name of the empty database you created in your web host's control panel. It is a filing cabinet: Clip makes its own drawers inside it the first time it connects. Some hosts add a prefix of their own, so copy the full name exactly as it is shown there.")

                SettingsTextField("Database user", text: $config.databaseUser, prompt: "the user you created")
                help("The account allowed to open that database. You create it in the same control panel, and you have to tick the box that gives it access to the database above, or the connection is refused. This is not your web host login.")

                SettingsSecureField("Database password", text: $config.databasePassword,
                                    prompt: "kept in this Mac's Keychain")
                help("The password for that database account. It stays in this Mac's Keychain, never in a file Clip writes, and it is sent to the server only once, when Clip sets it up.")

                DisclosureGroup(isExpanded: $showAdvancedServer) {
                    // One rhythm for the three settings: title left, control
                    // right, its explanation directly under, left-aligned
                    // (user, 03/09: "more ordered, aligned, scannable").
                    VStack(alignment: .leading, spacing: Spacing.related) {
                        advancedRow("Require HTTPS",
                                    help: "A token is a key. Over plain HTTP anyone on the network can read it in transit.") {
                            Toggle("Require HTTPS", isOn: $config.requireHTTPS).labelsHidden()
                        }
                        advancedRow("Rows per response",
                                    help: "How many clips the server hands over at a time. Smaller is gentler on a slow or shared host; larger finishes a big sync in fewer trips.") {
                            Text("\(config.pageSize)").monospacedDigit()
                            Stepper("Rows per response", value: $config.pageSize, in: 20...1000, step: 20).labelsHidden()
                        }
                        advancedRow("New tokens per hour",
                                    help: "A cap on how many new sync tokens can be created each hour, so nobody who finds your address can flood it with them.") {
                            Text("\(config.tokensPerHour)").monospacedDigit()
                            Stepper("New tokens per hour", value: $config.tokensPerHour, in: 1...500, step: 1).labelsHidden()
                        }
                        help("Neither limits how much a token can hold. Clip pages until it has everything.")
                    }
                    .padding(.top, Spacing.tight)
                } label: {
                    HStack {
                        Text("Advanced")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.15)) { showAdvancedServer.toggle() }
                    }
                    // M8.4: a hand-built disclosure header - the whole row
                    // toggles, not just DisclosureGroup's own chevron, and
                    // that custom row gets no hover from AppKit on its own.
                    .settingsHover(cornerRadius: 6)
                }

                HStack {
                    Button("Save") { saveServer() }
                        .disabled(config.address.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Test") { Task { await testServer() } }
                        .disabled(testing || !SyncClient.shared.hasPersonalServer)
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                }

                if let testResult {
                    Label(testResult.message,
                          systemImage: testResult.ok ? "checkmark.circle.fill"
                                                     : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(testResult.ok ? Color.green : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !config.missing.isEmpty {
                    Text("Still needed for the setup files: \(config.missing.joined(separator: ", ")).")
                        .font(.caption).foregroundStyle(SettingsPalette.note)
                }
            }

        }
    }

    /// The files that stand a server up. Only useful before there is one.
    var setupKitSection: some View {
        Group {
            ExplainedSection("Setup files", note: """
                Clip writes the files to upload, the SQL that builds the tables, \
                and the steps, filled in with what you entered. Any host running \
                PHP 8 and MySQL will do.
                """) {
                HStack {
                    Button("Save Setup Files…") { makeKit() }
                        .disabled(!config.isComplete)
                    if let kitResult {
                        Text(kitResult).font(.caption).foregroundStyle(SettingsPalette.note)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                Text("""
                    The database starts empty. The files only create its shape. \
                    Your clips arrive the first time Clip syncs.
                    """)
                    .font(.caption).foregroundStyle(SettingsPalette.note)
            }

        }
    }

    /// Carrying the server settings to another Mac.
    ///
    /// Meaningless when you sign in with Google: signing in on the other Mac
    /// is what this file exists to avoid having to do by hand.
    var otherMacsSection: some View {
        Group {
            ExplainedSection("Your other Macs", note: """
                Set the server up once, then export here and import there. No \
                retyping on every Mac.

                The file carries the address and database details. It never \
                carries the token or the password.
                """) {
                HStack {
                    Button("Export Settings…") { exportSettings() }
                        .disabled(!SyncClient.shared.hasPersonalServer)
                    Button("Import Settings…") { importSettings() }
                        .disabled(sync.isConnected)
                    Spacer()
                }
                if sync.isConnected {
                    Label("""
                        Importing needs this Mac disconnected first. The token it \
                        holds belongs to the current server. Disconnect under \
                        Account, then import.
                        """, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(SettingsPalette.note)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let settingsResult {
                    Text(settingsResult).font(.caption).foregroundStyle(SettingsPalette.note)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Server actions

    func saveServer() {
        var value = config.address.trimmingCharacters(in: .whitespaces)
        while value.hasSuffix("/") { value = String(value.dropLast()) }
        config.address = value

        // Pointing a connected Mac at a different server would leave it holding a
        // token the new server has never heard of, and every sync from then on
        // fails with "that token is not valid" - which is exactly the confusion
        // this pane exists to prevent. Ask, then do both steps together.
        let current = SyncClient.shared.personalURL?.absoluteString ?? ""
        if sync.isConnected, !current.isEmpty, current != value {
            confirmingServerChange = true
            return
        }
        commitServer()
    }

    func commitServer() {
        config.save()
        testResult = nil
        Task { await testServer() }
    }

    func changeServerAndDisconnect() {
        Task {
            await sync.disconnect()
            commitServer()
            settingsResult = "Disconnected, and now pointed at the new server. Create or paste a token for it."
        }
    }

    func testServer() async {
        testing = true
        defer { testing = false }
        switch await SyncClient.shared.testConnection() {
        case .success(let message): testResult = (true, message)
        case .failure(let error):   testResult = (false, error.localizedDescription)
        }
    }

    func makeKit() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Save Here"
        panel.message = "Where should Clip put the setup folder?"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory,
                                                      in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let folder = try ServerKit.writeKit(to: destination)
            kitResult = "Saved to \(folder.lastPathComponent). Open START-HERE.html."
            NSWorkspace.shared.open(folder.appendingPathComponent("START-HERE.html"))
        } catch {
            kitResult = error.localizedDescription
        }
    }

    func exportSettings() {
        guard let data = ServerKit.exportSettings() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clip-sync-settings.clipsync"
        panel.message = "Send this to your other Mac, then import it there."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            settingsResult = "Saved. Import it on your other Mac, then paste the token."
        } catch {
            settingsResult = error.localizedDescription
        }
    }

    func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.message = "Choose the .clipsync file exported from your other Mac."
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }

        switch ServerKit.importSettings(from: data) {
        case .applied(let service):
            config = ServerConfig.loadIncludingPassword()
            settingsResult = "Now pointed at \(service). Paste your token above to sync."
            Task { await testServer() }
        case .notClipSettings:
            settingsResult = "That file was not exported by Clip."
        case .noService:
            settingsResult = "That file has no server address in it."
        }
    }
}
