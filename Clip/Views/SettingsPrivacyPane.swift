import SwiftUI
import AppKit

/// One app that Clip may be told to ignore.
struct IgnorableApp: Identifiable, Equatable {
    let id: String          // bundle identifier
    let name: String
    let path: String

    var icon: NSImage { NSWorkspace.shared.icon(forFile: path) }
}

/// Discovers installed applications so the ignore list can be a real list of
/// apps with toggles, the way macOS Settings presents permissions, rather than
/// a text field asking for bundle identifiers.
@MainActor
final class AppInventory: ObservableObject {
    static let shared = AppInventory()

    @Published private(set) var apps: [IgnorableApp] = []
    @Published private(set) var isLoading = false

    private init() {}

    func loadIfNeeded() {
        guard apps.isEmpty, !isLoading else { return }
        isLoading = true
        Task.detached(priority: .utility) {
            let found = Self.scan()
            await MainActor.run {
                self.apps = found
                self.isLoading = false
            }
        }
    }

    /// Adds an app the scan missed (or one outside the usual folders).
    func add(_ url: URL) {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        guard !apps.contains(where: { $0.id == id }) else { return }
        apps.append(IgnorableApp(id: id, name: name, path: url.path))
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    nonisolated private static func scan() -> [IgnorableApp] {
        let fm = FileManager.default
        var dirs = [URL(fileURLWithPath: "/Applications"),
                    URL(fileURLWithPath: "/Applications/Utilities"),
                    URL(fileURLWithPath: "/System/Applications")]
        if let home = fm.urls(for: .applicationDirectory, in: .userDomainMask).first {
            dirs.append(home)
        }

        var seen = Set<String>()
        var out: [IgnorableApp] = []
        for dir in dirs {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            for url in entries where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url),
                      let id = bundle.bundleIdentifier,
                      !seen.contains(id) else { continue }
                seen.insert(id)
                out.append(IgnorableApp(
                    id: id,
                    name: url.deletingPathExtension().lastPathComponent,
                    path: url.path))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Privacy's own sub-pages (M14): what Clip captures, which apps it never
/// records from, and where everything it keeps actually lives.
enum PrivacyPage: String, CaseIterable, Identifiable, SettingsSubpageID {
    case captureRules, ignoredApps, storage
    var id: String { rawValue }
    var title: String {
        switch self {
        case .captureRules: return "Capture rules"
        case .ignoredApps:  return "Ignored apps"
        case .storage:      return "Storage"
        }
    }
    var symbol: String {
        switch self {
        case .captureRules: return "shield"
        case .ignoredApps:  return "app.badge.checkmark"
        case .storage:      return "internaldrive"
        }
    }
}

struct PrivacyPane: View {
    @ObservedObject private var prefs = PreferencesModel.shared
    @StateObject private var inventory = AppInventory.shared
    @EnvironmentObject var router: SettingsRouter
    @State private var search = ""

    /// Everything is off until the user turns it on.
    private var ignored: Set<String> { prefs.ignoredAppList }

    private var listed: [IgnorableApp] {
        let all = inventory.apps
        guard !search.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Group {
            switch router.page(for: .privacy).flatMap(PrivacyPage.init(rawValue:)) {
            case nil:              hub
            case .captureRules:    captureRulesSubpage
            case .ignoredApps:     ignoredAppsSubpage
            case .storage:         storageSubpage
            }
        }
        .onAppear {
            inventory.loadIfNeeded()
            refreshStorage()
        }
    }

    // MARK: - Hub

    private var hub: some View {
        SettingsHub(icon: "hand.raised", title: "Privacy & Security",
                    purpose: "Control what Clip remembers, and where it keeps it.",
                    groups: [
            SettingsHubGroup(id: "privacy", rows: [
                .init(id: PrivacyPage.captureRules.rawValue, symbol: PrivacyPage.captureRules.symbol,
                      title: PrivacyPage.captureRules.title),
                .init(id: PrivacyPage.ignoredApps.rawValue, symbol: PrivacyPage.ignoredApps.symbol,
                      title: PrivacyPage.ignoredApps.title,
                      summary: "\(ignored.count) ignored app\(ignored.count == 1 ? "" : "s")"),
                .init(id: PrivacyPage.storage.rawValue, symbol: PrivacyPage.storage.symbol,
                      title: PrivacyPage.storage.title),
            ])
        ], onSelectRow: { id in router.openSubpage(id, in: .privacy) })
    }

    private func subpage<Content: View>(_ page: PrivacyPage, @ViewBuilder content: @escaping () -> Content) -> some View {
        SettingsSubpage(tab: .privacy, title: page.title, router: router, content: content)
    }

    // MARK: - Capture rules

    private var captureRulesSubpage: some View {
        subpage(.captureRules) {
            Form {
                ExplainedSection("Links", note: """
                    When you copy a link, Clip can ask the page for its title so the \
                    row says what the page is instead of just the domain.

                    That is one request to that site, which tells the site you copied \
                    the link. Nothing else is sent, and only the title is read.
                    """) {
                    Toggle("Read the page title when I copy a link",
                           isOn: $prefs.fetchLinkTitles)
                }

                ExplainedSection("Sensitive content", note: """
                    Password managers such as 1Password and KeeWeb mark what they copy as \
                    private. With this on, Clip never records it.
                    """) {
                    Toggle("Ignore content marked confidential", isOn: $prefs.respectConcealedTypes)
                }
            }
            .formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Ignored apps

    private var ignoredAppsSubpage: some View {
        subpage(.ignoredApps) {
            Form {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(SettingsPalette.note)
                        // M8.3, 02/09: this used to be a real `TextField` with a
                        // rounded border, always visibly an input. The ask was
                        // the opposite - it should look exactly like inert text
                        // until clicked, then become editable with the SAME
                        // font and colour and no border at all. `EditableLabel`
                        // is that component, built once so any other Settings
                        // label that doubles as a filter can reuse it instead of
                        // growing its own copy.
                        EditableLabel(value: $search, placeholder: "Search apps", testID: "m8b_privacySearch")
                        Spacer()
                        ClipLink("Add App", size: .small) { addApp() }
                    }

                    if inventory.isLoading {
                        HStack { ProgressView().controlSize(.small); Text("Looking for apps…").font(.caption) }
                    } else if listed.isEmpty {
                        Text("No apps match.").font(.caption).foregroundStyle(SettingsPalette.note)
                    } else {
                        ForEach(listed) { app in
                            // M8.4, 02/09: a composite row - icon, name, bundle
                            // id - not a bare `Toggle("text", isOn:)`, so it gets
                            // none of AppKit's own hover chrome and needs
                            // `.settingsHover()` explicitly, over the whole row.
                            Toggle(isOn: binding(for: app)) {
                                HStack(spacing: 8) {
                                    Image(nsImage: app.icon)
                                        .resizable().frame(width: 18, height: 18)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(app.name)
                                        Text(app.id).font(.caption2).foregroundStyle(SettingsPalette.note)
                                    }
                                }
                            }
                            .settingsHover(cornerRadius: 6)
                        }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ignored apps")
                        Text("Everything is off by default. Turn an app on and Clip will not record anything copied while it is frontmost.")
                            .font(.caption).foregroundStyle(SettingsPalette.note).textCase(nil)
                    }
                }
            }
            .formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Storage

    private var storageSubpage: some View {
        // Captured at body-evaluation time, the same way `officialServiceNote`
        // (SettingsSyncPane.swift) already proves its own on-screen sentence -
        // NOT `.onAppear`, which this Text originally used. `.onAppear` on a
        // row this far into a `Form`'s `Section` is SwiftUI/AppKit view-
        // lifecycle timing: it fires once, when the row's own hosting cell
        // is materialized, which section 150's own gate found does not
        // reliably happen inside the window this bridge's driven navigation
        // settles for (`m14_settingsPage` already read "storage" - the
        // ROUTER had switched - while `privacyPaneText` stayed the empty
        // default). A `let _ = { ... }()` at the top of this computed
        // property runs synchronously every time SwiftUI asks for this
        // property's value, which happens on every real body recompute -
        // no separate lifecycle event to miss.
        let _ = { SettingsProbe.privacyPaneText = Self.encryptionNote }()
        return subpage(.storage) {
            Form {
                Section {
                    LabeledContent("Data location", value: "~/Library/Application Support/Clip")
                    LabeledContent("History file", value: "clip.sqlite")
                    LabeledContent("API keys", value: "macOS Keychain")
                    LabeledContent("Sync", value: SyncManager.shared.isConnected ? "On" : "Off")
                    LabeledContent("AI activity", value: PreferencesModel.shared.aiEnabled
                                   ? "Only when you invoke a feature" : "None")
                    Text(Self.encryptionNote)
                        .font(.caption)
                        .foregroundStyle(SettingsPalette.note)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Where your data lives")
                        Text(networkNote).font(.caption).foregroundStyle(SettingsPalette.note).textCase(nil)
                    }
                }

                Section {
                    SecondaryButton("Diagnostics…") { AppDelegate.shared?.showDiagnostics() }
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Health")
                        Text("Every open notice, storage and Keychain state, and the last things Clip did to its own data.")
                            .font(.caption).foregroundStyle(SettingsPalette.note).textCase(nil)
                    }
                }

                Section {
                    LabeledContent("Data folder permissions", value: permissionBitsText)
                    if orphans.isEmpty {
                        Text("Nothing to reclaim.").font(.caption).foregroundStyle(SettingsPalette.note)
                    } else {
                        ForEach(orphans) { orphan in
                            HStack {
                                Text(orphan.reason).lineLimit(1)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: orphan.size, countStyle: .file))
                                    .font(.caption).foregroundStyle(SettingsPalette.note)
                            }
                        }
                        HStack {
                            SecondaryButton("Reclaim \(totalMBText)") { reclaim() }
                            if hasReclaimedFolder {
                                SecondaryButton("Empty Reclaimed Folder", isDestructive: true) { emptyReclaimed() }
                            }
                        }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Storage")
                        Text("""
                            Old files Clip found but no longer uses: superseded installs, backups \
                            past retention, images no item points at any more. Reclaiming moves them \
                            into a dated folder inside Clip's own data folder. Nothing is deleted \
                            until you empty that folder yourself.
                            """)
                            .font(.caption).foregroundStyle(SettingsPalette.note).textCase(nil)
                    }
                }
            }
            .formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Storage (M3.7)

    @State private var orphans: [AppPaths.Orphan] = []
    @State private var hasReclaimedFolder = false

    private var totalMBText: String {
        let bytes = orphans.reduce(Int64(0)) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var permissionBitsText: String {
        let path = AppPaths.support.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mode = attrs[.posixPermissions] as? NSNumber else { return "unknown" }
        return String(mode.intValue, radix: 8)
    }

    private func refreshStorage() {
        let audit = AppPaths.audit()
        // Items whose image is missing are removed at startup by
        // `StartupHealth.run()` (M5 REVISED: they are local-only, so there
        // is no server copy to fetch, and the original still lives wherever
        // it was really copied) - by the time Settings opens, `.degradedMedia`
        // should be empty. Excluded here anyway, defensively, so a file lost
        // mid-session never pads the reclaim total until the next launch.
        orphans = audit.filter { $0.category != .degradedMedia }
        hasReclaimedFolder = AppPaths.hasReclaimedFolder()
    }

    private func reclaim() {
        _ = AppPaths.reclaim(orphans)
        refreshStorage()
    }

    private func emptyReclaimed() {
        _ = AppPaths.emptyReclaimed()
        refreshStorage()
    }

    /// User-approved wording (Clip/docs/USER-FACING-COPY.md) - verbatim, not
    /// paraphrased. Sits with the other facts about where data lives, because
    /// it answers the same question ("what actually protects this") rather
    /// than warning about a risk.
    static let encryptionNote = """
        Clipboard contents are stored unencrypted on this Mac. A key this app \
        could use on its own is a key anyone with the same file access could \
        use too, so encrypting here would not add real protection - what \
        protects this data is FileVault, which is already on your Mac if you \
        turned it on at setup.
        """

    /// The privacy claim has to change the moment sync is on. Saying "nothing
    /// leaves this Mac" while uploading would be a lie.
    private var networkNote: String {
        var parts = ["Clipboard history is stored on this Mac."]
        if SyncManager.shared.isConnected {
            // Named, not addressed. On the official service the host is
            // deliberately not shown anywhere, and a privacy note is not the
            // place to make an exception - "Clip's own service" is the honest
            // answer to "where does this go" without printing the address.
            let destination: String
            if SyncManager.shared.serviceKind == .official {
                destination = OfficialService.displayName
            } else {
                destination = SyncClient.shared.personalURL?.host ?? "your own server"
            }
            parts.append("Sync is on. Your content is uploaded to \(destination) under your account.")
        } else {
            parts.append("Sync is off, so nothing is uploaded.")
        }
        parts.append(PreferencesModel.shared.aiEnabled
            ? "AI features contact your configured provider only when you invoke them."
            : "No AI connection, so no requests are made.")
        return parts.joined(separator: " ")
    }

    private func binding(for app: IgnorableApp) -> Binding<Bool> {
        Binding(
            get: { ignored.contains(app.id) },
            set: { on in
                var set = ignored
                if on { set.insert(app.id) } else { set.remove(app.id) }
                prefs.ignoredApps = set.sorted().joined(separator: ",")
            }
        )
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { inventory.add(url) }
    }
}
