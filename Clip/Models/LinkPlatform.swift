import Foundation

/// A recognised service behind a copied link.
///
/// A link is not one thing. A GitHub repository, a Figma file and a ChatGPT
/// conversation are as different from each other as an image is from a file, so
/// they get their own identity, their own filter and — if the user wants — their
/// own tab. Detection is host-and-path based and deliberately conservative: an
/// unrecognised link stays a plain link rather than being guessed at.
enum LinkPlatform: String, Codable, CaseIterable, Identifiable, Hashable {
    case repository          // GitHub / GitLab / Bitbucket repo
    case gist
    case figma
    case chatgpt
    case claude
    case gemini
    case googleDocs
    case googleDrive
    case microsoft
    case notion
    case slack
    case youtube
    case linkedin
    case jira
    case stackoverflow
    case npm
    case huggingface

    var id: String { rawValue }

    var title: String {
        switch self {
        case .repository:    return "Repository"
        case .gist:          return "Gist"
        case .figma:         return "Figma"
        case .chatgpt:       return "ChatGPT"
        case .claude:        return "Claude"
        case .gemini:        return "Gemini"
        case .googleDocs:    return "Google Docs"
        case .googleDrive:   return "Google Drive"
        case .microsoft:     return "Microsoft"
        case .notion:        return "Notion"
        case .slack:         return "Slack"
        case .youtube:       return "YouTube"
        case .linkedin:      return "LinkedIn"
        case .jira:          return "Jira"
        case .stackoverflow: return "Stack Overflow"
        case .npm:           return "npm"
        case .huggingface:   return "Hugging Face"
        }
    }

    var symbol: String {
        switch self {
        case .repository:    return "shippingbox"
        case .gist:          return "doc.text"
        case .figma:         return "pencil.and.outline"
        case .chatgpt:       return "bubble.left.and.bubble.right"
        case .claude:        return "sparkle"
        case .gemini:        return "diamond"
        case .googleDocs:    return "doc.richtext"
        case .googleDrive:   return "externaldrive"
        case .microsoft:     return "square.grid.2x2"
        case .notion:        return "note.text"
        case .slack:         return "number"
        case .youtube:       return "play.rectangle"
        case .linkedin:      return "person.crop.square"
        case .jira:          return "checklist"
        case .stackoverflow: return "questionmark.bubble"
        case .npm:           return "cube.box"
        case .huggingface:   return "brain"
        }
    }

    var badge: String { title.uppercased() }

    // MARK: - Detection

    /// True when `host` is this domain or any subdomain of it.
    ///
    /// Exact-host matching missed most of the real world: `il.linkedin.com`,
    /// `m.youtube.com`, `music.youtube.com`, `uk.linkedin.com` and every other
    /// regional or mobile front door fell through and arrived as an unlabelled
    /// link. A service is its domain, not one hostname it happens to use.
    private static func isHost(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    /// Identifies the service behind a URL, or nil when it is an ordinary link.
    ///
    /// Order matters: the specific Google properties are tested before anything
    /// generic, and gist.github.com before github.com, or the broader rule would
    /// swallow the narrower one.
    static func detect(_ raw: String) -> LinkPlatform? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // A bare "github.com/owner/name" is a link people paste constantly and
        // URL(string:) reads it as a path with no host at all.
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }

        let parts = url.path.split(separator: "/").map(String.init)

        // Google, most specific first.
        if isHost(host, "gemini.google.com") || isHost(host, "aistudio.google.com")
            || isHost(host, "makersuite.google.com") { return .gemini }
        if isHost(host, "docs.google.com") { return .googleDocs }
        if isHost(host, "drive.google.com") { return .googleDrive }

        // Code hosting, gist before the repositories it lives beside.
        if isHost(host, "gist.github.com") { return .gist }
        for domain in ["github.com", "gitlab.com", "bitbucket.org"] where isHost(host, domain) {
            // "/owner/name" is a repository; anything shorter is a profile or
            // the site itself, which is just a link.
            return parts.count >= 2 ? .repository : nil
        }
        if host.hasSuffix(".github.io") { return .repository }

        if isHost(host, "figma.com") { return .figma }
        if isHost(host, "chatgpt.com") || isHost(host, "chat.openai.com") { return .chatgpt }
        if isHost(host, "claude.ai") || isHost(host, "console.anthropic.com") { return .claude }
        if isHost(host, "notion.so") || isHost(host, "notion.site") { return .notion }
        if isHost(host, "slack.com") { return .slack }
        if isHost(host, "youtube.com") || isHost(host, "youtu.be") { return .youtube }
        if isHost(host, "linkedin.com") || isHost(host, "lnkd.in") { return .linkedin }
        if isHost(host, "atlassian.net") || isHost(host, "atlassian.com") { return .jira }
        for domain in ["stackoverflow.com", "stackexchange.com", "superuser.com",
                       "serverfault.com", "askubuntu.com"] where isHost(host, domain) {
            return .stackoverflow
        }
        if isHost(host, "npmjs.com") { return .npm }
        if isHost(host, "huggingface.co") { return .huggingface }
        for domain in ["sharepoint.com", "office.com", "office365.com", "microsoft.com",
                       "outlook.com", "live.com", "onedrive.com"] where isHost(host, domain) {
            return .microsoft
        }
        return nil
    }

    /// A repository's "owner/name", used as the card title.
    static func repositoryName(from raw: String) -> String? {
        guard let url = URL(string: raw) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }
}
