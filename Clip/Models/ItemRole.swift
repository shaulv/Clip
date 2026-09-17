import Foundation

/// What a saved item *is*, as opposed to what kind of data it holds.
///
/// A single `isPrompt` flag stopped scaling once notes and skills arrived, and
/// four parallel booleans would have allowed nonsense states (a note that is
/// also a skill). One enum makes the tabs a straight partition of history.
enum ItemRole: String, Codable, CaseIterable, Identifiable {
    /// An ordinary clipboard capture.
    case clip
    /// A reusable prompt, with a name, tags and optionally a hotkey.
    case prompt
    /// A written note, authored in Clip rather than captured.
    case note
    /// A markdown document edited full-screen.
    case skill
    /// A design system document - a DESIGN.md - recognised by its own content.
    case design

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clip:   return "Clip"
        case .prompt: return "Prompt"
        case .note:   return "Note"
        case .skill:  return "Skill"
        case .design: return "Design"
        }
    }

    var symbol: String {
        switch self {
        case .clip:   return "doc.on.clipboard"
        case .prompt: return "text.badge.star"
        case .note:   return "note.text"
        case .skill:  return "graduationcap"
        case .design: return "paintpalette"
        }
    }

    /// Roles whose items are markdown documents, and open in the full-screen
    /// editor with a live preview rather than in a card.
    ///
    /// A property rather than three `role == .skill` comparisons scattered
    /// across the views: that is how design documents ended up opening in a
    /// plain text card despite being markdown, and how the next document role
    /// would have too.
    /// Notes and prompts joined skills and designs here. All four are things a
    /// person writes and comes back to, and all four are markdown in practice -
    /// a note with a list in it, a prompt with a fenced example. Only the plain
    /// clipping, which is whatever the pasteboard happened to hold, still gets
    /// the simple card.
    var isMarkdownDocument: Bool { self != .clip }

    /// Skills and design documents carry YAML front matter, which is the least
    /// readable part of the file and the part a preview must not lead with.
    /// Notes and prompts have no such header, so they preview as themselves.
    var hasFrontMatter: Bool { self == .skill || self == .design }

    /// Curated roles are never trimmed by the history limit.
    var isCurated: Bool { self != .clip }
}
