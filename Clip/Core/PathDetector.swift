import Foundation

/// Recognises filesystem paths that arrive as **plain text**.
///
/// Copying a file in Finder puts real file URLs on the pasteboard, which
/// `ClipboardMonitor.readFile` already types correctly. Copying a *path* — from
/// a terminal, from Finder's "Copy as Pathname", from a chat message, out of a
/// log — puts a string there instead, and that string used to be filed as text
/// or, worse, guessed at as code. A path is a path however it was copied.
enum PathDetector {

    struct Match {
        let kind: ItemKind          // .folder or .file
        let paths: [String]
    }

    /// Returns folder/file paths when the text is nothing but paths, else nil.
    ///
    /// Every line must be a path. One path buried in a sentence is not a copied
    /// path, it is a sentence — reclassifying that would make prose disappear
    /// from the Text tab, which is a worse bug than the one being fixed.
    static func classify(_ text: String) -> Match? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // A hundred-line file listing is a document about paths, not a path.
        guard (1...32).contains(lines.count) else { return nil }

        var paths: [String] = []
        var directories = 0
        for line in lines {
            guard let (path, isDirectory) = evaluate(line) else { return nil }
            paths.append(path)
            if isDirectory { directories += 1 }
        }

        // Mixed selections paste as files, which is how a multi-item drag from
        // Finder already behaves.
        return Match(kind: directories == paths.count ? .folder : .file, paths: paths)
    }

    // MARK: - One line

    /// Normalises one line and decides whether it is a path, and whether it
    /// points at a directory.
    private static func evaluate(_ raw: String) -> (path: String, isDirectory: Bool)? {
        guard let path = normalise(raw) else { return nil }

        // The root on its own carries no intent: nobody copies "/" meaning a
        // folder, and it exists on every Mac, so existence cannot rescue it.
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return nil }

        // On disk is the only answer that cannot be argued with.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            return (path, isDirectory.boolValue)
        }

        // Otherwise the path is from another Mac, a backup, or a colleague. It
        // is still a path, so read its shape.
        //
        // A space is where this gets dangerous: "/Users/me/Drive is the folder"
        // opens like a path and ends like a sentence. A path that exists can
        // contain spaces freely; a path that has to be recognised by shape
        // alone may not.
        guard !path.contains(" ") else { return nil }
        guard components.count >= 2 else { return nil }

        if raw.hasSuffix("/") { return (path, true) }

        let last = String(components[components.count - 1])
        return (path, !hasFileExtension(last))
    }

    /// Turns a written path into an absolute one, or nil if it is not a path.
    private static func normalise(_ raw: String) -> String? {
        var s = raw

        // Shells and copied commands quote paths that contain spaces.
        for quote in ["\"", "'"] where s.hasPrefix(quote) && s.hasSuffix(quote) && s.count > 1 {
            s = String(s.dropFirst().dropLast())
        }
        s = s.replacingOccurrences(of: "\\ ", with: " ")

        // `file://` never reached the link reader, which only takes http(s).
        if s.lowercased().hasPrefix("file://") {
            guard let url = URL(string: s), url.isFileURL else { return nil }
            return url.path
        }
        // Any other scheme is a link, and links are handled elsewhere.
        guard !s.contains("://") else { return nil }

        if s == "~" || s.hasPrefix("~/") {
            s = NSString(string: s).expandingTildeInPath
        }
        guard s.hasPrefix("/") else { return nil }

        // A trailing slash is meaningful to the caller, but not to the path.
        while s.count > 1 && s.hasSuffix("/") { s = String(s.dropLast()) }

        // Characters no macOS path contains, which cheaply rules out prose,
        // shell fragments and code.
        let forbidden = CharacterSet(charactersIn: "\t\u{0}*?<>|\"")
        guard s.rangeOfCharacter(from: forbidden) == nil else { return nil }
        return s
    }

    /// A real extension: short, alphanumeric, and not the tail of a version
    /// number — `/opt/homebrew/3.11` is a directory, `/etc/hosts.bak` is a file.
    private static func hasFileExtension(_ component: String) -> Bool {
        guard let dot = component.lastIndex(of: "."), dot != component.startIndex else { return false }
        let ext = component[component.index(after: dot)...]
        guard (1...8).contains(ext.count) else { return false }
        guard ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        // "1.2" and "v2.11" are versions; an extension has at least one letter.
        return ext.contains { $0.isLetter }
    }
}
