import AppKit

/// What the menu bar is currently confirming, and for how long.
///
/// Split from the button on purpose. A test run creates no status item - it must
/// not leave a trace on the menu bar of whoever is using the machine - so with
/// the logic living inside the button there was nothing to test and the feature
/// could only be checked by looking at it. Here the decisions are ordinary state
/// and the button is a thin rendering of them.
@MainActor
final class CopyConfirmation: ObservableObject {

    static let shared = CopyConfirmation()

    /// The text beside the icon, empty when nothing is showing.
    @Published private(set) var title = ""

    /// True while a confirmation is up.
    ///
    /// The icon sits to the *right* of the text while this is true. Left to
    /// itself `NSStatusItem` puts the title after the icon, which pushes the
    /// preview out past it into the next app's space - it reads as belonging to
    /// whatever is next door, and it shoves every other icon along as it comes
    /// and goes.
    var iconTrailing: Bool { !title.isEmpty }

    /// Called whenever the state changes, so the button can redraw.
    var onChange: (() -> Void)?

    private var clearWork: DispatchWorkItem?
    private init() {}

    /// True when the icon should pulse rather than, or as well as, show text.
    @Published private(set) var pulse = 0

    /// Set by the delegate: there is no room for the preview right now.
    ///
    /// The preview is the thing that widens the status item into another app's
    /// menus, so when space is short it is the first thing to go - and the
    /// pulse carries the message instead.
    var isCrowded = false

    /// Shows `text` for the configured number of seconds.
    ///
    /// Two channels, and either can be off. The pulse fires whenever a copy
    /// lands and the user wants it; the text appears only if it is wanted AND
    /// there is somewhere to put it.
    func show(_ text: String) {
        if PreferencesModel.shared.animateStatusItemOnCopy {
            // A counter rather than a flag: two copies in quick succession must
            // read as two pulses, and a Bool set twice is one.
            pulse += 1
            onChange?()
        }
        guard PreferencesModel.shared.showCopyConfirmation else { return }
        guard !(isCrowded && PreferencesModel.shared.keepStatusItemVisible) else { return }
        let clean = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        title = clean
        onChange?()

        // A second copy replaces the first rather than queueing behind it: the
        // confirmation is about the *last* thing copied.
        clearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.clear() }
        clearWork = work
        let seconds = max(1, PreferencesModel.shared.copyConfirmationSeconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    func clear() {
        guard !title.isEmpty else { return }
        title = ""
        onChange?()
    }
}
