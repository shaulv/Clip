import Foundation

/// Recognises a design document - a DESIGN.md - from what it contains.
///
/// This has to be more specific than `SkillDetector`, not merely different. A
/// DESIGN.md opens with front matter carrying `name:` and `description:`, which
/// is exactly the skill signature: measured over a 74-document corpus, the skill
/// detector claimed 64 of them. So the design detector runs **first** at every
/// call site, and demands evidence a skill would not carry.
///
/// Two dialects exist in the wild and both must pass, or a tenth of the corpus
/// is silently misfiled:
///
/// - **Front-matter dialect** (64 of 74): a YAML block with a `colors:` mapping
///   or `version: alpha`, followed by `## Colors`, `## Typography` and friends.
/// - **Numbered dialect** (10 of 74): no front matter at all, a
///   `# Design System …` heading, and numbered sections - `## 2. Color Palette
///   & Roles`, `## 3. Typography Rules`.
///
/// Either way the rule is the same: **two independent signals**. A stray
/// `## Colors` in an ordinary note is not a design system, and never classifies
/// as one.
enum DesignDocDetector {

    /// The sections every document in the corpus carries, in both dialects.
    ///
    /// Matched on the leading words after any number, so `## 2. Color Palette &
    /// Roles` and `## Colors` are the same section.
    /// Both spellings survive here, like the front-matter parser: these match
    /// section headings in documents other people wrote, and their spelling is
    /// not ours to standardise. A blanket rename to "color" briefly reduced
    /// this to the same word twice.
    private static let sections: [[String]] = [
        ["color", "colour"],
        ["typography", "type"],
        ["layout"],
        ["component"],
        ["overview", "visual theme"],
        ["elevation", "depth"],
        ["shape"],
        ["do's and don'ts", "dos and don'ts"],
        ["responsive"]
    ]

    /// How many of the canonical sections a document must carry.
    ///
    /// Three, not one: one heading is a coincidence, three together is a design
    /// system. Every document in the corpus carries at least five.
    private static let requiredSections = 3

    /// Returns the document's name when the text is a design document, else nil.
    static func detect(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Shorter than this and there is no room for the evidence required.
        guard trimmed.count > 200 else { return nil }

        let head = String(trimmed.prefix(20_000))
        guard sectionCount(head) >= requiredSections else { return nil }

        if let matter = frontMatter(trimmed) {
            // Front-matter dialect: the block must be a design token block, not
            // a skill header that happens to sit above design-ish prose.
            guard matter.contains("\ncolors:") || matter.hasPrefix("colors:")
                    || matter.contains("\ncolours:") || matter.hasPrefix("colours:")
                    || matter.contains("version: alpha")
                    || matter.contains("\ntypography:") else { return nil }
            return value("name", in: matter).map(tidyName) ?? headingTitle(trimmed)
        }

        // Numbered dialect: no front matter, so the heading carries the claim.
        guard let heading = headingTitle(trimmed) else { return nil }
        let lowered = heading.lowercased()
        guard lowered.contains("design system") || lowered.contains("design language")
                || lowered.contains("design guide") else { return nil }
        return tidyHeading(heading)
    }

    /// What the document is about, in one line, for the card.
    static func describe(_ text: String) -> String? {
        // The front matter is read from the WHOLE document: these run to
        // thousands of words and the block can close well past any window, at
        // which point the fallback below happily returned the raw
        // `description: "…"` line, key and all.
        if let matter = frontMatter(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           let d = value("description", in: matter) {
            return tidy(d)
        }
        let head = String(text.prefix(6000))
        // The numbered dialect has no front matter: the first real paragraph of
        // the opening section is the summary, the same way a skill falls back.
        var inFence = false
        for line in head.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("```") { inFence.toggle(); continue }
            guard !inFence, !l.isEmpty, !l.hasPrefix("#"), !l.hasPrefix(">"),
                  !l.hasPrefix("-"), !l.hasPrefix("*"), !l.hasPrefix("|"),
                  !l.hasPrefix("---"), l.count > 40 else { continue }
            return tidy(l)
        }
        return nil
    }

    /// True when this text should be filed as a design document.
    static func isDesignDoc(_ text: String) -> Bool { detect(text) != nil }

    // MARK: - Reading the document

    /// How many canonical sections appear as `##`-level headings.
    private static func sectionCount(_ text: String) -> Int {
        var seen = Set<Int>()
        for line in text.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("##") else { continue }
            // Strip the hashes, then any leading "2." style numbering.
            var title = l.drop(while: { $0 == "#" })
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            if let dot = title.firstIndex(of: "."),
               title[title.startIndex..<dot].allSatisfy(\.isNumber) {
                title = String(title[title.index(after: dot)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            for (i, names) in sections.enumerated() where names.contains(where: title.hasPrefix) {
                seen.insert(i)
            }
        }
        return seen.count
    }

    /// The YAML front-matter block, when the document opens with one.
    private static func frontMatter(_ text: String) -> String? {
        guard text.hasPrefix("---") else { return nil }
        let body = text.dropFirst(3)
        guard let end = body.range(of: "\n---") else { return nil }
        return String(body[body.startIndex..<end.lowerBound])
    }

    /// A `key: value` from the front matter, quotes removed.
    private static func value(_ key: String, in matter: String) -> String? {
        for line in matter.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix(key + ":") else { continue }
            let v = l.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            let unquoted = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return unquoted.isEmpty ? nil : unquoted
        }
        return nil
    }

    /// The first `#` heading, which the numbered dialect uses as its title.
    private static func headingTitle(_ text: String) -> String? {
        for line in text.prefix(4000).components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("# ") else { continue }
            let t = l.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : String(t)
        }
        return nil
    }

    /// "Design System Inspired by The Verge" is a sentence about the document.
    /// The card wants the brand, which is the half after the preamble.
    private static func tidyHeading(_ raw: String) -> String {
        let lowered = raw.lowercased()
        for lead in ["design system inspired by ", "design language of ",
                     "design system of ", "design guide for ", "design system: ",
                     "design language: "] where lowered.hasPrefix(lead) {
            let brand = String(raw.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
            if !brand.isEmpty { return brand }
        }
        return raw
    }

    /// Front-matter names read like slugs - "Linear-design-analysis". The card
    /// wants the brand, not the filename someone gave the analysis.
    private static func tidyName(_ raw: String) -> String {
        var s = raw
        for suffix in ["-design-analysis", "-design-system", "-design", "-analysis"] {
            if s.lowercased().hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
        }
        s = s.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return s.trimmingCharacters(in: .whitespaces).isEmpty ? raw : s
    }

    private static func tidy(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return s.count > 240 ? String(s.prefix(237)) + "…" : s
    }
}
