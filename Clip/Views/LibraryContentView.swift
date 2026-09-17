import SwiftUI

/// The one view type `PanelRootView` ever instantiates for a tab's body,
/// whatever that tab actually shows (M10b).
///
/// Before this, `PanelRootView`'s own `@ViewBuilder` chose between
/// `RoleCollectionView` / `GalleryView` / `ListView` as three different
/// occupants of the same slot in its VStack, each with its own
/// `.acceptsDrops` call attached at the branch. SwiftUI's conditional-content
/// reconciliation gives each branch of a switch/if its own identity: when the
/// active branch changes, the previous one's whole subtree - ScrollView,
/// LazyVStack/Grid, every materialised row, and their AttributeGraph nodes -
/// is torn down and the new one built from nothing. That is the 45-65 ms
/// structural floor M10 measured after the per-row hot spots (`DateFormatter`,
/// `Color.hexString`, the `enumerated()` allocation) were already gone; a CPU
/// sample during rapid switching showed almost no "in Clip" leaf time left,
/// with the busy frames in SwiftUICore/CoreGraphics/AttributeGraph instead.
///
/// Collapsing the switch into one named type, with drop handling attached
/// once outside it instead of per branch, means `PanelRootView` only ever
/// sees `LibraryContentView` at this position in its own tree - an update to
/// an existing node, not a remove-then-insert - and lets it keep TWO of these
/// alive at once (the outgoing tab and the incoming one) during the
/// cross-fade in `PanelRootView.content`, instead of swapping the sole
/// occupant of a conditional slot.
struct LibraryContentView: View {
    /// Which tab this instance renders. A value, not a type: the same struct
    /// draws every tab, curated or not, so `PanelRootView` never has to name
    /// a different concrete view per tab.
    let tabID: String

    @EnvironmentObject var store: HistoryStore
    @ObservedObject private var tabs = TabConfiguration.shared

    private var tab: TabSpec {
        tabs.spec(for: tabID) ?? store.activeTab
    }

    var body: some View {
        Group {
            switch tab.category {
            case .role(let role):
                // Curated tabs keep their toolbar and tag rail, but draw
                // their items in whichever layout the tab is set to, like
                // every other tab.
                RoleCollectionView(role: role, layout: tab.layout, density: tab.density)
            default:
                // Every tab takes a drop, not only the curated ones: dropping
                // onto history is how a file gets in without being copied
                // first.
                VStack(spacing: Spacing.tight) {
                    // The colors tab gets an add affordance of its own,
                    // because a library you can only fill by copying from
                    // somewhere else is half a library. It is the only kind
                    // tab with one: a color is a value you can pick, and a
                    // screenshot or a file is not.
                    if tab.category == .kind(.color) {
                        ColorComposer()
                    }
                    if tab.layout == .gallery {
                        GalleryView(density: tab.density)
                    } else {
                        ListView()
                    }
                }
            }
        }
        // Attached once, outside the switch, on the stable outer type -
        // rather than once per branch as before - so it is not part of what
        // has to be rebuilt when the branch changes.
        .acceptsDrops(role: tab.category.roleValue)
    }
}
