import Foundation

/// Imports a folder of design documents into the library, once.
///
/// A folder of DESIGN.md files - one per brand, the folder named for the brand -
/// is the shape the corpus ships in, so that is the shape this reads. It is a
/// one-shot import rather than a watched folder: nothing here needs to keep
/// tracking a directory on someone's Desktop after the documents are in.
@MainActor
enum DesignLibraryImport {

    struct Result {
        var imported: Int = 0
        /// Already in the library, by content. A second run should be all skips.
        var skipped: Int = 0
        /// Files that looked like design documents by name but failed detection.
        var rejected: [String] = []

        var summary: String {
            var parts = ["\(imported) imported"]
            if skipped > 0 { parts.append("\(skipped) already there") }
            if !rejected.isEmpty { parts.append("\(rejected.count) not recognized") }
            return parts.joined(separator: ", ")
        }
    }

    /// Every `DESIGN.md` one level down, which is how the corpus is laid out.
    ///
    /// `README.md` siblings sit beside all 74 of them and are not design
    /// documents; they are skipped by name before detection ever sees them.
    static func documents(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])
        else { return [] }

        var found: [URL] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let candidate = entry.appendingPathComponent("DESIGN.md")
                if fm.fileExists(atPath: candidate.path) { found.append(candidate) }
            } else if entry.lastPathComponent.caseInsensitiveCompare("DESIGN.md") == .orderedSame {
                found.append(entry)
            }
        }
        return found
    }

    /// Why nothing was imported, when nothing was - three different causes
    /// `run(folder:store:)` alone cannot tell apart, because they all end in
    /// the identical "0 imported, 0 skipped". Before this every one of them
    /// was reported as "No design documents found in that folder", which is
    /// simply false for a folder Clip could not even open, or one that held
    /// files that looked like candidates but were rejected by the detector.
    enum ScanProblem {
        /// `contentsOfDirectory` itself failed - gone, or unreadable.
        case unreadable
        /// Readable, and genuinely has nothing in it.
        case empty
        /// Has entries, but none of them are a `DESIGN.md` this scan found.
        case noCandidates
    }

    /// `nil` means `documents(in:)` found at least one candidate; the folder
    /// itself is not the reason nothing came in.
    static func scanProblem(_ folder: URL) -> ScanProblem? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])
        else { return .unreadable }
        if entries.isEmpty { return .empty }
        return documents(in: folder).isEmpty ? .noCandidates : nil
    }

    /// Reads every document in `folder` into the design role.
    ///
    /// The title comes from the **containing folder** - "linear.app", "airbnb" -
    /// not the front-matter `name:` ("Linear-design-analysis"). The folder name
    /// is the brand, and the brand is what you scan a library for.
    @discardableResult
    static func run(folder: URL, store: HistoryStore) -> Result {
        var result = Result()
        let existing = Set(store.items.map(\.fullText))

        for url in documents(in: folder) {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  !text.isEmpty else { continue }

            guard DesignDocDetector.detect(text) != nil else {
                result.rejected.append(url.deletingLastPathComponent().lastPathComponent)
                continue
            }

            // Deduplicated on content, so a second run is a no-op rather than a
            // second copy of the library.
            guard !existing.contains(text) else { result.skipped += 1; continue }

            let brand = url.deletingLastPathComponent().lastPathComponent
            let item = ClipboardItem(kind: .text, text: text,
                                     sourceAppName: "Design library",
                                     title: brand, role: .design)
            store.addExisting(item)
            result.imported += 1
        }

        // A library with documents in it should be visible. Nothing else about
        // the user's tab arrangement is touched.
        if result.imported > 0 {
            TabConfiguration.shared.setVisible(ItemCategory.role(.design).id, true)
        }
        return result
    }
}
