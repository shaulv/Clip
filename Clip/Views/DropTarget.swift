import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Makes a tab a place you can drop things.
///
/// Every tab becomes a library you can add to by dragging, not only by copying
/// something first. A drop into a curated tab takes that tab's role, so dragging
/// a markdown file onto Notes makes a note - unless the file is a document Clip
/// recognises on its own, and then the document wins. Filing a design system
/// under Notes because Notes happened to be open is not what dropping it there
/// means.
struct DropReceiver: ViewModifier {

    /// The role a plain drop takes here. Nil on the history tabs, where a drop
    /// is an ordinary clip.
    let role: ItemRole?

    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager
    @State private var isTargeted = false

    private var t: AppTheme { theme.theme }

    func body(content: Content) -> some View {
        content
            // The whole tab body is the target, including the empty space below
            // the last row - aiming at a list of cards is not a game of darts.
            .contentShape(Rectangle())
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(t.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(t.accent.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            Text(dropLabel)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(t.accent)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(t.surfaceBackground,
                                            in: Capsule())
                        )
                        // The state is up for the whole drag, not revealed on
                        // hover: a target you cannot see until you are already
                        // over it is not an invitation.
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isTargeted)
            .onDrop(of: [.fileURL, .plainText, .utf8PlainText],
                    isTargeted: $isTargeted) { providers in
                receive(providers)
                return true
            }
    }

    private var dropLabel: String {
        guard let role else { return "Drop to add to history" }
        return "Drop to add \(role.title.lowercased())s"
    }

    /// Providers arrive asynchronously and out of order, so each one is handled
    /// on its own and the store is only ever touched on the main actor.
    private func receive(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in store.acceptDroppedFile(url, preferredRole: role) }
                }
            } else {
                _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                    guard let text = value as? String else { return }
                    Task { @MainActor in store.acceptDroppedText(text, preferredRole: role) }
                }
            }
        }
    }
}

extension View {
    /// Accepts files and text dropped onto this tab.
    func acceptsDrops(role: ItemRole?) -> some View {
        modifier(DropReceiver(role: role))
    }
}
