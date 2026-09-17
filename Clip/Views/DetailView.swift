import SwiftUI
import AppKit

/// Full-size editor for one item: preview, editable body with explicit Save and
/// Cancel, prompt metadata, its own global shortcut, version history, and — only
/// when a model is connected — AI assistance.
struct DetailOverlay: View {
    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager
    @StateObject private var ai = AIService.shared

    @State private var draft = ""
    @State private var titleDraft = ""
    @State private var tagDraft = ""
    @State private var shortcutDraft = ""
    @State private var recording = false
    @State private var shortcutError: String?
    @State private var showVersions = false
    @State private var versions: [ItemVersion] = []

    // AI state. A suggestion is held here, shown, and applied only on Accept.
    @State private var suggestion: AIService.Suggestion?
    @State private var suggestedTags: [String] = []
    /// A failure: what went wrong and what to do about it.
    @State private var aiFailure: AIDiagnosis.Reading?
    /// A result that is not a suggestion - "nothing to correct". Kept apart from
    /// a failure because it is not one, and coloring it red said it was.
    @State private var aiVerdict: String?
    /// Showing the suggestion as a diff against what is there now.
    @State private var showingDiff = false
    /// The confirmation before a suggestion is written into the draft.
    @State private var confirmingApply = false

    private var t: AppTheme { theme.theme }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { attemptClose() }

            if let item = store.selectedItem {
                Group {
                    if item.role.isMarkdownDocument {
                        // Skills and design documents are markdown, so they get
                        // the full panel with a live preview.
                        MarkdownEditor(
                            item: item,
                            text: $draft, title: $titleDraft, tags: $tagDraft,
                            shortcut: $shortcutDraft, recording: $recording,
                            shortcutError: shortcutError,
                            onSave: { save(item) },
                            onCancel: { isDirty ? cancel(item) : store.closeDetail() },
                            isDirty: isDirty,
                            aiMenu: ai.isAvailable ? AnyView(aiMenu(item)) : nil,
                            aiWorking: ai.isWorking,
                            aiVerdict: aiVerdict
                        )
                        .clipShape(RoundedRectangle(cornerRadius: t.radiusContainer, style: .continuous))
                        // The suggestion card lived only in the plain-text
                        // editor, so every AI action taken from the markdown
                        // editor produced a reply with nowhere to appear: the
                        // spinner stopped and nothing happened. Now that notes
                        // and prompts open here too, that was most of them.
                        .overlay(alignment: .bottom) {
                            VStack(spacing: Spacing.tight) {
                                if let aiFailure {
                                    AIOutcomeLabel(kind: .failure, message: aiFailure.message,
                                                   remedy: aiFailure.remedy, theme: t)
                                        .padding(Spacing.related)
                                        .background(t.cardBackground,
                                                    in: RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous)
                                            .strokeBorder(t.destructive.opacity(0.4), lineWidth: 1))
                                }
                                if let suggestion {
                                    suggestionCard(suggestion, item)
                                        .background(t.cardBackground,
                                                    in: RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous))
                                        .frame(maxWidth: 720)
                                }
                            }
                            .padding(Spacing.group)
                            .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
                        }
                        .overlay(RoundedRectangle(cornerRadius: t.radiusContainer, style: .continuous)
                            .strokeBorder(t.border, lineWidth: 1))
                        .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
                        .padding(Spacing.comfortable)
                        // Checked, not committed. Save writes it; Cancel
                        // throws it away, exactly like the title and the body.
                        .onChange(of: shortcutDraft) { _, new in
                            guard !recording else { return }
                            shortcutError = store.validateShortcut(new, for: item.id)
                        }
                    } else {
                        card(for: item)
                            .frame(maxWidth: 660, maxHeight: 560)
                    }
                }
                .onAppear { seed(from: item) }
                .onChange(of: item.id) { _, _ in seed(from: item) }
            }
        }
        // M19: one aggregate tag for the whole overlay - `card(for:)` below
        // additionally tags its own, smaller card frame, which wins there.
        .themeTokens(["cardBackground", "surfaceBackground", "border", "accent",
                      "accentOnCard", "destructive", "textPrimary", "textSecondary",
                      "textTertiary"])
    }

    // MARK: - State

    private func seed(from item: ClipboardItem) {
        draft = item.fullText
        titleDraft = item.title ?? ""
        tagDraft = item.tags.joined(separator: ", ")
        shortcutDraft = item.shortcut ?? ""
        shortcutError = nil
        recording = false
        suggestion = nil
        suggestedTags = []
        aiFailure = nil
        aiVerdict = nil
        showVersions = false
        versions = store.versions(for: item.id)
        store.isEditing = false
    }

    /// Anything whose body is plain text the user may edit: real text kinds,
    /// plus anything they curated into a prompt, note or skill.
    private func isTextual(_ item: ClipboardItem) -> Bool {
        item.kind.isEditable || item.role.isCurated
    }

    /// Everything the editor can change, so Save lights up for any of it.
    ///
    /// The shortcut was missing, so recording one - or clearing one - left Save
    /// greyed out as though nothing had happened.
    private var isDirty: Bool {
        guard let item = store.selectedItem else { return false }
        return draft != item.fullText
            || titleDraft != (item.title ?? "")
            || tagDraft != item.tags.joined(separator: ", ")
            || shortcutDraft != (item.shortcut ?? "")
    }

    /// Escape and the scrim both go through here so unsaved work is never lost
    /// silently — Cancel is explicit, closing is not a discard.
    private func attemptClose() {
        if isDirty { return }        // the footer's Cancel is the way out
        store.closeDetail()
    }

    private func cancel(_ item: ClipboardItem) {
        seed(from: item)
        store.isEditing = false
    }

    private func save(_ item: ClipboardItem) {
        // The shortcut is committed here with everything else, and only here.
        // An empty draft means "unbind it", which is a change worth saving and
        // used to be one the editor performed behind the user's back.
        //
        // Save is the end of the task: on a clean commit the editor closes
        // and returns to the list, the same as Cancel does when there is
        // nothing to discard. The one way this can fail is the shortcut - a
        // conflict with another item's binding, or macOS itself declining
        // the combination - and `commitDetailEdit` reports that back instead
        // of closing, so the editor stays open with shortcutError shown and
        // the user can fix or clear it rather than losing that context
        // behind a closed popup.
        shortcutError = store.commitDetailEdit(
            item.id,
            text: isTextual(item) ? draft : nil,
            title: titleDraft,
            tags: tagDraft,
            shortcut: shortcutDraft,
            previousShortcut: item.shortcut
        )
        versions = store.versions(for: item.id)
    }

    // MARK: - Layout

    private func card(for item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(item)
            Divider().overlay(t.border)
            ScrollView {
                // Bumped a step further than a plain round-up (14 -> 16): these
                // are genuinely separate sections of the document (preview,
                // editor, AI results, metadata), not lines inside one of them.
                VStack(alignment: .leading, spacing: Spacing.group) {
                    preview(item)
                    if isTextual(item) { editor(item) }
                    if let suggestion { suggestionCard(suggestion, item) }
                    if !suggestedTags.isEmpty { tagSuggestions(item) }
                    if let aiFailure {
                        AIOutcomeLabel(kind: .failure, message: aiFailure.message,
                                       remedy: aiFailure.remedy, theme: t)
                    }
                    TypeActions(item: item, draft: $draft)
                    if item.role.isCurated { promptFields(item) }
                    if showVersions { versionList(item) }
                    metadata(item)
                }
                // No bottom padding here (T3-M4): the footer below already
                // carries a full Spacing.group before the shortcut field, so
                // a second helping here only pushed the two apart further
                // instead of matching them, and vanished first whenever the
                // scroll area was too short to show it - the exact "metadata
                // crowds the shortcut" defect this was reported as.
                .padding(.horizontal, Spacing.comfortable)
                .padding(.top, Spacing.comfortable)
            }
            Divider().overlay(t.border)
            VStack(alignment: .leading, spacing: 0) {
                // The shortcut sits in the footer, not down in the scroll.
                // It is one of the most useful things about a saved item -
                // paste it from any app without opening Clip - and it was
                // below the fold, so most items never got one.
                shortcutField(item)
                    .padding(.horizontal, Spacing.comfortable)
                    // Pixel-measured (T3-M4): Spacing.comfortable here lands
                    // within a pixel of the gap the metadata list gets above
                    // it - not the smaller Spacing.related this used to be,
                    // which read as the metadata list crowding the shortcut
                    // below it.
                    .padding(.top, Spacing.comfortable)
                actions(item)
            }
        }
        .background(t.cardBackground, in: RoundedRectangle(cornerRadius: t.radiusContainer, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: t.radiusContainer, style: .continuous).strokeBorder(t.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
        .themeTokens(["cardBackground", "border", "textPrimary", "textSecondary",
                      "textTertiary", "accent", "accentOnCard", "destructive"])
        .padding(Spacing.loose)
    }

    private func header(_ item: ClipboardItem) -> some View {
        HStack(spacing: Spacing.tight) {
            Image(systemName: "pencil").foregroundStyle(t.tint(for: item.kind))
            Text(item.displayTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(t.textPrimary)
                .lineLimit(1)
            if isDirty {
                Text("Edited")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(t.accentOnCard)
                    .padding(.horizontal, Spacing.inline).padding(.vertical, Spacing.inline)
                    .background(t.accent.opacity(0.15), in: Capsule())
            }
            Spacer()
            if versions.count > 1 {
                Button {
                    withAnimation { showVersions.toggle() }
                } label: {
                    HStack(spacing: Spacing.inline) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("\(versions.count)").font(.system(size: 10, weight: .bold, design: .rounded))
                    }
                }
                .buttonStyle(PillButtonStyle(theme: t))
                .help("Version history")
            }
        }
        .padding(Spacing.comfortable)
    }

    @ViewBuilder
    private func preview(_ item: ClipboardItem) -> some View {
        switch item.kind {
        case .image, .video:
            MediaPreview(item: item, theme: t, maxWidth: 560, maxHeight: 260,
                         cornerRadius: t.radiusCard, contentMode: .fit)
        case .color:
            RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous)
                .fill(item.hexColor.flatMap { Color(nsColor: NSColor(hex: $0) ?? .gray) } ?? .gray)
                .frame(height: 110)
        case .file:
            FilePreview(item: item, theme: t)
        default:
            EmptyView()
        }
    }

    private func editor(_ item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.tight) {
                SectionLabel("Content", theme: t)
                Spacer()
                // The verdict sits beside the button that produced it, small and
                // neutral, rather than below in the error slot.
                if let aiVerdict {
                    Text(aiVerdict)
                        .font(.system(size: 10))
                        .foregroundStyle(t.textTertiary)
                        .transition(.opacity)
                }
                if ai.isAvailable { aiMenu(item) }
            }
            TextEditor(text: $draft)
                .font(.system(size: item.kind == .code ? 11.5 : 12,
                              design: item.kind == .code ? .monospaced : .default))
                .scrollContentBackground(.hidden)
                .padding(Spacing.tight)
                .frame(minHeight: item.kind == .code ? 200 : 130,
                       maxHeight: item.kind == .code ? 320 : 240)
                .background(t.surfaceBackground, in: RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous).strokeBorder(t.border, lineWidth: 1))
                .aiProcessing(ai.isWorking, theme: t)
            TextMetrics(text: draft, theme: t, showsTokens: item.role.isCurated)
        }
    }

    // MARK: - AI

    /// Only ever rendered when `ai.isAvailable`. Prompt-only features are gated
    /// again here, so improving a prompt cannot be invoked on a plain clipping.
    private func aiMenu(_ item: ClipboardItem) -> some View {
        Menu {
            if item.role == .prompt {
                Button("Improve this prompt") { runAI(item) { try await ai.improvePrompt(draft) } }
                Button("Suggest a name") { runAI(item) { try await ai.suggestTitle(for: draft) } }
                Button("Suggest tags") { runTagSuggestions() }
            }
            Button("Check spelling and grammar") { runProofread() }
            Button("Summarize") { runAI(item) { try await ai.summarise(draft) } }
            if item.kind == .code {
                Button("Explain this code") {
                    runAI(item) { try await ai.explainCode(draft, language: item.language) }
                }
            }
            if item.role != .prompt {
                Button("Turn into a prompt template") {
                    runAI(item) { try await ai.makeTemplate(from: draft) }
                }
            }
            Menu("Translate to") {
                ForEach(["English", "Hebrew", "Spanish", "French", "German", "Japanese"], id: \.self) { lang in
                    Button(lang) { runAI(item) { try await ai.translate(draft, to: lang) } }
                }
            }
            Divider()
            Menu("Extract as") {
                ForEach(StructureFormat.allCases) { format in
                    Button(format.title) {
                        runAI(item) { try await ai.extractStructure(draft, as: format) }
                    }
                }
            }
            Menu("Rewrite for pasting") {
                ForEach(["Plain text, no formatting", "A bulleted list", "One paragraph",
                         "A commit message", "A polite message"], id: \.self) { how in
                    Button(how) {
                        runAI(item) { try await ai.transformForPaste(draft, instruction: how) }
                    }
                }
            }
            if versions.count > 1, let previous = versions.dropFirst().first {
                Button("What changed since the last version") {
                    runAI(item) { try await ai.describeChange(from: previous.body, to: draft) }
                }
            }
            if store.markedIDs.count > 1 {
                Divider()
                Menu("Compose \(store.markedIDs.count) marked items into") {
                    ForEach(["one merged document", "one prompt that supersedes them",
                             "a single token set", "a summary of all of them"], id: \.self) { how in
                        Button(how) {
                            let pieces = store.actionTargets.map(\.fullText)
                            runAI(item) { try await ai.compose(pieces, instruction: how) }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.inline) {
                if ai.isWorking {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "sparkles")
                }
                Text("AI").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(t.accentOnCard)
            .padding(.horizontal, Spacing.tight).padding(.vertical, Spacing.inline)
            .background(t.accent.opacity(0.14), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(ai.isWorking)
    }

    private func runAI(_ item: ClipboardItem, _ work: @escaping () async throws -> AIService.Suggestion) {
        aiFailure = nil
        aiVerdict = nil
        suggestion = nil
        let length = draft.count
        Task {
            do { suggestion = try await work() }
            catch { aiFailure = AIDiagnosis.read(error, inputLength: length) }
        }
    }

    private func runProofread() {
        aiFailure = nil
        aiVerdict = nil
        suggestion = nil
        let length = draft.count
        Task {
            do {
                if let s = try await ai.proofread(draft) {
                    suggestion = s
                } else {
                    // A finding, not a fault.
                    aiVerdict = "No changes needed"
                }
            } catch { aiFailure = AIDiagnosis.read(error, inputLength: length) }
        }
    }

    private func runTagSuggestions() {
        aiFailure = nil
        let length = draft.count
        Task {
            do { suggestedTags = try await ai.suggestTags(for: draft) }
            catch { aiFailure = AIDiagnosis.read(error, inputLength: length) }
        }
    }

    /// A suggestion is never applied on its own. Accept writes it into the draft
    /// (which the user still has to Save); Discard throws it away.
    private func suggestionCard(_ s: AIService.Suggestion, _ item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.tight) {
                Image(systemName: "sparkles").foregroundStyle(t.accentOnCard)
                SectionLabel(s.title, theme: t, tint: t.accentOnCard)
                Spacer()
            }
            ScrollView {
                Text(s.body)
                    .font(.system(size: 12))
                    .foregroundStyle(t.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 150)

            HStack(spacing: Spacing.tight) {
                Button(s.title == "Suggested name" ? "Use as Name" : "Replace Content") {
                    confirmingApply = true
                }
                .buttonStyle(.borderedProminent)
                // The diff is the whole difference between trusting this and
                // hoping. It is computed from the two strings here, so it shows
                // what will actually be written rather than what the model said
                // it did.
                if s.title != "Suggested name", let original = s.original {
                    let summary = TextDiff.summary(from: original, to: s.body)
                    Button("See the Changes (\(summary.sentence))") { showingDiff = true }
                        .buttonStyle(.bordered)
                }
                Button("Discard") { suggestion = nil }
                Spacer()
                Text("Nothing is saved until you press Save.")
                    .font(.system(size: 10)).foregroundStyle(t.textTertiary)
            }
            .alert("Replace the text with this suggestion?", isPresented: $confirmingApply) {
                Button("Cancel", role: .cancel) { }
                Button("Replace") { apply(s) }
            } message: {
                Text("""
                    This puts the suggestion into the editor, replacing what is there \
                    now. It's still not saved: the Save button writes it, and Cancel \
                    puts back the text you started with.
                    """)
            }
            .sheet(isPresented: $showingDiff) {
                VStack(spacing: 0) {
                    HStack {
                        Text(s.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(t.textPrimary)
                        Spacer()
                        Text("Not applied yet")
                            .font(.system(size: 10)).foregroundStyle(t.textTertiary)
                    }
                    .padding(Spacing.comfortable)
                    Divider().overlay(t.border)
                    DiffView(before: s.original ?? draft, after: s.body, theme: t)
                        .padding(Spacing.comfortable)
                    Divider().overlay(t.border)
                    HStack {
                        Button("Close") { showingDiff = false }
                        Spacer()
                        Button("Replace the Text") {
                            showingDiff = false
                            confirmingApply = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(Spacing.comfortable)
                }
                .frame(width: 860, height: 620)
                .background(t.cardBackground)
            }
        }
        .padding(Spacing.related)
        .background(t.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous)
            .strokeBorder(t.accent.opacity(0.35), lineWidth: 1))
    }

    /// Writes an accepted suggestion into the draft - and no further. Save is
    /// still the only thing that touches the stored item.
    private func apply(_ s: AIService.Suggestion) {
        if s.title == "Suggested name" { titleDraft = s.body } else { draft = s.body }
        suggestion = nil
    }

    private func tagSuggestions(_ item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            SectionLabel("Suggested tags", theme: t)
            HStack(spacing: Spacing.tight) {
                ForEach(suggestedTags, id: \.self) { tag in
                    Button {
                        var current = tagDraft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        if !current.contains(tag) { current.append(tag) }
                        tagDraft = current.filter { !$0.isEmpty }.joined(separator: ", ")
                        suggestedTags.removeAll { $0 == tag }
                    } label: {
                        Text("+ \(tag)")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, Spacing.tight).padding(.vertical, Spacing.inline)
                            .background(t.surfaceBackground, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
    }

    // MARK: - Fields

    private func promptFields(_ item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: Spacing.related) {
            labelled("Name") {
                TextField("Untitled prompt", text: $titleDraft)
                    .textFieldStyle(.plain)
            }
            labelled("Tags") {
                TextField("comma, separated", text: $tagDraft)
                    .textFieldStyle(.plain)
            }
        }
    }

    private func shortcutField(_ item: ClipboardItem) -> some View {
        ShortcutField(value: $shortcutDraft, isRecording: $recording, error: shortcutError) {
            // Clearing is an edit like any other: it empties the draft, Save
            // lights up, and nothing is unbound until Save is pressed.
            shortcutDraft = ""
            shortcutError = nil
        }
        .onChange(of: shortcutDraft) { _, new in
            guard !recording else { return }
            shortcutError = store.validateShortcut(new, for: item.id)
        }
    }

    /// Every revision, newest first, each restorable.
    private func versionList(_ item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            SectionLabel("Version history", theme: t)
            ForEach(versions) { version in
                HStack(spacing: Spacing.tight) {
                    VStack(alignment: .leading, spacing: Spacing.inline) {
                        Text(version.preview)
                            .font(.system(size: 11)).foregroundStyle(t.textSecondary).lineLimit(1)
                        Text("\(version.note) · \(version.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 9)).foregroundStyle(t.textTertiary)
                    }
                    Spacer()
                    if version.body == draft {
                        Text("current").font(.system(size: 9)).foregroundStyle(t.textTertiary)
                    } else {
                        Button("Restore") {
                            store.restore(version, for: item.id)
                            draft = version.body
                            versions = store.versions(for: item.id)
                        }
                        .buttonStyle(.link).font(.system(size: 11))
                    }
                }
                .padding(Spacing.tight)
                .background(t.surfaceBackground, in: RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous))
            }
        }
    }

    private func metadata(_ item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: Spacing.inline) {
            row("Type", item.kind.displayName)
            if let lang = item.language { row("Language", lang) }
            if let app = item.sourceAppName { row("From", app) }
            if let d = item.dimensionCaption { row("Size", d) }
            row("Copied", item.timestamp.formatted(date: .abbreviated, time: .shortened))
            row("Pasted", "\(item.useCount) time\(item.useCount == 1 ? "" : "s")")
            row("Versions", "\(versions.count)")
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 11)).foregroundStyle(t.textTertiary)
            Spacer()
            Text(v).font(.system(size: 11)).foregroundStyle(t.textSecondary)
        }
    }

    private func labelled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.inline) {
            SectionLabel(label, theme: t)
            content()
                .padding(Spacing.tight)
                .background(t.surfaceBackground, in: RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous).strokeBorder(t.border, lineWidth: 1))
        }
    }

    private func actions(_ item: ClipboardItem) -> some View {
        HStack(spacing: Spacing.tight) {
            Button(store.isPinned(item.id) ? "Unpin" : "Pin") { store.togglePin(item.id) }
            if item.kind.isOnDisk {
                Button("Show in Finder") { store.revealInFinder(item) }
            }
            Menu("Save as") {
                ForEach(ItemRole.allCases) { role in
                    Button(role == item.role ? "\(role.title) ✓" : role.title) {
                        store.setRole(item.id, to: role)
                    }
                }
            }
            .fixedSize()
            Spacer()
            // Cancel is the explicit undo for this editing session.
            Button("Cancel") {
                isDirty ? cancel(item) : store.closeDetail()
            }
            Button("Save") { save(item) }
                .disabled(!isDirty)
            Button("Save & Paste") {
                save(item)
                store.requestPaste(item)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(Spacing.comfortable)
    }
}

/// The one section label.
///
/// Four places in this file spelled out the same literal - 11pt semibold,
/// tertiary - to head a section, which is four chances for a fifth to arrive
/// slightly different.
///
/// The AI suggestion card's heading is the fifth caller and it is a variant,
/// not a different thing: identical size and weight, deliberately in
/// `accentOnCard` because it is the one heading that names something the app
/// just proposed rather than a part of the document. That is a change of
/// emphasis inside one contract, so it is a parameter here rather than a
/// second label component.
struct SectionLabel: View {
    let text: String
    let theme: AppTheme
    /// Defaults to the quiet tertiary every structural heading uses.
    var tint: Color?

    init(_ text: String, theme: AppTheme, tint: Color? = nil) {
        self.text = text
        self.theme = theme
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint ?? theme.textTertiary)
    }
}
