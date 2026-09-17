import Foundation

/// Recognises an AI skill document from its opening shape.
///
/// Skills all start the same way: a front-matter block, or a heading followed by
/// a name and a description. That header is the reliable signal — the body could
/// be anything. Detection is conservative: a document must carry both a name and
/// a description, or an explicit skill marker, before Clip reclassifies it.
enum SkillDetector {

    /// Returns a title when the text looks like a skill, else nil.
    static func detect(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 40 else { return nil }

        if let title = frontMatterTitle(trimmed) { return title }
        return markerTitle(trimmed)
    }

    /// What a skill is for, in one line, for the card.
    ///
    /// A row of skills all called "Systematic Debugging" and "Test Strategy" is a
    /// list of names, and names are not enough to decide whether you want one.
    /// The document already says what it does - `description:` in the front
    /// matter - it just was not being read.
    ///
    /// Only the opening of the document is examined: front matter lives at the
    /// top, and these run to thousands of words.
    static func describe(_ text: String) -> String? {
        let head = String(text.prefix(3000))

        if let value = frontMatterValue("description", in: head) { return tidy(value) }

        // No front matter: the first real sentence of prose, skipping headings,
        // quotes and lists, which are structure rather than a summary.
        for line in head.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("#"), !l.hasPrefix(">"), !l.hasPrefix("-"),
                  !l.hasPrefix("*"), !l.hasPrefix("|"), !l.hasPrefix("---"),
                  !l.hasPrefix("```"), l.count > 24 else { continue }
            return tidy(l)
        }
        return nil
    }

    /// When to reach for it, if the document says so plainly.
    static func usage(_ text: String) -> String? {
        let head = String(text.prefix(3000))
        for line in head.components(separatedBy: .newlines) {
            var l = line.trimmingCharacters(in: .whitespaces)
            while l.hasPrefix(">") || l.hasPrefix("*") || l.hasPrefix("-") {
                l = String(l.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            let lower = l.lowercased()
            guard lower.hasPrefix("use this when") || lower.hasPrefix("use this whenever")
                    || lower.hasPrefix("use when") || lower.hasPrefix("use this on")
                    || lower.hasPrefix("use this for") else { continue }
            // Just the first sentence: these lines often run on into sources.
            let sentence = l.split(separator: ".", maxSplits: 1,
                                   omittingEmptySubsequences: false).first.map(String.init) ?? l
            return tidy(sentence)
        }
        return nil
    }

    /// Reads one `key: value` out of a front-matter block.
    private static func frontMatterValue(_ key: String, in text: String) -> String? {
        guard text.hasPrefix("---") else { return nil }
        for line in text.components(separatedBy: .newlines).dropFirst() {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l == "---" { break }
            if let value = value(of: key, in: l) { return value }
        }
        return nil
    }

    /// Trims a summary to something that fits a card without a wall of text.
    private static func tidy(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Front-matter values are often quoted, and markdown emphasis is noise
        // once the line is rendered as plain text.
        if (text.hasPrefix("'") && text.hasSuffix("'")) ||
           (text.hasPrefix("\"") && text.hasSuffix("\"")), text.count > 1 {
            text = String(text.dropFirst().dropLast())
        }
        text = text.replacingOccurrences(of: "**", with: "")
                   .replacingOccurrences(of: "`", with: "")
                   .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                   .trimmingCharacters(in: .whitespaces)

        let limit = 240
        if text.count > limit {
            // Cut at a sentence if there is one nearby, so it does not stop mid-clause.
            let head = String(text.prefix(limit))
            if let stop = head.lastIndex(of: "."), head.distance(from: head.startIndex, to: stop) > 90 {
                return String(head[...stop])
            }
            return head.trimmingCharacters(in: .whitespaces) + "\u{2026}"
        }
        return text
    }

    /// `---\nname: x\ndescription: y\n---` — the Claude/Anthropic skill shape.
    private static func frontMatterTitle(_ text: String) -> String? {
        guard text.hasPrefix("---") else { return nil }
        let lines = text.components(separatedBy: .newlines)
        guard lines.count > 2 else { return nil }

        var name: String?
        var hasDescription = false
        for line in lines.dropFirst() {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l == "---" { break }
            if let value = value(of: "name", in: l) { name = value }
            if value(of: "description", in: l) != nil { hasDescription = true }
        }
        // Both keys are required; front matter alone is just YAML.
        guard let name, hasDescription else { return nil }
        return name
    }

    /// `# Skill: X`, or a heading followed by name/description lines.
    private static func markerTitle(_ text: String) -> String? {
        let lines = text.components(separatedBy: .newlines).prefix(8).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let first = lines.first else { return nil }

        for prefix in ["# skill:", "## skill:", "skill:"] where first.lowercased().hasPrefix(prefix) {
            let title = String(first.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? "Skill" : title
        }

        // A markdown heading plus explicit name/description keys underneath.
        guard first.hasPrefix("#") else { return nil }
        let rest = lines.dropFirst()
        let hasName = rest.contains { value(of: "name", in: $0) != nil }
        let hasDescription = rest.contains { value(of: "description", in: $0) != nil }
        guard hasName, hasDescription else { return nil }
        return String(first.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
    }

    /// Parses `key: value`, tolerating quotes and a leading list dash.
    private static func value(of key: String, in line: String) -> String? {
        var l = line
        if l.hasPrefix("- ") { l = String(l.dropFirst(2)) }
        let lower = l.lowercased()
        guard lower.hasPrefix(key + ":") else { return nil }
        var v = String(l.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count > 1 { v = String(v.dropFirst().dropLast()) }
        return v.isEmpty ? nil : v
    }
}
