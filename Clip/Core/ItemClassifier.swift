import Foundation

/// The one place that decides what a piece of text *is*.
///
/// There are four ways text becomes an item - a system copy, a file dropped on
/// a tab, the Add button, and the corpus import - and each used to make up its
/// own mind. That is how a document could be a design system when copied and a
/// skill when dropped. The ladder lives here once and every entry point climbs
/// the same rungs, in the same order.
enum ItemClassifier {

    /// The curated role a document claims, with its title, or nil for anything
    /// that is just text.
    ///
    /// **Order matters and is not cosmetic.** A DESIGN.md opens with front
    /// matter carrying `name:` and `description:`, which is exactly what makes
    /// a skill a skill: over a 74-document corpus the skill detector claimed 64
    /// of them. The design detector demands strictly more evidence, so it is
    /// asked first and the skill detector only sees what it declines.
    static func curatedRole(for text: String) -> (role: ItemRole, title: String)? {
        if let title = DesignDocDetector.detect(text) { return (.design, title) }
        if let title = SkillDetector.detect(text) { return (.skill, title) }
        return nil
    }

    /// Builds an item from text, with the role its content earns.
    ///
    /// `preferredRole` is the tab the text arrived in: a drop into Notes makes a
    /// note. A recognised document still wins, because filing a design system
    /// under Notes because that tab happened to be open is not what anyone
    /// means by dropping it there.
    static func item(fromText text: String,
                     preferredRole: ItemRole? = nil,
                     sourceApp: String? = nil,
                     sourceAppName: String = "Clip",
                     title: String? = nil) -> ClipboardItem {

        if let match = curatedRole(for: text) {
            return ClipboardItem(kind: .text, text: text, sourceApp: sourceApp,
                                 sourceAppName: sourceAppName,
                                 title: title ?? match.title, role: match.role)
        }

        if let role = preferredRole, role.isCurated {
            return ClipboardItem(kind: .text, text: text, sourceApp: sourceApp,
                                 sourceAppName: sourceAppName,
                                 title: title ?? firstLineTitle(text), role: role)
        }

        // A color is a color however it arrived. This path - drops, imports,
        // anything created rather than copied - recognised none at all, so the
        // same string was a swatch from the pasteboard and a paragraph from a
        // drag.
        if let hex = HexColor.normalised(text) {
            return ClipboardItem(kind: .color, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                 hexColor: hex, sourceApp: sourceApp,
                                 sourceAppName: sourceAppName)
        }

        if let language = CodeDetector.language(for: text) {
            return ClipboardItem(kind: .code, text: text, sourceApp: sourceApp,
                                 sourceAppName: sourceAppName, language: language)
        }

        return ClipboardItem(kind: .text, text: text, sourceApp: sourceApp,
                             sourceAppName: sourceAppName, title: title)
    }

    /// A usable name for an untitled document: its first heading or first line.
    static func firstLineTitle(_ text: String) -> String {
        for line in text.prefix(2000).components(separatedBy: .newlines) {
            var l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, l != "---" else { continue }
            l = l.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty else { continue }
            return l.count > 60 ? String(l.prefix(57)) + "…" : l
        }
        return "Untitled"
    }
}
