import Foundation

/// Reads a batch reply keyed by item number, in whatever shape it arrives.
///
/// The original parser accepted exactly one shape - a flat JSON object of
/// string to string - and threw "The reply was not a list of titles." for
/// anything else. That is a fair description of what happened and no help at
/// all, because the reply usually *was* a list of titles; it was wrapped, or
/// numbered as integers, or in an array, or cut off at the token limit with
/// forty perfectly good titles in it.
///
/// A model is not a function. Asking for JSON makes a particular shape likely,
/// not certain, and it varies by provider and by model - the same prompt to
/// Ollama and to Claude does not come back identical. Refusing everything but
/// one shape turns a working answer into an error the user cannot act on.
///
/// So this accepts what models actually send, and keeps whatever it can
/// understand. Recovering forty titles out of fifty is worth far more than
/// refusing all fifty because the last one was truncated.
@MainActor
enum KeyedReply {

    /// Item number (as a string) to its value. Empty when nothing was readable.
    static func parse(_ raw: String) -> [String: String] {
        let json = AIService.extractJSON(from: raw)

        // The array is tried against the RAW reply, not the extracted object.
        // `extractJSON` hunts for the first `{` and its matching `}`, so given
        // `[{"number":1,...},{"number":2,...}]` it returns only the first
        // element and the rest of the answer is thrown away before anything
        // gets to look at it.
        if let list = jsonArray(raw) {
            let flat = fromArray(list)
            if !flat.isEmpty { return flat }
        }

        if let object = jsonObject(json) {
            if let flat = flatten(object), !flat.isEmpty { return flat }
            // `{"titles": {...}}`, `{"result": [...]}` - a wrapper around the
            // answer. Take the first value that reads as one.
            for value in object.values {
                if let nested = value as? [String: Any],
                   let flat = flatten(nested), !flat.isEmpty { return flat }
                if let list = value as? [Any] {
                    let flat = fromArray(list)
                    if !flat.isEmpty { return flat }
                }
            }
        }

        if let list = jsonArray(json) {
            let flat = fromArray(list)
            if !flat.isEmpty { return flat }
        }

        // Truncated JSON: the token limit cut the reply mid-object, so it will
        // never parse, but every complete pair before the cut is still good.
        let recovered = recoverPairs(from: json)
        if !recovered.isEmpty { return recovered }

        // Not JSON at all: a numbered list, which is what a model falls back to
        // when it ignores the format instruction.
        return fromNumberedLines(raw)
    }

    // MARK: - Shapes

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func jsonArray(_ text: String) -> [Any]? {
        // `extractJSON` looks for a brace, so an array reply arrives unchanged.
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]"), start < end,
              let data = String(text[start...end]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [Any]
    }

    /// A flat object, with values coerced. A number where a string was asked
    /// for is still an answer.
    private static func flatten(_ object: [String: Any]) -> [String: String]? {
        var out: [String: String] = [:]
        for (key, value) in object {
            let number = key.trimmingCharacters(in: CharacterSet(charactersIn: "#. "))
            guard Int(number) != nil else { continue }
            if let text = scalar(value) { out[number] = text }
        }
        return out.isEmpty ? nil : out
    }

    /// `["first","second"]`, or `[{"number":1,"title":"first"}]`.
    private static func fromArray(_ list: [Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (index, element) in list.enumerated() {
            if let text = scalar(element) {
                out["\(index + 1)"] = text
            } else if let object = element as? [String: Any] {
                // A key that is a number, or a number field beside a value.
                if let flat = flatten(object) {
                    out.merge(flat) { current, _ in current }
                } else if let n = (object["number"] ?? object["id"] ?? object["index"]),
                          let key = scalar(n),
                          let value = object.first(where: { $0.key != "number" && $0.key != "id"
                                                            && $0.key != "index" })?.value,
                          let text = scalar(value) {
                    out[key] = text
                }
            }
        }
        return out
    }

    private static func scalar(_ value: Any) -> String? {
        switch value {
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    /// Every complete `"key": "value"` pair, whatever surrounds them.
    ///
    /// This is what rescues a reply the token limit cut in half.
    private static func recoverPairs(from text: String) -> [String: String] {
        guard let pattern = try? NSRegularExpression(
            pattern: "\"\\s*(\\d+)\\s*\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"")
        else { return [:] }
        var out: [String: String] = [:]
        let range = NSRange(text.startIndex..., in: text)
        pattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let k = Range(match.range(at: 1), in: text),
                  let v = Range(match.range(at: 2), in: text) else { return }
            let value = String(text[v])
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { out[String(text[k])] = value }
        }
        return out
    }

    /// `1. A title` / `1) A title` / `1 - A title`, one per line.
    private static func fromNumberedLines(_ text: String) -> [String: String] {
        guard let pattern = try? NSRegularExpression(
            pattern: "^\\s*(\\d+)\\s*[.):-]\\s*(.+)$", options: [.anchorsMatchLines])
        else { return [:] }
        var out: [String: String] = [:]
        let range = NSRange(text.startIndex..., in: text)
        pattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let k = Range(match.range(at: 1), in: text),
                  let v = Range(match.range(at: 2), in: text) else { return }
            let value = String(text[v])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            if !value.isEmpty { out[String(text[k])] = value }
        }
        return out
    }
}
