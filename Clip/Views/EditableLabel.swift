import SwiftUI

/// A label that looks like plain text until the user clicks it, and becomes
/// a borderless, unfilled text field to edit - "the search text should
/// become an input without a background and looks the same, just the text
/// becomes editable like an input" (M8.3, 02/09).
///
/// The idle state is a `Text`. The editing state is a `TextField` styled
/// `.plain` with the SAME font and the SAME foreground colour, so the two
/// states differ only in whether a caret can land there - not in typography,
/// not in a border, not in a fill. Reused wherever a Settings label doubles
/// as a filter, rather than re-implemented per pane, so that behaviour is
/// identical everywhere it appears.
///
/// - Click (or Return with the keyboard focus elsewhere in the pane) begins
///   editing.
/// - Return commits the typed text into `value` and ends editing.
/// - Escape discards the typed text and ends editing, leaving `value`
///   exactly as it was before the click - "Escape reverts".
struct EditableLabel: View {
    /// The committed value. Only changes when Return commits a new draft;
    /// typing while editing changes the LOCAL draft, not this binding, which
    /// is what makes Escape a real revert rather than "clear what's there".
    @Binding var value: String
    var placeholder: String = ""
    var font: Font = .body
    var color: Color = .primary
    var placeholderColor: Color = SettingsPalette.note
    /// Run after Return commits, for a caller that needs to react beyond the
    /// binding itself (PrivacyPane re-runs its app filter from this).
    var onCommit: (() -> Void)? = nil

    /// Lets `qa-probe.py` drive this exact instance without a synthesized
    /// click - see `EditableLabelTestRegistry` below. `nil` in every call
    /// site that has no probe reaching for it; carries no cost there.
    var testID: String? = nil

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField(placeholder, text: $draft, onCommit: commit)
                    .textFieldStyle(.plain)
                    .font(font)
                    .foregroundStyle(color)
                    // No background, no border - the whole point. `.plain`
                    // already paints neither; this is deliberately NOT
                    // `.roundedBorder`, which is what the Privacy pane's
                    // search field used before this component existed.
                    .focused($focused)
                    .onKeyPress(.escape) { revert(); return .handled }
                    .onAppear { focused = true }
                    .onChange(of: focused) { _, isFocused in
                        // Clicking away commits, the way a real text field
                        // would - it must never silently discard a typed
                        // value the user never pressed Escape on.
                        if !isFocused { commit() }
                    }
            } else {
                Text(value.isEmpty ? placeholder : value)
                    .font(font)
                    .foregroundStyle(value.isEmpty ? placeholderColor : color)
                    .contentShape(Rectangle())
                    // M8.4 allowlist (deliberate, not an oversight): no
                    // `.settingsHover()` here. M8.3's whole requirement is
                    // that this looks IDENTICAL to plain text - no
                    // background, no border - until it is actually clicked
                    // into edit mode. Painting a hover wash behind the idle
                    // label would violate that on every mouseover, which is
                    // the one thing this component exists to prevent.
                    .onTapGesture { begin() }
            }
        }
        #if CLIP_TESTING
        .onAppear {
            guard let testID else { return }
            EditableLabelTestRegistry.shared.register(testID, .init(
                isEditing: { isEditing },
                currentValue: { value },
                begin: { begin() },
                type: { draft = $0 },
                commit: { commit() },
                revert: { revert() }
            ))
        }
        .onDisappear {
            guard let testID else { return }
            EditableLabelTestRegistry.shared.unregister(testID)
        }
        #endif
    }

    private func begin() {
        draft = value
        isEditing = true
    }

    private func commit() {
        guard isEditing else { return }
        value = draft
        isEditing = false
        onCommit?()
    }

    private func revert() {
        isEditing = false
    }
}

#if CLIP_TESTING
/// Lets the QA bridge drive one `EditableLabel` instance by its `testID`,
/// without posting a synthesized click into a real window.
///
/// A real click needs a live `NSWindow` with real screen coordinates -
/// exactly what `CLIP_HEADLESS=1` never creates (see `SettingsWindowController
/// .show()`), and what section 137's V5 gate has to prove works in BOTH the
/// headless bridge-state sense and, separately, in a rendered screenshot.
/// This registry is the headless half: every `EditableLabel` that opts in
/// with a `testID` registers a handle here on appear, so the bridge can
/// call `begin()`/`type()`/`commit()`/`revert()` directly and read
/// `isEditing()`/`currentValue()` back, exactly mirroring what a click,
/// typing, and Return/Escape would do. Compiled only into the Testing
/// configuration - production carries no id-keyed registry at all.
@MainActor
final class EditableLabelTestRegistry {
    static let shared = EditableLabelTestRegistry()

    struct Handle {
        var isEditing: () -> Bool
        var currentValue: () -> String
        var begin: () -> Void
        var type: (String) -> Void
        var commit: () -> Void
        var revert: () -> Void
    }

    private var handles: [String: Handle] = [:]

    func register(_ id: String, _ handle: Handle) { handles[id] = handle }
    func unregister(_ id: String) { handles.removeValue(forKey: id) }
    func handle(_ id: String) -> Handle? { handles[id] }

    /// Every currently-mounted instance's live state, for
    /// `QABridge`'s `m8b_editableLabels` - one dictionary rather than a
    /// bespoke state key per `testID`, so a second component adopting
    /// `EditableLabel` needs no QABridge change to be provable the same way.
    func snapshot() -> [String: [String: Any]] {
        handles.mapValues { ["editing": $0.isEditing(), "value": $0.currentValue()] }
    }
}
#endif
