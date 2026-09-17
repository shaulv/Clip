import SwiftUI
import AppKit

/// Adding a color by hand, the way the other tabs let you add a note.
///
/// A colors tab with no way to add a color is a viewer, not a library. The
/// affordance has to fit the type though: "+ New note" opens an editor, and the
/// equivalent for a color is not a text box, it is a swatch you can pick and a
/// field that takes whatever people actually paste.
///
/// What it accepts is deliberately generous, because the recogniser already is:
/// `#3CFFD0`, `3cffd0`, `#abc` and `abc` are all the same color, and the hash
/// is punctuation. Anything it cannot read leaves the button disabled and says
/// so, rather than silently adding grey.
struct ColorComposer: View {
    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager

    @State private var isOpen = false
    @State private var hex = ""
    @State private var picked = Color.accentColor
    @State private var name = ""

    private var t: AppTheme { theme.theme }

    /// The canonical form of whatever is typed, or nil when it is not a color.
    private var parsed: String? { HexColor.normalised(hex) }

    var body: some View {
        HStack(spacing: 8) {
            GhostButton("+ Add Color", systemImage: "paintpalette", size: .small, theme: t) {
                isOpen = true
                if hex.isEmpty { hex = Color(nsColor: NSColor(picked)).hexString }
            }

            GhostButton("Paste a Color", systemImage: "doc.on.clipboard", size: .small, theme: t) {
                pasteFromClipboard()
            }
            .help("Reads the hex on the clipboard, with or without the hash")

            // A third way in, beside picking and pasting a hex by hand: pull
            // a palette out of a picture instead of typing digits at all. Its
            // own file (`ImageColorImport.swift`) because picking, extracting,
            // reviewing and trimming a whole palette is a bigger flow than
            // the one-value composer this file already holds.
            ImageColorImportButton()

            Spacer()
        }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) { composer }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The one picker every colour in Clip uses (square, hue, alpha,
            // eyedropper, HEX/RGB/HSL/HSB fields, swatches); the hex it
            // writes is what Add files.
            ColorEditor(hex: Binding(
                get: { HexColor.normalised(hex) ?? "#007AFF" },
                set: { hex = $0 }
            ), title: "Add a color", theme: t, onClose: { isOpen = false })

            Divider().overlay(t.border)

            VStack(alignment: .leading, spacing: Spacing.related) {
                TextField("Name", text: $name, prompt: Text("e.g. Sunset Orange"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    SecondaryButton("Cancel", theme: t) { isOpen = false }
                    Spacer()
                    PrimaryButton("Add", isDisabled: parsed == nil, theme: t) { add() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: ColorEditor.width)
        .background(t.panelBackground)
        .themeTokens(["panelBackground", "border", "radiusControl"])
    }

    private func add() {
        guard let parsed else { return }
        var item = ClipboardItem(kind: .color, text: parsed, hexColor: parsed,
                                 sourceAppName: "Added by hand")
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { item.title = trimmed }
        store.addExisting(item)
        store.select(item.id)
        ColorEditor.remember(parsed)
        hex = ""
        name = ""
        isOpen = false
        NoticeCenter.shared.report("Added \(parsed)", kind: .transient)
    }

    /// Reads a color off the system pasteboard.
    ///
    /// Separate from Add on purpose: the common case is copying a hex out of a
    /// design tool and wanting it filed without a dialogue in the way.
    private func pasteFromClipboard() {
        let text = TestIsolation.board.string(forType: .string) ?? ""
        guard let canonical = HexColor.normalised(text) else {
            NoticeCenter.shared.report(text.isEmpty
                                       ? "There's nothing on the clipboard right now."
                                       : "The clipboard doesn't hold a color Clip can read.",
                                       kind: .transient)
            return
        }
        let item = ClipboardItem(kind: .color, text: canonical, hexColor: canonical,
                                 sourceAppName: "Pasted")
        store.addExisting(item)
        store.select(item.id)
        NoticeCenter.shared.report("Added \(canonical)", kind: .transient)
    }
}
