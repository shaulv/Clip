import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Languages Clip can label, indent and save a file for.
///
/// The extension is the point: "download this snippet" is only useful if the
/// file lands as `.swift` or `.py` rather than a generic `.txt`.
struct CodeLanguage: Identifiable, Hashable {
    let id: String
    let title: String
    let ext: String
    let comment: String

    static let all: [CodeLanguage] = [
        .init(id: "swift", title: "Swift", ext: "swift", comment: "//"),
        .init(id: "javascript", title: "JavaScript", ext: "js", comment: "//"),
        .init(id: "typescript", title: "TypeScript", ext: "ts", comment: "//"),
        .init(id: "python", title: "Python", ext: "py", comment: "#"),
        .init(id: "ruby", title: "Ruby", ext: "rb", comment: "#"),
        .init(id: "go", title: "Go", ext: "go", comment: "//"),
        .init(id: "rust", title: "Rust", ext: "rs", comment: "//"),
        .init(id: "java", title: "Java", ext: "java", comment: "//"),
        .init(id: "kotlin", title: "Kotlin", ext: "kt", comment: "//"),
        .init(id: "c", title: "C", ext: "c", comment: "//"),
        .init(id: "cpp", title: "C++", ext: "cpp", comment: "//"),
        .init(id: "csharp", title: "C#", ext: "cs", comment: "//"),
        .init(id: "php", title: "PHP", ext: "php", comment: "//"),
        .init(id: "html", title: "HTML", ext: "html", comment: "<!--"),
        .init(id: "css", title: "CSS", ext: "css", comment: "/*"),
        .init(id: "json", title: "JSON", ext: "json", comment: ""),
        .init(id: "yaml", title: "YAML", ext: "yml", comment: "#"),
        .init(id: "sql", title: "SQL", ext: "sql", comment: "--"),
        .init(id: "shell", title: "Shell", ext: "sh", comment: "#"),
        .init(id: "markdown", title: "Markdown", ext: "md", comment: ""),
        .init(id: "xml", title: "XML", ext: "xml", comment: "<!--"),
        .init(id: "code", title: "Plain", ext: "txt", comment: "#")
    ]

    static func named(_ id: String?) -> CodeLanguage {
        all.first { $0.id == (id ?? "").lowercased() } ?? all.last!
    }
}

/// Per-type actions shown in the editor, below the shared fields.
///
/// The shared parts — name, tags, shortcut, versions, pin, role — stay identical
/// for every item so the editor is learnable. What changes is the row of actions
/// that only make sense for one type: you cannot indent a color, and converting
/// a code snippet to HSL would be nonsense.
struct TypeActions: View {
    let item: ClipboardItem
    @Binding var draft: String

    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager
    @State private var note: String?

    private var t: AppTheme { theme.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: item.kind.symbol).foregroundStyle(t.tint(for: item.kind))
                Text("\(item.kind.displayName) actions")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(t.textTertiary)
                Spacer()
            }

            content

            if let note {
                Text(note).font(.system(size: 10)).foregroundStyle(t.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        // A design document's actions come from its ROLE, not its kind: it is
        // stored as text, and text actions are not what you want from a palette.
        if item.role == .design {
            DesignActions(item: item, note: $note)
        } else {
            kindActions
        }
    }

    @ViewBuilder
    private var kindActions: some View {
        switch item.kind {
        case .code:                 CodeActions(item: item, draft: $draft, note: $note)
        case .text, .richText:      TextActions(draft: $draft, note: $note)
        case .url:                  LinkActions(item: item, note: $note)
        case .color:                ColorActions(item: item, note: $note)
        case .emoji:                EmojiActions(item: item, note: $note)
        case .image, .video:        MediaActions(item: item, note: $note)
        case .file, .folder:        FileActions(item: item, note: $note)
        case .colorData:            EmptyView()
        }
    }
}

// MARK: - Design documents

/// What you can do with a design system, none of it needing a model.
struct DesignActions: View {
    let item: ClipboardItem
    @Binding var note: String?

    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager

    private var colors: [String] {
        Array(DesignDocTheme.colorBlock(in: item.fullText).values).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !colors.isEmpty {
                // The palette, before you commit to anything.
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 4), count: 12),
                          spacing: 4) {
                    ForEach(colors.prefix(24), id: \.self) { hex in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(nsColor: NSColor(hex: hex) ?? .gray))
                            .frame(height: 20)
                            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(theme.theme.border, lineWidth: 1))
                            .help(hex)
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Make a Theme") { makeTheme() }
                Button("Copy Palette") {
                    let pb = TestIsolation.board
                    pb.clearContents()
                    pb.setString(colors.joined(separator: "\n"), forType: .string)
                    note = "\(colors.count) color\(colors.count == 1 ? "" : "s") copied"
                }
                .disabled(colors.isEmpty)
                Spacer()
            }
        }
    }

    /// Builds, repairs, saves and switches to it - and says plainly when the
    /// palette could not be made readable, rather than quietly shipping a theme
    /// that fails its own audit.
    private func makeTheme() {
        guard let draft = DesignDocTheme.theme(from: item.fullText, named: item.displayTitle) else {
            note = "This document doesn't have a color palette in it."
            return
        }
        let repaired = ThemeDoctor.repaired(draft)
        let report = ThemeRules.audit(repaired.appTheme)
        CustomThemeStore.shared.save(repaired)
        theme.themeID = "custom:\(repaired.id)"
        note = report.passes
            ? "Made “\(repaired.name)” and switched to it."
            : "Made “\(repaired.name)”, but \(report.failures.count) color pairing"
              + "\(report.failures.count == 1 ? "" : "s") couldn't be made readable. "
              + "This palette was built for a page, not a dense list."
    }
}

// MARK: - Code

struct CodeActions: View {
    let item: ClipboardItem
    @Binding var draft: String
    @Binding var note: String?

    @EnvironmentObject var store: HistoryStore
    @State private var language: CodeLanguage = .named(nil)
    @State private var wrap = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Language", selection: $language) {
                    ForEach(CodeLanguage.all) { Text($0.title).tag($0) }
                }
                .frame(width: 200)
                .onChange(of: language) { _, new in
                    store.update(item.id) { $0.language = new.id }
                }

                Text("\(draft.components(separatedBy: .newlines).count) lines")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 8) {
                Button("Save as .\(language.ext)…") { download() }
                Button("Copy as Markdown") { copyFenced() }
                Button("Re-indent") { reindent() }
                Button("Strip Comments") { stripComments() }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .onAppear { language = .named(item.language) }
    }

    /// Writes the snippet to a real file with the language's own extension.
    private func download() {
        let panel = NSSavePanel()
        let base = (item.title?.isEmpty == false ? item.title! : "snippet")
            .replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(base).\(language.ext)"
        if let type = UTType(filenameExtension: language.ext) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try draft.write(to: url, atomically: true, encoding: .utf8)
            note = "Saved to \(url.lastPathComponent)."
        } catch {
            note = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func copyFenced() {
        let pb = TestIsolation.board
        pb.clearContents()
        pb.setString("```\(language.id)\n\(draft)\n```", forType: .string)
        note = "Copied as a fenced Markdown block."
    }

    /// Converts leading tabs to four spaces and trims trailing whitespace —
    /// the two things that most often survive a copy and look wrong.
    private func reindent() {
        draft = draft
            .components(separatedBy: .newlines)
            .map { line -> String in
                var l = line
                while l.hasPrefix("\t") { l = "    " + l.dropFirst() }
                while l.hasSuffix(" ") || l.hasSuffix("\t") { l = String(l.dropLast()) }
                return l
            }
            .joined(separator: "\n")
        note = "Tabs converted to spaces, trailing whitespace removed."
    }

    private func stripComments() {
        let token = language.comment
        guard !token.isEmpty else { note = "No line-comment syntax for \(language.title)."; return }
        let before = draft.components(separatedBy: .newlines).count
        draft = draft
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(token) }
            .joined(separator: "\n")
        let after = draft.components(separatedBy: .newlines).count
        note = "Removed \(before - after) comment line\(before - after == 1 ? "" : "s")."
    }
}

// MARK: - Text

struct TextActions: View {
    @Binding var draft: String
    @Binding var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(draft.count) character\(draft.count == 1 ? "" : "s") · \(words) word\(words == 1 ? "" : "s") · \(lines) line\(lines == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Trim") {
                    draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    note = "Leading and trailing whitespace removed."
                }
                Button("Single Line") {
                    draft = draft.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    note = "Collapsed to one line."
                }
                Button("UPPER") { draft = draft.uppercased() }
                Button("lower") { draft = draft.lowercased() }
                Button("Title Case") { draft = draft.capitalized }
                Button("Save as .txt…") { save() }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var words: Int { draft.split { $0 == " " || $0.isNewline }.count }
    private var lines: Int { draft.components(separatedBy: .newlines).count }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clipping.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? draft.write(to: url, atomically: true, encoding: .utf8)
        note = "Saved to \(url.lastPathComponent)."
    }
}

// MARK: - Link

struct LinkActions: View {
    let item: ClipboardItem
    @Binding var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let platform = item.platform {
                Label(platform.title, systemImage: platform.symbol)
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                let targets = LinkOpener.targets(for: item)
                if targets.count > 1 {
                    Menu("Open With") {
                        ForEach(targets) { target in
                            Button(target.isDefault ? "\(target.name) (default)" : target.name) {
                                LinkOpener.open(item, with: target)
                            }
                        }
                    }
                    .fixedSize()
                } else {
                    Button("Open Link") { LinkOpener.open(item, with: targets.first) }
                }
                Button("Copy Domain") {
                    guard let host = item.host else { return }
                    TestIsolation.board.clearContents()
                    TestIsolation.board.setString(host, forType: .string)
                    note = "Copied \(host)."
                }
                if item.platform == .repository,
                   let name = LinkPlatform.repositoryName(from: item.fullText) {
                    Button("Copy Clone Command") {
                        TestIsolation.board.clearContents()
                        TestIsolation.board.setString("git clone \(item.fullText).git", forType: .string)
                        note = "Copied a clone command for \(name)."
                    }
                }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

// MARK: - Color

struct ColorActions: View {
    let item: ClipboardItem
    @Binding var note: String?
    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager
    @State private var editing = false

    private var color: NSColor { NSColor(hex: item.hexColor ?? "#888888") ?? .gray }

    /// The item's colour as the shared editor sees it: every change is
    /// written straight back to the item (hex and text together), so the
    /// swatch, the formats and the card all follow the sliders live.
    private var editedHex: Binding<String> {
        Binding(
            get: { item.hexColor ?? "#888888" },
            set: { hex in store.update(item.id) { $0.hexColor = hex; $0.text = hex } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // Tap the swatch for the full editor (user, 03/09 evening:
                // "color picker here so I could edit any color I want").
                Button { editing = true } label: {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: color))
                        .frame(width: 44, height: 24)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.white.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Edit this color")
                .popover(isPresented: $editing, arrowEdge: .trailing) {
                    ColorEditor(hex: editedHex, title: "Edit color", theme: theme.theme, onClose: { editing = false })
                }
                .onChange(of: editing) { _, open in
                    if !open, let hex = item.hexColor { ColorEditor.remember(hex) }
                }

                Text(item.hexColor?.uppercased() ?? "")
                    .font(.system(.caption, design: .monospaced))
                Spacer()
            }

            HStack(spacing: 8) {
                ForEach(formats, id: \.0) { label, value in
                    Button(label) {
                        TestIsolation.board.clearContents()
                        TestIsolation.board.setString(value, forType: .string)
                        note = "Copied \(value)."
                    }
                }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    /// The formats a designer or developer actually pastes into.
    private var formats: [(String, String)] {
        guard let c = color.usingColorSpace(.sRGB) else { return [] }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())

        var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &br, alpha: nil)

        return [
            ("HEX", item.hexColor?.uppercased() ?? ""),
            ("RGB", "rgb(\(r), \(g), \(b))"),
            ("HSL", String(format: "hsl(%.0f, %.0f%%, %.0f%%)", h * 360, s * 100, br * 100)),
            ("SwiftUI", String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)",
                               c.redComponent, c.greenComponent, c.blueComponent))
        ]
    }
}

// MARK: - Emoji

struct EmojiActions: View {
    let item: ClipboardItem
    @Binding var note: String?

    var body: some View {
        HStack(spacing: 14) {
            Text(item.fullText).font(.system(size: 46))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(item.fullText.unicodeScalars.prefix(4)), id: \.self) { scalar in
                    Text(String(format: "U+%04X  %@", scalar.value,
                                scalar.properties.name ?? "Unnamed"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

// MARK: - Media

struct MediaActions: View {
    let item: ClipboardItem
    @Binding var note: String?
    @EnvironmentObject var store: HistoryStore

    @EnvironmentObject var theme: ThemeManager
    @State private var palette: [Color] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Save a Copy…") { save() }
                Button("Show in Finder") { store.revealInFinder(item) }
                // Free: the pixels are already here, and k-means is arithmetic.
                // A vision model is the expensive way to answer this.
                Button("Pull the Palette") { extractPalette() }
                if let d = item.dimensionCaption {
                    Text(d).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if !palette.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(palette.enumerated()), id: \.offset) { _, color in
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(color)
                            .frame(width: 40, height: 26)
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(theme.theme.border, lineWidth: 1))
                            .help(color.hexString)
                    }
                    Button("Copy") {
                        let pb = TestIsolation.board
                        pb.clearContents()
                        pb.setString(palette.map(\.hexString).joined(separator: "\n"), forType: .string)
                        note = "\(palette.count) color\(palette.count == 1 ? "" : "s") copied"
                    }
                    .buttonStyle(.link).font(.caption)
                    Button("Make a Theme") { themeFromPalette() }
                        .buttonStyle(.link).font(.caption)
                    Spacer()
                }
            }
        }
    }

    private func extractPalette() {
        guard let file = item.imageFile, let data = MediaStore.shared.data(for: file),
              let image = NSImage(data: data) else {
            note = "That image couldn't be read."
            return
        }
        palette = ImagePalette.colors(from: image, count: 5)
        note = palette.isEmpty ? "No colors could be pulled from that image." : nil
    }

    /// Straight into the theme maker, since a palette with nowhere to go is
    /// just a row of swatches.
    private func themeFromPalette() {
        guard palette.count >= 3 else { return }
        let hexes = palette.map(\.hexString)
        let doc = "colors:\n  canvas: \"\(hexes[0])\"\n  primary: \"\(hexes[1])\"\n"
                + "  surface-1: \"\(hexes[2])\"\n"
                + (hexes.count > 3 ? "  ink: \"\(hexes[3])\"\n" : "")
                + (hexes.count > 4 ? "  hairline: \"\(hexes[4])\"\n" : "")
        guard let draft = DesignDocTheme.theme(from: doc, named: item.displayTitle) else { return }
        let repaired = ThemeDoctor.repaired(draft)
        CustomThemeStore.shared.save(repaired)
        theme.themeID = "custom:\(repaired.id)"
        let report = ThemeRules.audit(repaired.appTheme)
        note = report.passes
            ? "Made a theme from this image and switched to it."
            : "Made a theme, but \(report.failures.count) pairing\(report.failures.count == 1 ? "" : "s") stayed unreadable."
    }

    private func save() {
        guard let file = item.imageFile, let data = MediaStore.shared.data(for: file) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(item.displayTitle).png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
        note = "Saved to \(url.lastPathComponent)."
    }
}

// MARK: - Files

struct FileActions: View {
    let item: ClipboardItem
    @Binding var note: String?
    @EnvironmentObject var store: HistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Show in Finder") { store.revealInFinder(item) }
                Button("Open") {
                    for path in item.filePaths {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                }
                Button("Copy Path") {
                    TestIsolation.board.clearContents()
                    TestIsolation.board.setString(item.filePaths.joined(separator: "\n"),
                                                   forType: .string)
                    note = "Copied \(item.filePaths.count) path\(item.filePaths.count == 1 ? "" : "s")."
                }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if !exists {
                Label("This path no longer exists on disk.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// A file reference outlives the file; saying so beats a silent no-op.
    private var exists: Bool {
        item.filePaths.allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }
}
