import SwiftUI

/// The one bucketing concept shared by filters and tabs.
///
/// Before this, filters knew about kinds and tabs knew about roles, and a link
/// platform fitted neither. Folding all three into one type means "give Figma
/// links their own tab" and "filter to Figma links" are the same idea expressed
/// twice, rather than two features to build.
enum ItemCategory: Hashable, Identifiable, Codable {
    /// Everything, unfiltered.
    case all
    /// A data kind: text, code, image, color…
    case kind(ItemKind)
    /// A recognised service behind a link.
    case platform(LinkPlatform)
    /// Something the user curated: prompts, notes, skills.
    case role(ItemRole)

    var id: String {
        switch self {
        case .all:               return "all"
        case .kind(let k):       return "kind:\(k.rawValue)"
        case .platform(let p):   return "platform:\(p.rawValue)"
        case .role(let r):       return "role:\(r.rawValue)"
        }
    }

    init?(id: String) {
        if id == "all" { self = .all; return }
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "kind":     guard let k = ItemKind(rawValue: parts[1]) else { return nil }; self = .kind(k)
        case "platform": guard let p = LinkPlatform(rawValue: parts[1]) else { return nil }; self = .platform(p)
        case "role":     guard let r = ItemRole(rawValue: parts[1]) else { return nil }; self = .role(r)
        default: return nil
        }
    }

    /// The role this category curates, if any.
    var roleValue: ItemRole? {
        if case .role(let r) = self { return r }
        return nil
    }

    var title: String {
        switch self {
        case .all:             return "All"
        case .kind(let k):     return k.displayName
        case .platform(let p): return p.title
        case .role(let r):     return r.title + "s"
        }
    }

    var symbol: String {
        switch self {
        case .all:             return "square.grid.2x2"
        case .kind(let k):     return k.symbol
        case .platform(let p): return p.symbol
        case .role(let r):     return r.symbol
        }
    }

    /// Does this item belong in this category?
    func contains(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all:
            return true
        case .role(let r):
            return item.role == r
        case .platform(let p):
            return item.platform == p
        case .kind(let k):
            // Files and folders share a bucket when the user picks either, and
            // rich text lives under Text.
            return item.kind.filterCategory == k.filterCategory
        }
    }

    // MARK: Codable
    //
    // Encoded as its `id` string, so a stored tab layout stays readable and
    // survives new cases being added.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = ItemCategory(id: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unknown category \(raw)"))
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(id)
    }

    func tint(_ theme: AppTheme) -> Color {
        switch self {
        case .all:             return theme.accent
        case .kind(let k):     return theme.tint(for: k)
        case .platform:        return theme.accentSecondary
        case .role:            return theme.accent
        }
    }

    /// Every category that could sensibly become a tab or a filter chip.
    static var offerable: [ItemCategory] {
        [.all]
        // Derived, not listed: a hand-written trio meant adding a role left it
        // with no tab and no filter, silently, in a build that compiled.
        + ItemRole.allCases.filter(\.isCurated).map(ItemCategory.role)
        + ItemKind.filterable.map(ItemCategory.kind)
        + LinkPlatform.allCases.map(ItemCategory.platform)
    }
}
