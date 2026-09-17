import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A drag that means "put this item here", not "add this text".
    ///
    /// The whole reason it exists. Every collection tab already accepts dropped
    /// text and files, so a reorder drag carrying a plain string would be picked
    /// up by that handler and dragging a note two rows up would create a new
    /// note whose contents are a UUID. A private identifier cannot be confused
    /// with anything: the drop handlers that want text never see it, and this
    /// one never sees text.
    static let clipItemReorder = UTType(exportedAs: "com.shaulv.clip.item-reorder")
}

/// Drag a card or row to a new place in its own collection.
///
/// Applied per item, with the collection passed in, because "before which one"
/// is a question about the list as it is drawn - after filtering, after search -
/// and only the view knows that.
struct Reorderable: ViewModifier {
    let item: ClipboardItem
    /// The collection as drawn, in the order it is drawn.
    let collection: [ClipboardItem]
    /// False on tabs where an arrangement would be meaningless.
    var enabled: Bool = true

    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager
    @State private var isTargeted = false

    private var t: AppTheme { theme.theme }

    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrag { Self.provider(for: item) }
                // The insertion point, drawn on the leading edge, because that
                // is where the dragged item is about to land.
                .overlay(alignment: .leading) {
                    if isTargeted {
                        Capsule()
                            .fill(t.accent)
                            .frame(width: 3)
                            .padding(.vertical, 2)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeOut(duration: 0.1), value: isTargeted)
                .onDrop(of: [.clipItemReorder], isTargeted: $isTargeted) { providers in
                    receive(providers)
                    return true
                }
        } else {
            content
        }
    }

    private func receive(_ providers: [NSItemProvider]) {
        ReorderPayload.read(providers) { dragged in
            guard dragged != item.id else { return }
            store.reorder([dragged], before: item.id, in: collection)
        }
    }

    /// The id, under our own type. Nothing else needs to travel: the receiving
    /// side looks the item up in the collection it is drawing, which is the
    /// only place the answer is right.
    static func provider(for item: ClipboardItem) -> NSItemProvider {
        ReorderPayload.provider(for: item.id)
    }
}

/// Carrying an item id across a drag, and the reason it is done this way.
///
/// This was `NSItemProvider(item: uuid as NSString, typeIdentifier:)` paired
/// with `loadItem(forTypeIdentifier:)`, and it did not work at all: the load
/// **completion was never called**. Not called with nil, not called with an
/// error - never called. So the drop handler sat waiting for an answer that
/// never came, `reorder` was never reached, and dragging an item did nothing
/// whatsoever.
///
/// It looked right, which is why it survived: the type is declared correctly in
/// `Info.plist`, `UTType(...)` resolves it, and the provider reports
/// `hasItemConformingToTypeIdentifier` as true. Everything about it inspects
/// correctly. Only actually loading the value reveals it, and that is the one
/// thing no code path checked, because reordering shipped with no test.
///
/// Measured, all three in one run against the real declared type:
///
///     NSItemProvider(item:) + loadItem                 no callback at all
///     NSItemProvider(item:) + loadDataRepresentation   called back with nil
///     registerDataRepresentation + loadData            round-trips
///
/// So the data representation is registered explicitly, and read the same way.
enum ReorderPayload {

    static func provider(for id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.clipItemReorder.identifier,
            visibility: .ownProcess       // a reorder means nothing outside Clip
        ) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    /// Reads the dragged id and hands it over on the main actor.
    static func read(_ providers: [NSItemProvider],
                     then act: @escaping @MainActor (UUID) -> Void) {
        for provider in providers {
            provider.loadDataRepresentation(
                forTypeIdentifier: UTType.clipItemReorder.identifier
            ) { data, _ in
                guard let data,
                      let raw = String(data: data, encoding: .utf8),
                      let id = UUID(uuidString: raw) else { return }
                Task { @MainActor in act(id) }
            }
        }
    }
}

/// The strip below the last row, so something can be dragged to the end.
///
/// Without it the last position is unreachable: every row inserts *before*
/// itself, so there is no gesture that means "after everything".
struct ReorderTailTarget: View {
    let collection: [ClipboardItem]
    var enabled: Bool = true

    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager
    @State private var isTargeted = false

    var body: some View {
        if enabled, collection.count > 1 {
            Rectangle()
                .fill(isTargeted ? theme.theme.accent.opacity(0.18) : Color.clear)
                .frame(height: 26)
                .overlay {
                    if isTargeted {
                        Text("Move to the end")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.theme.accentOnPanel)
                    }
                }
                .animation(.easeOut(duration: 0.1), value: isTargeted)
                .onDrop(of: [.clipItemReorder], isTargeted: $isTargeted) { providers in
                    ReorderPayload.read(providers) { dragged in
                        store.reorder([dragged], before: nil, in: collection)
                    }
                    return true
                }
        }
    }
}

extension View {
    /// Lets this item be dragged to a new place among `collection`.
    func reorderable(_ item: ClipboardItem, in collection: [ClipboardItem],
                     enabled: Bool = true) -> some View {
        modifier(Reorderable(item: item, collection: collection, enabled: enabled))
    }
}
