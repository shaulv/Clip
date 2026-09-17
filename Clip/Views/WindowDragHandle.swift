import SwiftUI
import AppKit

/// A region that drags the panel, for a window that is not draggable anywhere else.
///
/// The panel used to set `isMovableByWindowBackground`, which asks AppKit to
/// move the window whenever a drag starts on anything that is not an active
/// control. SwiftUI content mostly is not an active control, so starting to
/// drag a card - to reorder it, or to drag it out to another app - moved the
/// whole window instead. The two gestures are the same gesture, and the window
/// kept winning.
///
/// Dragging the panel to reposition it is a real feature: the new origin is
/// remembered. So rather than losing it, it is made deliberate. This view is
/// placed *behind* the header controls, so a click on a control reaches the
/// control and a drag on the empty space beside them moves the window, and
/// nothing in the content area can move it at all.
struct WindowDragHandle: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView { DragRegion() }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragRegion: NSView {

        /// Explicitly false. This view performs the drag itself, and letting
        /// AppKit also treat it as background would be the same ambiguity
        /// again, one layer down.
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            // `performDrag` runs its own event loop until the mouse comes up,
            // which is what makes this a drag rather than a click that happens
            // to move something.
            window?.performDrag(with: event)
        }

        /// Transparent to everything but the drag.
        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only claim the point if no sibling above wants it. SwiftUI draws
            // the header controls above this view, and AppKit hit-tests
            // front-to-back, so a control gets the click first and this only
            // ever sees the gaps between them.
            super.hitTest(point)
        }
    }
}


/// Four corners you can drag the panel by.
///
/// The header strip was the only handle, and it is behind the header controls -
/// so someone who happens to grab it where a button is gets the button, tries
/// again, gets the button again, and concludes the panel cannot be moved. Which
/// is what happened.
///
/// The corners are safe in a way the middle is not: the content area is full of
/// cards that are themselves draggable, and a drag that could mean either
/// "reorder this" or "move the window" has to mean one of them. Nothing is
/// drawn at the corners in the resting state, and a small grip appears on hover
/// so the affordance is discoverable without being decoration.
struct PanelDragCorners: View {
    let theme: AppTheme
    /// Side of the square grab zone.
    private let size: CGFloat = 30

    var body: some View {
        VStack {
            HStack {
                corner(.topLeading)
                Spacer()
                corner(.topTrailing)
            }
            Spacer()
            HStack {
                corner(.bottomLeading)
                Spacer()
                corner(.bottomTrailing)
            }
        }
        // Never intercept anything but a drag in the corner squares themselves.
        .allowsHitTesting(true)
    }

    private func corner(_ alignment: Alignment) -> some View {
        CornerGrip(theme: theme, alignment: alignment)
            .frame(width: size, height: size)
    }
}

private struct CornerGrip: View {
    let theme: AppTheme
    let alignment: Alignment
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: alignment) {
            // The drag region itself, the full square.
            WindowDragHandle()
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(theme.textTertiary)
                .opacity(hovering ? 0.9 : 0)
                .padding(6)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("Drag to move the panel. It opens where you leave it.")
    }
}
