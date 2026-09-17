import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Whether a shortcut is being recorded right now.
///
/// Deliberately a counter rather than a flag: two recorders can exist at once
/// (an item's editor open behind the Settings window), and a second one ending
/// must not hand the keyboard back while the first is still capturing.
@MainActor
enum ShortcutRecording {
    private static var depth = 0
    static var isActive: Bool { depth > 0 }
    static func begin() { depth += 1 }
    static func end() { depth = max(0, depth - 1) }
    /// Test-facing, so a probe can drive the state without an NSView.
    static func resetForTesting() { depth = 0 }
}

/// Click, then press a combination.
///
/// The previous recorder never worked: it hung a hidden `NSView` off
/// `.background()` and only tried to take first responder in
/// `viewDidMoveToWindow`, which fires long before the user clicks record. This
/// version is the control itself, grabs first responder the moment recording
/// starts, and installs a local key monitor so it captures even when something
/// else holds focus.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var value: String
    @Binding var isRecording: Bool
    // Themed by the caller (defaults to the active theme). Drawing an AppKit
    // control with NSColor.controlBackgroundColor/labelColor ties it to
    // macOS's own light/dark appearance, not Clip's - so a dark preset run
    // under a light system appearance rendered this pill as an unthemed white
    // badge. It now paints the same tokens every SwiftUI row around it does.
    var theme: AppTheme = AppTheme.presets[0]
    /// The window's own chrome theme, when it has one. Preferred over `theme`
    /// because that default is a hardcoded DARK preset and the Shortcuts pane
    /// never passed one: with Settings pinned to Light, every key chip on that
    /// page stayed near-black on a light card. See `clipChromeTheme`.
    @Environment(\.clipChromeTheme) private var chromeTheme

    private var effectiveTheme: AppTheme { chromeTheme ?? theme }

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView()
        v.onChange = { value = $0 }
        v.onRecordingChange = { isRecording = $0 }
        return v
    }

    func updateNSView(_ v: RecorderView, context: Context) {
        v.value = value
        v.theme = effectiveTheme
        v.setRecording(isRecording)
    }

    final class RecorderView: NSView {

        var value: String = "" { didSet { needsDisplay = true } }
        var theme: AppTheme = AppTheme.presets[0] { didSet { needsDisplay = true } }
        var onChange: ((String) -> Void)?
        var onRecordingChange: ((Bool) -> Void)?

        private var recording = false
        private var monitor: Any?
        /// Drawn brighter under the pointer, so the control announces that it
        /// is a control. It looked like a read-only badge of the current
        /// shortcut, and people did not know it could be clicked.
        private var hovering = false { didSet { needsDisplay = true } }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect, .cursorUpdate],
                owner: self))
        }

        override func mouseEntered(with event: NSEvent) { hovering = true }
        override func mouseExited(with event: NSEvent)  { hovering = false }
        override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 26) }

        // MARK: Recording

        func setRecording(_ on: Bool) {
            guard on != recording else { return }
            on ? startRecording() : stopRecording()
        }

        private func startRecording() {
            recording = true
            ShortcutRecording.begin()
            needsDisplay = true
            window?.makeFirstResponder(self)

            // A local monitor guarantees we see the keystroke even if the
            // window hands first responder to a text field behind us.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                guard let self, self.recording else { return event }
                if event.type == .flagsChanged {
                    self.needsDisplay = true
                    return nil
                }
                self.capture(event)
                return nil
            }
        }

        private func stopRecording() {
            recording = false
            ShortcutRecording.end()
            needsDisplay = true
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func capture(_ event: NSEvent) {
            // Escape cancels, leaving the previous value intact.
            if event.keyCode == 53 {
                stopRecording()
                onRecordingChange?(false)
                return
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var parts: [String] = []
            if flags.contains(.control) { parts.append("Control") }
            if flags.contains(.option)  { parts.append("Option") }
            if flags.contains(.shift)   { parts.append("Shift") }
            if flags.contains(.command) { parts.append("Command") }

            guard let name = Self.keyName(for: event) else {
                NSSound.beep()
                NoticeCenter.shared.report("That key can't be recorded", kind: .transient)
                return
            }

            // A shortcut with no modifier would swallow ordinary typing.
            guard !parts.isEmpty else {
                NSSound.beep()
                NoticeCenter.shared.report("Add at least one modifier key", kind: .transient)
                return
            }

            parts.append(name)
            let combo = parts.joined(separator: "+")
            value = combo
            onChange?(combo)
            stopRecording()
            onRecordingChange?(false)
        }

        /// Maps a key event to the canonical name `Shortcut.parse` understands.
        private static func keyName(for event: NSEvent) -> String? {
            switch Int(event.keyCode) {
            case kVK_Space:      return "Space"
            case kVK_Return, kVK_ANSI_KeypadEnter: return "Return"
            case kVK_Tab:        return "Tab"
            case kVK_Delete:     return "Delete"
            case kVK_LeftArrow:  return "Left"
            case kVK_RightArrow: return "Right"
            case kVK_UpArrow:    return "Up"
            case kVK_DownArrow:  return "Down"
            default: break
            }
            // charactersIgnoringModifiers still applies Shift, so "1" arrives as
            // "!". Strip back to the base key via the unshifted character.
            guard let chars = event.charactersIgnoringModifiers?.lowercased(),
                  let c = chars.first else { return nil }
            let name = String(c)
            return Shortcut.keyCode(for: name) != nil ? name : nil
        }

        // MARK: Interaction

        override func mouseDown(with event: NSEvent) {
            if recording {
                stopRecording()
                onRecordingChange?(false)
            } else {
                startRecording()
                onRecordingChange?(true)
            }
        }

        override func resignFirstResponder() -> Bool {
            if recording {
                stopRecording()
                onRecordingChange?(false)
            }
            return true
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            // A recorder torn down mid-capture must not leave the keyboard
            // permanently modal, or the panel would stop responding to every
            // shortcut it owns for the rest of the session. `deinit` is not on
            // the main actor, so the release is hopped there rather than
            // skipped - the leak it prevents is silent and permanent.
            if recording {
                DispatchQueue.main.async { ShortcutRecording.end() }
            }
        }

        // MARK: Drawing

        override func draw(_ dirtyRect: NSRect) {
            let radius: CGFloat = 6
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                    xRadius: radius, yRadius: radius)
            let cardBase = NSColor(hex: theme.cardBackground.hexString) ?? .controlBackgroundColor
            let accentColor = NSColor(hex: theme.accent.hexString) ?? .controlAccentColor
            let borderColor = NSColor(hex: theme.border.hexString) ?? .separatorColor
            let resting = hovering
                ? cardBase.blended(withFraction: 0.12, of: accentColor) ?? cardBase
                : cardBase
            (recording ? accentColor.withAlphaComponent(0.16) : resting).setFill()
            path.fill()
            (recording || hovering ? accentColor : borderColor).setStroke()
            path.lineWidth = recording ? 2 : (hovering ? 1.5 : 1)
            path.stroke()

            let text: String
            if recording {
                let live = Self.liveModifiers()
                text = live.isEmpty ? "Press keys…" : live + "…"
            } else if hovering {
                // Under the pointer the control says what a click will do,
                // rather than repeating what is already bound.
                text = value.isEmpty ? "Click to record" : "Click to change"
            } else {
                text = value.isEmpty ? "Click to record" : Shortcut.display(value)
            }

            let style = NSMutableParagraphStyle()
            style.alignment = .center
            // Tuned against the ground it is actually painted on (`resting`,
            // which already accounts for hover), never asserted from the
            // theme's authored values - a colour is only readable on the
            // ground it is measured on.
            let onCard = theme.accentText(on: theme.cardBackground)
            let textColor: NSColor
            if recording {
                textColor = NSColor(hex: onCard.hexString) ?? accentColor
            } else if value.isEmpty {
                textColor = NSColor(hex: theme.textTertiary.hexString) ?? .secondaryLabelColor
            } else {
                textColor = NSColor(hex: theme.textPrimary.hexString) ?? .labelColor
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: textColor,
                .paragraphStyle: style
            ]
            let size = (text as NSString).size(withAttributes: attrs)
            let rect = NSRect(x: 0, y: (bounds.height - size.height) / 2,
                              width: bounds.width, height: size.height)
            (text as NSString).draw(in: rect, withAttributes: attrs)
        }

        /// Shows modifiers as they are held, so the control feels alive.
        private static func liveModifiers() -> String {
            let f = NSEvent.modifierFlags
            var s = ""
            if f.contains(.control) { s += "⌃" }
            if f.contains(.option)  { s += "⌥" }
            if f.contains(.shift)   { s += "⇧" }
            if f.contains(.command) { s += "⌘" }
            return s
        }
    }
}

/// The global-shortcut row, as it appears in every editor.
///
/// It existed twice, written differently each time: one had a command glyph and
/// no way to clear, the other a text label, a Clear button and an explanatory
/// line. Two copies of a row is two chances to answer "what does this look
/// like?" differently, and they had already diverged. One component, used by
/// both.
struct ShortcutField: View {
    @Binding var value: String
    @Binding var isRecording: Bool
    var error: String?
    var onClear: () -> Void

    @EnvironmentObject var theme: ThemeManager
    @Environment(\.clipChromeTheme) private var chromeTheme
    /// The window's chrome theme where there is one (Settings), the panel's
    /// otherwise: this row appears in both.
    private var t: AppTheme { chromeTheme ?? theme.theme }

    var body: some View {
        HStack(spacing: 8) {
            Text("Global shortcut")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(t.textTertiary)
                .fixedSize()
            // The frame matches the recorder's intrinsic size. An NSView draws
            // its own bounds whatever frame SwiftUI wraps around it, so a
            // smaller one painted over the label to its left.
            ShortcutRecorder(value: $value, isRecording: $isRecording, theme: t)
                .frame(width: 150, height: 26)
            if !value.isEmpty {
                GhostButton("Clear", size: .small, isDestructive: true, theme: t, action: onClear)
                    .help("Remove this shortcut. Nothing changes until you press Save.")
            }
            if let error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(t.destructive)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }
}


