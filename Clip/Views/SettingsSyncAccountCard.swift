import SwiftUI
import AppKit

/// SyncPane's account-identity surface (T4-M3 split of SettingsSyncPane.swift):
/// the Account sub-page, the signed-in/token identity card and its avatar and
/// status badge, the Google sign-in entry point, the official-service note, and
/// the devices list. Pure extraction: no behaviour or string changes, only the
/// file boundary moved (design-taste rule 12).
extension SyncPane {

    // MARK: - Sub-page: Account

    @ViewBuilder
    var accountSections: some View {
        Group {
            Group {
                switch sync.connection {
                case .google(let email):
                    ExplainedSection("Account") { accountCard(email) }
                    officialServiceNote
                case .token:
                    tokenSyncStatusSection
                    tokenSharingSection
                case .none:
                    if method == .google {
                        if let notice = tokenRepairNotice {
                            repairBanner(notice)
                        } else {
                            let _ = { SettingsProbe.syncRepairBannerText = "" }()
                        }
                        googleSignInSection
                        syncErrorSection
                        officialServiceNote
                    } else {
                        ExplainedSection("Account", note: """
                            Sync with a token has no account to sign in to: the token \
                            itself is the connection. Create or paste one under Server.
                            """) {
                            Text("Not connected.").font(.caption).foregroundStyle(SettingsPalette.note)
                        }
                    }
                }
            }
        }
    }

    /// Signing in with Google, when nothing is connected yet - the other
    /// half of "Sync method", shown right there rather than on Account
    /// (there is no account/identity to show until this step is done).
    var googleSignInSection: some View {
        ExplainedSection("Sign in", note: """
            Clip opens your browser, Google asks whether you agree, and the \
            browser hands the answer straight back. Your password is never \
            typed into Clip, and Clip never sees it.
            """) {
            Toggle("Combine this Mac's items with the account's", isOn: $combineOnConnect)
            Text(combineOnConnect ? Self.mergeWarning : Self.replaceWarning)
                .font(.caption)
                .foregroundStyle(combineOnConnect ? SettingsPalette.note : SettingsPalette.warning)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Sign in with Google") {
                    Task {
                        // "before we ask the user for credentials then we
                        // must show him a popup with explanations" (M8.7):
                        // this is a sign-in entry point, so it goes through
                        // CredentialExplainer before Google's own page ever
                        // opens.
                        guard await CredentialExplainer.confirm(reason: .googleSignIn) else { return }
                        busy = true
                        await sync.signInWithGoogle(merge: combineOnConnect)
                        busy = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || googleAuth.isWorking || sync.connection != .none
                          || !OfficialService.isConfigured)
                if busy || googleAuth.isWorking { ProgressView().controlSize(.small) }
                Spacer()
            }
            // A build with no official service says so, rather than
            // offering a button that fails at the last step. This is the
            // open-source case: the export strips the address, because
            // publishing it would sync every fork's users into somebody
            // else's database.
            if !OfficialService.isConfigured {
                Text("""
                    This build has no sign-in service configured, so this \
                    option is unavailable. The other two work normally: you \
                    can run your own server and connect it with a token, or \
                    move your data by export and import.
                    """)
                    .font(.caption)
                    .foregroundStyle(SettingsPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Where the data goes under Google, said in words rather than an address.
    ///
    /// There is no server section here at all, and that is the point of this
    /// method: nothing to stand up, nothing to configure, nothing to get wrong.
    /// The address is Clip's and is deliberately not shown - see
    /// `OfficialService` for why hiding it is tidiness rather than security.
    ///
    /// What the user is owed instead is the truth about the trade they are
    /// making, in plain words: this is not their machine, and it is not their
    /// database.
    var officialServiceNote: some View {
        let shown = [OfficialService.displayName, "your Google account"]
        let _ = { SettingsProbe.googlePaneText = shown.joined(separator: " | ") }()
        return ExplainedSection("Where your data is kept", note: """
            Your synced clipboard lives on \(OfficialService.displayName), \
            which Clip runs. Nothing to set up and no address to enter.

            Your Google account is the only way in. To keep your clipboard on \
            machines you control instead, use “Set up sync server”: that \
            one is your server and your database, and Clip only speaks to it.
            """) {
            LabeledContent("Service", value: OfficialService.displayName)
            LabeledContent("Your data is reachable by", value: "your Google account")
            Text("""
                Your AI API keys are never uploaded, to this service or any other. \
                They stay in the macOS Keychain on this Mac.
                """)
                .font(.caption).foregroundStyle(SettingsPalette.note)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The Macs on this token, by name, with the one you are on marked.
    ///
    /// "2 Macs" was the whole story until now, which is unusable the moment one
    /// of them is a machine you do not recognise: there was no way to see what
    /// the other one was, and no way to remove it.
    @ViewBuilder
    var devicesSection: some View {
        ExplainedSection("Macs on this token", note: """
            Every Mac that has used this account. Sign one out and it stops \
            syncing; signing in on that Mac brings it back.

            Signing out another Mac asks for your Google account. The token \
            alone is not proof. All your Macs share it.
            """) {
            if sync.isLoadingDevices && sync.devices.isEmpty {
                HStack(spacing: Spacing.tight) {
                    ProgressView().controlSize(.small)
                    Text("Reading the list\u{2026}")
                        .font(.caption).foregroundStyle(SettingsPalette.note)
                }
            }
            ForEach(sync.devices) { device in
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(device.isThisMac ? "This Mac" : device.lastSeenText)
                            .font(.caption)
                            .foregroundStyle(SettingsPalette.note)
                        if !device.isThisMac {
                            SecondaryButton("Sign Out", size: .small) {
                                signingOut = device
                            }
                        }
                    }
                } label: {
                    Text(device.name)
                }
            }
            if sync.devices.isEmpty && !sync.isLoadingDevices {
                Text("No Macs reported yet.")
                    .font(.caption).foregroundStyle(SettingsPalette.note)
            }
            HStack(spacing: Spacing.tight) {
                // A press that reaches the network and comes back with the
                // same list looks exactly like a press that did nothing at
                // all, so the button says what it is doing and, afterwards,
                // when it last did it (user, 06/09).
                GhostButton(sync.isLoadingDevices ? "Refreshing\u{2026}" : "Refresh",
                            size: .small, isDisabled: sync.isLoadingDevices) {
                    Task { await sync.refreshDevices() }
                }
                if sync.isLoadingDevices {
                    ProgressView().controlSize(.small)
                } else if let checked = sync.devicesCheckedAt {
                    Text("Checked \(checked.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(SettingsPalette.note)
                }
                Spacer()
            }
            if let deviceError = sync.deviceError {
                Label(deviceError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(SettingsPalette.danger)
            }
        }
        .task { await sync.refreshDevices() }
        .alert("Sign out \(signingOut?.name ?? "that Mac")?",
               isPresented: Binding(get: { signingOut != nil },
                                    set: { if !$0 { signingOut = nil } })) {
            Button("Cancel", role: .cancel) { signingOut = nil }
            Button("Sign In and Sign It Out") {
                if let device = signingOut {
                    signingOut = nil
                    Task { await sync.signOut(device: device) }
                }
            }
        } message: {
            Text("Your browser opens so you can prove the account this token "
                 + "belongs to. That Mac stops syncing; its own copy of your "
                 + "data stays on it.")
        }
    }

    /// Who is signed in, and the one thing that can be done about it that
    /// is not destructive. "Delete Account…" moved to the Danger zone
    /// sub-page (M14) - isolated from routine identity controls by a real
    /// page boundary, per SETTINGS-DESIGN.md section 7's own rule that a
    /// destructive action gets its own isolated card, not just a divider.
    /// Who is signed in and whether this Mac is in step (user, 03/09 night):
    /// avatar (Google's photo, initials when there is none), full name,
    /// email, and one word for the sync state - Synced, Syncing or Not
    /// synced - with the detailed line under it.
    @ViewBuilder
    func accountCard(_ email: String) -> some View {
        let account = googleAuth.account
        let name = (account?.name.isEmpty == false) ? account!.name : email
        let badge = Self.syncStatus(sync.syncState)
        let failureNotice: String? = {
            if case .failed(let message) = sync.syncState {
                return message
            }
            return nil
        }()

        SyncAccountIdentityCard(
            name: name,
            email: email,
            picture: account?.picture,
            statusText: status,
            statusBadge: badge,
            isBusy: busy,
            failureMessage: failureNotice,
            onSyncNow: {
                Task { busy = true; await sync.syncNow(); busy = false }
            },
            onSignOut: {
                Task { await sync.signOutOfGoogle(unlinkAccount: false) }
            }
        )
    }

    /// 56pt circle: the profile photo when Google gave one, otherwise the
    /// initials on the accent tint. Never blank.
    /// Preserves compatibility call: accountAvatar(name: name, picture: account?.picture)
    @ViewBuilder
    func accountAvatar(name: String, picture: String?) -> some View {
        AccountAvatarView(name: name, picture: picture, size: 56)
    }

    /// One word, coloured: Synced (green), Syncing (accent), Not synced (warning).
    var syncStatusBadge: some View {
        let (word, symbol, colour) = Self.syncStatus(sync.syncState)
        return Label(word, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(colour)
            .padding(.horizontal, Spacing.tight).padding(.vertical, 3)
            .background(colour.opacity(0.14), in: Capsule())
            .accessibilityLabel("Sync status: \(word)")
    }

    // MARK: - Account sub-page content: token method, connected

    /// The token's own identity and health, plus the "Sync" status/action
    /// section - the token method's equivalent of Google's "Signed in as"
    /// block. Disconnect/Forget Token moved to the Danger zone sub-page
    /// (M14, same isolation rule `accountControls` follows above).
    @ViewBuilder
    var tokenSyncStatusSection: some View {
        if let space = sync.space {
            if sync.tokenBelongsElsewhere {
                Section {
                    Label("""
                        This token was created for a different sync server, so it \
                        won't work here. Disconnect and create a new one, or \
                        point this Mac back at the other server under Server.
                        """, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(SettingsPalette.warning)
                }
            }

            ExplainedSection("This token", note: """
                Copy it into Clip on another Mac. This Mac can show it because it \
                holds it; the server keeps only a hash and could never give it back.
                """) {
                if let token = sync.token {
                    HStack(spacing: 8) {
                        Text(revealed ? token : String(repeating: "•", count: 29))
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button(revealed ? "Hide" : "Show") { revealed.toggle() }
                            .buttonStyle(.link)
                        Button(copied ? "Copied" : "Copy") { copyToken() }
                            .buttonStyle(.link)
                    }
                } else {
                    // M2/2.6: readable and unreadable are told apart on
                    // screen, not just internally - an empty field here used
                    // to look identical to "hidden", which is how "the
                    // connections settings are empty with no token" read as
                    // silence instead of a fixable condition.
                    Label("Saved token could not be read: Repair",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(SettingsPalette.danger)
                        .contentShape(Rectangle())
                        .onTapGesture { AppDelegate.shared?.repairKeychainAccess() }
                        // M8.4: a bare `.onTapGesture` on a `Label`, not a
                        // `Button` at all - no native chrome whatsoever.
                        .settingsHover(cornerRadius: 4)
                }
                LabeledContent("Syncing between", value: space.deviceSummary)
                LabeledContent("Items in the token", value: "\(space.items)")
            }

            ExplainedSection("Sync", note: """
                Clip syncs on its own: on every change, once a minute, and when you \
                come back to the app. The button is for when you will not wait.
                """) {
                LabeledContent("Status", value: status)
                // The two counts, side by side. The user's question was "why do
                // these disagree", and a pane that shows only one of them cannot
                // even be asked it.
                LabeledContent("On this Mac", value: "\(store.items.count) items")
                if let space = sync.space {
                    LabeledContent("On the server", value: "\(space.items) items")
                }
                HStack {
                    Button("Sync Now") {
                        Task { busy = true; await sync.syncNow(); busy = false }
                    }
                    .disabled(busy)
                    Button("Full Resync") {
                        // The return value is discarded on purpose, not
                        // dropped by accident: `fullResync()` already
                        // publishes its outcome to `sync.lastResync` and
                        // `sync.syncState`, which is what the `Label` blocks
                        // below this button read to render it. A second
                        // reader here would just be a stale duplicate.
                        Task { busy = true; _ = await sync.fullResync(); busy = false }
                    }
                    .disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                Text("""
                    A full resync sends everything here up and brings everything \
                    there down again, then reports both counts. It deletes nothing. \
                    Use it when the two numbers above disagree.
                    """)
                    .font(.caption).foregroundStyle(SettingsPalette.note)
                    .fixedSize(horizontal: false, vertical: true)
                if let report = sync.lastResync {
                    Label(report.summary,
                          systemImage: report.agrees ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(report.agrees ? SettingsPalette.note : SettingsPalette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .failed(let message) = sync.syncState {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(SettingsPalette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// "Sharing" (lock the token) - a security-adjacent access control, kept
    /// beside the token's own identity on Account rather than on Danger:
    /// it is a toggle, not a destructive one-way action.
    @ViewBuilder
    var tokenSharingSection: some View {
        if let space = sync.space {
            ExplainedSection("Sharing", note: """
                Lock the token and no further Mac can join, even holding it. Lock it \
                once your own Macs are connected, and a leak reaches nothing.
                """) {
                Toggle("Let another Mac join with this token", isOn: Binding(
                    get: { space.shared },
                    set: { value in Task { await sync.setSharing(value) } }
                ))
            }
        }
    }
}

// MARK: - Identity Card & Avatar (M1)

/// Dedicated identity card for the connected Google account (M1).
/// Owns layout and image state only; GoogleAuth remains identity source
/// and SyncManager remains sync status source.
struct SyncAccountIdentityCard: View {
    let name: String
    let email: String
    let picture: String?
    let statusText: String
    let statusBadge: (word: String, symbol: String, colour: Color)
    let isBusy: Bool
    let failureMessage: String?
    let onSyncNow: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.related) {
            // Identity row: 56pt avatar on left, name & email in deliberate column, badge on trailing edge
            HStack(spacing: Spacing.related) {
                AccountAvatarView(name: name.isEmpty ? email : name, picture: picture, size: 56)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name.isEmpty ? email : name)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(SettingsPalette.label)
                        .lineLimit(1)
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(SettingsPalette.note)
                        .lineLimit(1)
                }
                .layoutPriority(1)

                Spacer(minLength: Spacing.tight)

                Label(statusBadge.word, systemImage: statusBadge.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusBadge.colour)
                    .padding(.horizontal, Spacing.tight)
                    .padding(.vertical, 3)
                    .background(statusBadge.colour.opacity(0.14), in: Capsule())
                    .accessibilityLabel("Sync status: \(statusBadge.word)")
            }
            .padding(.vertical, Spacing.tight)

            // Fuller sync detail below the identity row, inside the same card
            LabeledContent("Status", value: statusText)

            if let failureMessage, !failureMessage.isEmpty {
                Label(failureMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(SettingsPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Actions below divider
            HStack(spacing: 8) {
                Button("Sync Now") {
                    onSyncNow()
                }
                .disabled(isBusy)

                Button("Sign Out") {
                    onSignOut()
                }

                if isBusy {
                    ProgressView().controlSize(.small)
                }

                Spacer()
            }

            Text("""
                Signing out stops this Mac syncing and keeps everything already here. \
                Your other Macs are untouched, and signing back in reconnects this one.
                """)
                .font(.caption)
                .foregroundStyle(SettingsPalette.note)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 56pt circular avatar with explicit loading, success, and initials-fallback states.
/// Only absolute https URLs are loaded; non-https, absent, or failing URLs cleanly fall back.
struct AccountAvatarView: View {
    let name: String
    let picture: String?
    var size: CGFloat = 56

    private var initials: String {
        name.split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
            .map(String.init)
            .joined()
            .uppercased()
    }

    private var fallback: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.18))
            Text(initials.isEmpty ? "?" : initials)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
    }

    private var neutralPlaceholder: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.10))
            Text(initials.isEmpty ? "?" : initials)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(Color.accentColor.opacity(0.4))
        }
    }

    private var validHTTPSURL: URL? {
        guard let picture, !picture.isEmpty,
              let url = URL(string: picture),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    var body: some View {
        Group {
            if let url = validHTTPSURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else if phase.error != nil {
                        fallback
                    } else {
                        neutralPlaceholder
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel("Account photo")
    }
}
