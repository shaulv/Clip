import AppKit
import ApplicationServices

/// Keeping the menu-bar icon findable when an app's menus crowd it out.
///
/// **What was tried, and what macOS actually allows.** The first version also
/// wrote `NSStatusItem Preferred Position`, rebuilt the item, and hoped for a
/// spot nearer the clock. That is inert, and it was measured to be: the key
/// never survives, because removing a status item makes the system write the
/// real position back over anything put there. An app cannot move its own
/// status item, and code that appears to try is worse than none - it looks
/// like the feature works.
///
/// So this does the two things that do work, and says so:
///
/// 1. **Detect the crowding accurately.** The frontmost app's menu extent is
///    read from the Accessibility API, which Clip already has permission for.
///    An earlier estimate of 420 points was wrong by more than half - Figma's
///    menus run past 1000 - so the icon sat underneath "Window" while the check
///    reported everything fine.
/// 2. **Take as little room as possible while it lasts.** The copy preview is
///    what widens the item into the menus' space, so it is dropped, and the
///    pulse carries the confirmation instead. This is the part that keeps Clip
///    from making its own problem worse.
///
/// The actual fix belongs to the user and is one gesture: Command-drag the icon
/// along the menu bar. That is persistent, and Settings says so rather than
/// leaving them to discover it.
@MainActor
enum StatusItemVisibility {

    /// The autosave name, so the position the user chooses by dragging is
    /// remembered across launches. That is what this key is for; it is not a
    /// way to set the position from code.
    static let autosaveName = "ClipStatusItem"

    /// True when the last check found the icon overlapped.
    private(set) static var isCrowded = false

    /// Is the item's button actually in a place the user can see?
    ///
    /// The test is geometric and deliberately simple: the frontmost app's menus
    /// run from the left, status items from the right, and if our left edge is
    /// left of where the menus end, we are underneath them. `NSMenu`'s own
    /// width is not readable, so the frontmost app's menu bar extent is taken
    /// from the main menu when it is ours and estimated otherwise.
    static func isHidden(_ button: NSStatusBarButton?) -> Bool {
        guard let button, let window = button.window,
              let screen = window.screen ?? NSScreen.main else { return false }

        let frame = window.frame
        // Off the screen entirely: the classic "too many status items" case,
        // where the system simply stops drawing ours.
        if frame.maxX <= screen.frame.minX || frame.minX >= screen.frame.maxX { return true }
        if frame.width <= 1 { return true }

        // Only the x axis is compared. Accessibility reports a top-left origin
        // and window frames a bottom-left one, so the y values are not
        // comparable - but they do not need to be, because both live on the
        // one menu bar row.
        return frame.minX < menuExtent(on: screen)
    }

    /// How far the frontmost app's menus reach from the left of the screen.
    ///
    /// **Measured, not estimated.** The first version guessed 420 points for
    /// another app's menu bar and was wrong by more than half: Figma's menus run
    /// past 1000, so the icon sat at x=930 underneath "Window", the check
    /// happily reported "not hidden", and the whole feature did nothing while
    /// appearing to work. A guess that is wrong in the direction of "everything
    /// is fine" is worse than no check.
    ///
    /// The Accessibility API knows the answer exactly, and Clip already holds
    /// the permission - it needs it to synthesise the paste keystroke. When the
    /// permission is missing the estimate comes back as a fallback, and it is
    /// deliberately generous now rather than optimistic.
    private static func menuExtent(on screen: NSScreen) -> CGFloat {
        if let measured = measuredMenuExtent() { return measured }

        if NSApp.isActive, let main = NSApp.mainMenu {
            var width: CGFloat = 24
            for item in main.items {
                let estimate = CGFloat(item.title.count) * 9 + 20
                width += max(40, estimate)
            }
            return screen.frame.minX + width
        }
        // Erring towards "crowded" on purpose: a false alarm costs the preview
        // text for a moment, a false all-clear costs the icon entirely.
        return screen.frame.minX + 700
    }

    /// The right-hand edge of the frontmost app's last menu title, via AX.
    ///
    /// Returns nil when Accessibility is not granted or the app exposes no menu
    /// bar, which is the caller's signal to fall back.
    private static func measuredMenuExtent() -> CGFloat? {
        guard AXIsProcessTrusted(),
              let front = NSWorkspace.shared.frontmostApplication else { return nil }

        let app = AXUIElementCreateApplication(front.processIdentifier)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString,
                                            &menuBarRef) == .success,
              let menuBar = menuBarRef else { return nil }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar as! AXUIElement,
                                            kAXChildrenAttribute as CFString,
                                            &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement], !children.isEmpty
        else { return nil }

        // The last title is the rightmost one. Walking them all and taking the
        // maximum rather than trusting the order, because a disabled or hidden
        // title can sit anywhere in the array.
        var extent: CGFloat = 0
        for item in children {
            guard let frame = frameOf(item) else { continue }
            extent = max(extent, frame.maxX)
        }
        return extent > 0 ? extent : nil
    }

    private static func frameOf(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString,
                                            &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString,
                                            &sizeRef) == .success
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let positionValue = positionRef, let sizeValue = sizeRef,
              AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: origin, size: size)
    }

    static func noteVisible() { isCrowded = false }

    static func noteCrowded() { isCrowded = true }
}
