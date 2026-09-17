import Foundation

/// Reading and writing the YAML header at the top of a document.
///
/// `documentDescription` reads a description out of a document; the suggestion
/// bar has to be able to put one back. Doing that by string surgery at the call
/// site is how a document ends up with two `description:` keys, or with one
/// outside its own front matter, so it lives here with the rules written down.
enum FrontMatter {

    /// True when the text opens with a `---` fenced block.
    static func has(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("---")
    }

    /// Sets `key` in the document's front matter, creating the block if needed.
    ///
    /// Rules, in order of how badly getting them wrong reads:
    /// - An existing key is replaced in place, keeping its position and the
    ///   indentation of its neighbours.
    /// - A new key goes at the end of the block, not the start, so it does not
    ///   displace `name` or `version` from the top where people look for them.
    /// - A document with no front matter gets one, above everything.
    /// - The value is quoted, because a description containing a colon is the
    ///   normal case and unquoted YAML would break on it.
    static func setting(_ key: String, to value: String, in text: String) -> String {
        let quoted = "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces) + "\""
        let line = "\(key): \(quoted)"

        var lines = text.components(separatedBy: "\n")
        guard let openIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
              openIndex <= 2,
              let closeOffset = lines.dropFirst(openIndex + 1)
                  .firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else {
            return "---\n\(line)\n---\n\n" + text
        }

        let body = (openIndex + 1)..<closeOffset
        // Only a top-level key counts. A `description:` nested under `colors:`
        // is a different thing entirely and must not be overwritten.
        if let existing = body.first(where: { index in
            let raw = lines[index]
            guard !raw.hasPrefix(" "), !raw.hasPrefix("\t") else { return false }
            return raw.trimmingCharacters(in: .whitespaces)
                .lowercased().hasPrefix("\(key.lowercased()):")
        }) {
            lines[existing] = line
        } else {
            lines.insert(line, at: closeOffset)
        }
        return lines.joined(separator: "\n")
    }
}
