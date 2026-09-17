import SwiftUI
import AppKit

/// Sync's own sub-pages (M14): which method (and, if not yet connected,
/// connecting via it), the connection's own identity/status, the
/// self-hosted server's own configuration, what actually moves, and the
/// isolated destructive card every account/token eventually needs.
struct SyncPane: View {
    /// Settings surfaces come from the chosen theme, not the system's own
    /// neutral greys: see `SettingsHero`'s note (user, 07/09).
    @EnvironmentObject private var settingsTheme: ThemeManager
    private var st: AppTheme { settingsTheme.settingsTheme }
    /// The Mac a Sign out press is waiting on confirmation for.
    @State var signingOut: SyncDevice?
    @StateObject var sync = SyncManager.shared
    @StateObject var googleAuth = GoogleAuth.shared
    @StateObject var settingsSync = SettingsSync.shared
    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var router: SettingsRouter

    @ObservedObject var notices = NoticeCenter.shared
    @State var tokenDraft = ""
    @State var combineOnConnect = true
    @State var busy = false
    @State var revealed = false
    @State var newToken: String?
    @State var confirmingDisconnect = false
    @State var confirmingForgetToken = false
    @State var confirmingDelete = false
    @State var deleteResult: String?
    @State var copied = false
    @State var config = ServerConfig()
    @State var confirmingServerChange = false
    @State var testing = false
    @State var showAdvancedServer = false
    @State var testResult: (ok: Bool, message: String)?
    @State var kitResult: String?
    @State var settingsResult: String?

    /// Which method the pane is showing.
    ///
    /// A selection, not a mode: nothing about the app changes until the user
    /// acts on it. While something is connected it follows what is in force,
    /// because showing token settings to someone signed in with Google is
    /// offering a door that is bolted.
    /// `nil` until the person picks one (or a live connection decides):
    /// with no method chosen the hub shows the chooser and nothing else
    /// (user, 03/09).
    @State var method: SyncMethod? = nil
    static let methodChoiceKey = "syncMethodChoice"

    enum SyncMethod: String, CaseIterable, Identifiable {
        case google, server
        var id: String { rawValue }

        var title: String {
            switch self {
            case .google: return "Sign in with Google"
            case .server: return "Set up sync server"
            }
        }

        var symbol: String {
            switch self {
            case .google: return "person.crop.circle"
            case .server: return "key"
            }
        }

        var detail: String {
            switch self {
            case .google:
                return """
                    Your account holds the data. Sign in on another Mac and everything \
                    is there, with nothing to copy across. Clip asks Google for your \
                    email address and name and nothing else: no Drive, no Gmail, no \
                    contacts.
                    """
            case .server:
                return """
                    No account and nothing to sign up for. Clip gives you one long \
                    token; paste it into Clip on another Mac and the two share \
                    everything. Treat it like a key, because it is one.
                    """
            }
        }
    }

    /// M2/2.7: the same shape as the AI pane's banner - whichever sync-token
    /// notice is up, so this pane says so at the top rather than a person
    /// finding an empty token field and assuming the worst.
    var tokenRepairNotice: NoticeCenter.Notice? {
        notices.pending.first {
            guard let key = $0.key else { return false }
            return (key.hasPrefix("keychain.needsRepair.") || key.hasPrefix("keychain.missing."))
                && key.contains("sync.token")
        }
    }

    func repairBanner(_ notice: NoticeCenter.Notice) -> some View {
        let text = notice.remedy.map { "\(notice.message) \($0)" } ?? notice.message
        let _ = { SettingsProbe.syncRepairBannerText = text
                  + (notice.action.map { " [\($0.title)]" } ?? "") }()
        return Section {
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

    var body: some View {
        Group {
            flatPage
        }
        .onAppear {
            config = ServerConfig.loadIncludingPassword()
            // The choice survives closing Settings: a person who picked
            // "server" and comes back must find the Server row, not an
            // empty hub.
            if method == nil, let stored = AppPaths.defaults.string(forKey: Self.methodChoiceKey) {
                method = SyncMethod(rawValue: stored)
            }
            syncMethodToReality()
            if SettingsProbe.syncAdvancedOpen { showAdvancedServer = true }
        }
        .onChange(of: method) { _, new in
            if let new { AppPaths.defaults.set(new.rawValue, forKey: Self.methodChoiceKey) }
            else { AppPaths.defaults.removeObject(forKey: Self.methodChoiceKey) }
        }
        .onChange(of: sync.connection) { _, _ in syncMethodToReality() }
        .sheet(item: Binding(
            get: { newToken.map(TokenSheetItem.init) },
            set: { if $0 == nil { newToken = nil } }
        )) { item in
            newTokenSheet(item.token)
        }
        .alert("Forget the saved token on this Mac?", isPresented: $confirmingForgetToken) {
            Button("Cancel", role: .cancel) { }
            Button("Forget Token", role: .destructive) { sync.forgetTokenOnThisMac() }
        } message: {
            Text("""
            This removes the token from this Mac's Keychain. It stays valid on \
            your other Macs. You can reconnect here later by pasting it again.
            """)
        }
        .alert("Point this Mac at a different server?", isPresented: $confirmingServerChange) {
            Button("Cancel", role: .cancel) { config = ServerConfig.loadIncludingPassword() }
            Button("Disconnect and Change") { changeServerAndDisconnect() }
        } message: {
            Text("""
            The token this Mac holds belongs to the server it is connected to now, \
            and the new one has never heard of it.

            Clip will disconnect first, then point here. Everything already on this \
            Mac stays; your other Macs keep using the old token.
            """)
        }
        .alert("Disconnect this Mac?", isPresented: $confirmingDisconnect) {
            Button("Cancel", role: .cancel) { }
            Button("Disconnect") { Task { await sync.disconnect() } }
        } message: {
            Text("""
            Everything on this Mac stays exactly where it is. Only the token \
            connection is removed, so this Mac stops sending and receiving \
            changes.

            Your other Macs keep syncing, and pasting the token back here \
            reconnects this one.
            """)
        }
        .alert("Are you sure you want to delete your account?",
               isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Delete Account", role: .destructive) { Task { await runDelete() } }
        } message: {
            Text("""
            This deletes your account on \(OfficialService.displayName) and \
            everything it holds, for every Mac signed in to it.

            Nothing on this Mac is deleted. Your whole history, prompts, notes and \
            skills stay here exactly as they are. This only removes the copy that \
            is kept for syncing. To clear this Mac as well, use Privacy.

            It is kept for 30 days before being removed for good, so signing in \
            again within that time brings it all back.
            """)
        }
    }

    // MARK: - The one page (user, 03/09 night: "open their settings in their
    // main tab so it will be exposed") - hero, the method chooser, then every
    // section of the chosen method inline. Nothing sits behind a chevron.

    var flatPage: some View {
        Form {
            SettingsHero(icon: "arrow.triangle.2.circlepath", title: "Sync",
                         purpose: "Combine this Mac's clipboard history with your other Macs over a token, "
                                  + "so a copy on one shows up on the rest.")
                .listRowInsets(EdgeInsets(top: Spacing.tight, leading: 0, bottom: Spacing.related, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            chooserCard
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: Spacing.related, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            if let method {
                switch method {
                case .google: accountSections
                case .server: serverSections
                }
            }
            if sync.connection.isConnected {
                whatSyncsSections
                dangerSections
            }
        }
        .formStyle(.grouped)
                .scrollContentBackground(.hidden)
    }




    // MARK: - Choosing how to sync

    /// One of three, chosen with a radio, and only the chosen one explained.
    ///
    /// It was a numbered list, which read as three steps to work through. It is
    /// not a sequence: it is a choice, and two of the three are alternatives.
    /// Showing all three sets of settings at once also meant scrolling past
    /// configuration for a method you were not using to reach the one you were.
    ///
    /// Google and the token are two states of one connection, so exactly one can
    /// be live: a Mac holding both would push two pools through one cursor,
    /// which is data loss with a plausible explanation. While connected the
    /// selection is pinned to what is in force; disconnecting frees it.
    ///
    /// While a connection is live, EVERY option is locked.
    ///
    /// Importing a backup used to live here as a third option that stayed
    /// selectable, which made the list read as three sync methods when only two
    /// of them are. It has moved to Import and Export, beside the export it is
    /// the other half of. What is left is the two genuine, mutually exclusive
    /// connections - so once one is live, the whole group is locked until you
    /// disconnect, and there is no exception to explain.
    ///
    /// Why the two options exist and how they relate - behind a "?" rather
    /// than as a paragraph above the rows (user, 03/09: information goes
    /// into a question mark, never a wall of text or a tab of its own).
    static let chooserNote = """
        Two ways to keep Macs in step. They are alternatives (this Mac uses \
        one or the other, never both), so while either is connected the \
        choice is locked, and switching means disconnecting first. To bring \
        in an exported file instead, use Backup. That is not a way to sync: \
        it copies data in once and changes nothing about how this Mac is \
        connected.
        """

    /// The method chooser, at the top of the hub. Rows below it appear only
    /// once a method is chosen.
    var chooserCard: some View {
        // Body-evaluation capture, not `.onAppear` - see the identical fix
        // and reasoning on `PrivacyPane.storageSubpage` (SettingsPrivacyPane
        // .swift). `officialServiceNote` right below in this same file is
        // the proof this pattern already holds up; `.onAppear` on this row
        // was section 150's own gate reading `syncSwitchText` back empty
        // even after the sync tab had genuinely opened.
        let _ = { SettingsProbe.syncSwitchText = Self.localOnlyKindsNote }()
        return VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.inline) {
                Text("Choose how you sync").font(Typography.subheading)
                InfoButton(title: "Two ways to sync", text: Self.chooserNote)
                Spacer()
            }
            .padding(.horizontal, Spacing.inline)

            // Hand-built rather than a `Picker(.radioGroup)`: each row carries
            // its own "?" and its own hover, which a Picker cannot host.
            VStack(spacing: 0) {
                ForEach(Array(SyncMethod.allCases.enumerated()), id: \.element.id) { index, option in
                    if index > 0 {
                        Divider().padding(.leading, SettingsAppleMetrics.rowInset * 2
                                          + SettingsAppleMetrics.rowIconTile)
                    }
                    methodRow(option)
                }
            }
            .background(st.cardBackground,
                        in: RoundedRectangle(cornerRadius: SettingsAppleMetrics.cardRadius, style: .continuous))

            Text(Self.localOnlyKindsNote)
                .font(.caption)
                .foregroundStyle(SettingsPalette.note)
                .fixedSize(horizontal: false, vertical: true)

            if let locked {
                Label(locked, systemImage: "lock")
                    .font(.caption).foregroundStyle(SettingsPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.inline)
            }

            if let error = googleAuth.lastError, !error.isEmpty, method == .google {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(SettingsPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.inline)
            }
        }
    }


    /// One selectable method, drawn like a hub row: icon tile and title on
    /// the left, its own "?" and the radio mark on the right. The whole row
    /// is the target, not just the mark.
    @ViewBuilder
    func methodRow(_ option: SyncMethod) -> some View {
        let selected = method == option
        // Locked means a connection is live. Both options are connections,
        // and they are mutually exclusive, so neither can be chosen until
        // the current one is disconnected.
        let selectable = locked == nil

        HStack(spacing: 0) {
            Button {
                guard selectable else { return }
                method = option
            } label: {
                HStack(spacing: Spacing.related) {
                    RoundedRectangle(cornerRadius: SettingsAppleMetrics.rowIconTile * 0.27, style: .continuous)
                        .fill(Color.accentColor.opacity(selectable ? 0.18 : 0.08))
                        .frame(width: SettingsAppleMetrics.rowIconTile, height: SettingsAppleMetrics.rowIconTile)
                        .overlay(
                            Image(systemName: option.symbol)
                                .font(.system(size: SettingsAppleMetrics.rowGlyphSize))
                                .foregroundStyle(selectable ? Color.accentColor : SettingsPalette.note)
                        )
                    Text(option.title)
                        .font(Typography.body)
                        .foregroundStyle(selectable ? Color.primary : SettingsPalette.note)
                    Spacer(minLength: Spacing.tight)
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : SettingsPalette.note)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, SettingsAppleMetrics.rowInset)
                .padding(.vertical, Spacing.tight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // M8.4: `.plain`-styled radio row, no native chrome.
            .settingsHover(cornerRadius: SettingsAppleMetrics.rowIconTile * 0.27)
            .disabled(!selectable)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel(option.title)
        }
        .overlay(alignment: .trailing) {
            InfoButton(title: option.title, text: option.detail)
                .padding(.trailing, SettingsAppleMetrics.rowInset + Spacing.comfortable + Spacing.tight)
        }
    }




    /// The three states the user asked for, shared with QABridge
    /// (`sync_accountCard.status`) so the badge and the probe read one source.
    static func syncStatus(_ state: SyncManager.SyncState) -> (word: String, symbol: String, colour: Color) {
        switch state {
        case .syncing:       return ("Syncing", "arrow.triangle.2.circlepath", Color.accentColor)
        case .synced:        return ("Synced", "checkmark.circle.fill", SettingsPalette.success)
        case .idle, .failed: return ("Not synced", "exclamationmark.circle", SettingsPalette.warning)
        }
    }

    func syncMethodToReality() {
        switch sync.connection {
        case .google: method = .google
        case .token:  method = .server
        case .none:   break
        }
    }

    /// Why the choice cannot be changed right now, or nil when it can.
    var locked: String? {
        switch sync.connection {
        case .none:   return nil
        case .google: return "Signed in with Google. Sign out below to choose a different method."
        case .token:  return "Connected with a sync token. Disconnect below to choose a different method."
        }
    }





    /// User-approved wording (Clip/docs/USER-FACING-COPY.md) - verbatim, not
    /// paraphrased. Shown at the chooser, where the user is deciding whether
    /// to turn sync on at all, not after the fact.
    static let localOnlyKindsNote = """
        Sync carries text only. Images, files and folder references stay on \
        the Mac that captured them, because a file path only means something \
        on that Mac.
        """

    static let mergeWarning = """
        Everything on this Mac will be uploaded and added to the token's data. \
        Identical items are combined rather than duplicated, keeping whichever \
        copy is more set up: a pin, a title, a hotkey, or tags on either side.
        """

    static let replaceWarning = """
        The items on this Mac will be deleted and replaced by the token's data. \
        Nothing from this Mac is uploaded first.
        """





    /// What the last sync actually did.
    var status: String {
        switch sync.syncState {
        case .idle:
            return "On, waiting for the first sync"
        case .syncing:
            return "Syncing…"
        case .synced(let date):
            let when = date.formatted(date: .omitted, time: .shortened)
            switch sync.lastChangeCount {
            case 0:  return "Up to date, checked at \(when)"
            case 1:  return "1 change at \(when)"
            default: return "\(sync.lastChangeCount) changes at \(when)"
            }
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    // MARK: - The one time the token is shown

    /// Wrapper so the sheet can be driven by `Identifiable`, which is the only
    /// binding shape that survives the value changing while the sheet is up.
    struct TokenSheetItem: Identifiable {
        let token: String
        var id: String { token }
    }

    func newTokenSheet(_ token: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Your sync token", systemImage: "key.horizontal")
                .font(.headline)
            Text("""
                Save this somewhere safe now. Clip keeps it on this Mac, so you \
                can always read it here again - but if you lose this Mac, it is \
                gone. The server only stores a hash of it.
                """)
                .font(.caption).foregroundStyle(SettingsPalette.note)

            Text(token)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8))

            Text("On your other Mac: open Settings > Sync, then paste it under “Already have a token?”")
                .font(.caption).foregroundStyle(SettingsPalette.note)

            HStack {
                Button(copied ? "Copied" : "Copy Token") { copyToken() }
                Spacer()
                Button("Done") { newToken = nil }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    // MARK: - Actions

    func create() async {
        busy = true
        defer { busy = false }
        if let token = await sync.createToken() { newToken = token }
    }

    func connect() async {
        busy = true
        defer { busy = false }
        if await sync.connect(token: tokenDraft, merge: combineOnConnect) {
            tokenDraft = ""
        }
    }

    /// Requests the deletion and reports back in the account block.
    func runDelete() async {
        // M8.7: a delete-account entry point, gated the same as the other
        // two even though the confirmation alert above it already explains
        // the consequences - this explains the SERVER REQUEST itself, ahead
        // of whatever it triggers on the account's side.
        guard await CredentialExplainer.confirm(reason: .deleteAccount) else { return }
        busy = true
        defer { busy = false }
        // `deleteAccount`, not `deleteSpace`: it also signs this Mac out, so it
        // is not left syncing against something scheduled to disappear.
        deleteResult = await sync.deleteAccount().map {
            """
            Account deletion requested. Everything on this Mac is untouched, and \
            signing in again before \($0) brings the synced copy back.
            """
        } ?? sync.lastError ?? "Nothing was deleted." 
    }

    func copyToken() {
        guard let token = sync.token else { return }
        TestIsolation.board.clearContents()
        TestIsolation.board.setString(token, forType: .string)
        // Deliberately *not* suppressed. Pressing Copy is a copy: it should be in
        // the history like anything else, and finding that it was not is worse
        // than finding the token there. Suppression exists for pasting an item
        // back, where it stops a loop - not for a button the user pressed.
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
    }
}


/// A one-value window into what the Settings pane last drew.
///
/// The same trick as `RenderProbe` for the panel, and for the same reason:
/// reading the model tells you what the app believes, not what it displayed.
enum SettingsProbe {
    /// Everything the Google pane last drew as a value or a note.
    ///
    /// Recorded as text, not as a boolean, so the check that reads it can
    /// actually fail: a flag set to `false` in one place and never set anywhere
    /// else proves nothing at all. Searching the real drawn strings for the
    /// real host is a test that breaks the moment somebody adds the address
    /// back, which is the only version worth having.
    nonisolated(unsafe) static var googlePaneText = ""

    /// The repair banner Settings > Sync last drew, empty when it drew none.
    /// See M2/2.7: a persistent banner near the top of this pane and
    /// Settings > AI whenever the sync token or an AI key needs repair.
    nonisolated(unsafe) static var syncRepairBannerText = ""
    /// QA: opens the Server page's "Advanced" group on appear, so a
    /// rendered check can look at it without a real click.
    nonisolated(unsafe) static var syncAdvancedOpen = false
    /// QA: opens Themes' "Describe the theme you want" sheet on appear.
    nonisolated(unsafe) static var themeDescribeOpen = false
    /// The same, for Settings > AI.
    nonisolated(unsafe) static var aiRepairBannerText = ""

    /// What Settings > AI last drew under Connections after a key-recovery
    /// run, empty when it drew nothing (M28).
    nonisolated(unsafe) static var aiRecoveryMessage = ""

    /// What the Privacy and Storage pane last drew about local encryption.
    nonisolated(unsafe) static var privacyPaneText = ""

    /// What the sync chooser last drew next to the switch that turns sync on.
    nonisolated(unsafe) static var syncSwitchText = ""

    /// What the Settings sidebar sync row last drew: googleAvatar, initials, tokenIcon, disconnectedIcon
    nonisolated(unsafe) static var settingsSyncGlyphKind = ""
}
