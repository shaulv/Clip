import Foundation
import SwiftUI
import AppKit

/// A single clipboard history entry.
///
/// All kinds share one model so history stays a single ordered list. Heavy
/// payloads (images, video posters) live on disk via `MediaStore` and are
/// referenced by filename; text is stored inline.
///
/// Decoding is written by hand rather than synthesised so that histories saved
/// by older builds still load when new fields are added.
struct ClipboardItem: Identifiable, Codable, Equatable, Hashable {
    /// Settable only so `ItemMerge` can hold a folded entry to the id it
    /// already chose. Nothing else may reassign it.
    var id: UUID
    var kind: ItemKind
    var text: String?
    var richText: Data?
    var imageFile: String?
    var filePaths: [String]
    var hexColor: String?
    var sourceApp: String?
    /// Where the user dragged this item to, within its own collection.
    ///
    /// Nil until somebody reorders something. A collection with no manual order
    /// keeps whatever the sort says, which is what almost every tab wants;
    /// dragging one card is what opts that collection into being hand-arranged.
    var manualOrder: Int?

    /// When a model last looked this document over, if it ever has.
    ///
    /// This is what makes "review it again" a meaningful offer rather than an
    /// endlessly repeated one: a document is reviewable when it has never been
    /// reviewed, or when it has been edited since. Nil for everything that is
    /// not a document you write.
    var reviewedAt: Date?
    var sourceAppName: String?
    var timestamp: Date
    var isPinned: Bool
    var pinnedIndex: Int
    var isFavorite: Bool

    // MARK: Added after v1 — all optional-with-default for backward compatibility.

    /// How many times the user pasted this. Drives the "most used" sort.
    var useCount: Int = 0
    /// User-given name. Prompts almost always want one; clips rarely do.
    var title: String?
    /// Free-form tags, used by the prompt library.
    var tags: [String] = []
    /// What this item is: an ordinary clip, or something the user curated.
    var role: ItemRole = .clip

    /// Kept so existing call sites and older saved files keep working.
    var isPrompt: Bool {
        get { role == .prompt }
        set { role = newValue ? .prompt : .clip }
    }
    /// A per-item global hotkey, e.g. "Control+Option+1".
    var shortcut: String?
    /// Detected language for code items ("swift", "json", …).
    var language: String?
    /// Recognised service behind a link (GitHub repo, Figma, ChatGPT…).
    var platform: LinkPlatform?
    /// Pixel size for images/video, for the preview caption.
    var pixelWidth: Int?
    var pixelHeight: Int?

    /// When this item last changed, as opposed to when it was captured.
    ///
    /// Sync needs a clock that moves. `timestamp` deliberately does not: it means
    /// "when I copied this", and it orders the list. Editing a note should not
    /// shuffle it to the top of the history.
    ///
    /// Without a separate clock every edit was silently rejected by the server -
    /// it compares the incoming time against the stored one and keeps the newer,
    /// so an unchanged time always lost. The clip reached the server once, at
    /// capture, and nothing typed into it afterwards ever followed.
    var updatedAt: Date = Date()

    /// The title of the page a link points at, read from its own metadata.
    ///
    /// Separate from `title`, which is the name the *user* gave the item. If they
    /// name something, a background fetch must never overwrite it.
    var pageTitle: String?

    /// True when this item points at something that only exists on THIS Mac,
    /// and must never leave it through sync.
    ///
    /// The user's own words (02/09): "images can also move and names can
    /// change and a lot of things that break the path, we can't follow that
    /// ... anything that can't be a text/number syntax should be only local
    /// because the file is local ... it's specific paths for that mac." A
    /// filename or a path is only meaningful on the Mac that wrote it - the
    /// same `imageFile` on another Mac names nothing, and the same
    /// `filePaths` entry can already name a completely different file there.
    /// Media-as-a-second-sync-entity (the cancelled M5 step 5.2) tried to
    /// carry the bytes too; this field is what replaced that attempt.
    ///
    /// True for `.image`, `.video`, `.file` and `.folder` by kind, and true
    /// for anything else that happens to carry a non-nil `imageFile` or a
    /// non-empty `filePaths` (defence in depth - no code path is known to
    /// produce that combination today, but the cost of checking is one
    /// extra `||`, and the cost of missing it is a path uploaded to a
    /// server). A link to a repository is still a `.url` item whose only
    /// payload is its text address, so it is NOT local-only - the address
    /// works from any Mac.
    var isLocalOnly: Bool {
        switch kind {
        case .image, .video, .file, .folder:
            return true
        default:
            return imageFile != nil || !filePaths.isEmpty
        }
    }

    init(
        id: UUID = UUID(),
        kind: ItemKind,
        text: String? = nil,
        richText: Data? = nil,
        imageFile: String? = nil,
        filePaths: [String] = [],
        hexColor: String? = nil,
        sourceApp: String? = nil,
        sourceAppName: String? = nil,
        timestamp: Date = Date(),
        isPinned: Bool = false,
        pinnedIndex: Int = 0,
        isFavorite: Bool = false,
        useCount: Int = 0,
        title: String? = nil,
        tags: [String] = [],
        role: ItemRole = .clip,
        shortcut: String? = nil,
        language: String? = nil,
        platform: LinkPlatform? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        updatedAt: Date? = nil,
        pageTitle: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.richText = richText
        self.imageFile = imageFile
        self.filePaths = filePaths
        self.hexColor = hexColor
        self.sourceApp = sourceApp
        self.sourceAppName = sourceAppName
        self.timestamp = timestamp
        self.isPinned = isPinned
        self.pinnedIndex = pinnedIndex
        self.isFavorite = isFavorite
        self.useCount = useCount
        self.title = title
        self.tags = tags
        self.role = role
        self.shortcut = shortcut
        self.language = language
        self.platform = platform
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.updatedAt = updatedAt ?? timestamp
        self.pageTitle = pageTitle
    }

    // MARK: - Codable (tolerant of older files)

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, richText, imageFile, filePaths, hexColor
        case sourceApp, sourceAppName, reviewedAt, manualOrder, timestamp, isPinned, pinnedIndex, isFavorite
        case useCount, title, tags, isPrompt, role, shortcut, language, platform, pixelWidth, pixelHeight
        case updatedAt, pageTitle
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(richText, forKey: .richText)
        try c.encodeIfPresent(imageFile, forKey: .imageFile)
        try c.encode(filePaths, forKey: .filePaths)
        try c.encodeIfPresent(hexColor, forKey: .hexColor)
        try c.encodeIfPresent(sourceApp, forKey: .sourceApp)
        try c.encodeIfPresent(reviewedAt, forKey: .reviewedAt)
        try c.encodeIfPresent(manualOrder, forKey: .manualOrder)
        try c.encodeIfPresent(sourceAppName, forKey: .sourceAppName)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(isPinned, forKey: .isPinned)
        try c.encode(pinnedIndex, forKey: .pinnedIndex)
        try c.encode(isFavorite, forKey: .isFavorite)
        try c.encode(useCount, forKey: .useCount)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(tags, forKey: .tags)
        try c.encode(role, forKey: .role)
        try c.encode(role == .prompt, forKey: .isPrompt)
        try c.encodeIfPresent(shortcut, forKey: .shortcut)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encodeIfPresent(platform, forKey: .platform)
        try c.encodeIfPresent(pixelWidth, forKey: .pixelWidth)
        try c.encodeIfPresent(pixelHeight, forKey: .pixelHeight)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(pageTitle, forKey: .pageTitle)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        // An unknown kind from a newer build degrades to text rather than failing.
        kind = (try? c.decode(ItemKind.self, forKey: .kind)) ?? .text
        text = try c.decodeIfPresent(String.self, forKey: .text)
        richText = try c.decodeIfPresent(Data.self, forKey: .richText)
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
        filePaths = try c.decodeIfPresent([String].self, forKey: .filePaths) ?? []
        hexColor = try c.decodeIfPresent(String.self, forKey: .hexColor)
        sourceApp = try c.decodeIfPresent(String.self, forKey: .sourceApp)
        reviewedAt = try c.decodeIfPresent(Date.self, forKey: .reviewedAt)
        manualOrder = try c.decodeIfPresent(Int.self, forKey: .manualOrder)
        sourceAppName = try c.decodeIfPresent(String.self, forKey: .sourceAppName)
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        pinnedIndex = try c.decodeIfPresent(Int.self, forKey: .pinnedIndex) ?? 0
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        useCount = try c.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        // `role` supersedes the older `isPrompt` flag; fall back to it so a
        // history saved by an earlier build keeps its prompts.
        if let r = try c.decodeIfPresent(ItemRole.self, forKey: .role) {
            role = r
        } else {
            role = (try c.decodeIfPresent(Bool.self, forKey: .isPrompt) ?? false) ? .prompt : .clip
        }
        shortcut = try c.decodeIfPresent(String.self, forKey: .shortcut)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        platform = try c.decodeIfPresent(LinkPlatform.self, forKey: .platform)
        pixelWidth = try c.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try c.decodeIfPresent(Int.self, forKey: .pixelHeight)
        // Items written before this field existed fall back to their capture
        // time, which is exactly right: nothing has edited them since.
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? timestamp
        pageTitle = try c.decodeIfPresent(String.self, forKey: .pageTitle)
    }

    // MARK: - Display

    /// The name shown as a card's heading.
    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        switch kind {
        case .image:  return "Image"
        case .video:  return "Video"
        case .color:  return hexColor ?? "Color"
        case .file, .folder:
            return filePaths.first.map { ($0 as NSString).lastPathComponent } ?? kind.displayName
        case .url:
            // The address itself, not the domain and not the page's title. A row
            // reading "figma.com" says which site and nothing else, so twenty
            // Figma links made twenty identical rows; the path is what tells them
            // apart. The page title and the service name go on the line below.
            let address = shortURL
            return address.isEmpty ? (host ?? "Link") : address
        case .code:   return language?.capitalized ?? "Code"
        default:      return previewText.isEmpty ? kind.displayName : previewText
        }
    }

    /// What a curated skill is for, read from the document itself.
    ///
    /// Computed rather than stored: it comes from text the item already holds, so
    /// storing it would be a second copy to keep in step. Only the first few
    /// thousand characters are read, which is where the front matter lives.
    var skillDescription: String? { documentDescription }

    /// What a curated document is for, read from the document itself.
    ///
    /// Computed rather than stored: it comes from text the item already holds,
    /// so storing it would be a second copy to keep in step.
    var documentDescription: String? {
        switch role {
        case .skill:  return SkillDetector.describe(fullText)
        case .design: return DesignDocDetector.describe(fullText)
        default:      return nil
        }
    }

    /// When to reach for it, if the document says so plainly.
    var skillUsage: String? {
        guard role == .skill else { return nil }
        return SkillDetector.usage(fullText)
    }

    /// What this item is, in one word, for the line under the title.
    ///
    /// A recognised service beats the generic kind: "Figma" is more use than
    /// "Link", which the icon has already said.
    var typeLabel: String {
        if kind == .url, let platform { return platform.title }
        if kind == .code { return (language ?? "code").uppercased() }
        return kind.displayName
    }

    /// The address, trimmed to what is worth reading in a row.
    ///
    /// The scheme and a `www.` carry no information a reader needs, and a long
    /// query string pushes the part that identifies the page off the end.
    var shortURL: String {
        guard kind == .url, var text = text else { return "" }
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        while text.hasSuffix("/") { text = String(text.dropLast()) }
        return text
    }

    /// Host for link items, e.g. "github.com".
    var host: String? {
        guard let s = text, let u = URL(string: s), let h = u.host else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    var summary: String {
        switch kind {
        case .text, .code, .emoji: return cleaned(text ?? "")
        case .richText:            return cleaned(text ?? "")
        case .image:               return dimensionCaption ?? "Image"
        case .video:               return dimensionCaption ?? "Video"
        case .file, .folder:
            return filePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        case .url:                 return text ?? ""
        case .color:               return hexColor ?? "Color"
        case .colorData:           return "Binary Data"
        }
    }

    var dimensionCaption: String? {
        guard let w = pixelWidth, let h = pixelHeight else { return nil }
        return "\(w) × \(h)"
    }

    /// Single-line preview used on cards and for searching.
    var previewText: String {
        switch kind {
        case .url: return text ?? ""
        default:   return cleaned(text ?? summary)
        }
    }

    /// Full text, unclipped — used by search, editing and the detail view.
    var fullText: String { text ?? "" }

    /// Rough word count, for the skill card - a reader wants to know whether
    /// this is a paragraph or a chapter before they paste it into a chat.
    var wordCount: Int {
        fullText.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Line count, for the code card's caption.
    var lineCount: Int {
        guard let t = text, !t.isEmpty else { return 0 }
        return t.components(separatedBy: .newlines).count
    }

    private func cleaned(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLen = 160
        return t.count > maxLen ? String(t.prefix(maxLen)) + "…" : t
    }

    /// One short line confirming what was just copied, for the menu bar.
    ///
    /// The moment feedback matters most is the moment you *cannot* see what you
    /// copied - a screenshot, a file dragged from somewhere, a color picked out
    /// of a palette. Confirming those with the word "Image" or "File" is the same
    /// as not confirming them, so each kind says the thing that identifies it.
    var copyConfirmation: String {
        switch kind {
        case .image, .video:
            let what = kind == .video ? "Video" : "Image"
            return dimensionCaption.map { "\(what) \($0)" } ?? what

        case .file, .folder:
            let names = filePaths.map { ($0 as NSString).lastPathComponent }
            guard let first = names.first else { return kind.displayName }
            return names.count > 1 ? "\(first) +\(names.count - 1)" : first

        case .color, .colorData:
            return hexColor ?? kind.displayName

        default:
            let line = fullText
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? kind.displayName : line
        }
    }

    /// The confirmation, cut to something a menu bar can carry.
    ///
    /// Cut on a word where one is close to the limit: "Lightweight clipboard…"
    /// reads as a phrase, "Lightweight clipbo…" reads as damage.
    func copyConfirmation(limit: Int) -> String {
        let text = copyConfirmation
        guard text.count > limit else { return text }

        let head = String(text.prefix(limit))
        if let space = head.lastIndex(of: " "),
           head.distance(from: head.startIndex, to: space) > limit / 2 {
            return String(head[..<space]) + "\u{2026}"
        }
        return head + "\u{2026}"
    }

    /// The date and time, written out.
    ///
    /// "3d" tells you it was recent; it does not tell you it was Tuesday. Both
    /// are useful, so both are shown - the age for scanning, the date for
    /// knowing.
    var dateLabel: String {
        let calendar = Calendar.current

        if calendar.isDateInToday(timestamp) {
            return "Today \(DateLabelFormatters.formatter(dateFormat: "HH:mm").string(from: timestamp))"
        }
        if calendar.isDateInYesterday(timestamp) {
            return "Yesterday \(DateLabelFormatters.formatter(dateFormat: "HH:mm").string(from: timestamp))"
        }
        // A year is only worth the space once it is not this one.
        let sameYear = calendar.component(.year, from: timestamp)
            == calendar.component(.year, from: Date())
        let formatter = DateLabelFormatters.formatter(
            template: sameYear ? "d MMM HH:mm" : "d MMM yyyy HH:mm")
        return formatter.string(from: timestamp)
    }

    /// The forms of the date a search might reasonably be typed as.
    ///
    /// Searching "august", "30/08", "2026" or "yesterday" should narrow the list
    /// the same way any other word does. Matching only the rendered label would
    /// mean "August" finds nothing while "Aug" finds everything.
    var dateSearchText: String {
        let calendar = Calendar.current

        var forms: [String] = [dateLabel]
        for template in ["d MMMM yyyy", "d MMM yyyy", "dd/MM/yyyy", "yyyy-MM-dd", "EEEE", "MMMM"] {
            forms.append(DateLabelFormatters.formatter(template: template).string(from: timestamp))
        }
        if calendar.isDateInToday(timestamp) { forms.append("today") }
        if calendar.isDateInYesterday(timestamp) { forms.append("yesterday") }
        if calendar.isDate(timestamp, equalTo: Date(), toGranularity: .weekOfYear) {
            forms.append("this week")
        }
        return forms.joined(separator: " ")
    }

    /// Compact age label: "now", "3m", "2h", "5d".
    var timeShort: String {
        let seconds = Int(Date().timeIntervalSince(timestamp))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }

    /// Matches this item against a query under the given search mode.
    /// Everything this item can be found by, lowercased once.
    ///
    /// Built by the store and cached, because `matches` used to assemble a
    /// six-string array and lowercase the whole body on EVERY keystroke for
    /// EVERY item. Importing 74 design documents of roughly 20k characters made
    /// that plain: megabytes of allocation per character typed.
    var searchBlob: String {
        ([previewText, title ?? "", sourceAppName ?? "",
          tags.joined(separator: " "), fullText, dateSearchText]
            .joined(separator: "\n"))
            .lowercased()
    }

    /// Matches against a prepared blob, so nothing is rebuilt per keystroke.
    /// `alreadyLowercased` lets the caller lowercase the query once for the
    /// whole library instead of once per item, which is the same work repeated
    /// as many times as there are items.
    func matches(_ query: String, mode: SearchMode, blob: String,
                 alreadyLowercased: Bool = false) -> Bool {
        if query.isEmpty { return true }
        let needle = alreadyLowercased ? query : query.lowercased()
        switch mode {
        case .exact:
            // `.literal` skips Unicode canonical-equivalence work, which is
            // most of the cost of a plain `contains` over a megabyte of text.
            return blob.range(of: needle, options: .literal) != nil
        case .fuzzy:
            return Self.fuzzyMatch(needle, in: blob)
        case .regex:
            guard let re = try? NSRegularExpression(pattern: query, options: [.caseInsensitive]) else {
                return false
            }
            return re.firstMatch(in: blob, range: NSRange(blob.startIndex..., in: blob)) != nil
        }
    }

    /// Kept for callers that have no prepared blob to hand.
    func matches(_ query: String, mode: SearchMode) -> Bool {
        matches(query, mode: mode, blob: searchBlob)
    }

    /// Subsequence match: every query character appears in order.
    private static func fuzzyMatch(_ needle: String, in haystack: String) -> Bool {
        var idx = haystack.startIndex
        for ch in needle {
            guard let found = haystack[idx...].firstIndex(of: ch) else { return false }
            idx = haystack.index(after: found)
        }
        return true
    }
}

/// How the search field interprets what the user types.
enum SearchMode: String, CaseIterable, Identifiable, Codable {
    case exact, fuzzy, regex
    var id: String { rawValue }
    var title: String {
        switch self {
        case .exact: return "Contains"
        case .fuzzy: return "Fuzzy"
        case .regex: return "Regex"
        }
    }
}

/// Ordering of the visible list.
///
/// "Source app" was here and is gone. Grouping a clipboard by which app you
/// were in answers a question nobody asks of their own history - you remember
/// what you copied, not which window was in front - and it pushed the thing you
/// just copied to wherever the alphabet put its app.
enum SortOrder: String, CaseIterable, Identifiable, Codable {
    case newest, oldest, mostUsed, kind

    var id: String { rawValue }
    var title: String {
        switch self {
        case .newest:    return "Newest first"
        case .oldest:    return "Oldest first"
        case .mostUsed:  return "Most used"
        case .kind:      return "Type"
        }
    }
    var symbol: String {
        switch self {
        case .newest:    return "arrow.down.circle"
        case .oldest:    return "arrow.up.circle"
        case .mostUsed:  return "flame"
        case .kind:      return "square.grid.2x2"
        }
    }
    /// For the header pill, which has no room for "Newest first" - matches
    /// TimeFilter.shortTitle's job for the same control family.
    var shortTitle: String {
        switch self {
        case .newest:    return "Newest"
        case .oldest:    return "Oldest"
        case .mostUsed:  return "Most used"
        case .kind:      return "Type"
        }
    }
}

/// One cached `DateFormatter` per distinct format, for `dateLabel` and
/// `dateSearchText`.
///
/// `dateLabel` used to build a fresh `DateFormatter` on every call - and it is
/// called once per visible row, per render, because it is not itself cached.
/// A tab switch over 200 rows was therefore 200 `DateFormatter` allocations
/// just to draw a timestamp whose format string never changes between two of
/// them. `DateFormatter` is one of the more expensive types to stand up on
/// Apple platforms (it resolves the user's calendar, locale and time zone),
/// so this alone measured in the milliseconds on a populated tab.
///
/// The cache is keyed by the format string itself (a fixed `dateFormat`, or a
/// `template:` - prefixed key for `setLocalizedDateFormatFromTemplate`, which
/// resolves to a different concrete format per locale and so cannot share a
/// key with a literal `dateFormat`). It is invalidated wholesale on
/// `NSLocale.currentLocaleDidChangeNotification` - a cached "d MMM" formatter
/// must not keep speaking yesterday's locale after the user changes it.
enum DateLabelFormatters {
    private static var cache: [String: DateFormatter] = [:]
    private static var isObservingLocaleChanges = false

    /// A cached formatter for a literal `dateFormat` string, e.g. "HH:mm".
    static func formatter(dateFormat: String) -> DateFormatter {
        observeLocaleChangesIfNeeded()
        if let cached = cache[dateFormat] { return cached }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = dateFormat
        cache[dateFormat] = formatter
        return formatter
    }

    /// A cached formatter built via `setLocalizedDateFormatFromTemplate`.
    static func formatter(template: String) -> DateFormatter {
        observeLocaleChangesIfNeeded()
        let key = "template:" + template
        if let cached = cache[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate(template)
        cache[key] = formatter
        return formatter
    }

    private static func observeLocaleChangesIfNeeded() {
        guard !isObservingLocaleChanges else { return }
        isObservingLocaleChanges = true
        NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil, queue: .main) { _ in cache.removeAll() }
    }
}
