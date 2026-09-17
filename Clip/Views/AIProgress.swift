import SwiftUI

/// A light sweeping across the text a model is reading.
///
/// Until now the only sign that an AI action was running was a two-millimetre
/// spinner inside the AI menu label, which is nowhere near the thing being
/// worked on. Worse, the editor stayed live: you could keep typing into text
/// that was about to be replaced by a rewrite of what it said thirty seconds
/// ago, and lose the edit with no warning.
///
/// So this does two jobs, and the second is the important one. It shows where
/// the work is happening, and it *freezes* what is being worked on for as long
/// as the work lasts.
struct AIProcessing: ViewModifier {
    let active: Bool
    let theme: AppTheme

    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            // Not `.disabled`, which dims the whole thing to unreadable grey and
            // makes it look broken. `allowsHitTesting` keeps the text legible
            // and simply refuses the caret.
            .allowsHitTesting(!active)
            .overlay {
                if active {
                    GeometryReader { geometry in
                        LinearGradient(
                            colors: [.clear, theme.accent.opacity(0.28), .clear],
                            startPoint: .leading, endPoint: .trailing)
                            .frame(width: geometry.size.width * 0.55)
                            .offset(x: phase * geometry.size.width * 1.6)
                            .blendMode(theme.isDark ? .plusLighter : .multiply)
                    }
                    .allowsHitTesting(false)
                    .clipped()
                    .onAppear {
                        phase = -1
                        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                            phase = 1
                        }
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if active {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Working. This text is locked.")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.accentOnCard)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(theme.cardBackground.opacity(0.92), in: Capsule())
                    .overlay(Capsule().strokeBorder(theme.accent.opacity(0.4), lineWidth: 1))
                    .padding(6)
                    .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.15), value: active)
    }
}

extension View {
    /// Marks a view as the text a model is currently reading or rewriting.
    func aiProcessing(_ active: Bool, theme: AppTheme) -> some View {
        modifier(AIProcessing(active: active, theme: theme))
    }
}


/// How much text there is, and - where a model will have to read it - what that
/// costs.
///
/// The token estimate is shown only for the roles a model actually processes
/// whole: a skill, a prompt, a design document. On an ordinary clipping it would
/// be a number with no decision attached to it, and a count nobody acts on is
/// noise.
struct TextMetrics: View {
    let text: String
    let theme: AppTheme
    /// Show the token estimate as well as the character count.
    var showsTokens: Bool = false
    /// The context window to measure against, when one is known.
    var limit: Int?

    private var characters: Int { text.count }
    private var words: Int {
        text.split(whereSeparator: { $0 == " " || $0.isNewline }).count
    }
    private var tokens: Int { AIDiagnosis.estimatedTokens(in: text) }

    /// Amber past three quarters of the window, red past it.
    private var pressure: Color? {
        guard showsTokens, let limit, limit > 0 else { return nil }
        let ratio = Double(tokens) / Double(limit)
        if ratio >= 1 { return theme.destructive }
        if ratio >= 0.75 { return theme.warning }
        return nil
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("\(characters.formatted()) characters")
            Text("·")
            Text("\(words.formatted()) words")
            if showsTokens {
                Text("·")
                Text("~\(tokens.formatted()) tokens")
                    .foregroundStyle(pressure ?? theme.textTertiary)
                    .help("""
                        An estimate, at roughly four characters per token. Clip doesn't \
                        have the model's own vocabulary, so this is a guide to size, not \
                        an exact count.
                        """)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(theme.textTertiary)
    }
}


/// What an AI action came back with, when it was not a suggestion.
///
/// "No spelling or grammar issues found" is a *result*, and it used to be
/// rendered in the same red as "the provider rejected your key". Errors get the
/// destructive color and a remedy; verdicts get a quiet line beside the button
/// that produced them.
struct AIOutcomeLabel: View {
    enum Kind { case verdict, failure }

    let kind: Kind
    let message: String
    var remedy: String?
    let theme: AppTheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: kind == .verdict ? "checkmark.circle" : "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                if let remedy, !remedy.isEmpty {
                    Text(remedy)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(kind == .verdict ? theme.textSecondary : theme.destructive)
    }
}
