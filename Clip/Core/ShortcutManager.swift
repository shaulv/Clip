import Carbon.HIToolbox
import ApplicationServices
import AppKit

/// Registers global hotkeys through Carbon's `RegisterEventHotKey`, which needs
/// no Accessibility permission.
///
/// That last sentence is exactly half the story, and the half that is missing
/// cost a user two "fixes". Carbon delivers the keypress with no permission at
/// all, so registration succeeds, the handler runs and every in-app assertion
/// about the hotkey passes. The *effect* of a per-item hotkey is a synthesized
/// ⌘V posted to `.cghidEventTap`, and THAT needs Accessibility. Without the
/// grant the post is dropped by the window server with no error, no exception
/// and no return value to inspect: the key works and nothing happens, forever.
///
/// macOS ties the grant to the code signature, so re-signing the app under a
/// new identity revokes it silently. Nothing on the paste path checked, so the
/// app had no way to say what was wrong. `AccessibilityGate` below is that
/// check, placed at the one point every per-item hotkey passes through.
///
/// Handles both the panel's own open shortcut and a per-item hotkey for any
/// clip or prompt the user assigns one to.
final class ShortcutManager {

    static let shared = ShortcutManager()

    /// Fired when the main open/close shortcut is pressed.
    var onHotkey: (() -> Void)?
    /// Fired by the secondary global binding (pause / resume capture).
    var onSecondaryHotkey: (() -> Void)?
    /// Fired with the item id when a per-item hotkey is pressed.
    var onItemHotkey: ((UUID) -> Void)?
    /// Fired with the action name for any other system-wide binding.
    var onNamedHotkey: ((String) -> Void)?

    private struct Registration {
        let ref: EventHotKeyRef
        let id: UInt32
    }

    private var mainRegistration: Registration?
    private var secondaryRegistration: Registration?
    private var itemRegistrations: [UUID: Registration] = [:]
    private var idToItem: [UInt32: UUID] = [:]
    /// Named global actions beyond the two originals, by action name.
    private var namedRegistrations: [String: Registration] = [:]
    private var idToName: [UInt32: String] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 3          // 1 and 2 are the two global hotkeys
    private var currentMain = ""

    /// What actually happened to one item's hotkey, kept in the SHIPPED build.
    ///
    /// Three rounds of fixes were reported to a user who could not see any of
    /// them, because every trace this class kept was behind `CLIP_TESTING` and
    /// therefore absent from the app on their Mac. "Registered" and "fired"
    /// are facts about a running process, not about a test binary, so they are
    /// recorded here unconditionally and rendered by `diagnosticReport()`.
    struct ItemDiagnostic {
        var shortcut: String
        /// What `RegisterEventHotKey` returned. `noErr` (0) is the only
        /// success; anything else means Carbon refused the combination and
        /// the key belongs to something else on this Mac.
        var status: OSStatus
        var registeredAt: Date?
        var lastFiredAt: Date?
        /// Where the last press of this key stopped.
        var lastOutcome: String
    }

    private(set) var itemDiagnostics: [UUID: ItemDiagnostic] = [:]

    /// The same fact as `ItemDiagnostic`, for the three system-wide slots.
    ///
    /// Before this, `set(shortcut:)`, `setSecondary` and `setNamedGlobal` each
    /// discarded `RegisterEventHotKey`'s status outright: a combination macOS
    /// had already handed to another app looked exactly like a bound,
    /// working shortcut everywhere in the app, because nothing recorded that
    /// Carbon had refused it.
    struct GlobalDiagnostic {
        var shortcut: String
        var status: OSStatus
        var registeredAt: Date?
    }

    private(set) var mainDiagnostic: GlobalDiagnostic?
    private(set) var secondaryDiagnostic: GlobalDiagnostic?
    private(set) var namedDiagnostics: [String: GlobalDiagnostic] = [:]

    /// What the last `registerAllItems` did, in one line.
    private(set) var lastLaunchReport = "registerAllItems has not run"

    /// The last few hotkey events the Carbon handler saw, newest last.
    ///
    /// This is the single fact that separates "the key never reached the app"
    /// from "it reached the app and died on the way to the keystroke", and it
    /// is the question that could not be answered for the user because the
    /// existing trace was compiled out of their build.
    private(set) var recentDispatches: [String] = []

    private static let signature = OSType(0x434C4950)   // 'CLIP'
    private static let mainID: UInt32 = 1
    private static let secondaryID: UInt32 = 2

    private init() {}

    // MARK: - Event handler

    /// One process-wide handler dispatches every hotkey by its id.
    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return noErr }
            // A shortcut is being recorded: every combination belongs to the
            // recorder, including the ones registered here.
            //
            // This is the other half of the vanishing panel, and the half that
            // was missed. `RegisterEventHotKey` is SYSTEM-WIDE and fires before
            // any in-app monitor, so guarding `KeyRouter` did nothing for it.
            // Recording ⌘⇧Space toggled the panel shut; recording a combination
            // an item already owned pasted that item and closed the panel to do
            // it. Both looked like the recorder closing the window.
            if MainActor.assumeIsolated({ ShortcutRecording.isActive }) {
                // Recorded in EVERY build. A guard that swallows a key and
                // says nothing prints the same diagnostic as a key that never
                // arrived; that is the one distinction the report exists for.
                DispatchQueue.main.async {
                    ShortcutManager.shared.recordDispatch("suppressed-by-recording")
                    #if CLIP_TESTING
                    ShortcutManager.shared.noteRecordingSuppressed()
                    #endif
                }
                return noErr
            }
            let id = hotKeyID.id
            DispatchQueue.main.async {
                let manager = ShortcutManager.shared
                if id == ShortcutManager.mainID {
                    manager.onHotkey?()
                    manager.recordDispatch("main")
                } else if id == ShortcutManager.secondaryID {
                    manager.onSecondaryHotkey?()
                    manager.recordDispatch("secondary")
                } else if let name = manager.idToName[id] {
                    manager.onNamedHotkey?(name)
                    manager.recordDispatch("named:\(name)")
                } else if let itemID = manager.idToItem[id] {
                    // The keystroke arrived. Whether anything can come of it
                    // depends on a permission Carbon never needed, so it is
                    // checked here rather than being discovered as silence.
                    if !AccessibilityGate.isTrusted {
                        manager.noteItemOutcome(itemID, "blocked: no Accessibility permission")
                        manager.recordDispatch("item-blocked:\(itemID.uuidString)")
                        AccessibilityGate.reportBlocked()
                        return
                    }
                    manager.noteItemOutcome(itemID, "delivered to the paste path")
                    manager.onItemHotkey?(itemID)
                    manager.recordDispatch("item:\(itemID.uuidString)")
                } else {
                    // Carbon still holds a registration whose row this
                    // manager no longer has. The keystroke is consumed and
                    // nothing happens, which is indistinguishable from a
                    // dead hotkey unless it is recorded.
                    manager.recordDispatch("orphan:\(id)")
                }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    // MARK: - Main shortcut

    /// Registers the panel's own shortcut. Returns the `OSStatus`
    /// `RegisterEventHotKey` produced, the same way `registerItem` already
    /// does for a per-item hotkey.
    ///
    /// The new combination is registered BEFORE the old one is let go, and
    /// only replaces it on success. This used to unregister first: a
    /// combination macOS refused (because another app already owns it) left
    /// this with NEITHER binding - the key that used to open the panel was
    /// gone, and the one the person just typed never worked either. That is
    /// a dead hotkey shown as bound, silently, every time.
    @discardableResult
    func set(shortcut: String) -> OSStatus {
        guard let parsed = Shortcut.parse(shortcut) else {
            mainDiagnostic = GlobalDiagnostic(shortcut: shortcut, status: -1, registeredAt: nil)
            return -1
        }
        if shortcut == currentMain, mainRegistration != nil { return noErr }
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(parsed.keyCode, parsed.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: Self.mainID),
                                         GetApplicationEventTarget(), 0, &ref)
        mainDiagnostic = GlobalDiagnostic(shortcut: shortcut, status: status,
                                          registeredAt: status == noErr ? Date() : nil)
        guard status == noErr, let ref else { return status }
        if let existing = mainRegistration { UnregisterEventHotKey(existing.ref) }
        mainRegistration = Registration(ref: ref, id: Self.mainID)
        currentMain = shortcut
        return status
    }

    /// A second system-wide binding (pause/resume capture). Empty unbinds it.
    /// Returns the `OSStatus`, and keeps the old binding live on a refusal -
    /// see `set(shortcut:)` above for why registering-then-retiring matters.
    @discardableResult
    func setSecondary(_ shortcut: String) -> OSStatus {
        if shortcut.isEmpty {
            if let existing = secondaryRegistration { UnregisterEventHotKey(existing.ref) }
            secondaryRegistration = nil
            secondaryDiagnostic = nil
            return noErr
        }
        guard let parsed = Shortcut.parse(shortcut), parsed.modifiers != 0 else {
            secondaryDiagnostic = GlobalDiagnostic(shortcut: shortcut, status: -1, registeredAt: nil)
            return -1
        }
        // Already exactly this, and already live: re-registering an
        // unchanged combination while the old registration is still up would
        // have Carbon refuse it as already claimed - by us.
        if secondaryDiagnostic?.shortcut == shortcut, secondaryRegistration != nil { return noErr }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(parsed.keyCode, parsed.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: Self.secondaryID),
                                         GetApplicationEventTarget(), 0, &ref)
        secondaryDiagnostic = GlobalDiagnostic(shortcut: shortcut, status: status,
                                               registeredAt: status == noErr ? Date() : nil)
        guard status == noErr, let ref else { return status }
        if let existing = secondaryRegistration { UnregisterEventHotKey(existing.ref) }
        secondaryRegistration = Registration(ref: ref, id: Self.secondaryID)
        return status
    }

    /// Registers one named system-wide action. Empty unbinds it. Returns the
    /// `OSStatus`, and keeps the old binding live on a refusal.
    ///
    /// Named rather than numbered because the id is an implementation detail
    /// that has to survive a re-registration: binding the same action twice
    /// must replace its hotkey, not leak the old one and answer to both.
    @discardableResult
    func setNamedGlobal(_ name: String, shortcut: String) -> OSStatus {
        if shortcut.isEmpty {
            if let existing = namedRegistrations.removeValue(forKey: name) {
                UnregisterEventHotKey(existing.ref)
                idToName.removeValue(forKey: existing.id)
            }
            namedDiagnostics.removeValue(forKey: name)
            return noErr
        }
        guard let parsed = Shortcut.parse(shortcut), parsed.modifiers != 0 else {
            namedDiagnostics[name] = GlobalDiagnostic(shortcut: shortcut, status: -1, registeredAt: nil)
            return -1
        }
        if namedDiagnostics[name]?.shortcut == shortcut, namedRegistrations[name] != nil { return noErr }
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(parsed.keyCode, parsed.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        namedDiagnostics[name] = GlobalDiagnostic(shortcut: shortcut, status: status,
                                                  registeredAt: status == noErr ? Date() : nil)
        guard status == noErr, let ref else { return status }
        if let existing = namedRegistrations.removeValue(forKey: name) {
            UnregisterEventHotKey(existing.ref)
            idToName.removeValue(forKey: existing.id)
        }
        namedRegistrations[name] = Registration(ref: ref, id: id)
        idToName[id] = name
        return status
    }

    /// Which named globals are currently claimed. Test-facing.
    var registeredGlobalNames: [String] { namedRegistrations.keys.sorted() }

    /// Records what the Carbon handler actually did with one keypress.
    ///
    /// Compiled out of the shipped build. It exists because "the hotkey did
    /// nothing" has three completely different causes that look identical from
    /// outside: the event never arrived, it arrived and was swallowed by the
    /// recording guard, or it arrived and resolved to an id this app no longer
    /// has an item for.
    func recordDispatch(_ what: String) {
        recentDispatches.append("\(Self.stamp(Date()))  \(what)")
        if recentDispatches.count > 20 { recentDispatches.removeFirst() }
        #if CLIP_TESTING
        hotkeyDispatchCount += 1
        lastHotkeyDispatch = what
        #endif
    }

    #if CLIP_TESTING
    /// How many hotkey events the Carbon handler has dispatched, and what the
    /// last one resolved to. Test-facing.
    private(set) var hotkeyDispatchCount = 0
    private(set) var lastHotkeyDispatch = ""
    /// How many hotkey events the recording guard swallowed.
    private(set) var hotkeySuppressedByRecording = 0

    func resetHotkeyDispatchRecord() {
        hotkeyDispatchCount = 0
        lastHotkeyDispatch = ""
        hotkeySuppressedByRecording = 0
    }

    func noteRecordingSuppressed() { hotkeySuppressedByRecording += 1 }

    /// Which items currently have a live Carbon registration. Test-facing,
    /// mirroring `registeredGlobalNames` above: it proves the row exists in
    /// Carbon's table (`itemRegistrations`/`idToItem`), not just that a
    /// shortcut string got saved next to the item. Gated behind CLIP_TESTING
    /// so this never widens the type's API for production code.
    var registeredItemIDs: Set<UUID> { Set(itemRegistrations.keys) }
    #endif

    // MARK: - Per-item shortcuts

    /// Registers (or re-registers) a hotkey for one item. Returns false when the
    /// combination could not be claimed — usually because something else owns it.
    @discardableResult
    func registerItem(_ itemID: UUID, shortcut: String) -> Bool {
        unregisterItem(itemID)
        guard let parsed = Shortcut.parse(shortcut) else { return false }
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(parsed.keyCode, parsed.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        // Recorded whether it worked or not. A refusal here was previously
        // discarded at every call site (`registerAllItems` ignores the return
        // value entirely), so a combination another app already owns produced
        // a hotkey that was never registered, no error anywhere, and a user
        // told three times that it was fixed.
        var diagnostic = itemDiagnostics[itemID]
            ?? ItemDiagnostic(shortcut: shortcut, status: status,
                              registeredAt: nil, lastFiredAt: nil, lastOutcome: "never fired")
        diagnostic.shortcut = shortcut
        diagnostic.status = status
        diagnostic.registeredAt = (status == noErr) ? Date() : nil
        itemDiagnostics[itemID] = diagnostic

        guard status == noErr, let ref else { return false }
        itemRegistrations[itemID] = Registration(ref: ref, id: id)
        idToItem[id] = itemID
        return true
    }

    func unregisterItem(_ itemID: UUID) {
        itemDiagnostics.removeValue(forKey: itemID)
        guard let reg = itemRegistrations.removeValue(forKey: itemID) else { return }
        UnregisterEventHotKey(reg.ref)
        idToItem.removeValue(forKey: reg.id)
    }

    func unregisterAllItems() {
        for (_, reg) in itemRegistrations { UnregisterEventHotKey(reg.ref) }
        itemRegistrations.removeAll()
        idToItem.removeAll()
        itemDiagnostics.removeAll()
    }

    /// Registers every stored per-item shortcut. Called once at launch.
    ///
    /// The return value of `registerItem` used to be discarded here, so a
    /// combination macOS or another app already owned failed silently at every
    /// launch for ever. It is counted now, and the counts are readable from
    /// the shipped app through `diagnosticReport()`.
    @discardableResult
    func registerAllItems(from items: [ClipboardItem]) -> (bound: Int, refused: Int) {
        unregisterAllItems()
        var bound = 0
        var refused = 0
        for item in items {
            if let s = item.shortcut, !s.isEmpty {
                if registerItem(item.id, shortcut: s) { bound += 1 } else { refused += 1 }
            }
        }
        lastLaunchReport = "\(bound) registered, \(refused) refused by macOS, at \(Self.stamp(Date()))"
        // The permission is NOT checked here. It used to be, gated on
        // `bound > 0`, while `AppDelegate.applicationDidFinishLaunching` also
        // checks it unconditionally - two call sites deciding the same thing,
        // which is how they come to disagree. `checkAtLaunch` is silent when
        // the grant is present, so the unconditional one covers this case
        // exactly, and covers the user who has no hotkey bound yet as well.
        // See AppDelegate for the single call.
        return (bound, refused)
    }

    /// "registered", or "refused by macOS (OSStatus N)", or "not registered"
    /// when nothing has ever tried to register this item's key at all -
    /// M8.5's Settings > Shortcuts item rows read this, and QABridge exposes
    /// the identical call for `m8b_itemShortcutRows`, so the row a person
    /// sees and the row a probe asserts on can never independently drift
    /// apart the way M0's own hotkey bug did.
    func itemStatusWord(_ itemID: UUID) -> (registered: Bool, word: String) {
        guard let d = itemDiagnostics[itemID] else { return (false, "not registered") }
        if d.status == noErr { return (true, "registered") }
        return (false, "refused by macOS (OSStatus \(d.status))")
    }

    /// Records where one item's key press ended up, for the report below.
    func noteItemOutcome(_ itemID: UUID, _ outcome: String) {
        guard var diagnostic = itemDiagnostics[itemID] else { return }
        diagnostic.lastFiredAt = Date()
        diagnostic.lastOutcome = outcome
        itemDiagnostics[itemID] = diagnostic
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    /// "   OSStatus: -9878 (macOS refused it, another app owns this key)",
    /// or "" when there is nothing wrong to report.
    private static func refusalSuffix(_ d: GlobalDiagnostic?) -> String {
        guard let d, d.status != noErr else { return "" }
        return "   OSStatus: \(d.status) (macOS refused it, another app owns this key)"
    }

    /// Everything known about the per-item hotkeys, as plain text a user can
    /// read and paste back. This is the answer to "you have told me it is
    /// fixed three times": it is not an assertion in a test binary, it is the
    /// live state of the process on their Mac.
    func diagnosticReport(items: [ClipboardItem]) -> String {
        var out: [String] = []
        out.append("Accessibility permission: \(AccessibilityGate.isTrusted ? "granted" : "not granted, if System Settings shows Clip on, that grant belongs to an older build; use Reset Permission")")
        out.append("Panel shortcut: \(currentMain.isEmpty ? "not set" : Shortcut.display(currentMain)) "
                   + "(\(mainRegistration == nil ? "not registered" : "registered"))"
                   + Self.refusalSuffix(mainDiagnostic))
        out.append("Launch registration: \(lastLaunchReport)")
        // The main/secondary/named globals used to have no row here at all -
        // only per-item hotkeys were ever printed - so a refusal on the
        // pause/resume key or a named action (paste translated, paste with
        // an action) was invisible to the same report that already caught
        // this failure mode for items.
        if let d = secondaryDiagnostic {
            out.append("Pause/resume shortcut: \(Shortcut.display(d.shortcut)) "
                       + "(\(secondaryRegistration == nil ? "not registered" : "registered"))"
                       + Self.refusalSuffix(d))
        } else {
            out.append("Pause/resume shortcut: not set")
        }
        if namedDiagnostics.isEmpty {
            out.append("Named global shortcuts: none")
        } else {
            out.append("Named global shortcuts (\(namedDiagnostics.count)):")
            for (name, d) in namedDiagnostics.sorted(by: { $0.key < $1.key }) {
                out.append("  \(name): \(Shortcut.display(d.shortcut)) "
                           + "(\(namedRegistrations[name] == nil ? "not registered" : "registered"))"
                           + Self.refusalSuffix(d))
            }
        }
        out.append("Recording guard active: \(MainActor.assumeIsolated({ ShortcutRecording.isActive }) ? "yes, every global hotkey is being swallowed by an open shortcut recorder" : "no")")
        out.append("Last paste keystroke: \(PasteKeystroke.lastOutcome)"
                   + (PasteKeystroke.lastAttemptAt.map { " at \(Self.stamp($0))" } ?? ""))
        out.append("")

        let bound = items.filter { ($0.shortcut ?? "").isEmpty == false }
        if bound.isEmpty {
            out.append("No item has a shortcut assigned.")
        } else {
            out.append("Item shortcuts (\(bound.count)):")
            for item in bound {
                let shortcut = Shortcut.display(item.shortcut ?? "")
                guard let d = itemDiagnostics[item.id] else {
                    out.append("  \(shortcut)  \(item.displayTitle)")
                    out.append("      registered: NO (no Carbon row at all)")
                    continue
                }
                let live = itemRegistrations[item.id] != nil
                out.append("  \(shortcut)  \(item.displayTitle)")
                out.append("      registered: \(live ? "yes" : "no")   OSStatus: \(d.status)"
                           + (d.status == noErr ? " (noErr)" : " (macOS refused it, another app owns this key)"))
                out.append("      last fired: "
                           + (d.lastFiredAt.map { Self.stamp($0) } ?? "never")
                           + "   outcome: \(d.lastOutcome)")
            }
        }
        out.append("")
        out.append("Recent hotkey events seen by Clip:")
        if recentDispatches.isEmpty {
            out.append("  none, no global hotkey has reached this app since launch")
        } else {
            for line in recentDispatches { out.append("  \(line)") }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Conflicts

    /// Why a proposed shortcut can't be used, or nil when it is free.
    func conflictReason(for shortcut: String, excluding itemID: UUID?, items: [ClipboardItem]) -> String? {
        guard let parsed = Shortcut.parse(shortcut) else { return "Not a usable combination" }
        // A bare key with no modifiers would swallow ordinary typing.
        if parsed.modifiers == 0 { return "Add at least one modifier" }
        if shortcut == currentMain { return "Already opens Clip" }
        if let clash = items.first(where: { $0.shortcut == shortcut && $0.id != itemID }) {
            return "Used by “\(clash.displayTitle)”"
        }
        // The recorder stores letters lowercase ("Command+q"); the reserved set
        // is written the way people read it. Compare without case or ⌘Q records.
        if Shortcut.systemReserved.contains(where: { $0.lowercased() == shortcut.lowercased() }) {
            return "Reserved by macOS"
        }
        return nil
    }
}

/// Parsing and rendering of shortcut strings like "Command+Shift+Space".
enum Shortcut {

    struct Parsed {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    /// A few combinations macOS owns outright; claiming them silently fails.
    static let systemReserved: Set<String> = [
        "Command+Space", "Command+Tab", "Command+Q", "Command+Option+Escape",
        "Command+Shift+3", "Command+Shift+4", "Command+Shift+5", "Command+Control+Space"
    ]

    /// True when a live key event is exactly this shortcut.
    static func matches(_ shortcut: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard !shortcut.isEmpty, let parsed = parse(shortcut) else { return false }
        guard UInt32(keyCode) == parsed.keyCode else { return false }
        // Compare the exact modifier set, so Cmd+Return never fires plain Return.
        var live: UInt32 = 0
        let f = flags.intersection(.deviceIndependentFlagsMask)
        if f.contains(.command) { live |= UInt32(cmdKey) }
        if f.contains(.shift)   { live |= UInt32(shiftKey) }
        if f.contains(.option)  { live |= UInt32(optionKey) }
        if f.contains(.control) { live |= UInt32(controlKey) }
        return live == parsed.modifiers
    }

    static func parse(_ s: String) -> Parsed? {
        let parts = s.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, !key.isEmpty else { return nil }
        var mods: UInt32 = 0
        for m in parts.dropLast() {
            switch m.lowercased() {
            case "command", "cmd":   mods |= UInt32(cmdKey)
            case "shift":            mods |= UInt32(shiftKey)
            case "option", "opt", "alt": mods |= UInt32(optionKey)
            case "control", "ctrl":  mods |= UInt32(controlKey)
            default: return nil
            }
        }
        guard let code = keyCode(for: key) else { return nil }
        return Parsed(keyCode: code, modifiers: mods)
    }

    /// Renders "Command+Shift+Space" as "⌘⇧Space" for display.
    static func display(_ s: String) -> String {
        guard !s.isEmpty else { return "Not set" }
        let parts = s.split(separator: "+").map(String.init)
        guard let key = parts.last else { return s }
        var out = ""
        for m in parts.dropLast() {
            switch m.lowercased() {
            case "control", "ctrl":  out += "⌃"
            case "option", "opt", "alt": out += "⌥"
            case "shift":            out += "⇧"
            case "command", "cmd":   out += "⌘"
            default: break
            }
        }
        return out + keyGlyph(key)
    }

    private static func keyGlyph(_ key: String) -> String {
        switch key.lowercased() {
        case "space":  return "Space"
        case "return", "enter": return "↩"
        case "tab":    return "⇥"
        case "escape": return "⎋"
        case "delete": return "⌫"
        case "left":   return "←"
        case "right":  return "→"
        case "up":     return "↑"
        case "down":   return "↓"
        default:       return key.uppercased()
        }
    }

    static func keyCode(for name: String) -> UInt32? {
        let map: [String: UInt32] = [
            "space": UInt32(kVK_Space), "return": UInt32(kVK_Return), "enter": UInt32(kVK_Return),
            "tab": UInt32(kVK_Tab), "escape": UInt32(kVK_Escape), "delete": UInt32(kVK_Delete),
            "left": UInt32(kVK_LeftArrow), "right": UInt32(kVK_RightArrow),
            "up": UInt32(kVK_UpArrow), "down": UInt32(kVK_DownArrow),
            "-": UInt32(kVK_ANSI_Minus), "=": UInt32(kVK_ANSI_Equal),
            "[": UInt32(kVK_ANSI_LeftBracket), "]": UInt32(kVK_ANSI_RightBracket),
            ";": UInt32(kVK_ANSI_Semicolon), "'": UInt32(kVK_ANSI_Quote),
            ",": UInt32(kVK_ANSI_Comma), ".": UInt32(kVK_ANSI_Period), "/": UInt32(kVK_ANSI_Slash),
            "\\": UInt32(kVK_ANSI_Backslash), "`": UInt32(kVK_ANSI_Grave),
            "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C),
            "d": UInt32(kVK_ANSI_D), "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F),
            "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H), "i": UInt32(kVK_ANSI_I),
            "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
            "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O),
            "p": UInt32(kVK_ANSI_P), "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R),
            "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T), "u": UInt32(kVK_ANSI_U),
            "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
            "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
            "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2),
            "3": UInt32(kVK_ANSI_3), "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
            "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8),
            "9": UInt32(kVK_ANSI_9)
        ]
        return map[name.lowercased()]
    }
}

/// Whether this app may synthesize the keystroke that a per-item hotkey exists
/// to send, and how it says so when it may not.
///
/// Separate from `ShortcutManager` because registration and delivery are a
/// genuinely different concern from permission: Carbon owns the first, the
/// window server owns the second, and conflating them is what let a dead paste
/// path look like a healthy hotkey for two rounds of fixes.
///
/// The grant is attached to the code signature. Re-signing under a new identity
/// (an ad-hoc signature is a *new identity on every build*) drops it, and macOS
/// does not tell the app. So this is re-read live rather than cached: the user
/// can grant it in System Settings while the app is running, and the very next
/// keypress has to work without a relaunch.
enum AccessibilityGate {

    /// The live answer, never cached.
    static var isTrusted: Bool {
        #if CLIP_TESTING
        if let forced = forcedTrust { return forced }
        #endif
        return AXIsProcessTrusted()
    }

    #if CLIP_TESTING
    /// Lets a probe run the untrusted path on a machine where the grant is
    /// present. Without this the failure is unreachable from a test: the suite
    /// cannot revoke a TCC grant, so it could only ever exercise the branch
    /// that already works. Defaults to nil, meaning "ask the system".
    nonisolated(unsafe) static var forcedTrust: Bool?
    /// How many hotkeys this gate has refused, and when the last one was.
    nonisolated(unsafe) static var blockedCount = 0
    nonisolated(unsafe) static var lastBlockedAt: Date?

    static func resetForTesting() {
        forcedTrust = nil
        blockedCount = 0
        lastBlockedAt = nil
        hasWarnedThisLaunch = false
        versionChangeResetCountForTesting = 0
    }
    #endif

    /// One alert per launch. The notice is refreshed every time, because the
    /// panel's row is the thing someone reads after the alert is gone.
    nonisolated(unsafe) private static var hasWarnedThisLaunch = false

    static let message = "Clip needs Accessibility permission to paste"
    static let remedy = "If System Settings already shows Clip switched on, that grant belongs to an older build of Clip: use Reset Permission, then accept the prompt. Otherwise open System Settings, Privacy & Security, Accessibility, and switch Clip on."

    /// The notice key, so a successful paste can take the row down.
    static let noticeKey = "accessibility"

    /// The repair for the case measured on 02/09/2026: System Settings showed
    /// Clip ON and `AXIsProcessTrusted()` said no, because macOS keys the grant
    /// to the code signature and nineteen rows from earlier builds sat under
    /// the one bundle id. `tccutil reset` for our own bundle needs no admin
    /// rights; the prompt that follows creates a row for THIS signature.
    @MainActor
    static func resetAndAskAgain() {
        let bundle = Bundle.main.bundleIdentifier ?? "com.clip.app"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", bundle]
        do {
            try task.run()
            task.waitUntilExit()
            Database.shared.log("accessibility", "tccutil reset exit \(task.terminationStatus)")
        } catch {
            Database.shared.log("accessibility", "tccutil could not run: \(error.localizedDescription)")
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettingsPane()
    }

    /// The one action every surface offers for this condition.
    @MainActor
    static var resetAction: NoticeCenter.Action {
        NoticeCenter.Action(title: "Reset Permission") { resetAndAskAgain() }
    }

    /// The second action the M8.6 permissions row offers beside it: opening
    /// System Settings directly, for the person whose grant is simply
    /// missing rather than stale - `resetAndAskAgain()` would run `tccutil`
    /// for no reason in that case.
    @MainActor
    static var openSettingsAction: NoticeCenter.Action {
        NoticeCenter.Action(title: "Open Accessibility Settings") { openSettingsPane() }
    }

    #if CLIP_TESTING
    /// How many times `resetAndAskAgainOnVersionChange()` has actually run
    /// the interactive repair (tccutil plus the system prompt) - counted
    /// unconditionally so a probe can prove "once, only when untrusted"
    /// (V4) without ever triggering the real subprocess or prompt itself.
    nonisolated(unsafe) static var versionChangeResetCountForTesting = 0
    #endif

    /// M8.2: "each time we install clip, make sure to delete the last
    /// accessibility entry so you refresh it to the new code." `package.sh
    /// --install` does this for a fresh install from the DMG; this covers
    /// the same repair for whoever updates some other way (Sparkle, a
    /// manual copy) by running it once per version change, and ONLY when
    /// the grant is not already working - resetting a grant that is fine
    /// would just make a person answer the system prompt again for nothing.
    @MainActor
    static func resetAndAskAgainOnVersionChange() {
        guard !isTrusted else { return }
        #if CLIP_TESTING
        versionChangeResetCountForTesting += 1
        // Never the real tccutil reset or system prompt under an automated
        // run: this same call runs every time a probe simulates a version
        // change in section 133 (M3) and elsewhere, and a real prompt there
        // would hang the harness exactly like an un-suppressed Keychain
        // prompt does (see TestIsolation). The counter above is what a
        // probe reads instead.
        guard !QABridge.isEnabled else { return }
        #endif
        resetAndAskAgain()
    }

    /// A per-item hotkey arrived and cannot do anything. Say so.
    static func reportBlocked() {
        #if CLIP_TESTING
        blockedCount += 1
        lastBlockedAt = Date()
        #endif
        MainActor.assumeIsolated {
            NoticeCenter.shared.report(message, remedy: remedy, kind: .persistent,
                                       key: noticeKey, action: resetAction,
                                       stillNeeded: { !AccessibilityGate.isTrusted })
            presentAlertOnce()
        }
    }

    /// Checked at launch when at least one item has a hotkey bound, so the
    /// person is told before they press a key rather than after.
    static func checkAtLaunch(boundItems: Int) {
        // Silent when the grant is already there: a user who has granted it
        // must never be asked again.
        guard !isTrusted else { return }
        MainActor.assumeIsolated {
            // And never during an automated run, headless or not: a modal in a
            // probe is a hang, and a notice in a probe is a false failure.
            guard !QABridge.isEnabled else { return }
            NoticeCenter.shared.report(message, remedy: remedy, kind: .persistent,
                                       key: noticeKey, action: resetAction,
                                       stillNeeded: { !AccessibilityGate.isTrusted })
            // Proactive: the app cannot grant itself the permission, but it
            // can clear its stale entry and make macOS ask, without waiting
            // for anyone to find a button. Once per launch; the alert is the
            // fallback when that has already been tried this launch.
            if boundItems > 0, autoRepairOnce() { return }
            if autoRepairOnce() { return }
            presentAlertOnce()
        }
    }

    /// Runs `resetAndAskAgain` by itself, at most once per launch, when the
    /// permission is missing and something needs it. Returns whether it ran.
    /// The user's words (02/09): "why do i need to click repair and it can't
    /// be proactive fixing it without letting the user know?"
    nonisolated(unsafe) private static var autoRepairedThisLaunch = false
    #if CLIP_TESTING
    nonisolated(unsafe) static var autoRepairCountForTesting = 0
    #endif
    @MainActor
    @discardableResult
    static func autoRepairOnce() -> Bool {
        guard !isTrusted, !autoRepairedThisLaunch else { return false }
        autoRepairedThisLaunch = true
        #if CLIP_TESTING
        autoRepairCountForTesting += 1
        #endif
        guard !QABridge.isEnabled else { return true }
        resetAndAskAgain()
        return true
    }

    /// Opens the exact pane, because "Privacy & Security" has twenty rows and
    /// telling someone to go find one is not a remedy.
    @MainActor
    static func openSettingsPane() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    private static func presentAlertOnce() {
        // A probe must never be interrupted by a modal, and neither must a
        // headless run: both would hang on a dialog nobody can click.
        guard TestIsolation.sendsRealKeystrokes else { return }
        guard !hasWarnedThisLaunch else { return }
        hasWarnedThisLaunch = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = """
        Your shortcuts are being received, but macOS is blocking the paste \
        keystroke they send, so nothing happens.

        \(remedy)
        """
        alert.addButton(withTitle: "Reset Permission")
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: resetAndAskAgain()
        case .alertSecondButtonReturn: openSettingsPane()
        default: break
        }
        // M8.6: "resolved... as soon as trust is detected (check at panel
        // open and after each alert)". `resetAndAskAgain()`'s own system
        // prompt can grant trust before this alert even closes, and
        // "Later"/dismissing it should not leave a resolved condition
        // sitting on screen until the next panel open happens to run.
        recheckAfterAlert()
    }

    /// Takes the Accessibility row down the moment trust is actually true,
    /// rather than waiting for the next panel open to notice. Cheap and
    /// idempotent: `NoticeCenter.resolve` is a no-op when nothing is pending
    /// under this key.
    @MainActor
    static func recheckAfterAlert() {
        guard isTrusted else { return }
        NoticeCenter.shared.resolve(noticeKey)
    }
}
