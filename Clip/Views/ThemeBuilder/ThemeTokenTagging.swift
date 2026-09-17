import SwiftUI
import AppKit

/// M19: "Inspect element" for the theme builder - the user's own words:
/// "add to the theme builder an inspect element option so the user could
/// select it and then select any element or text in the panel with it (same
/// like dev tools in the browser), the moment he selects we need to
/// highlight him the color that controls the element color so the user
/// doesn't need to search and can only select an element and see the color
/// to change quick".
///
/// Three pieces, in this one file:
/// 1. `themeTokens(_:)` - a view modifier every themed view in the panel
///    calls once, naming the tokens that paint it (background first, then
///    foreground). Recorded into `ThemeInspectRegistry` ONLY while inspect
///    mode is on.
/// 2. `ThemeInspectRegistry` - the map from a panel-local point to "what's
///    painted here, with which tokens" - hit-tested by area, innermost
///    (smallest) frame wins.
/// 3. `ThemeInspectController` + the overlay `NSWindow` - the AppKit side
///    that tracks the real pointer over the real panel and swallows real
///    clicks, so "Inspect" behaves like a browser's dev tools rather than a
///    SwiftUI gesture bolted onto one view.

// MARK: - 1. The modifier every themed view declares itself with

private struct ThemeTokenTaggingModifier: ViewModifier {
    let tokens: [String]
    /// One id per attached instance, not per struct - two on-screen cards
    /// tagged from the same `GalleryCard` body are still two separate
    /// registry entries, each with its own frame.
    private let id = UUID()
    @ObservedObject private var registry = ThemeInspectRegistry.shared

    func body(content: Content) -> some View {
        // Zero cost when inspect mode is off: no `GeometryReader` is even
        // attached, so a normal launch (inspect is a theme-builder-only
        // mode) pays nothing here - not a layout pass, not a registry
        // write. Measured directly against the alternative (always
        // attaching the reader and gating only the registry write inside
        // it): that still cost an extra layout pass on every themed view,
        // on every frame, forever.
        if registry.isInspecting {
            content.background(
                GeometryReader { proxy in
                    let rect = proxy.frame(in: .named(ThemeInspectRegistry.coordinateSpaceName))
                    Color.clear
                        .onAppear { registry.register(id: id, tokens: tokens, rect: rect) }
                        .onChange(of: rect) { _, new in registry.register(id: id, tokens: tokens, rect: new) }
                        .onDisappear { registry.unregister(id: id) }
                }
            )
        } else {
            content
        }
    }
}

extension View {
    /// Declares which theme tokens paint this view - background token(s)
    /// first, then foreground - so the theme builder's "Inspect" mode can
    /// answer "what controls this colour" for whatever the pointer lands
    /// on. A view with more than one background state (idle/hover/selected)
    /// or more than one foreground piece (title/secondary/tertiary text,
    /// a kind chip) lists all of them - the point is discovery, not a claim
    /// that every listed token is painting THIS pixel right now.
    ///
    /// Call it once per themed view struct, not once per `foregroundStyle`/
    /// `.background` call inside it - `qa-probe.py`'s coverage gate (section
    /// 146) checks for a `.themeTokens(` call on the ENCLOSING struct, the
    /// same way section 140's `_M11_BUTTON_FILE_ALLOWLIST` checks by file
    /// rather than by call site.
    func themeTokens(_ names: [String]) -> some View {
        modifier(ThemeTokenTaggingModifier(tokens: names))
    }
}

extension ThemeInspectRegistry {

    /// What a view declares when its colour comes from the CONTENT, not the
    /// theme - a saved colour swatch, an emoji, an image thumbnail.
    ///
    /// Inspect used to report nothing at all for these, which reads as "this
    /// element is not covered yet" - the one answer that is never true here.
    /// Naming the reason is the honest version, and no token row can match
    /// this string, so nothing flashes.
    static let notThemed = "not a theme color: this comes from the item itself"
}

// MARK: - 2. The registry

/// Every themed view currently declaring `.themeTokens(...)`, resolved to a
/// frame in the panel's own coordinate space.
///
/// Populated ONLY while `isInspecting` is on - see `ThemeTokenTaggingModifier`
/// above. `@MainActor` because every reader and writer (the tagged views'
/// own `body`, the overlay window's mouse tracking, `QABridge`) already runs
/// on the main thread; this just makes the compiler hold that guarantee.
@MainActor
final class ThemeInspectRegistry: ObservableObject {
    static let shared = ThemeInspectRegistry()
    private init() {}

    /// One themed view's own declared frame + token names.
    struct TaggedFrame {
        let id: UUID
        let tokens: [String]
        var rect: CGRect
        /// When this frame first registered, so two frames of equal area
        /// resolve the same way every time.
        var sequence: Int = 0
    }

    /// The named coordinate space every `.themeTokens` frame is measured
    /// in, rooted on `PanelRootView`'s own top-level container - the same
    /// view `PanelController`'s `NSHostingView` mounts. `NSHostingView` is
    /// flipped (top-left origin), which is also SwiftUI's own convention
    /// for a named coordinate space and for `NSView`'s `isFlipped`, so a
    /// rect measured here already agrees with a point the overlay window's
    /// own (flipped) view reports from a real mouse event - neither side
    /// has to flip an axis to talk to the other.
    static let coordinateSpaceName = "themeInspect"

    /// On while the builder's "Inspect" toggle is on. `.themeTokens`
    /// observes this directly, so every tagged view attaches or detaches
    /// its own `GeometryReader` the instant this flips.
    @Published private(set) var isInspecting = false

    private var frames: [UUID: TaggedFrame] = [:]
    /// Increments once per newly registered frame - see `hitTest`.
    private var sequenceCounter = 0

    /// The tagged frame currently under the pointer - `nil` when the
    /// pointer is over nothing tagged, which is the real "no theme token
    /// here" case (an untagged themed view, or genuinely nothing) the
    /// overlay draws instead of staying silent about.
    @Published private(set) var hoveredID: UUID?
    @Published private(set) var hoveredTokens: [String] = []

    /// What the last click selected: `scrolledToken` is the first token
    /// (what the builder's `ScrollViewReader` scrolls to); `scrollRequestToken`
    /// is bumped on every select, including a second click on the SAME
    /// element, since `.onChange` needs a value that actually changes to
    /// re-run `scrollTo`. `flashedTokens` is the full set - read by
    /// `ColorTokenRow` (flashes its own row) and by `ContrastMatrixView`
    /// (highlights every cell either token appears in) for 600ms.
    @Published private(set) var scrolledToken: String?
    @Published private(set) var scrollRequestToken = 0
    @Published private(set) var flashedTokens: Set<String> = []
    /// How many tokens the last click flashed - `0` for a click that hit
    /// nothing tagged. `QABridge`'s `m19_flashCount`.
    private(set) var lastFlashCount = 0
    private var flashGeneration = 0

    var registeredCount: Int { frames.count }

    func setInspecting(_ on: Bool) {
        guard isInspecting != on else { return }
        isInspecting = on
        if !on {
            // Leaving inspect mode: every tagged view is about to detach its
            // own `GeometryReader` (the modifier's `if` branch flips), which
            // would `unregister` each of these anyway - cleared up front so
            // nothing here reads as still-hovered/still-selected the moment
            // inspect mode is back on.
            frames.removeAll()
            hoveredID = nil
            hoveredTokens = []
            scrolledToken = nil
            flashedTokens = []
            lastFlashCount = 0
        }
    }

    func register(id: UUID, tokens: [String], rect: CGRect) {
        // A re-register (the frame moved) keeps the order it first had: the
        // tie-break is about which view is nested inside which, and that does
        // not change because a row scrolled.
        let order = frames[id]?.sequence ?? nextSequence()
        frames[id] = TaggedFrame(id: id, tokens: tokens, rect: rect, sequence: order)
    }

    private var sequenceCounterValue: Int { sequenceCounter }
    private func nextSequence() -> Int {
        sequenceCounter += 1
        return sequenceCounter
    }

    func unregister(id: UUID) {
        frames.removeValue(forKey: id)
        if hoveredID == id {
            hoveredID = nil
            hoveredTokens = []
        }
    }

    /// The innermost (smallest-area) tagged frame containing `point` - the
    /// same reasoning a browser's dev tools use for "the element under the
    /// pointer" when several tagged ancestors all contain it (a card sits
    /// inside the grid, which sits inside the panel's own background tag).
    func hitTest(_ point: CGPoint) -> TaggedFrame? {
        // A zero-area frame contains no pixel anybody can point at, but it
        // does contain the point mathematically - and being the smallest, it
        // would win every hit test it takes part in. It is excluded rather
        // than ranked last, because "the smallest thing here" must stay a
        // statement about something visible.
        let candidates = frames.values.filter {
            $0.rect.contains(point) && $0.rect.width > 0.5 && $0.rect.height > 0.5
        }
        // Smallest area wins; between two frames of the SAME area the newest
        // registration does, so the answer is stable rather than whatever
        // order a dictionary happened to yield. Two 30x30 glyphs stacked in
        // one row was not hypothetical - the avatar and its badge are exactly
        // that.
        return candidates.min { a, b in
            let areaA = a.rect.width * a.rect.height
            let areaB = b.rect.width * b.rect.height
            if abs(areaA - areaB) > 0.5 { return areaA < areaB }
            return a.sequence > b.sequence
        }
    }

    /// The hovered frame's own rect, for the overlay's outline and for
    /// `QABridge`'s rendered-check command - what actually resolved, not a
    /// re-derivation of it.
    var hoveredRect: CGRect? {
        guard let hoveredID else { return nil }
        return frames[hoveredID]?.rect
    }

    /// Every registered frame, for `QABridge`'s `m19_registryFrames` - a
    /// probe needs this to find, say, "the frame carrying `selectedBackground`"
    /// without the app also exposing raw screen geometry some other way.
    var allFrames: [TaggedFrame] { Array(frames.values) }

    @discardableResult
    func hover(at point: CGPoint) -> TaggedFrame? {
        let hit = hitTest(point)
        hoveredID = hit?.id
        hoveredTokens = hit?.tokens ?? []
        return hit
    }

    /// Click = select. The SAME call a real click on the overlay makes
    /// (`ThemeInspectOverlayView.mouseDown`) and `QABridge`'s `m19_click`
    /// drives directly - one implementation, not two that could disagree.
    func selectHovered() {
        let tokens = hoveredTokens
        guard !tokens.isEmpty else { lastFlashCount = 0; return }
        scrolledToken = tokens.first
        scrollRequestToken += 1
        flashedTokens = Set(tokens)
        lastFlashCount = tokens.count
        flashGeneration += 1
        let generation = flashGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.flashGeneration == generation else { return }
            self.flashedTokens = []
        }
    }
}

// MARK: - 3. The overlay: AppKit tracks the real pointer, swallows real clicks

/// Owns the toggle's own state transition and the overlay window's
/// lifecycle - the AppKit half `ThemeInspectRegistry` (pure model) has none
/// of. A SwiftUI `.onHover`/`.onTapGesture` inside the panel's own view tree
/// cannot do this job: inspect mode has to catch every pointer move and
/// click across the WHOLE panel, including blank space with no gesture
/// recognizer of its own, and a click has to be consumed before the panel's
/// own hit-testing ever sees it - not merely ignored by one view once it
/// gets there. A borderless `NSWindow`, the same frame as the panel and one
/// level above it, catches both at the AppKit layer instead.
@MainActor
final class ThemeInspectController {
    static let shared = ThemeInspectController()
    private init() {}

    private var overlay: ThemeInspectOverlayWindow?
    private var panelMoveObserver: NSObjectProtocol?
    private var escapeMonitor: Any?

    var isOn: Bool { ThemeInspectRegistry.shared.isInspecting }

    func toggle() { setOn(!isOn) }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        ThemeInspectRegistry.shared.setInspecting(on)
        if on { openOverlay() } else { closeOverlay() }
    }

    private func openOverlay() {
        // Headless: there is no real panel window for an overlay to sit
        // over, and every QA bridge command below (`m19_hover`/`m19_click`)
        // drives `ThemeInspectRegistry` directly, with no window involved -
        // the same split `PanelController.enterThemeEditing` already makes.
        guard let panel = PanelController.shared.panelWindowForInspect else { return }

        let window = overlay ?? ThemeInspectOverlayWindow()
        overlay = window
        window.setFrame(panel.frame, display: true)
        window.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        window.orderFront(nil)

        panelMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = PanelController.shared.panelWindowForInspect else { return }
                self.overlay?.setFrame(panel.frame, display: true)
            }
        }

        // Escape leaves inspect mode. A local monitor rather than a SwiftUI
        // `.keyboardShortcut(.escape)` on some view inside the builder：the
        // overlay window itself is plain AppKit with no SwiftUI content to
        // hang a shortcut off, and the panel underneath must not see this
        // key either.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOn else { return event }
            if event.keyCode == 53 { // kVK_Escape
                self.setOn(false)
                return nil
            }
            return event
        }
    }

    private func closeOverlay() {
        overlay?.orderOut(nil)
        if let panelMoveObserver { NotificationCenter.default.removeObserver(panelMoveObserver) }
        panelMoveObserver = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    #if CLIP_TESTING
    /// The overlay's own drawing surface, for `QABridge`'s rendered check
    /// (`m19_renderOverlay`) - `nil` until inspect mode has actually opened
    /// one, exactly like every other testing-only accessor onto a live view.
    var overlayViewForProbe: NSView? { overlay?.overlayView }
    #endif
}

/// Transparent, borderless, ignores nothing (`ignoresMouseEvents = false`)
/// - that refusal to ignore is the whole swallow mechanism: AppKit delivers
/// a click to whichever window is frontmost and accepting events, and while
/// this one is on screen (one level above the real panel, same frame) that
/// window is this one, never the panel underneath.
private final class ThemeInspectOverlayWindow: NSWindow {
    let overlayView = ThemeInspectOverlayView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        contentView = overlayView
    }

    /// Never takes key - stealing focus from the builder or the panel would
    /// be its own bug on top of the one it exists to avoid.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Tracks the pointer, draws the accent outline + token label around
/// whatever is under it, and swallows the click.
final class ThemeInspectOverlayView: NSView {
    private var trackingArea: NSTrackingArea?
    private var lastLocalPoint: CGPoint = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Matches `NSHostingView`'s own flipped, top-left-origin coordinate
    /// system, which is also what `ThemeInspectRegistry.coordinateSpaceName`
    /// measures its frames in - a point from `convert(_:from:)` on this view
    /// lands directly in the registry's own space, with no axis flip.
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        lastLocalPoint = convert(event.locationInWindow, from: nil)
        ThemeInspectRegistry.shared.hover(at: lastLocalPoint)
        needsDisplay = true
    }

    /// The click stops here - it is never forwarded to the panel beneath.
    override func mouseDown(with event: NSEvent) {
        lastLocalPoint = convert(event.locationInWindow, from: nil)
        ThemeInspectRegistry.shared.hover(at: lastLocalPoint)
        ThemeInspectRegistry.shared.selectHovered()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let registry = ThemeInspectRegistry.shared
        guard let rect = registry.hoveredRect else {
            drawLabel("no theme token here", near: lastLocalPoint)
            return
        }
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        drawLabel(registry.hoveredTokens.joined(separator: ", "), near: CGPoint(x: rect.minX, y: rect.minY - 2))
    }

    private func drawLabel(_ text: String, near point: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: " \(text) ", attributes: attrs)
        let size = string.size()
        // Drawn ABOVE the point (this view is flipped, so a smaller y is
        // higher on screen) with a floor at 0 so the label never draws off
        // the top edge for a frame that starts right at the panel's top.
        let origin = CGPoint(x: point.x, y: max(0, point.y - size.height))
        let backgroundRect = NSRect(origin: origin, size: size)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: backgroundRect, xRadius: 3, yRadius: 3).fill()
        string.draw(at: origin)
    }
}
