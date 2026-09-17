import Foundation
import AppKit
import Combine
import Carbon.HIToolbox

/// Every action in Clip that can be bound to a key, in one place.
///
/// Having a single registry is what makes honest conflict reporting possible: a
/// clash can name *which* action or item already owns a combination, and offer
/// to take the user straight to it, instead of a dead "already in use".
enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case openPanel
    case pasteSelection
    case copyWithoutPasting
    case pastePlain
    case pinSelection
    case deleteSelection
    case clearUnpinned
    case clearAll
    case nextTab
    case previousTab
    case focusSearch
    case openSettings
    case quickLook
    case closePanel
    case toggleCapture
    /// One key, one translation, no menu.
    case pasteTranslated
    /// One key, the action menu at the pointer.
    case pasteWithActions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openPanel:          return "Open Clip"
        case .pasteSelection:     return "Paste the selection"
        case .copyWithoutPasting: return "Copy without pasting"
        case .pastePlain:         return "Paste as plain text"
        case .pinSelection:       return "Pin or unpin"
        case .deleteSelection:    return "Delete the selection"
        case .clearUnpinned:      return "Clear unpinned"
        case .clearAll:           return "Clear everything"
        case .nextTab:            return "Next tab"
        case .previousTab:        return "Previous tab"
        case .focusSearch:        return "Focus search"
        case .openSettings:       return "Settings"
        case .quickLook:          return "Quick look"
        case .closePanel:         return "Close the panel"
        case .toggleCapture:      return "Pause or resume capture"
        case .pasteTranslated:    return "Paste translated"
        case .pasteWithActions:   return "Paste with an action"
        }
    }

    var detail: String {
        switch self {
        case .openPanel:     return "Shows the panel from any app"
        case .toggleCapture: return "Stops recording new clipboard content"
        case .pasteTranslated:
            return "Translates between your two languages and pastes, from any app"
        case .pasteWithActions:
            return "Opens the action menu at the pointer, from any app"
        default:             return "Works while the panel is open"
        }
    }

    /// `true` when the binding is registered with the system and therefore works
    /// from any app. The rest are handled inside the panel.
    /// Registered with the system, so it works with no panel on screen.
    ///
    /// The two paste actions are global on purpose: the value of the feature is
    /// that it happens where the user is already typing. Making them in-panel
    /// only would have put the panel back in the middle of the one flow that
    /// exists to avoid it.
    var isGlobal: Bool {
        switch self {
        case .openPanel, .toggleCapture, .pasteTranslated, .pasteWithActions: return true
        default: return false
        }
    }

    var defaultShortcut: String {
        switch self {
        case .openPanel:          return "Command+Shift+Space"
        case .pasteSelection:     return "Return"
        case .copyWithoutPasting: return "Command+Return"
        case .pastePlain:         return "Option+Shift+Return"
        case .pinSelection:       return "Option+P"
        case .deleteSelection:    return "Option+Delete"
        case .clearUnpinned:      return "Option+Command+Delete"
        case .clearAll:           return "Shift+Option+Command+Delete"
        case .nextTab:            return "Tab"
        case .previousTab:        return "Shift+Tab"
        case .focusSearch:        return "Command+F"
        case .openSettings:       return "Command+,"
        case .quickLook:          return "Space"
        case .closePanel:         return "Escape"
        case .toggleCapture:      return ""
        // Control+Option leaves the ⌘⇧ space alone, which is where nearly every
        // app's own bindings live.
        case .pasteTranslated:    return "Control+Option+T"
        case .pasteWithActions:   return "Control+Option+A"
        }
    }

    /// In-panel actions may legitimately be a bare key (Return, Escape, Tab);
    /// a system-wide hotkey must carry a modifier or it swallows all typing.
    var requiresModifier: Bool { isGlobal }
}

/// Where a conflicting shortcut already lives, so the UI can link to it.
enum ShortcutOwner: Equatable {
    case action(ShortcutAction)
    case item(UUID, String)
    case pasteAction(UUID, String)
    case system(String)

    var describe: String {
        switch self {
        case .action(let a):     return a.title
        case .item(_, let name): return "the item “\(name)”"
        case .system(let s):     return "macOS (\(s))"
        case .action(let a):            return a.title
        case .item(_, let name):        return "the item “\(name)”"
        case .pasteAction(_, let name): return "the action “\(name)”"
        case .system(let s):            return "macOS (\(s))"
        }
    }
}

struct ShortcutConflict: Equatable {
    let owner: ShortcutOwner
    let message: String
}

/// Holds the current binding for every action, validates changes, and keeps the
/// global ones registered with Carbon.
@MainActor
final class ShortcutRegistry: ObservableObject {

    static let shared = ShortcutRegistry()

    @Published private(set) var bindings: [ShortcutAction: String] = [:]

    private init() { load() }

    // MARK: - Access

    func shortcut(for action: ShortcutAction) -> String {
        bindings[action] ?? action.defaultShortcut
    }

    func matches(_ action: ShortcutAction, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        Shortcut.matches(shortcut(for: action), keyCode: keyCode, flags: flags)
    }

    /// Whether any action claims this combination.
    ///
    /// Used to decide what a focused text field may keep: a combination the user
    /// has bound to a Clip action is Clip's, and anything else is the field's.
    func isBound(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        ShortcutAction.allCases.contains { matches($0, keyCode: keyCode, flags: flags) }
    }

    // MARK: - Validation

    /// Returns nil when `shortcut` is free for `action`, else who owns it.
    func conflict(for shortcut: String, assigning action: ShortcutAction) -> ShortcutConflict? {
        if shortcut.isEmpty { return nil }
        guard let parsed = Shortcut.parse(shortcut) else {
            return ShortcutConflict(owner: .system("unusable"),
                                    message: "That is not a usable key combination.")
        }
        if action.requiresModifier, parsed.modifiers == 0 {
            return ShortcutConflict(owner: .system("no modifier"),
                                    message: "A system-wide shortcut needs at least one modifier, or it would capture ordinary typing.")
        }
        if Shortcut.systemReserved.contains(shortcut) {
            return ShortcutConflict(owner: .system("reserved"),
                                    message: "macOS reserves \(Shortcut.display(shortcut)) and will not hand it over.")
        }
        // Another action.
        for (other, combo) in bindings where other != action && combo == shortcut {
            return ShortcutConflict(owner: .action(other),
                                    message: "Already used by “\(other.title)”.")
        }
        for other in ShortcutAction.allCases
        where other != action && bindings[other] == nil && other.defaultShortcut == shortcut {
            return ShortcutConflict(owner: .action(other),
                                    message: "Already used by “\(other.title)”.")
        }
        // A per-item hotkey.
        if let clash = HistoryStore.shared.items.first(where: { $0.shortcut == shortcut }) {
            return ShortcutConflict(owner: .item(clash.id, clash.displayTitle),
                                    message: "Already used by the item “\(clash.displayTitle)”.")
        }
        // A per-paste-action hotkey.
        if let clash = PasteActionStore.shared.actions.first(where: { $0.shortcut == shortcut }) {
            return ShortcutConflict(owner: .pasteAction(clash.id, clash.title),
                                    message: "Already used by the action “\(clash.title)”.")
        }
        return nil
    }

    func conflictForPasteAction(_ shortcut: String, excluding id: UUID) -> String? {
        if shortcut.isEmpty { return nil }
        guard let parsed = Shortcut.parse(shortcut) else {
            return "That is not a usable key combination."
        }
        if parsed.modifiers == 0 {
            return "A system-wide shortcut needs at least one modifier, or it would capture ordinary typing."
        }
        if Shortcut.systemReserved.contains(shortcut) {
            return "macOS reserves \(Shortcut.display(shortcut)) and will not hand it over."
        }
        for action in ShortcutAction.allCases {
            if self.shortcut(for: action) == shortcut {
                return "Already used by “\(action.title)”."
            }
        }
        if let clash = HistoryStore.shared.items.first(where: { $0.shortcut == shortcut }) {
            return "Already used by the item “\(clash.displayTitle)”."
        }
        if let clash = PasteActionStore.shared.actions.first(where: { $0.shortcut == shortcut && $0.id != id }) {
            return "Already used by the action “\(clash.title)”."
        }
        return nil
    }

    /// Applies a binding, or returns the conflict that stopped it.
    ///
    /// `conflict(for:assigning:)` above only catches what THIS app already
    /// knows about - another Clip action, a per-item hotkey, macOS's fixed
    /// reserved list. It cannot see a combination another app has already
    /// registered with Carbon; only actually trying the registration proves
    /// that, and that only happens inside `applyGlobals()`. Before this, a
    /// refusal there was invisible from here: the binding was saved, the
    /// Shortcuts pane showed it as bound, and the key simply never fired
    /// again - the same silent failure `registerItem` was fixed for on
    /// per-item hotkeys, just not yet on the three system-wide slots.
    @discardableResult
    func assign(_ shortcut: String, to action: ShortcutAction) -> ShortcutConflict? {
        if let conflict = conflict(for: shortcut, assigning: action) { return conflict }
        let previous = bindings[action]
        bindings[action] = shortcut
        persist()
        applyGlobals()
        if let status = osRefusal(for: action) {
            // Refused at the OS level: keep the OLD binding rather than
            // leaving the pane showing a combination that will never fire.
            bindings[action] = previous
            persist()
            applyGlobals()
            let conflict = ShortcutConflict(
                owner: .system("refused"),
                message: "macOS refused that combination: another app owns it.")
            _ = MainActor.assumeIsolated {
                NoticeCenter.shared.report(conflict.message, kind: .transient)
            }
            Database.shared.log("shortcut",
                                "\(action.rawValue) -> \(shortcut) refused, OSStatus \(status)")
            return conflict
        }
        Database.shared.log("shortcut", "\(action.rawValue) -> \(shortcut)")
        return nil
    }

    /// Takes a combination that is already bound to something else, because
    /// the user said so.
    ///
    /// The only caller is a restore whose clash the user approved: the
    /// combination is unbound from whatever holds it here, then assigned. A
    /// system-reserved or unusable combination is still refused - approval is
    /// about this Mac's other bindings, not about what macOS will hand over.
    @discardableResult
    func forceAssign(_ shortcut: String, to action: ShortcutAction) -> ShortcutConflict? {
        for (other, combo) in bindings where other != action && combo == shortcut {
            bindings[other] = ""
        }
        persist()
        return assign(shortcut, to: action)
    }

    /// What Carbon actually did with `action`'s current global registration,
    /// read back from `ShortcutManager`'s own diagnostics rather than trusted
    /// blind. `nil` when `action` is not one of the three global slots, or
    /// when its last attempt succeeded.
    private func osRefusal(for action: ShortcutAction) -> OSStatus? {
        let manager = ShortcutManager.shared
        let status: OSStatus?
        if action == .openPanel {
            status = manager.mainDiagnostic?.status
        } else if action == .toggleCapture {
            status = manager.secondaryDiagnostic?.status
        } else if action.isGlobal {
            status = manager.namedDiagnostics[action.rawValue]?.status
        } else {
            status = nil
        }
        guard let status, status != noErr else { return nil }
        return status
    }

    func reset(_ action: ShortcutAction) {
        bindings[action] = action.defaultShortcut
        persist()
        applyGlobals()
    }

    func resetAll() {
        bindings = [:]
        persist()
        applyGlobals()
    }

    // MARK: - Registration

    /// Registers the system-wide bindings. In-panel ones need no registration —
    /// `KeyRouter` consults this registry directly.
    func applyGlobals() {
        ShortcutManager.shared.set(shortcut: shortcut(for: .openPanel))
        ShortcutManager.shared.setSecondary(shortcut(for: .toggleCapture))
        // Every other global action goes through one generic path, so adding a
        // third and a fourth did not mean a third and fourth special case.
        for action in ShortcutAction.allCases
        where action.isGlobal && action != .openPanel && action != .toggleCapture {
            ShortcutManager.shared.setNamedGlobal(action.rawValue,
                                                  shortcut: shortcut(for: action))
        }
        for action in PasteActionStore.shared.actions {
            guard let combo = action.shortcut, !combo.isEmpty else { continue }
            ShortcutManager.shared.setNamedGlobal(action.id.uuidString, shortcut: combo)
        }
    }

    // MARK: - Storage

    private func persist() {
        let raw = bindings.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: ";")
        Database.shared.setPreference("shortcutBindings", raw)
    }

    /// Re-reads the stored bindings and re-registers the global ones.
    func reload() { load(); applyGlobals() }

    private func load() {
        guard let raw = Database.shared.preference("shortcutBindings"), !raw.isEmpty else { return }
        for pair in raw.split(separator: ";") {
            let bits = pair.split(separator: "=", maxSplits: 1)
            guard bits.count == 2, let action = ShortcutAction(rawValue: String(bits[0])) else { continue }
            bindings[action] = String(bits[1])
        }
    }
}
