import AppKit

/// Every in-panel keystroke is decided here.
///
/// Installed as a *local* monitor, so it only sees events while Clip itself is
/// the active app and the panel is key. Returning `nil` swallows the event;
/// returning it lets it fall through, so typing still reaches the search field.
///
/// Nothing here hardcodes a key: each branch asks `ShortcutRegistry` whether the
/// event matches an action, which is what makes every binding user-changeable.
@MainActor
enum KeyRouter {

    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event) ? nil : event
        }
    }

    /// Used by `QABridge` so tests drive the exact same decision logic a real
    /// keystroke does, rather than a parallel copy that could drift.
    static func handleForTesting(_ event: NSEvent) -> Bool { handle(event) }

    // Arrow keys are navigation, not a bindable command.
    private enum Arrow {
        static let left: UInt16 = 123, right: UInt16 = 124
        static let down: UInt16 = 125, up: UInt16 = 126
    }

    /// What kind of text input currently has the keyboard.
    ///
    /// The distinction matters. A **multi-line editor** owns everything except
    /// Escape — space, Return and the arrows are all part of writing. The
    /// **search field** is single-line, so it owns the printable characters but
    /// not navigation: arrowing out of the search box into the list is the whole
    /// point of typing to filter.
    ///
    /// Never track this with a manual flag. `isEditing` was set from a tap
    /// gesture, so focusing a text view any other way left it false — and Space
    /// was then read as Quick Look, slamming the editor shut mid-sentence.
    private enum TextContext { case none, field, editor }

    private static var textContext: TextContext {
        guard let responder = NSApp.keyWindow?.firstResponder else { return .none }
        if let textView = responder as? NSTextView {
            // The field editor is the shared NSTextView an NSTextField borrows.
            if textView.isFieldEditor { return .field }
            // RT-2: SwiftUI removes the `TextEditor` inside `DetailOverlay`
            // (DetailView.swift) with an animated transition when the overlay
            // closes, but it does not resign first responder on the way out -
            // so the window's first responder stayed pointed at that (now
            // detached) NSTextView. The next Option+P or Option+Delete then
            // landed in the `.editor` branch below, which swallows every key
            // but Escape/Command, and both looked like they had silently
            // stopped working - even though they still worked earlier in the
            // run, before the overlay had ever been opened once.
            //
            // The guard for that asked `HistoryStore.shared.isDetailOpen`, on
            // the premise that the detail overlay is the only non-field editor
            // in the app. It is not, and was not on the day it was written:
            // `ActionPanelView`, `SettingsPasteActionsPane` and
            // `MarkdownEditor` (the theme "describe it" sheet) are all
            // non-field NSTextViews, and none of them is the detail overlay.
            // So typing in any of them handed the arrows, Return, Escape and
            // Command+1-9 to the panel's command ladder - the caret would not
            // move, Return pasted, Escape closed the panel underneath.
            //
            // Detachment is the thing to test, and it is directly observable:
            // a view SwiftUI has taken out of the hierarchy has no `window`.
            // A live editor is in the key window's own view tree, whichever
            // editor it happens to be, so this covers the overlay and every
            // other one without naming any of them.
            guard let host = textView.window, host === NSApp.keyWindow else { return .none }
            return .editor
        }
        if responder is NSTextField { return .field }
        return .none
    }

    private static func handle(_ event: NSEvent) -> Bool {
        guard PanelController.shared.isOpen else { return false }

        // A shortcut recorder has the keyboard. Every keystroke belongs to it,
        // including - especially - the ones bound to actions here.
        //
        // This is the bug where recording a shortcut made the panel vanish. It
        // was never a focus problem. The recorder captured the combination and
        // so did this router, so recording `Command+Return` also ran "copy
        // without pasting", which closes the panel, and recording `Command+1`
        // pasted the first item. Whichever monitor AppKit happened to call
        // first decided whether it happened, which is why it looked
        // intermittent.
        if ShortcutRecording.isActive { return false }

        let store = HistoryStore.shared
        let registry = ShortcutRegistry.shared
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.keyCode
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        func hit(_ action: ShortcutAction) -> Bool {
            registry.matches(action, keyCode: key, flags: flags)
        }

        // ---- Give the text what belongs to the text.
        let context = textContext
        // Someone is typing, and NOT in the clipboard panel.
        //
        // Open is not the same as focused. The panel deliberately stays open
        // while Settings is in front - `PanelController.handleFocusLoss` bails
        // outright while a theme preview is running, the Settings binding does
        // not close the panel, and neither does the action panel. In each of
        // those states an editor in another window holds the keyboard, and
        // every key it presses is its own. The `.editor` branch below hands
        // back all but Escape and Command; those two were never handed back,
        // so Escape typed into the theme "describe it" sheet closed the
        // clipboard panel behind it and Command+1 pasted item one into
        // whatever was in front.
        //
        // Deliberately narrow: only while a text responder is live, and only
        // when there is a panel window to compare against. Ordinary panel
        // commands with no editor focused route exactly as they did.
        if context != .none,
           let panelWindow = PanelController.shared.panelWindowForInspect,
           let key = NSApp.keyWindow, key !== panelWindow {
            return false
        }
        if context != .none {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCommand = flags.contains(.command)
            let isEscape = event.keyCode == 53
            // Keys the panel keeps even while a single-line field has focus.
            let isNavigation = [Arrow.up, Arrow.down, Arrow.left, Arrow.right,
                                36, 76, 48].contains(event.keyCode)

            switch context {
            case .editor:
                // Writing: space, Return and arrows all belong to the document.
                guard isEscape || isCommand else { return false }
            case .field:
                // A bound Option or Control shortcut is Clip's, even while the
                // search field has focus. Swallowing everything non-Command here
                // meant Option+P silently did nothing after a search - which is
                // when pinning is most wanted, since searching is how you found
                // the thing you want to pin. Unbound combinations still belong
                // to the field, so Option+P only stops typing π because the user
                // asked for it to mean something else.
                let claimed = flags.contains(.option) || flags.contains(.control)
                guard isEscape || isCommand || isNavigation
                        || (claimed && registry.isBound(keyCode: event.keyCode, flags: flags))
                else { return false }
            case .none:
                break
            }
        }

        // ---- A picker owns the keyboard while it is up. Both are modal, so
        // stray keys cannot paste or delete the thing behind them.
        if store.openingItemID != nil {
            switch key {
            case Arrow.down:  store.stepOpenChoice(1);  return true
            case Arrow.up:    store.stepOpenChoice(-1); return true
            default: break
            }
            if hit(.closePanel) { store.cancelOpenWith(); return true }
            if hit(.pasteSelection) { store.commitOpenWith(); return true }
            return true
        }

        if store.movingItemID != nil {
            switch key {
            case Arrow.down:  store.stepMoveChoice(1);  return true
            case Arrow.up:    store.stepMoveChoice(-1); return true
            default: break
            }
            if hit(.closePanel) { store.cancelMove(); return true }
            if hit(.pasteSelection) { store.commitMove(); return true }
            return true
        }

        // ---- Close: the overlay first, then the panel.
        if hit(.closePanel) {
            if store.isDetailOpen || store.isEditing {
                store.closeDetail()
            } else {
                PanelController.shared.close()
            }
            return true
        }

        // While editing an item's text, everything except Close belongs to the
        // text field.
        if store.isEditing { return false }

        if hit(.openSettings) { SettingsWindowController.shared.show(); return true }
        if hit(.focusSearch) {
            NotificationCenter.default.post(name: .clipFocusSearch, object: nil)
            return true
        }
        if hit(.nextTab)     { store.cycleTab(forward: true);  return true }
        if hit(.previousTab) { store.cycleTab(forward: false); return true }

        // ---- ⌘Z takes back the delete whose notice is still offering Undo.
        //
        // Claimed only while no text responder is live, which is why it is
        // tested against `context` rather than simply on the key: inside a note
        // or the detail editor ⌘Z is the document's own undo, and the `.editor`
        // branch above deliberately hands Command keys to this router, so an
        // ungated check here would have quietly replaced typing undo with row
        // undo. Not a bindable command either: it is the platform's undo key,
        // and it does nothing at all unless a delete is waiting.
        if context == .none, store.pendingDelete != nil, chars == "z",
           flags.contains(.command),
           !flags.contains(.shift), !flags.contains(.option), !flags.contains(.control) {
            store.undoPendingDelete()
            return true
        }

        // ---- ⌘1–9 paste the nth item.
        if PreferencesModel.shared.numberShortcuts,
           flags.contains(.command), !flags.contains(.option),
           let digit = chars.first?.wholeNumberValue, (1...9).contains(digit) {
            if let item = store.item(atVisibleIndex: digit - 1) {
                store.requestPaste(item)
            }
            return true
        }

        // ---- Ordering matters: the more-modified bindings are tested first, so
        // ⌘↩ never falls through to plain ↩.
        if hit(.pastePlain) {
            if let item = store.selectedItem { store.requestPaste(item, plain: true) }
            return true
        }
        if hit(.copyWithoutPasting) {
            if let item = store.selectedItem {
                store.copyOnly(item)
                PanelController.shared.close()
            }
            return true
        }
        // The paste actions work on the selection too, so someone who is
        // already in the panel does not have to leave it to use them.
        if hit(.pasteTranslated) {
            guard store.selectedItem != nil else { return true }
            PasteActionRunner.translateAndPaste(from: .selection)
            return true
        }
        if hit(.pasteWithActions) {
            // The panel is independent, so this does not close the clipboard
            // panel or change what is selected in it. It opens beside it with
            // the selected item as its source.
            ActionPanelController.shared.open()
            if let item = store.selectedItem {
                ActionPanelController.shared.model.use(item)
            }
            return true
        }
        if hit(.clearAll)      { store.clearAll();      return true }
        if hit(.clearUnpinned) { store.clearUnpinned(); return true }
        if hit(.deleteSelection) {
            if let item = store.selectedItem { store.deleteKeepingSelection(item.id) }
            return true
        }
        if hit(.pinSelection) {
            if let item = store.selectedItem { store.togglePin(item.id) }
            return true
        }
        if hit(.pasteSelection) {
            if store.runEmptyAction() { return true }
            // With an action focused, Return runs that action rather than
            // pasting — the same thing clicking it would do. For Move that
            // opens the destination picker, which then takes over the keyboard.
            if store.runFocusedAction() { return true }
            if let item = store.selectedItem ?? store.visibleItems.first {
                store.requestPaste(item)
            }
            return true
        }
        if hit(.quickLook), !store.searchIsFocused, textContext == .none {
            if store.selectedItem != nil { store.toggleDetail() }
            return true
        }

        // Per-paste-action shortcuts when panel is active.
        for pasteAction in PasteActionStore.shared.actions {
            guard let combo = pasteAction.shortcut, !combo.isEmpty else { continue }
            if Shortcut.matches(combo, keyCode: event.keyCode, flags: flags) {
                if store.selectedItem != nil {
                    PasteTransform.shared.run(pasteAction, from: .selection)
                } else {
                    PasteTransform.shared.run(pasteAction, from: .clipboard)
                }
                return true
            }
        }

        // ---- Arrow navigation.
        //
        // ⌥→ / ⌥← always step into and out of the selected item's action row.
        // That has to be the rule in *both* layouts: in a grid, plain → is
        // genuinely needed to move a column, so overloading it would break
        // navigation. Option is the natural "reach further" modifier on macOS,
        // and the footer says so rather than leaving it to be discovered.
        let option = flags.contains(.option)

        switch key {
        case Arrow.down:
            // On an empty curated tab the arrows walk the toolbar, because
            // there is nothing else for them to do.
            if store.stepEmptyAction(1) { return true }
            store.focusedActionIndex = nil
            store.moveSelection(by: store.selectionStride)
            return true
        case Arrow.up:
            if store.stepEmptyAction(-1) { return true }
            store.focusedActionIndex = nil
            store.moveSelection(by: -store.selectionStride)
            return true

        case Arrow.right:
            if option { _ = store.focusNextAction(); return true }
            // In a single-column list, → cannot mean "next column", so it may
            // step into the actions as well.
            if store.selectionStride == 1, store.focusNextAction() { return true }
            store.focusedActionIndex = nil
            store.moveSelection(by: 1)
            return true

        case Arrow.left:
            if option { _ = store.focusPreviousAction(); return true }
            if store.selectionStride == 1, store.focusPreviousAction() { return true }
            store.focusedActionIndex = nil
            store.moveSelection(by: -1)
            return true

        default: return false
        }
    }
}
