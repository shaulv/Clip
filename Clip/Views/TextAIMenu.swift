import SwiftUI

/// The AI menu, for any piece of text.
///
/// The document editor has had this since M-whatever: proofread, summarise,
/// translate, extract, rewrite. Every other place you can type in Clip - the
/// theme assistant, "Describe the theme you want", a paste action's custom
/// instruction - had a bare text box, so the same sentence got the full
/// toolkit in one window and nothing in the next (user, 05/09: "I want the
/// markdown experience to be the same like designs edit in all markdown
/// editors in the app").
///
/// It works on a text BINDING rather than on a `ClipboardItem`, which is what
/// makes it reusable: the item-specific actions (improve this prompt, suggest
/// tags, what changed since the last version) stay in `DetailView`, where the
/// item is.
struct TextAIMenu: View {
    @Binding var text: String
    let theme: AppTheme

    /// Shown in place of a change when the model had nothing to change - a
    /// silent no-op reads as a broken button.
    @State private var verdict: String?
    @State private var working = false
    @ObservedObject private var ai = AIService.shared

    var body: some View {
        HStack(spacing: Spacing.inline) {
            if let verdict {
                Text(verdict)
                    .font(Typography.caption)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
            menu
        }
    }

    @ViewBuilder
    private var menu: some View {
        Menu {
            Button("Check spelling and grammar") {
                run { try await ai.proofread(text)?.body }
            }
            Button("Summarize") { run { try await ai.summarise(text).body } }
            Button("Turn into a prompt template") {
                run { try await ai.makeTemplate(from: text).body }
            }
            Menu("Translate to") {
                ForEach(["English", "Hebrew", "Spanish", "French", "German", "Japanese"],
                        id: \.self) { language in
                    Button(language) { run { try await ai.translate(text, to: language).body } }
                }
            }
            Divider()
            Menu("Extract as") {
                ForEach(StructureFormat.allCases) { format in
                    Button(format.title) {
                        run { try await ai.extractStructure(text, as: format).body }
                    }
                }
            }
            Menu("Rewrite for pasting") {
                ForEach(["Plain text, no formatting", "A bulleted list", "One paragraph",
                         "A commit message", "A polite message"], id: \.self) { how in
                    Button(how) { run { try await ai.transformForPaste(text, instruction: how).body } }
                }
            }
        } label: {
            HStack(spacing: Spacing.inline) {
                if working {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "sparkles")
                }
                Text("AI").font(Typography.captionStrong)
            }
            .foregroundStyle(theme.accentOnCard)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .themeTokens(["accentOnCard"])
    }

    /// Runs one action and lands its result in the bound text.
    ///
    /// The replaced text is not thrown away silently: an action that returns
    /// nothing says so instead of leaving the field looking untouched for a
    /// reason nobody can see.
    private func run(_ work: @escaping () async throws -> String?) {
        guard !working else { return }
        working = true
        verdict = nil
        Task { @MainActor in
            defer { working = false }
            do {
                guard let result = try await work(),
                      !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    verdict = "Nothing to change"
                    return
                }
                text = result
            } catch {
                verdict = error.localizedDescription
            }
        }
    }
}
