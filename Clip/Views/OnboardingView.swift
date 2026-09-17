import SwiftUI
import AppKit
import ApplicationServices

/// The first-run welcome: the shortcut, arrow-key navigation, and the
/// Accessibility permission explained before macOS ever asks for it.
///
/// Three things this deliberately is not:
///
/// - **Not a tour.** Clip is a menu-bar utility, not a product with a funnel.
///   One screen, three things taught, done.
/// - **Not blocking.** Every way out of this window - "Not Now", the
///   permission button, the window's own close button - lands in a fully
///   working app. Nothing here gates `applicationDidFinishLaunching`.
/// - **Not a second design system.** Every colour and the one corner radius
///   come from `AppTheme`, the same tokens the panel and Settings already
///   use, via `ThemeManager.shared` - a first-run screen that looked like a
///   different app would be a worse first impression than none at all.
struct OnboardingView: View {
    @EnvironmentObject var theme: ThemeManager
    @ObservedObject private var checklist = SetupChecklist.shared
    /// Called once the window should go away, whichever button caused it.
    var onDone: () -> Void

    /// Only offered when there is no token this launch already knows about -
    /// a Mac with a saved account gets the persistent restore NOTICE instead
    /// (`SyncManager.offerRestoreIfNeeded`), which does not need a welcome
    /// screen open to be seen. This step is for the Mac that has neither: a
    /// genuinely first install, where the only way back to an existing
    /// library is pasting the token by hand.
    @State private var showingRestore = false
    @State private var restoreToken = ""
    @State private var restoreState: RestoreState = .idle
    @State private var hoveredStep: String?

    private enum RestoreState: Equatable {
        case idle, working, failed(String), done
    }

    private var t: AppTheme { theme.theme }

    /// The window's fixed width; the height follows the content.
    static let width: CGFloat = 460

    private var shortcutDisplay: String {
        Shortcut.display(PreferencesModel.shared.globalShortcut)
    }

    /// The shortcut split into one keycap per modifier symbol plus one for
    /// the key itself: "⌘⇧Space" becomes ["⌘", "⇧", "Space"]. "Not set"
    /// (no shortcut) is a single cap saying so.
    private var keycaps: [String] {
        let modifiers: Set<Character> = ["⌘", "⇧", "⌥", "⌃"]
        var caps: [String] = []
        var key = ""
        for ch in shortcutDisplay {
            if modifiers.contains(ch), key.isEmpty {
                caps.append(String(ch))
            } else {
                key.append(ch)
            }
        }
        if !key.isEmpty { caps.append(key) }
        return caps
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            VStack(alignment: .leading, spacing: Spacing.group) {
                headline
                stepsSection
                if showingRestore { restoreSection }
                footer
            }
            .padding(.horizontal, Spacing.section)
            .padding(.top, Spacing.group)
            .padding(.bottom, Spacing.section)
        }
        .frame(width: Self.width)
        .background(t.panelBackground)
        // Marked here, on the frame that actually reached the screen - not by
        // the code that decided to open the window. A launch killed before
        // this ever draws must still get the welcome on its next try.
        .onAppear { PreferencesModel.shared.hasSeenOnboarding = true }
    }

    // MARK: - Hero

    /// The one signature move of this screen: the shortcut as physical
    /// keycaps under the mark. A menu-bar utility has exactly one thing to
    /// teach on first run - how to summon it - so that is what the hero is.
    private var hero: some View {
        VStack(spacing: Spacing.related) {
            Image(nsImage: AppDelegate.statusImage(for: AppDelegate.markIconName) ?? NSImage())
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(t.accent)
                .frame(width: 40, height: 40)
                .padding(.top, Spacing.loose)
            HStack(spacing: Spacing.tight) {
                ForEach(Array(keycaps.enumerated()), id: \.offset) { _, cap in
                    keycap(cap)
                }
            }
            Text("opens Clip from anywhere")
                .font(Typography.label)
                .foregroundStyle(t.textTertiary)
                .padding(.bottom, Spacing.section)
        }
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [t.accent.opacity(0.20), t.accent.opacity(0.04)],
                           startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(t.border).frame(height: 1)
        }
    }

    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(t.textPrimary)
            .padding(.horizontal, label.count == 1 ? 10 : 12)
            .frame(minWidth: 34, minHeight: 32)
            .background(t.surfaceBackground, in: RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous)
                .strokeBorder(t.border, lineWidth: 1))
            .elevation(Shadows.tooltip)
    }

    // MARK: - Headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: Spacing.inline + 2) {
            Text("Welcome to Clip")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(t.textPrimary)
            Text("Everything you copy, one keystroke away. Arrow keys move through it, Return pastes.")
                .font(Typography.body)
                .foregroundStyle(t.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Steps

    /// The Getting Started checklist, live: a tick the moment a step's real
    /// condition holds. Clicking a row goes where that step is finished and
    /// closes this window - every way out lands in a working app.
    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            SectionLabel("Set up in four steps", theme: t)
            VStack(spacing: 2) {
                ForEach(checklist.steps) { step in
                    stepRow(step)
                }
            }
            .id(checklist.revision)
        }
    }

    private func stepHint(_ step: SetupStep) -> String {
        switch step.id {
        case "accessibility":
            return "macOS will ask for Accessibility. Decline it and pasting stops, silently."
        case "ai":
            return "Translate, rewrite, summarize or turn any clip into code from its own menu."
        case "tabs":
            return "Turn on the tabs you use, order them, pick gallery or list for each."
        default:
            return "Keep your library the same on every Mac you own."
        }
    }

    private func stepRow(_ step: SetupStep) -> some View {
        let done = checklist.isDone(step)
        let hovering = hoveredStep == step.id
        return Button {
            step.deepLink()
            Self.dismiss(onDone: onDone)
        } label: {
            HStack(alignment: .top, spacing: Spacing.related) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(done ? t.success : t.textTertiary)
                    .frame(width: 18, height: 18)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(done ? t.textSecondary : t.textPrimary)
                        .strikethrough(done, color: t.textTertiary)
                    Text(stepHint(step))
                        .font(Typography.label)
                        .foregroundStyle(t.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, Spacing.tight)
            .padding(.horizontal, Spacing.tight + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous))
            .background(hovering ? t.actionHoverFill : .clear,
                        in: RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hoveredStep = $0 ? step.id : (hoveredStep == step.id ? nil : hoveredStep) }
        .help(step.explanation)
    }

    // MARK: - Restore

    /// "Restore from sync": collapsed by default, since most first launches
    /// really are a first launch and a text field asking for a token nobody
    /// has yet would be noise. Opened by the one person it is for.
    private var restoreSection: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
                SectionLabel("Restore from sync", theme: t)
                TextField("Paste your sync token", text: $restoreToken)
                    .textFieldStyle(.plain)
                    .font(Typography.bodyMono)
                    .padding(Spacing.tight)
                    .background(t.surfaceBackground, in: RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous)
                        .strokeBorder(t.border, lineWidth: 1))
                    .disabled(restoreState == .working)
                HStack(spacing: Spacing.tight + 2) {
                    SecondaryButton("Restore", size: .small, theme: t, action: startRestore)
                        .disabled(restoreToken.trimmingCharacters(in: .whitespaces).isEmpty
                                  || restoreState == .working)
                    if restoreState == .working {
                        Text("Restoring…").font(Typography.label).foregroundStyle(t.textTertiary)
                    }
                    if case .failed(let message) = restoreState {
                        Text(message).font(Typography.label).foregroundStyle(t.warning)
                    }
                    if restoreState == .done {
                        Text("Restored.").font(Typography.label).foregroundStyle(t.textSecondary)
                    }
                }
        }
    }

    private func startRestore() {
        let token = restoreToken
        restoreState = .working
        Task { @MainActor in
            let ok = await SyncManager.shared.connect(token: token, merge: true)
            if ok {
                restoreState = .done
            } else {
                restoreState = .failed(SyncManager.shared.lastError ?? "That token wasn't accepted.")
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Spacing.tight + 2) {
            if !showingRestore {
                ClipLink("Have a sync token? Restore your library", size: .small, theme: t) {
                    showingRestore = true
                }
            }
            Spacer()
            GhostButton("Not Now", theme: t) { Self.dismiss(onDone: onDone) }
            PrimaryButton("Continue", theme: t) { Self.acceptAndDismiss(onDone: onDone) }
        }
    }

    // MARK: - Actions
    //
    // Both routes out of this window - "Not Now" and "Continue" - end at the
    // same place: the flag is set and the window goes away. "Continue" does
    // one thing first that "Not Now" never does: it raises the real macOS
    // Accessibility prompt. That is why the two are split into three pieces
    // rather than two: `dismiss(onDone:)` is the shared ending both buttons
    // reach, `requestAccessibilityPermission()` is the ONLY place that calls
    // `AXIsProcessTrustedWithOptions`, and `acceptAndDismiss(onDone:)` is what
    // wires the two together for the real "Continue" button.
    //
    // `QABridge`'s `onboardingNotNow` command calls `dismiss(onDone:)`
    // directly - exactly what "Not Now" does. Its `onboardingContinueDismiss`
    // command ALSO calls `dismiss(onDone:)` directly, never
    // `acceptAndDismiss(onDone:)` - so it proves Continue's dismissal outcome
    // (flag set, window closed) without ever calling
    // `requestAccessibilityPermission()` and raising the real system dialog.
    //
    // Both methods are `static` and take `onDone` as a parameter, rather than
    // being instance methods on this view, because SwiftUI never hands a
    // live `OnboardingView` instance back once its window is up - there is
    // nothing for a bridge command to call an instance method ON. Taking
    // `onDone` explicitly is also what keeps this view honestly decoupled
    // from `OnboardingWindowController`: it doesn't know or care what closing
    // means, only that something happens once dismissal is decided.

    /// "Not Now", and the second half of "Continue": marks onboarding seen
    /// and closes the window. No system prompt of any kind.
    static func dismiss(onDone: () -> Void) {
        PreferencesModel.shared.hasSeenOnboarding = true
        onDone()
    }

    /// "Continue": raises macOS's own Accessibility prompt, having just
    /// explained what it is for, then dismisses exactly like `dismiss(onDone:)`
    /// does. `AXIsProcessTrustedWithOptions` with the prompt key is the
    /// documented way to ask for it on demand rather than waiting for the
    /// first `CGEvent.post` to surface it with no context at all.
    static func acceptAndDismiss(onDone: () -> Void) {
        requestAccessibilityPermission()
        dismiss(onDone: onDone)
    }

    /// The one call in this file that can raise a real system dialog. Never
    /// called from `QABridge` under `CLIP_TESTING` - see the note above.
    private static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}

/// Owns the welcome window's lifecycle, and is the one door back to it from
/// Settings for anyone who dismissed it the first time.
///
/// A real `NSWindow`, not a sheet on the panel: the panel is a nonactivating
/// `NSPanel` built and owned by `PanelController`, elsewhere in this codebase
/// and out of scope for this change. A plain, ordinary, activating window
/// needs none of that panel's custom key-routing to get Tab order and a
/// visible focus ring - both work here for free.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {

    static let shared = OnboardingWindowController()

    private var window: NSWindow?

    private override init() { super.init() }

    /// Shows the welcome, unconditionally. This is the entry point Settings
    /// uses to bring it back for someone who skipped it.
    func show() {
        let window = self.window ?? make()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        // No control starts focused: the first focusable in layout order is
        // the restore link, and a ringed, underlined link is the wrong first
        // thing to read on a welcome. Tab still reaches everything.
        DispatchQueue.main.async { window.makeFirstResponder(nil) }
    }

    /// Shows it only if this Mac has never shown it, and never under the QA
    /// harness - a headless test run must not have a real window steal focus
    /// on launch. Called once, from `AppDelegate.applicationDidFinishLaunching`.
    func presentIfFirstRun() {
        guard !QABridge.isHeadless, !PreferencesModel.shared.hasSeenOnboarding else { return }
        show()
    }

    private func make() -> NSWindow {
        // Sized by the hosted content (the hero band plus a four-row
        // checklist), never by a guessed constant: `fittingSize` is read
        // after the hosting view exists, so a longer shortcut label or a
        // theme with a taller line never clips the footer.
        let hosting = NSHostingView(
            rootView: OnboardingView(onDone: { [weak self] in self?.close() })
                .environmentObject(ThemeManager.shared)
        )
        let size = hosting.fittingSize
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: OnboardingView.width, height: max(size.height, 420)),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // The title string stays for the QA state key ("onboardingWindowOpen"
        // matches on it); on screen the hero band is the title.
        window.title = "Welcome to Clip"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = hosting
        return window
    }

    func close() {
        window?.orderOut(nil)
    }

    /// Covers the path where the user dismisses with the window's own red
    /// close button rather than either in-content button.
    func windowWillClose(_ notification: Notification) {
        PreferencesModel.shared.hasSeenOnboarding = true
    }
}
