import AppKit
import Combine
import SwiftUI

/// How tall the panel should be, and why.
///
/// Two rules the panel did not previously keep:
///
/// 1. **The top edge never moves.** Rows appear and disappear above the content
///    - the AI suggestion row is there for one tab and not the next - and the
///    panel was centred, so every one of those took the search field with it.
///    Typing into a field that had just moved under the pointer is the whole
///    complaint. Height changes now come off the bottom.
/// 2. **Searching uses the screen.** A search is the moment there is most to
///    show and least reason to keep a tidy 640pt window, so the panel extends
///    to the bottom of the visible frame while there is a query.
///
/// The floor is the height with no AI row: that is the smallest the panel is
/// ever allowed to be, so it can never shrink below what it started as.
@MainActor
final class PanelMetrics: ObservableObject {

    static let shared = PanelMetrics()

    /// The panel with nothing extra in it: no banner, no search.
    static let baseHeight: CGFloat = 640
    /// Every banner currently above the content, by id, with the height it
    /// actually renders at.
    ///
    /// A count of rows times a constant was wrong twice over: a notice is one
    /// line or two depending on whether it carries a remedy, and the setup
    /// promo is several times taller than either. Each banner measures itself
    /// (`reservesPanelHeight`) and the panel adds up what is really there.
    @Published private(set) var bannerHeights: [String: CGFloat] = [:]

    /// What the banners add to the panel, all together.
    var bannersHeight: CGFloat { bannerHeights.values.reduce(0, +) }

    /// True while the notice row is on screen. Kept as a question about the
    /// banner registry rather than a second copy of the same fact.
    var showsNoticeRow: Bool { (bannerHeights[Self.noticeBanner] ?? 0) > 1 }

    /// The banner ids the app reserves height for.
    static let noticeBanner = "notice"
    static let setupBanner = "setup"
    /// True while there is something in the search field.
    @Published var isSearching = false

    private init() {}

    /// Breathing room kept between the panel and the edge of the visible
    /// frame. The same inset the opening position uses, so a panel that grows
    /// to its limit sits where a panel that opened at its limit would.
    static let screenInset: CGFloat = 8

    /// The height the panel wants, given a screen to live on.
    ///
    /// Clamped to the visible frame, so a short screen or a large Dock cannot
    /// produce a panel taller than the space it has.
    /// Takes the visible frame rather than the screen, so the one under test
    /// can be a rectangle nobody owns: a cap that can only be reached on a
    /// small physical display is a cap that never gets tested.
    func height(within visible: NSRect?) -> CGFloat {
        // The tallest the panel may ever be is the visible frame minus the
        // inset on both edges. Handing back the raw visible height made the
        // "grew past the bottom" case unavoidable rather than clamped: the
        // frame then had to be slid or clipped by whoever applied it.
        let available = visible.map { max(0, $0.height - Self.screenInset * 2) }
            ?? Self.baseHeight
        let floor = min(Self.baseHeight, available)

        // Default height, then every banner on top of it, then the cap. Past
        // the cap the panel cannot grow any further, so the banners take the
        // space from the items list instead - the list is the flexible region
        // in the layout, and the banner is the thing that just asked to be
        // read.
        var wanted = Self.baseHeight + bannersHeight
        if isSearching { wanted = available }

        return min(max(wanted, floor), available)
    }

    /// Records what a banner actually measures, and resizes the panel if that
    /// changed anything.
    ///
    /// Sub-pixel noise is ignored: a geometry reader reports a fresh height on
    /// every layout pass, and forwarding each one would set the frame over and
    /// over for changes nobody can see.
    func reserve(_ id: String, _ height: CGFloat) {
        let rounded = (height * 2).rounded() / 2
        guard abs((bannerHeights[id] ?? 0) - rounded) > 0.5 else { return }
        if rounded <= 0.5 { bannerHeights.removeValue(forKey: id) }
        else { bannerHeights[id] = rounded }
        PanelController.shared.applyHeight()
    }

    /// A banner has left the layout.
    func release(_ id: String) {
        guard bannerHeights.removeValue(forKey: id) != nil else { return }
        PanelController.shared.applyHeight()
    }
}


extension View {

    /// Makes the panel reserve this view's real height above the content.
    ///
    /// Applied at the call site, AFTER the padding the banner sits in, so the
    /// reservation covers the space the banner occupies rather than the space
    /// its text occupies. A banner that does not do this squeezes the items
    /// list silently, which is what the setup promo did.
    func reservesPanelHeight(_ id: String) -> some View {
        background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { PanelMetrics.shared.reserve(id, geo.size.height) }
                    .onChange(of: geo.size.height) { _, height in
                        PanelMetrics.shared.reserve(id, height)
                    }
                    .onDisappear { PanelMetrics.shared.release(id) }
            }
        )
    }
}


/// Where the panel opens.
///
/// The panel could always be dragged and it always remembered where it was put,
/// but both facts were invisible: the only handle was a strip of empty space
/// beside the header controls, and the setting reported the outcome ("Where you
/// put it") rather than offering a choice. Someone who could not find the
/// handle had no way to say what they wanted.
///
/// So the intent is now a setting, and the drag is one way of expressing it.
enum PanelPlacement: String, CaseIterable, Identifiable, Codable {
    /// Under the menu-bar icon when clicked, centred when opened by shortcut.
    case automatic
    /// Wherever it was last dragged to.
    case remembered
    /// At the pointer, which is where the eye already is.
    case pointer
    /// Middle of the active screen, however it was opened.
    case centre
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:   return "Automatic"
        case .remembered:  return "Where I put it"
        case .pointer:     return "At the pointer"
        case .centre:      return "Center of the screen"
        case .topLeft:     return "Top left"
        case .topRight:    return "Top right"
        case .bottomLeft:  return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "Under the menu-bar icon when you click it, centered when you use the shortcut."
        case .remembered:
            return "Fixed where you last dragged it. Drag a corner to move it."
        case .pointer:
            return "Opens where the mouse is, so it is never far from the cursor."
        case .centre:
            return "The middle of whichever screen you are working on."
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return "Pinned to that corner of the active screen."
        }
    }

    /// True when this placement is a fixed screen corner.
    var corner: (x: CGFloat, y: CGFloat)? {
        switch self {
        case .topLeft:     return (0, 1)
        case .topRight:    return (1, 1)
        case .bottomLeft:  return (0, 0)
        case .bottomRight: return (1, 0)
        default:           return nil
        }
    }
}
