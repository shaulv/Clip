import Foundation

/// The kind of content a clipboard item holds. Drives icons, badges, filtering,
/// and which preview card the gallery renders.
enum ItemKind: String, Codable, CaseIterable, Identifiable {
    case text
    case code
    case richText
    case emoji
    case image
    case video
    case file
    case folder
    case url
    case color
    case colorData

    var id: String { rawValue }

    /// Kinds offered as filter chips. Rich text is deliberately absent: it is
    /// the same *category* as text to a user (both are "some words I copied"),
    /// so it filters under Text while keeping its own RTF tag on the card.
    static var filterable: [ItemKind] {
        [.text, .code, .emoji, .image, .video, .file, .folder, .url, .color]
    }

    /// The category this kind filters under.
    var filterCategory: ItemKind {
        self == .richText ? .text : self
    }

    var symbol: String {
        switch self {
        case .text:      return "text.alignleft"
        case .code:      return "chevron.left.forwardslash.chevron.right"
        case .richText:  return "textformat"
        case .emoji:     return "face.smiling"
        case .image:     return "photo"
        case .video:     return "play.rectangle"
        case .file:      return "doc"
        case .folder:    return "folder"
        case .url:       return "link"
        case .color:     return "paintpalette"
        case .colorData: return "square.fill"
        }
    }

    var displayName: String {
        switch self {
        case .text:      return "Text"
        case .code:      return "Code"
        case .richText:  return "Rich Text"
        case .emoji:     return "Emoji"
        case .image:     return "Image"
        case .video:     return "Video"
        case .file:      return "File"
        case .folder:    return "Folder"
        case .url:       return "Link"
        case .color:     return "Color"
        case .colorData: return "Data"
        }
    }

    var badge: String {
        switch self {
        case .text:      return "TXT"
        case .code:      return "CODE"
        case .richText:  return "RTF"
        case .emoji:     return "EMOJI"
        case .image:     return "IMG"
        case .video:     return "VIDEO"
        case .file:      return "FILE"
        case .folder:    return "DIR"
        case .url:       return "LINK"
        case .color:     return "COLOR"
        case .colorData: return "DATA"
        }
    }

    /// True when the item's payload is plain editable text.
    var isEditable: Bool {
        self == .text || self == .code || self == .url || self == .emoji
    }

    /// Items that exist somewhere on disk, so Finder can be asked to show them.
    var isOnDisk: Bool {
        self == .file || self == .folder || self == .image || self == .video
    }
}
