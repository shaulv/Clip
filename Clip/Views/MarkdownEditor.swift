import SwiftUI
import AppKit

/// Full-screen markdown workspace used when editing a skill.
///
/// A skill is a document, not a snippet, so it gets the whole panel: a source
/// pane, a live preview, a formatting toolbar, and the item's own configuration
/// (name, tags, shortcut) alongside rather than buried under it.
struct MarkdownEditor: View {
    let item: ClipboardItem
    @Binding var text: String
    @Binding var title: String
    @Binding var tags: String
    @Binding var shortcut: String
    @Binding var recording: Bool
    var shortcutError: String?
    let onSave: () -> Void
    let onCancel: () -> Void
    let isDirty: Bool
    /// Rendered only when a model is connected.
    var aiMenu: AnyView?
    /// True while a model is reading or rewriting this document, which locks
    /// the source pane: an edit made during a rewrite is an edit about to be
    /// silently thrown away.
    var aiWorking: Bool = false
    /// A result that is not a change - "nothing to correct". Shown beside the
    /// AI button, quietly.
    var aiVerdict: String?

    @EnvironmentObject var theme: ThemeManager
    @State private var mode: Mode = .split
    @State private var selection: NSRange?

    private var t: AppTheme { theme.theme }

    enum Mode: String, CaseIterable {
        case write, split, preview
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .write:   return "pencil"
            case .split:   return "rectangle.split.2x1"
            case .preview: return "eye"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(t.border)
            formattingBar
            Divider().overlay(t.border)

            HStack(spacing: 0) {
                if mode != .preview {
                    MarkdownSourceView(text: $text, selection: $selection, theme: t)
                        .frame(maxWidth: .infinity)
                        .aiProcessing(aiWorking, theme: t)
                }
                if mode == .split { Divider().overlay(t.border) }
                if mode != .write {
                    ScrollView {
                        MarkdownRender(text: text, theme: t)
                            .padding(Spacing.group)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxWidth: .infinity)
                    .background(t.panelBackground.opacity(0.4))
                }
            }
            .frame(maxHeight: .infinity)

            Divider().overlay(t.border)
            configuration
            Divider().overlay(t.border)
            footer
        }
        .background(t.cardBackground)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: Spacing.related) {
            // The role's own glyph: the editor serves skills and design
            // documents, and a hard-coded graduation cap labelled a design
            // system as a skill.
            Image(systemName: item.role.symbol).foregroundStyle(t.accentOnCard)
            TextField("\(item.role.title) name", text: $title)
                .textFieldStyle(.plain)
                .font(Typography.heading)
                .foregroundStyle(t.textPrimary)

            if isDirty {
                Text("Edited")
                    .font(Typography.micro)
                    .foregroundStyle(t.accentOnCard)
                    .padding(.horizontal, Spacing.inline).padding(.vertical, Spacing.inline)
                    .background(t.accent.opacity(0.15), in: Capsule())
            }

            Spacer()

            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { m in
                    Image(systemName: m.symbol).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)

            if let aiVerdict {
                Text(aiVerdict)
                    .font(Typography.caption)
                    .foregroundStyle(t.textTertiary)
            }
            if let aiMenu { aiMenu }
        }
        .padding(.horizontal, Spacing.comfortable).padding(.vertical, Spacing.related)
    }

    /// Wraps or prefixes the current selection — the small set of actions people
    /// actually reach for when writing markdown.
    private var formattingBar: some View {
        HStack(spacing: Spacing.inline) {
            tool("bold", "Bold") { wrap("**") }
            tool("italic", "Italic") { wrap("_") }
            tool("chevron.left.forwardslash.chevron.right", "Code") { wrap("`") }
            Divider().frame(height: 16)
            tool("number", "Heading") { prefixLine("## ") }
            tool("list.bullet", "Bullet list") { prefixLine("- ") }
            tool("list.number", "Numbered list") { prefixLine("1. ") }
            tool("checkmark.square", "Task") { prefixLine("- [ ] ") }
            tool("quote.opening", "Quote") { prefixLine("> ") }
            Divider().frame(height: 16)
            tool("link", "Link") { insert("[title](https://)") }
            tool("tablecells", "Table") {
                insert("\n| Column | Column |\n| --- | --- |\n| value | value |\n")
            }
            tool("curlybraces", "Code block") { insert("\n```\ncode\n```\n") }
            Spacer()
            // A skill or a prompt is read whole by a model, so its size is a
            // number with a decision attached: the token estimate turns amber
            // as it approaches what a typical window will take.
            TextMetrics(text: text, theme: t, showsTokens: true, limit: 8_000)
        }
        .padding(.horizontal, Spacing.comfortable).padding(.vertical, Spacing.tight)
    }

    private func tool(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Typography.label)
                .foregroundStyle(t.textSecondary)
                .frame(width: 26, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var configuration: some View {
        HStack(spacing: Spacing.comfortable) {
            HStack(spacing: Spacing.tight) {
                Text("Tags")
                    .font(Typography.labelStrong)
                    .foregroundStyle(t.textTertiary)
                    .fixedSize()
                TextField("comma, separated", text: $tags)
                    .textFieldStyle(.plain)
                    .font(Typography.label)
                    .padding(.horizontal, Spacing.tight).padding(.vertical, Spacing.inline)
                    .background(t.surfaceBackground, in: Capsule())
                    // Flexible, not a fixed 200pt. At a fixed width the row was
                    // wider than the panel, and the overflow was taken out of
                    // whatever came next - so the tags capsule sat on top of the
                    // word "Shortcut".
                    .frame(minWidth: 90, idealWidth: 200, maxWidth: 240)
            }
            .layoutPriority(1)

            ShortcutField(value: $shortcut, isRecording: $recording, error: shortcutError,
                          onClear: { shortcut = "" })
                .fixedSize()
                .layoutPriority(2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.comfortable).padding(.vertical, Spacing.related)
    }

    private var footer: some View {
        HStack {
            Text("Markdown")
                .font(Typography.caption).foregroundStyle(t.textTertiary)
            Spacer()
            SecondaryButton("Cancel", action: onCancel)
            PrimaryButton("Save", isDisabled: !isDirty, action: onSave)
        }
        .padding(.horizontal, Spacing.comfortable).padding(.vertical, Spacing.related)
    }

    // MARK: - Editing helpers

    private func wrap(_ token: String) {
        guard let r = selection, r.length > 0,
              let range = Range(r, in: text) else {
            insert(token + token)
            return
        }
        let selected = String(text[range])
        text.replaceSubrange(range, with: token + selected + token)
    }

    private func prefixLine(_ token: String) {
        guard let r = selection, let range = Range(r, in: text) else {
            insert(token)
            return
        }
        // Walk back to the start of the line the caret sits on.
        var lineStart = range.lowerBound
        while lineStart > text.startIndex {
            let prev = text.index(before: lineStart)
            if text[prev].isNewline { break }
            lineStart = prev
        }
        text.insert(contentsOf: token, at: lineStart)
    }

    private func insert(_ snippet: String) {
        if let r = selection, let range = Range(r, in: text) {
            text.replaceSubrange(range, with: snippet)
        } else {
            text += snippet
        }
    }
}

/// Monospaced source pane that reports its selection back, so the formatting
/// toolbar can act on what the user highlighted.
struct MarkdownSourceView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange?
    let theme: AppTheme

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(theme.textPrimary)
        textView.backgroundColor = NSColor(theme.cardBackground)
        textView.insertionPointColor = NSColor(theme.accent)
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.string = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text { textView.string = text }
        textView.textColor = NSColor(theme.textPrimary)
        textView.backgroundColor = NSColor(theme.cardBackground)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: MarkdownSourceView
        init(_ parent: MarkdownSourceView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.selection = tv.selectedRange()
        }
    }
}

/// Renders the subset of markdown that matters for a skill document.
///
/// `AttributedString(markdown:)` handles inline styling but flattens block
/// structure, so headings, lists, quotes and fenced code are laid out here and
/// only the inline spans are handed to the parser.
struct MarkdownRender: View {
    let text: String
    let theme: AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                block.view(theme)
            }
        }
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var codeBuffer: [String] = []
        var inCode = false

        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("```") {
                if inCode {
                    out.append(.code(codeBuffer.joined(separator: "\n")))
                    codeBuffer = []
                }
                inCode.toggle()
                continue
            }
            if inCode { codeBuffer.append(line); continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { out.append(.spacer) }
            else if trimmed.hasPrefix("###") { out.append(.heading(String(trimmed.dropFirst(3)), 3)) }
            else if trimmed.hasPrefix("##") { out.append(.heading(String(trimmed.dropFirst(2)), 2)) }
            else if trimmed.hasPrefix("#") { out.append(.heading(String(trimmed.dropFirst(1)), 1)) }
            else if trimmed.hasPrefix("> ") { out.append(.quote(String(trimmed.dropFirst(2)))) }
            else if trimmed.hasPrefix("- [ ] ") { out.append(.task(String(trimmed.dropFirst(6)), false)) }
            else if trimmed.hasPrefix("- [x] ") { out.append(.task(String(trimmed.dropFirst(6)), true)) }
            else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                out.append(.bullet(String(trimmed.dropFirst(2))))
            }
            else if trimmed.range(of: "^\\d+\\. ", options: .regularExpression) != nil {
                let body = trimmed.replacingOccurrences(of: "^\\d+\\. ", with: "",
                                                       options: .regularExpression)
                out.append(.numbered(body))
            }
            else if trimmed.hasPrefix("|") { out.append(.paragraph(trimmed)) }
            else if trimmed == "---" { out.append(.rule) }
            else { out.append(.paragraph(trimmed)) }
        }
        if inCode, !codeBuffer.isEmpty { out.append(.code(codeBuffer.joined(separator: "\n"))) }
        return out
    }

    enum Block {
        case heading(String, Int)
        case paragraph(String)
        case bullet(String)
        case numbered(String)
        case task(String, Bool)
        case quote(String)
        case code(String)
        case rule
        case spacer

        /// Inline markdown (bold, italic, links, code spans) via the system parser.
        private func inline(_ s: String) -> AttributedString {
            (try? AttributedString(markdown: s)) ?? AttributedString(s)
        }

        @ViewBuilder
        func view(_ theme: AppTheme) -> some View {
            switch self {
            case .heading(let s, let level):
                Text(inline(s.trimmingCharacters(in: .whitespaces)))
                    .font(level == 1 ? Typography.markdownH1
                          : level == 2 ? Typography.markdownH2 : Typography.markdownH3)
                    .foregroundStyle(theme.textPrimary)
                    .padding(.top, level == 1 ? Spacing.tight : Spacing.inline)
            case .paragraph(let s):
                Text(inline(s)).font(Typography.markdownBody).foregroundStyle(theme.textSecondary)
            case .bullet(let s):
                HStack(alignment: .top, spacing: Spacing.tight) {
                    Text("•").foregroundStyle(theme.accentOnCard)
                    Text(inline(s)).font(Typography.markdownBody).foregroundStyle(theme.textSecondary)
                }
            case .numbered(let s):
                HStack(alignment: .top, spacing: Spacing.tight) {
                    Text("›").foregroundStyle(theme.accentOnCard)
                    Text(inline(s)).font(Typography.markdownBody).foregroundStyle(theme.textSecondary)
                }
            case .task(let s, let done):
                HStack(alignment: .top, spacing: Spacing.tight) {
                    Image(systemName: done ? "checkmark.square.fill" : "square")
                        .foregroundStyle(done ? theme.accent : theme.textTertiary)
                    Text(inline(s))
                        .font(Typography.markdownBody)
                        .strikethrough(done)
                        .foregroundStyle(done ? theme.textTertiary : theme.textSecondary)
                }
            case .quote(let s):
                HStack(alignment: .top, spacing: Spacing.tight) {
                    Rectangle().fill(theme.accent).frame(width: 3).clipShape(Capsule())
                    Text(inline(s)).font(Typography.markdownBody).italic()
                        .foregroundStyle(theme.textSecondary)
                }
            case .code(let s):
                Text(s)
                    .font(Typography.labelMono)
                    .foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.related)
                    .background(theme.surfaceBackground,
                                in: RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous))
            case .rule:
                Rectangle().fill(theme.border).frame(height: 1)
            case .spacer:
                Spacer().frame(height: 2)
            }
        }
    }
}

/// A markdown-capable, multi-line prompt field: grows to a cap with internal
/// scroll instead of a fixed-height box, so a huge paste stays readable
/// rather than squeezed into a couple of visible lines.
///
/// M9 9.3, the user's own words: "in the generate theme popup, use markdown
/// editor for the prompt so the user could paste huge text and see it
/// clearly." Reuses `MarkdownSourceView` - the same monospaced, real-`NSText
/// View`-backed source pane `MarkdownEditor` already edits a whole document
/// with - rather than a plain `TextField`/`TextEditor`, which is what both
/// the "Ask for a change" field and the "Describe a theme" prompt used
/// before this: a `TextField` truncates to one line, and the old fixed
/// 90pt `TextEditor` clipped anything longer than about a paragraph.
struct MarkdownPromptEditor: View {
    @Binding var text: String
    var placeholder: String = ""
    let theme: AppTheme
    var minHeight: CGFloat = 64
    var maxHeight: CGFloat = 220
    /// Lets `qa-probe.py` drive and read this exact instance without a
    /// synthesized paste event - see `MarkdownPromptTestRegistry` below,
    /// the same pattern `EditableLabel`/`EditableLabelTestRegistry` already
    /// use for the same reason.
    var testID: String? = nil
    /// Write / Split / Preview like the document editor (user, 04/09: "make
    /// this popup a markdown editor so the user will have visibility") - the
    /// rendered side shows headings, lists and code the way the model will
    /// read them, not as raw asterisks.
    var showsPreview: Bool = false
    /// The same AI menu the document editor carries. Off by default so a field
    /// that genuinely is one line does not grow a menu; on everywhere the user
    /// writes prose (user, 05/09: the markdown experience is the same in every
    /// markdown editor in the app).
    var showsAI: Bool = false

    @State private var selection: NSRange?
    @State private var mode: MarkdownEditor.Mode = .split
    @ObservedObject private var aiService = AIService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.inline) {
            if showsPreview || (showsAI && aiService.isAvailable) {
                HStack {
                    Text(mode == .preview ? "Preview" : (mode == .split ? "Write and preview" : "Write"))
                        .font(Typography.caption).foregroundStyle(theme.textTertiary)
                    Spacer()
                    if showsAI && aiService.isAvailable {
                        TextAIMenu(text: $text, theme: theme)
                    }
                    if showsPreview {
                        Picker("", selection: $mode) {
                            ForEach(MarkdownEditor.Mode.allCases, id: \.self) { m in
                                Image(systemName: m.symbol).tag(m).help(m.title)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                    }
                }
            }
            HStack(spacing: 0) {
                if !showsPreview || mode != .preview {
                    ZStack(alignment: .topLeading) {
                        MarkdownSourceView(text: $text, selection: $selection, theme: theme)
                        if text.isEmpty {
                            Text(placeholder)
                                .font(Typography.body)
                                .foregroundStyle(theme.textTertiary)
                                .padding(.horizontal, 18)
                                .padding(.top, 14)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                if showsPreview && mode == .split { Divider().overlay(theme.border) }
                if showsPreview && mode != .write {
                    ScrollView {
                        Group {
                            if text.isEmpty {
                                Text("Nothing to preview yet.").font(Typography.caption).foregroundStyle(theme.textTertiary)
                            } else {
                                MarkdownRender(text: text, theme: theme)
                            }
                        }
                        .padding(Spacing.related)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxWidth: .infinity)
                    .background(theme.panelBackground.opacity(0.4))
                }
            }
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .background(theme.cardBackground,
                        in: RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                .stroke(theme.border))

            TextMetrics(text: text, theme: theme, showsTokens: true, limit: 20_000)
        }
        #if CLIP_TESTING
        .onAppear {
            guard let testID else { return }
            MarkdownPromptTestRegistry.shared.register(testID, .init(
                currentText: { text },
                setText: { text = $0 }
            ))
        }
        .onDisappear {
            guard let testID else { return }
            MarkdownPromptTestRegistry.shared.unregister(testID)
        }
        #endif
    }
}

#if CLIP_TESTING
/// Lets the QA bridge drive one `MarkdownPromptEditor` instance by its
/// `testID`, mirroring `EditableLabelTestRegistry` in `EditableLabel.swift`.
///
/// M9 9.3's W4 ("a 10 KB paste is readable, no truncation") has to SET the
/// real bound `text` through the same path typing does, and read the real
/// character count back the same way - not a stand-in that could pass while
/// the actual field truncates.
@MainActor
final class MarkdownPromptTestRegistry {
    static let shared = MarkdownPromptTestRegistry()

    struct Handle {
        var currentText: () -> String
        var setText: (String) -> Void
    }

    private var handles: [String: Handle] = [:]

    func register(_ id: String, _ handle: Handle) { handles[id] = handle }
    func unregister(_ id: String) { handles.removeValue(forKey: id) }
    func handle(_ id: String) -> Handle? { handles[id] }

    /// Every currently-mounted instance's text length, for `QABridge`'s
    /// `m9_prompts` - one dictionary rather than a bespoke state key per
    /// `testID`, the same reasoning `EditableLabelTestRegistry.snapshot()`
    /// already uses.
    func snapshot() -> [String: [String: Any]] {
        handles.mapValues { ["length": $0.currentText().count] }
    }
}
#endif
