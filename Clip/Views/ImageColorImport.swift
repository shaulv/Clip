import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// "From an image": pull a handful of colors out of a picture, let the user
/// trim and touch up the set, then add only what they kept.
///
/// Two ways in, because a color worth saving is just as often a screenshot
/// taken a second ago as it is a file already on disk: choose a file, or
/// paste whatever image is already on the clipboard. Extraction always runs
/// through `ImagePalette` - the one place in this app that turns pixels into
/// colors - so this view is only the picking, reviewing and committing around
/// it, never a second extractor.
///
/// Two ways out: "Add to library" commits whatever is left in the review
/// list, "Cancel" (or dismissing the popover) discards the draft entirely.
/// Nothing is written to the library until the user presses Add - the swatch
/// list lives in `@State` here and nowhere else.
struct ImageColorImportButton: View {
    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager

    @State private var isOpen = false
    @State private var stage: Stage = .picking
    @State private var swatches: [DraftSwatch] = []
    /// Blocking on `.picking` (nothing to review yet), informational on
    /// `.reviewing` (the palette below is still shown, just with a caveat).
    @State private var message: String?

    private var t: AppTheme { theme.theme }

    /// How many colors a fresh extraction offers for review.
    ///
    /// The single-image palette elsewhere in the app (`TypeEditors.swift`,
    /// `ImageActions`) shows 5 - a one-off strip glanced at once for an item
    /// already in the library. This is seeding the library itself, meant to
    /// last, so it goes wider: 8 is still small enough to scan and edit in a
    /// few rows without becoming a wall of near-duplicates, but wide enough
    /// that a real photo or screenshot's actual distinct hues usually all
    /// make the cut rather than being chopped off at five. It is a ceiling,
    /// not a target - k-means already returns fewer when an image simply does
    /// not have this many distinct colors in it.
    private let maxColors = 8

    /// Above this, decoding the file before it is even downsampled risks a
    /// multi-hundred-megabyte allocation on the main thread with nothing to
    /// show for the wait - this view has no progress UI, so the honest answer
    /// to a huge file is to say no rather than freeze. Real photos and
    /// screenshots sit well under a tenth of this.
    private let maxFileBytes = 75_000_000

    private enum Stage { case picking, reviewing }

    var body: some View {
        GhostButton("From an Image", systemImage: "photo", size: .small, theme: t) {
            reset()
            isOpen = true
        }
        .help("Pull colors out of a picture, then choose which ones to keep")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            Group {
                switch stage {
                case .picking:   pickingView
                case .reviewing: reviewingView
                }
            }
            .padding(16)
            .frame(width: stage == .reviewing ? 320 : 300)
        }
    }

    // MARK: - Stage 1: pick a source

    private var pickingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Colors from an image")
                .font(.system(size: 13, weight: .semibold))
            Text("Choose a file, or paste an image already on your clipboard.")
                .font(.system(size: 11))
                .foregroundStyle(t.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                SecondaryButton("Choose File…", size: .small, theme: t) { chooseFile() }
                SecondaryButton("Paste Image", size: .small, theme: t) { pasteImage() }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(t.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                SecondaryButton("Cancel", size: .small, theme: t) { isOpen = false }
            }
        }
    }

    // MARK: - Stage 2: review, edit, trim

    private var reviewingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick what to keep")
                .font(.system(size: 13, weight: .semibold))

            if let message {
                // Informational here, never blocking - the swatches below are
                // real regardless, this just explains why there may be fewer
                // of them than `maxColors`.
                Text(message)
                    .font(.caption)
                    .foregroundStyle(t.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if swatches.isEmpty {
                Text("Nothing left to add. Pick another image, or cancel.")
                    .font(.caption)
                    .foregroundStyle(t.textTertiary)
            } else {
                VStack(spacing: 6) {
                    ForEach(swatches) { swatch in
                        swatchRow(swatch)
                    }
                }
            }

            HStack {
                SecondaryButton("Cancel", size: .small, theme: t) { cancel() }
                Spacer()
                Text(swatches.isEmpty ? "" : "\(swatches.count) will be added")
                    .font(.caption)
                    .foregroundStyle(t.textTertiary)
                PrimaryButton("Add to Library", size: .small, isDisabled: swatches.isEmpty, theme: t) {
                    commit()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func swatchRow(_ swatch: DraftSwatch) -> some View {
        HStack(spacing: 8) {
            // The picker and the hex field are two views of one value, the
            // same contract the manual composer (`ColorComposer`) uses -
            // nudging the wheel updates the digits and typing digits moves
            // the wheel, so "quick edit" works from whichever the user
            // reaches for.
            ColorPicker("", selection: Binding(
                get: { swatch.color },
                set: { update(swatch.id, color: $0) }
            ), supportsOpacity: false)
            .labelsHidden()

            TextField("Hex", text: Binding(
                get: { swatch.hex },
                set: { update(swatch.id, hex: $0) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 96)

            Spacer(minLength: 0)

            RemoveSwatchButton(theme: t) { remove(swatch.id) }
        }
    }

    // MARK: - Bringing an image in

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else {
            message = "Couldn't read that file."
            return
        }
        ingest(data)
    }

    private func pasteImage() {
        let pb = TestIsolation.board
        let types = pb.types ?? []
        guard !types.isEmpty else {
            message = "The clipboard is empty."
            return
        }
        guard types.contains(.png) || types.contains(.tiff) || types.contains(.jpegType) else {
            message = "The clipboard doesn't hold an image."
            return
        }
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) ?? pb.data(forType: .jpegType) else {
            message = "The clipboard doesn't hold an image."
            return
        }
        ingest(data)
    }

    /// Turns raw image bytes into a reviewable draft, or explains why it
    /// could not - every failure here says what happened rather than leaving
    /// the picker sitting there looking like nothing was clicked.
    private func ingest(_ data: Data) {
        message = nil

        guard data.count <= maxFileBytes else {
            let limit = maxFileBytes / 1_000_000
            message = "That image is too large to preview (over \(limit) MB). Try a smaller one."
            return
        }
        guard let image = NSImage(data: data), image.size.width > 1, image.size.height > 1 else {
            message = "That doesn't look like an image Clip can read."
            return
        }

        let colors = ImagePalette.colors(from: image, count: maxColors)
        guard !colors.isEmpty else {
            message = "Couldn't find any usable color in that image. It may be blank or fully transparent."
            return
        }

        swatches = colors.map { color in
            DraftSwatch(color: color, hex: Color(nsColor: NSColor(color)).hexString)
        }
        // Fewer than a handful back is not a failure - k-means collapsed to
        // this because the image genuinely does not vary much - but a review
        // screen with one lonely swatch and no explanation reads as broken,
        // so say what happened.
        if colors.count < 3 {
            let noun = colors.count == 1 ? "color" : "colors"
            message = "This image has very little color variation: only \(colors.count) distinct \(noun) found."
        }
        stage = .reviewing
    }

    // MARK: - Editing the draft

    private func update(_ id: UUID, color: Color) {
        guard let i = swatches.firstIndex(where: { $0.id == id }) else { return }
        swatches[i].color = color
        swatches[i].hex = Color(nsColor: NSColor(color)).hexString
    }

    private func update(_ id: UUID, hex: String) {
        guard let i = swatches.firstIndex(where: { $0.id == id }) else { return }
        swatches[i].hex = hex
        // Only a value that actually parses moves the wheel - a half-typed
        // hex should not fight the field the user is still typing into.
        if let canonical = HexColor.normalised(hex), let parsed = NSColor(hex: canonical) {
            swatches[i].color = Color(nsColor: parsed)
        }
    }

    private func remove(_ id: UUID) {
        swatches.removeAll { $0.id == id }
    }

    // MARK: - The two exits

    private func commit() {
        for swatch in swatches {
            // The hex field may hold something the user typed that no longer
            // parses (mid-edit); the color wheel is always valid, so it is
            // the source of truth for what actually gets saved.
            let hex = Color(nsColor: NSColor(swatch.color)).hexString
            let item = ClipboardItem(kind: .color, text: hex, hexColor: hex,
                                     sourceAppName: "From an image")
            store.addExisting(item)
        }
        let count = swatches.count
        NoticeCenter.shared.report("Added \(count) color\(count == 1 ? "" : "s") from the image",
                                   kind: .transient)
        reset()
        isOpen = false
    }

    /// Cancel must store nothing at all - every bit of the draft lives in
    /// `@State` on this view and simply stops existing when it closes.
    private func cancel() {
        reset()
        isOpen = false
    }

    private func reset() {
        stage = .picking
        swatches = []
        message = nil
    }
}

/// One color pulled from the image, editable before it becomes real.
private struct DraftSwatch: Identifiable {
    let id = UUID()
    var color: Color
    var hex: String
}

/// The per-swatch remove control.
///
/// Built from the same `iconButtonChrome` every other icon-sized action
/// button in the app uses (see `MediaPreview.swift`), rather than a bespoke
/// look for just this one button - hover and keyboard focus render with the
/// ring this app already uses for "this is a small destructive action."
private struct RemoveSwatchButton: View {
    let theme: AppTheme
    let action: () -> Void

    @State private var hovering = false
    @FocusState private var focused: Bool

    private var highlighted: Bool { hovering || focused }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(highlighted ? theme.destructive : theme.textTertiary)
                .iconButtonChrome(theme, variant: .item, side: 22,
                                  highlighted: highlighted, focused: focused,
                                  destructive: true)
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onHover { hovering = $0 }
        .help("Remove this color")
    }
}
