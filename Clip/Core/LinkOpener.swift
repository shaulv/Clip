import AppKit

/// One place a link can be opened.
struct OpenTarget: Identifiable, Equatable {
    /// Application bundle path, which is unique and stable.
    let id: String
    let name: String
    /// Set for the app the system would use anyway.
    let isDefault: Bool
    /// True when this is the service's own app rather than a browser.
    let isNative: Bool

    var appURL: URL { URL(fileURLWithPath: id) }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: id) }

    var symbol: String { isNative ? "app.badge" : "safari" }
}

/// Works out what can open a link.
///
/// The list is discovered from the system rather than hardcoded: whichever
/// browsers are installed will handle an `https` URL, and a service's own app
/// registers for its domain. A hardcoded list would go stale the moment someone
/// installs a different browser, and would name apps the user does not have.
enum LinkOpener {

    /// Apps a service ships that will not necessarily claim the URL themselves.
    ///
    /// Figma is the reason this exists: the desktop app is installed far more
    /// often than it is registered as the handler for `figma.com`, so it never
    /// appears in the system's list even though it opens the file perfectly.
    private static let nativeApps: [LinkPlatform: [String]] = [
        .figma:       ["com.figma.Desktop"],
        .slack:       ["com.tinyspeck.slackmacgap"],
        .notion:      ["notion.id"],
        .youtube:     ["com.apple.TV"],
        .linkedin:    [],
        .chatgpt:     ["com.openai.chat"],
        .claude:      ["com.anthropic.claudefordesktop"],
        .repository:  ["com.github.GitHubClient"],
        .googleDocs:  [],
        .googleDrive: ["com.google.drivefs"],
        .microsoft:   ["com.microsoft.teams2", "com.microsoft.teams"],
        .jira:        [],
        .gist:        [],
        .gemini:      [],
        .stackoverflow: [],
        .npm:         [],
        .huggingface: []
    ]

    /// Everything that can open this link, native apps first.
    static func targets(for item: ClipboardItem) -> [OpenTarget] {
        guard let url = URL(string: item.fullText), url.scheme != nil else { return [] }

        let workspace = NSWorkspace.shared
        let defaultURL = workspace.urlForApplication(toOpen: url)
        // Deduplicate by bundle identifier, not path: a second copy of the same
        // app in another folder is the same app, and listing "Google Chrome for
        // Testing" twice tells the user nothing about which one to pick.
        var seen = Set<String>()
        var out: [OpenTarget] = []

        func identity(_ appURL: URL) -> String {
            Bundle(url: appURL)?.bundleIdentifier ?? appURL.path
        }

        // The service's own app, when it is actually installed.
        if let platform = item.platform {
            for bundleID in nativeApps[platform] ?? [] {
                guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID),
                      !seen.contains(identity(appURL)) else { continue }
                seen.insert(identity(appURL))
                out.append(OpenTarget(id: appURL.path,
                                      name: displayName(appURL),
                                      isDefault: appURL == defaultURL,
                                      isNative: true))
            }
        }

        // Then every app the system says can handle it, browsers included.
        for appURL in workspace.urlsForApplications(toOpen: url)
        where !seen.contains(identity(appURL)) {
            seen.insert(identity(appURL))
            out.append(OpenTarget(id: appURL.path,
                                  name: displayName(appURL),
                                  isDefault: appURL == defaultURL,
                                  isNative: false))
        }

        // The default handler leads, since it is what a plain click would do.
        return out.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            if lhs.isNative != rhs.isNative { return lhs.isNative }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func displayName(_ appURL: URL) -> String {
        FileManager.default.displayName(atPath: appURL.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    /// Opens the link in the chosen app.
    static func open(_ item: ClipboardItem, with target: OpenTarget?) {
        guard let url = URL(string: item.fullText) else { return }
        guard let target else {
            NSWorkspace.shared.open(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: target.appURL,
                                configuration: configuration) { _, error in
            if error != nil {
                // The app may have been moved or removed since the list was
                // built - the fallback below always ran, but silently, so a
                // link opening in the WRONG app (the system default, not the
                // one the person actually chose) looked identical to it
                // opening in the right one.
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(url)
                    NoticeCenter.shared.report(
                        "\(target.name) is no longer installed. Opened in your default browser instead.",
                        kind: .transient)
                }
            }
        }
    }
}
