import Foundation
import AppKit

/// Placeholders in a saved prompt, filled in at the moment you use it.
///
/// A prompt library is only reusable if the parts that change are allowed to
/// change. Without this, a prompt with a client name baked into it gets copied,
/// edited by hand and saved again as a near-duplicate - which is how a library
/// of twelve prompts becomes forty of the same one.
///
/// No model involved: finding `{{name}}` is a regex and filling it is string
/// substitution. Values are remembered per variable name, so the second use of
/// a prompt is usually just Return.
enum PromptVariables {

    /// The variable names in a text, in the order they first appear.
    ///
    /// Order matters because it is the order the fill-in sheet asks in, and a
    /// form that asks in a different order than the text reads is a form people
    /// fill in wrongly.
    static func names(in text: String) -> [String] {
        guard let pattern = try? NSRegularExpression(pattern: "\\{\\{\\s*([^}\\n]{1,60}?)\\s*\\}\\}")
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var out: [String] = []
        pattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: text) else { return }
            let name = String(text[r]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !out.contains(name) { out.append(name) }
        }
        return out
    }

    static func hasVariables(_ text: String) -> Bool { !names(in: text).isEmpty }

    /// Substitutes every occurrence, leaving unfilled ones as they are.
    ///
    /// An unfilled placeholder stays visible rather than becoming an empty gap:
    /// a prompt with a hole you can see is fixable, one with a silent hole is
    /// pasted into a chat before anyone notices.
    static func filled(_ text: String, with values: [String: String]) -> String {
        var out = text
        for name in names(in: text) {
            guard let value = values[name], !value.isEmpty else { continue }
            for form in ["{{\(name)}}", "{{ \(name) }}"] {
                out = out.replacingOccurrences(of: form, with: value)
            }
            // Any spacing the two exact forms missed.
            if let pattern = try? NSRegularExpression(
                pattern: "\\{\\{\\s*\(NSRegularExpression.escapedPattern(for: name))\\s*\\}\\}") {
                out = pattern.stringByReplacingMatches(
                    in: out, range: NSRange(out.startIndex..., in: out),
                    withTemplate: NSRegularExpression.escapedTemplate(for: value))
            }
        }
        return out
    }

    // MARK: - Remembered values

    private static let key = "promptVariableValues"

    /// What was typed last time, so the common case is one keystroke.
    static var remembered: [String: String] {
        get { AppPaths.defaults.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { AppPaths.defaults.set(newValue, forKey: key) }
    }

    static func remember(_ values: [String: String]) {
        var all = remembered
        for (name, value) in values where !value.isEmpty { all[name] = value }
        remembered = all
    }
}
