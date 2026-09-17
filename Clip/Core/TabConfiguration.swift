import SwiftUI
import Combine

/// How a tab lays its items out.
enum TabLayout: String, Codable, CaseIterable, Identifiable {
    case gallery, list
    var id: String { rawValue }
    var title: String { self == .gallery ? "Gallery" : "List" }
    var symbol: String { self == .gallery ? "square.grid.2x2" : "list.bullet" }
}

/// One tab: what it shows, and how.
///
/// Layout and density belong to the tab, not the app. Files want a list;
/// screenshots want a gallery; a prompt library wants roomy rows. Forcing one
/// global choice made at least one of those wrong all the time.
struct TabSpec: Identifiable, Codable, Equatable {
    var category: ItemCategory
    var isVisible: Bool
    var layout: TabLayout
    var density: GalleryDensity
    /// Overrides the category's own name when the user renames the tab.
    var customTitle: String?

    var id: String { category.id }
    var title: String { customTitle ?? category.title }
    var symbol: String { category.symbol }

    init(_ category: ItemCategory,
         visible: Bool = true,
         layout: TabLayout = .gallery,
         density: GalleryDensity = .comfortable,
         customTitle: String? = nil) {
        self.category = category
        self.isVisible = visible
        self.layout = layout
        self.density = density
        self.customTitle = customTitle
    }
}

/// The ordered set of tabs, persisted.
@MainActor
final class TabConfiguration: ObservableObject {

    static let shared = TabConfiguration()

    @Published private(set) var tabs: [TabSpec] = [] {
        didSet { revision &+= 1 }
    }

    /// Bumped whenever the tab set changes, so `HistoryStore`'s derived-list
    /// cache can notice that hiding a tab changed which items are visible.
    private(set) var revision: Int = 0

    /// The tabs actually drawn in the panel, in order.
    var visible: [TabSpec] { tabs.filter(\.isVisible) }

    private init() {
        load()
        if tabs.isEmpty { tabs = Self.defaults }
        migrateIfNeeded()
    }

    /// What a fresh install gets: the two history views, the curated
    /// collections, and files. Every other category is available but hidden, so
    /// the bar stays short until the user asks for more.
    static var defaults: [TabSpec] {
        [
            TabSpec(.all, layout: .gallery, density: .comfortable),
            TabSpec(.role(.prompt), layout: .list, density: .comfortable),
            TabSpec(.role(.note), layout: .list, density: .comfortable),
            TabSpec(.role(.skill), layout: .list, density: .comfortable),
            TabSpec(.kind(.file), layout: .list, density: .compact),
            // Hidden until there is something in it: importing the corpus turns
            // it on, since a tab holding 74 documents should not be invisible.
            TabSpec(.role(.design), visible: false, layout: .list, density: .comfortable),
            TabSpec(.kind(.color), visible: false, layout: .gallery, density: .compact),
            TabSpec(.kind(.image), visible: false, layout: .gallery, density: .comfortable),
            TabSpec(.kind(.code), visible: false, layout: .list, density: .comfortable),
            TabSpec(.platform(.repository), visible: false, layout: .list, density: .comfortable)
        ]
    }

    /// Adds any category the user has never seen as a hidden tab, so new
    /// platforms appear in Settings after an update without resetting anything.
    private func migrateIfNeeded() {
        let known = Set(tabs.map(\.id))
        for category in ItemCategory.offerable where !known.contains(category.id) {
            tabs.append(TabSpec(category, visible: false,
                                layout: .list, density: .comfortable))
        }
        persist()
    }

    func spec(for id: String) -> TabSpec? { tabs.first { $0.id == id } }

    func update(_ spec: TabSpec) {
        guard let i = tabs.firstIndex(where: { $0.id == spec.id }) else { return }
        tabs[i] = spec
        persist()
    }

    func setVisible(_ id: String, _ visible: Bool) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        // The panel must always have at least one tab to show.
        if !visible, tabs.filter(\.isVisible).count <= 1 { return }
        tabs[i].isVisible = visible
        persist()
    }

    /// Replaces the whole ordered list, used by drag-and-drop reordering.
    func replaceAll(_ newTabs: [TabSpec]) {
        tabs = newTabs
        persist()
    }

    func resetToDefaults() {
        tabs = Self.defaults
        migrateIfNeeded()
    }

    // MARK: - Storage

    private func persist() {
        guard let data = try? JSONEncoder().encode(tabs),
              let json = String(data: data, encoding: .utf8) else { return }
        Database.shared.setPreference("tabs", json)
    }

    /// Re-reads the stored configuration, for when something other than this
    /// object wrote it - a settings snapshot arriving from another Mac.
    func reload() { load(); objectWillChange.send() }

    /// Decoded row by row, so one tab saved in a shape this build no longer
    /// understands does not take the rest of the bar down with it. The old
    /// all-or-nothing `try? JSONDecoder().decode([TabSpec].self, ...)` threw
    /// away every tab - visible or not, including the ones the user had
    /// spent time arranging - the moment a single one failed to parse.
    private func load() {
        guard let json = Database.shared.preference("tabs"), !json.isEmpty,
              let data = json.data(using: .utf8) else { return }
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            NoticeCenter.shared.report(.decodeFailed(entity: "tab", count: 1))
            return
        }
        var loaded: [TabSpec] = []
        var quarantined = 0
        let decoder = JSONDecoder()
        for row in rows {
            if let rowData = try? JSONSerialization.data(withJSONObject: row),
               let spec = try? decoder.decode(TabSpec.self, from: rowData) {
                loaded.append(spec)
            } else {
                quarantined += 1
            }
        }
        guard quarantined == 0 || !loaded.isEmpty else {
            // Every row failed: keep whatever is already in memory (the
            // caller falls back to the defaults on a first load) rather
            // than replacing it with an empty tab bar.
            NoticeCenter.shared.report(.decodeFailed(entity: "tab", count: quarantined))
            return
        }
        tabs = loaded
        if quarantined > 0 {
            NoticeCenter.shared.report(.decodeFailed(entity: "tab", count: quarantined))
        }
    }
}
