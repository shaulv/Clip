import Foundation

/// A per-item action, offered identically to the mouse and the keyboard.
///
/// This type exists so the two never drift: the hover cluster and the arrow-key
/// focus ring are rendered from the same list, in the same order.
enum ItemAction: String, Identifiable, CaseIterable {
    case copy, pin, move, edit, openWith, finder, delete

    var id: String { rawValue }

    func symbol(isPinned: Bool, isPrompt: Bool) -> String {
        switch self {
        case .copy:   return "doc.on.doc"
        case .pin:    return isPinned ? "pin.fill" : "pin"
        // "Move to…" rather than a one-way star: an item can go to any
        // collection, so the icon has to promise a choice, not a toggle.
        case .move:   return "arrow.turn.up.right"
        // "Open with" is a choice of app, so it reads as a launch, not a link.
        case .openWith: return "arrow.up.forward.app"
        case .edit:   return "pencil"
        case .finder: return "folder"
        case .delete: return "trash"
        }
    }

    func label(isPinned: Bool, isPrompt: Bool) -> String {
        switch self {
        case .copy:   return "Copy to the clipboard"
        case .pin:    return isPinned ? "Unpin" : "Pin"
        case .move:   return "Move to…"
        case .openWith: return "Open with…"
        case .edit:   return "Edit"
        case .finder: return "Show in Finder"
        case .delete: return "Delete"
        }
    }

    var isDestructive: Bool { self == .delete }

    /// Only the actions that make sense for this item, in drawing order.
    ///
    /// The order is fixed: **leave, edit, pin, move, delete.** It used to run
    /// pin, move, edit and then append open-with or Finder if the item happened
    /// to have them, so the two actions that take you out of Clip landed in the
    /// middle and moved position depending on the item's type. A toolbar whose
    /// buttons move by item is a toolbar you re-read every time.
    ///
    /// "Go to the thing itself" leads, because it is the only action that leaves
    /// the app. Delete stays last, away from everything else.
    ///
    /// Copy comes before all of it, on every item without exception. Clicking an
    /// item pastes it into whatever Clip can reach, and there are apps Clip
    /// cannot reach - a remote desktop, a VM, a secure field, anything that
    /// refuses a synthesised keystroke. For those the only route is to load the
    /// system pasteboard and press Command-V yourself, and until now the panel
    /// had no button that did just that.
    static func available(for item: ClipboardItem, isPinned: Bool) -> [ItemAction] {
        var out: [ItemAction] = [.copy]
        // Only a link has somewhere else to be opened; only a file is on disk.
        if item.kind == .url { out.append(.openWith) }
        if item.kind.isOnDisk { out.append(.finder) }
        out.append(contentsOf: [.edit, .pin, .move, .delete])
        return out
    }
}
