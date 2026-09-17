import Foundation
import Combine

/// What a paste action does to the text on its way out.
///
/// The whole point of this file is that the *instruction* lives with the
/// action, in one place, rather than being assembled at each call site. There
/// are three callers (the menu, the two shortcuts and the settings preview) and
/// the first version of this had the wording in two of them, which is how a
/// translation and a "translate" menu item can disagree about which direction
/// they go.
enum PasteActionKind: String, Codable, CaseIterable {
    /// Between the two configured languages, either way, decided from the text.
    case translateAuto
    /// Into one named language, from whatever the text is in.
    case translateTo
    /// A named voice: formal, friendly, direct, and whatever else is configured.
    case rewriteStyle
    case improvePrompt
    case fixGrammar
    case shorten
    case expand
    case bullets
    case summarise
    case explain
    case toJSON
    case toTypeScript
    case toSwift
    case commitMessage
    case emailReply
    case slackMessage
    case redactSecrets
    /// The user's own instruction.
    case custom

    /// True when this kind is a parent whose children come from a configured
    /// list, rather than a single leaf action.
    var hasSubmenu: Bool { self == .translateTo || self == .rewriteStyle }

    var symbol: String {
        switch self {
        case .translateAuto, .translateTo: return "character.bubble"
        case .rewriteStyle:   return "textformat.alt"
        case .improvePrompt:  return "wand.and.stars"
        case .fixGrammar:     return "checkmark.circle"
        case .shorten:        return "arrow.down.right.and.arrow.up.left"
        case .expand:         return "arrow.up.left.and.arrow.down.right"
        case .bullets:        return "list.bullet"
        case .summarise:      return "text.line.first.and.arrowtriangle.forward"
        case .explain:        return "questionmark.circle"
        case .toJSON:         return "curlybraces"
        case .toTypeScript:   return "chevron.left.forwardslash.chevron.right"
        case .toSwift:        return "swift"
        case .commitMessage:  return "arrow.triangle.branch"
        case .emailReply:     return "envelope"
        case .slackMessage:   return "bubble.left.and.bubble.right"
        case .redactSecrets:  return "eye.slash"
        case .custom:         return "sparkles"
        }
    }

    var defaultTitle: String {
        switch self {
        case .translateAuto: return "Translate"
        case .translateTo:   return "Translate to"
        case .rewriteStyle:  return "Rewrite in a style"
        case .improvePrompt: return "Improve this prompt"
        case .fixGrammar:    return "Fix spelling and grammar"
        case .shorten:       return "Make it shorter"
        case .expand:        return "Make it fuller"
        case .bullets:       return "Turn into bullets"
        case .summarise:     return "Summarize"
        case .explain:       return "Explain this"
        case .toJSON:        return "As JSON"
        case .toTypeScript:  return "As a TypeScript type"
        case .toSwift:       return "As a Swift struct"
        case .commitMessage: return "As a commit message"
        case .emailReply:    return "Write a reply"
        case .slackMessage:  return "As a Slack message"
        case .redactSecrets: return "Remove secrets"
        case .custom:        return "Custom action"
        }
    }

    /// One line, in the settings list, saying what the user gets.
    var detail: String {
        switch self {
        case .translateAuto: return "Between your two languages, whichever way round the text is"
        case .translateTo:   return "Into one language you pick from the submenu"
        case .rewriteStyle:  return "The same content in a different voice"
        case .improvePrompt: return "Rewrites a prompt to be specific and unambiguous"
        case .fixGrammar:    return "Corrections only, the wording left alone"
        case .shorten:       return "Same meaning, fewer words"
        case .expand:        return "Fills out notes into full sentences"
        case .bullets:       return "Prose into a scannable list"
        case .summarise:     return "The point of a long piece, in a few lines"
        case .explain:       return "What this code or error actually means"
        case .toJSON:        return "Structures loose text into JSON"
        case .toTypeScript:  return "A type declaration for the pasted shape"
        case .toSwift:       return "A Codable struct for the pasted shape"
        case .commitMessage: return "A diff or a description into a commit message"
        case .emailReply:    return "A reply to the message you copied"
        case .slackMessage:  return "Shorter, plainer, no salutation"
        case .redactSecrets: return "Keys, tokens, emails and names stripped before it lands"
        case .custom:        return "Your own instruction"
        }
    }
}

/// One entry in the paste action menu.
struct PasteAction: Identifiable, Codable, Equatable {
    var id: UUID
    var kind: PasteActionKind
    var isEnabled: Bool
    /// Overrides the kind's own name.
    var customTitle: String?
    /// The user's instruction, for `.custom` only.
    var instruction: String?
    /// A global key combination that fires this action from any app.
    /// Same "Command+Shift+X" format as ShortcutRegistry. nil means no shortcut.
    var shortcut: String?

    var title: String { customTitle ?? kind.defaultTitle }
    var symbol: String { kind.symbol }
    /// Only what the user added can be removed; the built-ins are turned off.
    var isRemovable: Bool { kind == .custom }

    init(_ kind: PasteActionKind,
         enabled: Bool = true,
         title: String? = nil,
         instruction: String? = nil,
         shortcut: String? = nil,
         id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.isEnabled = enabled
        self.customTitle = title
        self.instruction = instruction
        self.shortcut = shortcut
    }
}

/// The ordered action list, the language pair, and the two configured lists.
///
/// Persisted through `Database` preferences like `TabConfiguration`, so it
/// travels with a settings snapshot to another Mac without new plumbing.
@MainActor
final class PasteActionStore: ObservableObject {

    static let shared = PasteActionStore()

    @Published private(set) var actions: [PasteAction] = []
    /// The submenu under "Translate to".
    @Published private(set) var languages: [String] = []
    /// The submenu under "Rewrite in a style".
    @Published private(set) var styles: [String] = []
    /// The two languages the one-key translation goes between.
    @Published private(set) var pair: LanguagePair = LanguagePair.systemDefault

    struct LanguagePair: Codable, Equatable {
        var first: String
        var second: String

        /// What a fresh install gets, read from the Mac.
        ///
        /// This was hard-coded to English and Hebrew, which is the author's own
        /// pair rather than a default - the sort of personal setting that has no
        /// business shipping to anyone else. The system's own preferred
        /// languages are the only honest guess: someone whose Mac is in French
        /// wants French, and someone with one language configured gets a second
        /// they will change on the first day either way.
        static var systemDefault: LanguagePair {
            let names = Locale.preferredLanguages.compactMap { code -> String? in
                let language = Locale(identifier: code).language.languageCode?.identifier
                guard let language else { return nil }
                return Locale(identifier: "en").localizedString(forLanguageCode: language)?
                    .capitalized
            }
            var unique: [String] = []
            for name in names where !unique.contains(name) { unique.append(name) }
            let first = unique.first ?? "English"
            let second = unique.dropFirst().first
                ?? (first == "English" ? "Spanish" : "English")
            return LanguagePair(first: first, second: second)
        }
    }

    /// The menu, in order, with the disabled ones gone.
    ///
    /// Disabled means **absent**, not greyed: a menu item that can never be
    /// chosen is a question asked on every open that never has an answer.
    var enabled: [PasteAction] { actions.filter(\.isEnabled) }

    private init() { load() }

    // MARK: - Defaults

    /// A short menu out of the box. Everything else is available and off, so
    /// the first press of the shortcut shows something readable rather than
    /// eighteen rows.
    static var defaultActions: [PasteAction] {
        [
            PasteAction(.translateAuto),
            PasteAction(.translateTo),
            PasteAction(.improvePrompt),
            PasteAction(.rewriteStyle),
            PasteAction(.fixGrammar),
            PasteAction(.shorten),
            PasteAction(.bullets),
            PasteAction(.summarise, enabled: false),
            PasteAction(.expand, enabled: false),
            PasteAction(.explain, enabled: false),
            PasteAction(.toJSON, enabled: false),
            PasteAction(.toTypeScript, enabled: false),
            PasteAction(.toSwift, enabled: false),
            PasteAction(.commitMessage, enabled: false),
            PasteAction(.emailReply, enabled: false),
            PasteAction(.slackMessage, enabled: false),
            PasteAction(.redactSecrets, enabled: false)
        ]
    }

    /// The submenu list a fresh install gets.
    ///
    /// The system pair goes first, and the rest are the most-spoken languages
    /// its users are likely to want. Whatever the pair points at must be in
    /// this list, or the Settings pickers would be showing a selection that is
    /// not among their own options.
    static var defaultLanguages: [String] {
        let pair = LanguagePair.systemDefault
        var list = [pair.first, pair.second]
        for name in ["English", "Spanish", "French", "German", "Chinese",
                     "Arabic", "Hindi", "Portuguese", "Russian", "Japanese"]
        where !list.contains(name) {
            list.append(name)
        }
        return list
    }
    static let defaultStyles = ["Formal", "Friendly", "Direct", "Confident",
                                "Plain English", "Technical"]

    // MARK: - Editing

    /// Replaces the whole ordered list. Used by drag-and-drop reordering.
    func replaceAll(_ new: [PasteAction]) {
        actions = new
        persist()
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = actions.firstIndex(where: { $0.id == id }) else { return }
        actions[i].isEnabled = on
        persist()
    }

    func rename(_ id: UUID, to title: String) {
        guard let i = actions.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        actions[i].customTitle = trimmed.isEmpty ? nil : trimmed
        persist()
    }

    /// Adds the user's own transform. Returns nil, or why it was refused.
    @discardableResult
    func addCustom(title: String, instruction: String) -> String? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Give the action a name." }
        if body.isEmpty { return "Say what it should do with the text." }
        if actions.contains(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
            return "There is already an action called “\(name)”."
        }
        actions.append(PasteAction(.custom, title: name, instruction: body))
        persist()
        return nil
    }

    func validateShortcut(_ combo: String, for id: UUID) -> String? {
        ShortcutRegistry.shared.conflictForPasteAction(combo, excluding: id)
    }

    @discardableResult
    func setShortcut(_ combo: String?, for id: UUID) -> String? {
        guard let idx = actions.firstIndex(where: { $0.id == id }) else { return nil }
        if let combo, !combo.isEmpty {
            if let reason = validateShortcut(combo, for: id) { return reason }
            let status = ShortcutManager.shared.setNamedGlobal(id.uuidString, shortcut: combo)
            guard status == noErr else {
                return "macOS refused that combination: another app owns it."
            }
        } else {
            _ = ShortcutManager.shared.setNamedGlobal(id.uuidString, shortcut: "")
        }
        actions[idx].shortcut = (combo?.isEmpty == false) ? combo : nil
        persist()
        return nil
    }

    func clearShortcut(for id: UUID) { _ = setShortcut(nil, for: id) }

    func remove(_ id: UUID) {
        guard let action = actions.first(where: { $0.id == id }), action.isRemovable else { return }
        clearShortcut(for: id)
        actions.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Lists

    @discardableResult
    func addLanguage(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Name the language." }
        if languages.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "\(trimmed) is already in the list."
        }
        languages.append(trimmed)
        persist()
        return nil
    }

    func removeLanguage(_ name: String) {
        // Never leave the pair pointing at a language that is gone.
        guard languages.count > 2, name != pair.first, name != pair.second else { return }
        languages.removeAll { $0 == name }
        persist()
    }

    @discardableResult
    func addStyle(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Name the style." }
        if styles.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "\(trimmed) is already in the list."
        }
        styles.append(trimmed)
        persist()
        return nil
    }

    func removeStyle(_ name: String) {
        guard styles.count > 1 else { return }
        styles.removeAll { $0 == name }
        persist()
    }

    func setPair(first: String, second: String) {
        // Two languages that are the same would translate to itself, and the
        // either-way rule would have nothing to choose between.
        guard first != second else { return }
        pair = LanguagePair(first: first, second: second)
        if !languages.contains(first) { languages.append(first) }
        if !languages.contains(second) { languages.append(second) }
        persist()
    }

    func resetToDefaults() {
        actions = Self.defaultActions
        languages = Self.defaultLanguages
        styles = Self.defaultStyles
        pair = LanguagePair.systemDefault
        persist()
    }

    // MARK: - Instructions

    /// What the model is told to do, for one action and one optional argument.
    ///
    /// Every instruction ends by demanding the transformed text alone. The
    /// result is pasted straight into whatever the user was typing in, so a
    /// preamble ("Sure! Here is your translation:") is not a cosmetic problem,
    /// it is wrong output in someone's document.
    func instruction(for action: PasteAction, argument: String? = nil) -> String {
        let onlyText = "Reply with the resulting text only. No preamble, no explanation, no quotes around it, no markdown fences."
        switch action.kind {
        case .translateAuto:
            return """
                The text is in either \(pair.first) or \(pair.second). Work out which, then \
                translate it into the other one: \(pair.first) text becomes \(pair.second), \
                and \(pair.second) text becomes \(pair.first). If it is in neither, translate \
                it into \(pair.first). Keep the tone, the formatting and any code or names \
                exactly as they are. \(onlyText)
                """
        case .translateTo:
            let language = argument ?? pair.second
            return """
                Translate the text into \(language). Keep the tone, the formatting and any \
                code, URLs or proper names exactly as they are. \(onlyText)
                """
        case .rewriteStyle:
            let style = argument ?? "Plain English"
            return """
                Rewrite the text in a \(style.lowercased()) voice. Keep every fact and every \
                name; change only the wording. Keep it about the same length. \(onlyText)
                """
        case .improvePrompt:
            return """
                Rewrite this as a clearer prompt for an AI model: state the task, the context \
                and the required output shape, and remove ambiguity. Keep the user's intent \
                exactly. \(onlyText)
                """
        case .fixGrammar:
            return """
                Correct spelling, grammar and punctuation. Change nothing else - not the \
                wording, not the tone, not the formatting. \(onlyText)
                """
        case .shorten:
            return "Rewrite the text to be substantially shorter while keeping every point that matters. \(onlyText)"
        case .expand:
            return "Turn these notes into complete, well-formed sentences without inventing facts. \(onlyText)"
        case .bullets:
            return "Rewrite the text as a short bulleted list, one point per line, each line starting with \"- \". \(onlyText)"
        case .summarise:
            return "Summarize the text in at most four sentences, keeping the specifics that matter. \(onlyText)"
        case .explain:
            return """
                Explain what this code, error or message means and what to do about it, in a \
                few plain sentences. \(onlyText)
                """
        case .toJSON:
            return "Convert the text into valid, minimal JSON that captures its structure. \(onlyText)"
        case .toTypeScript:
            return "Write a TypeScript type declaration for the shape of this data. \(onlyText)"
        case .toSwift:
            return "Write a Swift struct conforming to Codable for the shape of this data. \(onlyText)"
        case .commitMessage:
            return """
                Write a git commit message for this change: a short imperative subject line \
                under 72 characters, a blank line, then the why in a few lines. \(onlyText)
                """
        case .emailReply:
            return """
                Write a reply to this message. Match its register, answer what it asks, and \
                keep it brief. \(onlyText)
                """
        case .slackMessage:
            return """
                Rewrite this as a Slack message: plain, direct, no salutation and no sign-off, \
                a couple of sentences at most. \(onlyText)
                """
        case .redactSecrets:
            return """
                Return the text with every secret and personal detail replaced by a placeholder \
                in square brackets: API keys, tokens, passwords, connection strings, email \
                addresses, phone numbers, and personal names. Change nothing else, so the text \
                still reads and still shows the structure. \(onlyText)
                """
        case .custom:
            let body = action.instruction ?? "Rewrite the text."
            return "\(body)\n\n\(onlyText)"
        }
    }

    /// The children of a parent action, in the order they are shown.
    func submenu(for action: PasteAction) -> [String] {
        switch action.kind {
        case .translateTo:  return languages
        case .rewriteStyle: return styles
        default:            return []
        }
    }

    /// How the finished action reads once its argument is chosen, for the
    /// working indicator and for any error about it.
    func label(for action: PasteAction, argument: String?) -> String {
        switch action.kind {
        case .translateAuto: return "\(pair.first) and \(pair.second)"
        case .translateTo:   return "into \(argument ?? pair.second)"
        case .rewriteStyle:  return "in a \((argument ?? "plain").lowercased()) voice"
        default:             return action.title.lowercased()
        }
    }

    // MARK: - Storage

    private func persist() {
        write(actions, to: "pasteActions")
        write(languages, to: "pasteLanguages")
        write(styles, to: "pasteStyles")
        write(pair, to: "pasteLanguagePair")
    }

    private func write<T: Encodable>(_ value: T, to key: String) {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else { return }
        Database.shared.setPreference(key, json)
    }

    private func read<T: Decodable>(_ type: T.Type, from key: String) -> T? {
        guard let json = Database.shared.preference(key),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Re-reads everything, for a settings snapshot arriving from another Mac.
    func reload() { load(); objectWillChange.send() }

    private func load() {
        actions = read([PasteAction].self, from: "pasteActions") ?? Self.defaultActions
        languages = read([String].self, from: "pasteLanguages") ?? Self.defaultLanguages
        styles = read([String].self, from: "pasteStyles") ?? Self.defaultStyles
        pair = read(LanguagePair.self, from: "pasteLanguagePair")
            ?? LanguagePair.systemDefault
        // A kind added in an update appears, turned off, without resetting what
        // the user has arranged. Same rule as tabs.
        let known = Set(actions.map(\.kind))
        for kind in PasteActionKind.allCases
        where kind != .custom && !known.contains(kind) {
            actions.append(PasteAction(kind, enabled: false))
        }
    }
}
