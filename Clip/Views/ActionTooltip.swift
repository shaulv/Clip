import SwiftUI

/// The name of the action under the pointer, or under keyboard focus, drawn
/// once at the top of the panel rather than inside the row.
///
/// The first attempt drew the label in an overlay on the button itself. It
/// worked in the gallery, where a card is 150pt tall and there is room, and
/// failed everywhere else: a list row is **44pt**, so a label placed above the
/// icon escaped the row and was covered by the row above it, and one placed
/// below escaped into the row underneath. There is no offset that fits inside
/// 44 points, so no amount of adjusting was going to fix it.
///
/// A tooltip has to be able to leave the thing it describes. So the button only
/// *publishes* what it would say and where it is, and the panel - which is the
/// last view with room and nothing above it to be clipped by - draws it. That
/// also fixes the z-order: from the panel it is drawn after all the content, so
/// nothing can paint over it.
struct ActionTooltipKey: PreferenceKey {

    struct Payload: Equatable {
        let text: String
        let anchor: Anchor<CGRect>

        static func == (a: Payload, b: Payload) -> Bool { a.text == b.text }
    }

    static let defaultValue: Payload? = nil

    /// First one wins. Only one action is highlighted at a time, but during the
    /// frame where the pointer moves between two buttons both can briefly
    /// publish, and picking one is better than flickering between them.
    static func reduce(value: inout Payload?, nextValue: () -> Payload?) {
        value = value ?? nextValue()
    }
}

extension View {

    /// Publishes this view's label and position while `showing` is true.
    func actionTooltip(_ text: String, showing: Bool) -> some View {
        anchorPreference(key: ActionTooltipKey.self, value: .bounds) { anchor in
            showing ? ActionTooltipKey.Payload(text: text, anchor: anchor) : nil
        }
    }

    /// Draws whatever the content published, above everything in it.
    func drawsActionTooltips(theme: AppTheme) -> some View {
        overlayPreferenceValue(ActionTooltipKey.self) { payload in
            GeometryReader { proxy in
                if let payload {
                    ActionTooltipLabel(text: payload.text, theme: theme)
                        .position(Self.place(proxy[payload.anchor], in: proxy.size))
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Above the icon, unless there is no room, in which case below it.
    ///
    /// Clamped horizontally too: the rightmost action is close enough to the
    /// panel edge that a long label would otherwise hang off it.
    private static func place(_ target: CGRect, in size: CGSize) -> CGPoint {
        let gap: CGFloat = 16
        let above = target.minY - gap
        let y = above > 22 ? above : target.maxY + gap
        let half: CGFloat = 70
        let x = min(max(target.midX, half + 6), max(size.width - half - 6, half + 6))
        return CGPoint(x: x, y: y)
    }
}

/// The label itself. Kept separate so the placement above reads as placement.
private struct ActionTooltipLabel: View {
    let text: String
    let theme: AppTheme

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(.regularMaterial)
                Capsule().strokeBorder(theme.border.opacity(0.7), lineWidth: 1)
            }
            .foregroundStyle(theme.textPrimary)
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .transition(.opacity)
    }
}
