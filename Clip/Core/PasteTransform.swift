import AppKit
import Carbon.HIToolbox
import Combine

/// Runs one paste action and pastes the result where the user is typing.
///
/// The value of this whole feature is that it happens **on the way out**: the
/// text never comes back into Clip's own interface, it lands in the app that
/// was in front. So the order of operations is the feature, and it is written
/// out here rather than spread over the callers:
///
/// 1. Read the text (the selection, or whatever is on the clipboard).
/// 2. Remember the app to paste into, before anything can change focus.
/// 3. Say that something is happening, near the menu bar, where the pointer is
///    not.
/// 4. Ask the model.
/// 5. **Only on success**, write to the pasteboard and send the keystroke.
///    A failure must leave the clipboard exactly as it was - a half-done
///    transform that ate the user's clipboard is worse than no feature.
@MainActor
final class PasteTransform: ObservableObject {

    static let shared = PasteTransform()

    /// What is in flight, for the indicator. Nil when idle.
    @Published private(set) var runningLabel: String?

    /// The last result, test-facing: what went in, what came out, and whether
    /// the pasteboard was touched.
    struct Outcome: Equatable {
        var instruction: String
        var input: String
        var output: String
        var pasted: Bool
        var failure: String?
    }
    @Published private(set) var lastOutcome: Outcome?

    /// Where the text comes from.
    enum Source: Equatable {
        /// The item selected in the panel, which then closes and pastes.
        case selection
        /// Whatever is on the clipboard right now, with no panel involved.
        case clipboard
    }

    private var task: Task<Void, Never>?

    private init() {}

    // MARK: - Running

    func run(_ action: PasteAction, argument: String? = nil, from source: Source) {
        let store = PasteActionStore.shared
        // Cleared first. A previous run's outcome left standing is a lie about
        // what just happened - and worse, a test reading it cannot tell a
        // refusal apart from a success that happened a minute ago.
        lastOutcome = nil

        guard AIService.shared.isAvailable else {
            // The invitation, not an error: nothing went wrong, the feature is
            // simply not switched on. Reported the same way whether the panel
            // is open to read it or not.
            NoticeCenter.shared.report(
                "Connect a model to use paste actions.",
                remedy: AIGate.sentence)
            CopyConfirmation.shared.show("AI is off")
            lastOutcome = Outcome(instruction: "", input: "", output: "",
                                  pasted: false, failure: "No model connected.")
            return
        }

        let text = sourceText(source)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NoticeCenter.shared.report("There is no text to work with.",
                                       remedy: "Copy something first, or pick an item.")
            lastOutcome = Outcome(instruction: "", input: "", output: "",
                                  pasted: false, failure: "Nothing to transform.")
            return
        }

        // Before anything else can take focus. On the global path this is the
        // app the user is typing in; on the panel path the panel is in front,
        // so it is the app they came from.
        let target: NSRunningApplication? = source == .selection
            ? PanelController.shared.previousApp
            : NSWorkspace.shared.frontmostApplication

        let instruction = store.instruction(for: action, argument: argument)
        let label = store.label(for: action, argument: argument)

        // The panel gets out of the way immediately, so the result appears in
        // the app being typed into rather than behind a floating window. Closing
        // first also means a slow request is not a frozen-looking panel.
        if source == .selection, PanelController.shared.isOpen {
            PanelController.shared.close(restoreFocus: false)
        }

        runningLabel = label
        CopyConfirmation.shared.show("\(action.title)…")

        task?.cancel()
        task = Task { [weak self] in
            defer { self?.runningLabel = nil }
            do {
                let suggestion = try await AIService.shared
                    .transformForPaste(text, instruction: instruction)
                let output = Self.cleaned(suggestion.body)
                guard !output.isEmpty else {
                    throw AIError.malformed("The model replied with nothing at all.")
                }
                guard !Task.isCancelled else { return }
                self?.deliver(output, to: target, input: text, instruction: instruction)
            } catch is CancellationError {
                self?.lastOutcome = Outcome(instruction: instruction, input: text,
                                            output: "", pasted: false,
                                            failure: "Stopped.")
            } catch {
                // The clipboard is untouched, and that is said out loud: the
                // user is about to press ⌘V again out of habit.
                let reading = AIDiagnosis.read(error)
                NoticeCenter.shared.report(reading.message, remedy: reading.remedy)
                CopyConfirmation.shared.show("Could not \(label)")
                self?.lastOutcome = Outcome(instruction: instruction, input: text,
                                            output: "", pasted: false,
                                            failure: reading.message)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        runningLabel = nil
    }

    // MARK: - Delivery

    private func deliver(_ output: String, to target: NSRunningApplication?,
                         input: String, instruction: String) {
        let pb = TestIsolation.board
        pb.clearContents()
        pb.setString(output, forType: .string)

        guard PreferencesModel.shared.pasteAutomatically else {
            // Left on the clipboard, and said so. Silently not pasting is
            // indistinguishable from silently failing.
            CopyConfirmation.shared.show("Ready. Press ⌘V.")
            lastOutcome = Outcome(instruction: instruction, input: input,
                                  output: output, pasted: false, failure: nil)
            return
        }

        // Activating the target app under test would take focus off whatever
        // the user is doing, which is half of the same problem.
        if TestIsolation.sendsRealKeystrokes { target?.activate() }
        // Long enough for the activation to land. Without it the target app is
        // not first responder yet and the keystroke goes nowhere - the same
        // 0.12s the ordinary paste path waits.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            PasteKeystroke.send()
        }
        lastOutcome = Outcome(instruction: instruction, input: input,
                              output: output, pasted: true, failure: nil)
    }

    private func sourceText(_ source: Source) -> String {
        switch source {
        case .selection:
            return HistoryStore.shared.selectedItem?.fullText ?? ""
        case .clipboard:
            return TestIsolation.board.string(forType: .string) ?? ""
        }
    }

    /// Strips what a model adds around an answer even when told not to.
    ///
    /// Not defensive dressing: this text goes straight into someone's document,
    /// so a stray fence or a "Sure, here you go" is wrong output rather than an
    /// untidy one. Kept to the two shapes that actually occur.
    static func cleaned(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            // Drop the opening fence with any language tag, and the closing one.
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A whole answer wrapped in quotes, which happens with short strings.
        if text.count > 1, text.hasPrefix("\""), text.hasSuffix("\""),
           !text.dropFirst().dropLast().contains("\"") {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }
}

/// Where the last per-item hotkey press got to on its way to the keystroke.
///
/// Lived in `TestIsolation` as `lastPasteGate`, which was wrong twice over.
/// Everything in that type is compiled out of the shipped build, so the line
/// the user reads in Shortcut Diagnostics - "paste requested: ..." - was
/// always blank in the app they actually run, on exactly the machine where the
/// answer matters. And a stored property there put a test symbol in the
/// shipped binary.
///
/// The dispatch reaching `onItemHotkey` proves the keystroke arrived; it says
/// nothing about which of the silent early returns between there and the
/// keystroke swallowed it. So this ships, deliberately: it is a diagnostic,
/// not a seam. It holds one short string and nothing can write to it from
/// outside the paste path.
enum PasteTrace {
    nonisolated(unsafe) private(set) static var lastStage = ""

    static func note(_ stage: String) { lastStage = stage }

    static func reset() { lastStage = "" }
}

/// The ⌘V that puts the result into the other app.
///
/// One owner. It existed inside `AppDelegate` as a private helper, and a second
/// copy in the transform path would have been a second place for the modifier
/// flags and the event source to be got subtly wrong.
enum PasteKeystroke {

    /// What became of the last synthesized paste, in plain words.
    ///
    /// The end of the per-item hotkey path, and the only step that can fail
    /// with no error of any kind: `CGEvent.post` returns nothing and the
    /// window server drops the event silently when the app is not trusted.
    /// Recorded so `ShortcutManager.diagnosticReport` can say which of the
    /// two happened instead of leaving a user to guess.
    nonisolated(unsafe) private(set) static var lastOutcome = "no paste attempted yet"
    nonisolated(unsafe) private(set) static var lastAttemptAt: Date?

    private static func record(_ what: String) {
        lastAttemptAt = Date()
        lastOutcome = what
    }

    /// Forgets the last outcome. A diagnostic that can show a stale success
    /// is worse than none: one was observed reporting "posted" before any
    /// keystroke of the run.
    static func resetRecord() {
        lastAttemptAt = nil
        lastOutcome = "no paste attempted yet"
    }

    static func send() {
        PasteTrace.note("keystroke-send")
        // Under test this goes nowhere. A probe that posts ⌘V pastes into
        // whatever the user is typing in - it did, repeatedly, while they were
        // working. What would have been pasted is recorded instead, which is
        // strictly more than the assertion needed anyway.
        guard TestIsolation.sendsRealKeystrokes else {
            record("suppressed (test run)")
            TestIsolation.recordSuppressedPaste(
                TestIsolation.board.string(forType: .string) ?? "")
            return
        }
        // The panel's own paste and ActionPanel's paste both funnel through
        // here, same as the per-item hotkey - so this is the one place that
        // has to check Accessibility rather than every caller doing it.
        // Without the grant, `post` below is silently dropped by the window
        // server: no error, no thrown exception, nothing to catch. Checking
        // first turns that silence into the same notice + alert the per-item
        // hotkey path already gives, via the one gate both paths share.
        guard AccessibilityGate.isTrusted else {
            record("BLOCKED: no Accessibility permission")
            AccessibilityGate.reportBlocked()
            return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else {
            record("FAILED: could not build the key event")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        record("posted Command-V to the frontmost app")
        DispatchQueue.main.async { NoticeCenter.shared.resolve(AccessibilityGate.noticeKey) }
    }
}

/// The two shortcut entry points, in one place.
///
/// Both shortcuts and the menu end up calling `PasteTransform.run`, but the
/// translate key has to *find* its action first, and that lookup was about to
/// be written twice - once for the global hotkey and once for the in-panel
/// binding.
@MainActor
enum PasteActionRunner {

    /// The one-key translation. Uses the configured pair, in whichever
    /// direction the text calls for.
    static func translateAndPaste(from source: PasteTransform.Source) {
        let store = PasteActionStore.shared
        // The configured entry if it is there, so a renamed action keeps its
        // name in the indicator; otherwise a transient one, because turning the
        // menu entry off must not disable the dedicated key that has its own
        // binding in Settings.
        let action = store.actions.first { $0.kind == .translateAuto }
            ?? PasteAction(.translateAuto)
        PasteTransform.shared.run(action, from: source)
    }
}
