import SwiftUI

/// A line diff, computed here rather than asked for.
///
/// The point of showing a diff before applying an AI change is trust, and a
/// diff the model wrote is not evidence - it is another thing the model said.
/// This one is arithmetic over the two strings, so what you see is what will be
/// written, whatever the model claimed it did.
enum TextDiff {

    enum Kind { case same, added, removed }

    struct Line: Identifiable {
        let id = UUID()
        let kind: Kind
        let text: String
        /// Line number in the original, where there is one.
        let before: Int?
        /// Line number in the result, where there is one.
        let after: Int?
    }

    struct Summary {
        var added = 0
        var removed = 0
        var isEmpty: Bool { added == 0 && removed == 0 }

        var sentence: String {
            if isEmpty { return "No changes" }
            var parts: [String] = []
            if added > 0 { parts.append("\(added) line\(added == 1 ? "" : "s") added") }
            if removed > 0 { parts.append("\(removed) line\(removed == 1 ? "" : "s") removed") }
            return parts.joined(separator: ", ")
        }
    }

    /// Longest-common-subsequence diff over lines.
    ///
    /// Bounded deliberately: the table is O(n·m), and two 5000-line documents
    /// would allocate 25 million cells to render a preview nobody reads to the
    /// end. Past the bound it falls back to "everything replaced", which is
    /// honest and cheap - and at that size it is also true in spirit.
    static func lines(from before: String, to after: String,
                      limit: Int = 1200) -> [Line] {
        let a = before.components(separatedBy: .newlines)
        let b = after.components(separatedBy: .newlines)

        guard a.count <= limit, b.count <= limit else {
            var out: [Line] = a.enumerated().map { Line(kind: .removed, text: $0.element,
                                                        before: $0.offset + 1, after: nil) }
            out += b.enumerated().map { Line(kind: .added, text: $0.element,
                                             before: nil, after: $0.offset + 1) }
            return out
        }

        // table[i][j] = length of the LCS of a[i...] and b[j...]
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1),
                          count: a.count + 1)
        if !a.isEmpty && !b.isEmpty {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    table[i][j] = a[i] == b[j]
                        ? table[i + 1][j + 1] + 1
                        : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        var out: [Line] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                out.append(Line(kind: .same, text: a[i], before: i + 1, after: j + 1))
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                out.append(Line(kind: .removed, text: a[i], before: i + 1, after: nil))
                i += 1
            } else {
                out.append(Line(kind: .added, text: b[j], before: nil, after: j + 1))
                j += 1
            }
        }
        while i < a.count { out.append(Line(kind: .removed, text: a[i], before: i + 1, after: nil)); i += 1 }
        while j < b.count { out.append(Line(kind: .added, text: b[j], before: nil, after: j + 1)); j += 1 }
        return out
    }

    static func summary(from before: String, to after: String) -> Summary {
        var s = Summary()
        for line in lines(from: before, to: after) {
            switch line.kind {
            case .added:   s.added += 1
            case .removed: s.removed += 1
            case .same:    break
            }
        }
        return s
    }
}


/// The diff, drawn the way an editor draws uncommitted changes.
///
/// Gutter line numbers, a `+`/`-` marker, a tinted row, and unchanged context
/// collapsed to a few lines either side so a one-word fix in a long document is
/// findable. Monospaced throughout: this is the view where alignment carries
/// meaning.
struct DiffView: View {
    let before: String
    let after: String
    let theme: AppTheme
    /// Unchanged lines kept either side of a change.
    var context: Int = 3

    private var lines: [TextDiff.Line] { TextDiff.lines(from: before, to: after) }

    /// Only the interesting neighbourhoods, with a marker where a run is hidden.
    private var shown: [Row] {
        let all = lines
        let changed = Set(all.indices.filter { all[$0].kind != .same })
        guard !changed.isEmpty else {
            return all.prefix(20).map { Row.line($0) }
        }
        var keep = Set<Int>()
        for index in changed {
            for offset in -context...context where all.indices.contains(index + offset) {
                keep.insert(index + offset)
            }
        }
        var out: [Row] = []
        var skipped = 0
        for index in all.indices {
            if keep.contains(index) {
                if skipped > 0 { out.append(.gap(skipped)); skipped = 0 }
                out.append(.line(all[index]))
            } else {
                skipped += 1
            }
        }
        if skipped > 0 { out.append(.gap(skipped)) }
        return out
    }

    enum Row: Identifiable {
        case line(TextDiff.Line)
        case gap(Int)

        var id: String {
            switch self {
            case .line(let l): return l.id.uuidString
            case .gap(let n):  return "gap-\(n)-\(UUID().uuidString)"
            }
        }
    }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { row in
                    switch row {
                    case .gap(let n):
                        Text("⋯ \(n) unchanged line\(n == 1 ? "" : "s")")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3).padding(.horizontal, 10)
                            .background(theme.surfaceBackground.opacity(0.5))
                    case .line(let line):
                        lineRow(line)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.surfaceBackground,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(theme.border, lineWidth: 1))
    }

    private func lineRow(_ line: TextDiff.Line) -> some View {
        HStack(alignment: .top, spacing: 0) {
            gutter(line.before)
            gutter(line.after)
            Text(marker(line.kind))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(color(line.kind) ?? theme.textTertiary)
                .frame(width: 16)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(line.kind == .same ? theme.textSecondary : theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
        .padding(.trailing, 10)
        .background(background(line.kind))
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? " ")
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(theme.textTertiary)
            .frame(width: 34, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private func marker(_ kind: TextDiff.Kind) -> String {
        switch kind {
        case .added:   return "+"
        case .removed: return "-"
        case .same:    return " "
        }
    }

    private func color(_ kind: TextDiff.Kind) -> Color? {
        switch kind {
        case .added:   return theme.success
        case .removed: return theme.destructive
        case .same:    return nil
        }
    }

    @ViewBuilder
    private func background(_ kind: TextDiff.Kind) -> some View {
        switch kind {
        case .added:   theme.success.opacity(0.12)
        case .removed: theme.destructive.opacity(0.12)
        case .same:    Color.clear
        }
    }
}
