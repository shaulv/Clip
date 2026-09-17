import Foundation
import SwiftUI
import AppKit
import Combine

/// Single source of truth for history and panel UI state.
/// Per-stage timings for one `computeVisibleItems` run, off unless asked for.
///
/// The filter pipeline was measured at 0.75 ms per keystroke over 672 items and
/// 80 ms over 5,206 - 107x the cost for 7.7x the items. A whole-pipeline number
/// cannot say which stage did that, and the three candidates (the match scan,
/// the pin partition, the sort) have completely different fixes. This splits
/// them so the answer is measured rather than argued.
///
/// Gated on `CLIP_PERF` in the environment rather than a build flag, so the
/// same binary the probe already builds can be asked for the numbers. When it
/// is off, `isEnabled` is a single already-resolved `Bool` read and no clock is
/// sampled at all.
enum FilterStageTimings {
    static let isEnabled = ProcessInfo.processInfo.environment["CLIP_PERF"] == "1"

    struct Sample {
        let items: Int
        let matched: Int
        let filterMS: Double
        let partitionMS: Double
        let sortMS: Double
        var totalMS: Double { filterMS + partitionMS + sortMS }
    }

    private(set) static var samples: [Sample] = []

    static func record(items: Int, matched: Int,
                       start: CFAbsoluteTime, afterFilter: CFAbsoluteTime,
                       afterPartition: CFAbsoluteTime) {
        guard isEnabled else { return }
        let end = CFAbsoluteTimeGetCurrent()
        samples.append(Sample(items: items,
                              matched: matched,
                              filterMS: (afterFilter - start) * 1000,
                              partitionMS: (afterPartition - afterFilter) * 1000,
                              sortMS: (end - afterPartition) * 1000))
        // Bounded so a long session cannot grow this without limit.
        if samples.count > 2000 { samples.removeFirst(samples.count - 2000) }
    }

    static func reset() { samples.removeAll(keepingCapacity: true) }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Medians per stage, for the QA bridge to report.
    static var report: [String: Any] {
        [
            "runs": samples.count,
            "items": samples.last?.items ?? 0,
            "matched": samples.last?.matched ?? 0,
            "filterMS.median": median(samples.map(\.filterMS)),
            "partitionMS.median": median(samples.map(\.partitionMS)),
            "sortMS.median": median(samples.map(\.sortMS)),
            "totalMS.median": median(samples.map(\.totalMS))
        ]
    }
}

final class HistoryStore: ObservableObject {

    static let shared = HistoryStore()

    /// The most pins allowed at once, across every tab - a pin is a single
    /// property on an item, so every pin surfaces in the All tab regardless of
    /// where it was set, and the cap has to be global rather than per-tab.
    ///
    /// Past four, the pinned row at the top of the panel stops being a
    /// shortcut and starts being a second list - the exact thing scrolling
    /// past history exists to avoid. Four keeps it a glance.
    ///
    /// Enforced here, in the model, not only where the pin button is drawn:
    /// `togglePin` is the gate every interactive path shares (the row button,
    /// the keyboard shortcut in `KeyRouter`, the QA bridge), and `merge` guards
    /// the one path that never calls `togglePin` at all - a sync payload can
    /// hand back two devices' pins at once, and their union can exceed four
    /// even though neither device ever went over on its own.
    static let maxPinnedItems = 4

    /// Shown on the pin control instead of "Pin" when the cap above is
    /// reached and this particular item is not one of the pinned ones - a
    /// disabled control that says nothing is indistinguishable from a broken
    /// one, so this names both the limit and the fix.
    static var pinCapExplanation: String {
        "Pin limit reached (\(maxPinnedItems)) - unpin one to pin this"
    }

    // MARK: - Published state
    @Published private(set) var items: [ClipboardItem] = [] {
        didSet { contentRevision &+= 1 }
    }

    /// Bumped whenever the content changes, so the derived-list cache can tell
    /// "the same question" from "a new answer" without comparing arrays.
    private(set) var contentRevision: Int = 0
    @Published var query: String = ""
    /// The type chips currently switched on. Empty means everything.
    ///
    /// A set, not one choice: picking "Image" then "Code" should show both. A
    /// single slot made every new pick replace the last, so there was no way to
    /// ask for two types at once.
    @Published var activeFilters: Set<ItemCategory> = []

    /// The single active filter, when exactly one is on. Kept for the callers
    /// that only ask "is anything filtered".
    var activeFilter: ItemCategory? {
        get { activeFilters.count == 1 ? activeFilters.first : nil }
        set { activeFilters = newValue.map { [$0] } ?? [] }
    }
    /// Narrows the list to when something was copied. Independent of the
    /// category filter: "images" and "this week" are two separate questions.
    @Published var timeFilter: TimeFilter = .any

    /// Items marked for an action that takes several at once.
    ///
    /// Separate from `selectedID`, which is the cursor. The cursor is where you
    /// are; the marks are what you have gathered. Conflating them would mean
    /// arrowing through the list destroyed the set you were building.
    @Published var markedIDs: Set<UUID> = []

    /// The prompt waiting for its placeholders to be filled in.
    @Published var fillingVariablesFor: ClipboardItem?

    /// Pastes a prompt with its placeholders replaced.
    @MainActor
    func pasteFilled(_ item: ClipboardItem, values: [String: String]) {
        PromptVariables.remember(values)
        var filled = item
        filled.text = PromptVariables.filled(item.fullText, with: values)
        fillingVariablesFor = nil
        ClipboardWriter.write(filled, plain: false)
        update(item.id) { $0.useCount += 1 }
        pasteTicket = PasteTicket(item: filled, plain: false)
    }

    /// The items an action should run on: the marked set, or the cursor.
    @MainActor
    var actionTargets: [ClipboardItem] {
        guard !markedIDs.isEmpty else { return selectedItem.map { [$0] } ?? [] }
        // In visible order, so a composed result reads down the screen.
        return visibleItems.filter { markedIDs.contains($0.id) }
    }

    @MainActor
    func toggleMark(_ id: UUID) {
        if markedIDs.contains(id) { markedIDs.remove(id) } else { markedIDs.insert(id) }
    }

    @MainActor
    func clearMarks() { markedIDs = [] }

    /// Joins the marked items into one block and puts it on the pasteboard.
    ///
    /// No model: this is what "I need these five things together" actually
    /// means most of the time, and asking a model to concatenate is theatre.
    @MainActor
    @discardableResult
    func composePaste(separator: String = "\n\n") -> Int {
        let items = actionTargets
        guard !items.isEmpty else { return 0 }
        let text = items.map(\.fullText).filter { !$0.isEmpty }.joined(separator: separator)
        guard !text.isEmpty else { return 0 }
        ClipboardMonitor.shared.suppressNextCapture()
        let pb = TestIsolation.board
        pb.clearContents()
        pb.setString(text, forType: .string)
        return items.count
    }
    /// Id of the active tab (a `TabSpec.id`, i.e. an `ItemCategory.id`).
    @Published var activeTabID: String = "all"
    @Published var selectedID: UUID?
    @Published var pinnedIDs: [UUID] = [] {
        didSet {
            pinRevision &+= 1
            pinnedSet = Set(pinnedIDs)
        }
    }

    /// A delete that has left the list but not yet touched anything on disk.
    ///
    /// See `deleteWithUndo`. Stored here rather than in an extension because
    /// `items` has a file-private setter, so the code that takes a row out of
    /// the list and the code that puts it back both have to live in this file.
    struct PendingDelete {
        let item: ClipboardItem
        /// Where it was in `items`, so undo puts it back rather than on top.
        let index: Int
        /// Its place in the pin order, nil when it was not pinned.
        let pinIndex: Int?
        /// The notice carrying the Undo button, dismissed when the window ends
        /// either way, so the button never outlives what it can do.
        let noticeID: UUID
    }

    @Published private(set) var pendingDelete: PendingDelete?
    private var pendingDeleteWork: DispatchWorkItem?

    /// How long Undo stays available. Matches the transient notice's own life
    /// in `NoticeCenter.report`, because the notice IS the affordance: a
    /// shorter window would leave a button that silently does nothing, and a
    /// longer one would outlast the only place it is offered.
    static let undoDeleteWindow: TimeInterval = 12

    /// Membership as a set, alongside the array that records the order.
    ///
    /// `isPinned` was `pinnedIDs.contains`, a linear scan, called once per item
    /// inside the pinned/unpinned partition of the visible list: O(n*m) for a
    /// question that is O(1). Derived in one place from the array, so there is
    /// no second source of truth to drift.
    private(set) var pinnedSet: Set<UUID> = []
    private(set) var pinRevision: Int = 0
    @Published var isDetailOpen: Bool = false
    @Published var isEditing: Bool = false
    @Published var searchIsFocused: Bool = false
    @Published var sortOrder: SortOrder = .newest { didSet { persistSetting(sortOrder.rawValue, "sortOrder") } }
    @Published var searchMode: SearchMode = .exact { didSet { persistSetting(searchMode.rawValue, "searchMode") } }

    /// Bumped to ask the delegate to perform a real ⌘V.
    @Published var pasteTicket: PasteTicket?

    struct PasteTicket: Equatable {
        let id = UUID()
        let item: ClipboardItem
        let plain: Bool
    }

    /// Which action button on the selected row has keyboard focus.
    ///
    /// `nil` means the row itself is focused, so Return pastes. Right arrow
    /// steps into the action row; Left steps back out. This is what makes every
    /// hover affordance reachable without a mouse.
    @Published var focusedActionIndex: Int?

    /// How many columns the gallery is currently showing — arrow up/down move by
    /// a whole row, so the stride has to match the layout.
    @Published var selectionStride: Int = 1

    // MARK: - Config
    @AppStorage("historyLimit", store: AppPaths.defaults) var historyLimit: Int = 200
    /// Whether `historyLimit` is enforced at all. Default OFF: saving is
    /// unlimited unless the user asks for a cap.
    ///
    /// Two preferences rather than a sentinel value in `historyLimit` (0 or -1
    /// meaning "unlimited") because the number has to survive being switched
    /// off: a user who caps at 500, turns the cap off to keep everything for a
    /// while, then turns it back on expects 500 back, not 200. A sentinel
    /// destroys the number the moment it is used.
    @AppStorage("historyLimitEnabled", store: AppPaths.defaults) var historyLimitEnabled: Bool = false
    @AppStorage("deduplicate", store: AppPaths.defaults) var deduplicate: Bool = true
    @AppStorage("clearOnQuit", store: AppPaths.defaults) var clearOnQuit: Bool = false

    /// The cap actually in force, or `nil` for unlimited.
    ///
    /// Every trim/load decision reads this rather than `historyLimit` directly,
    /// so "is there a cap" is decided in exactly one place.
    var effectiveHistoryLimit: Int? {
        historyLimitEnabled ? max(1, historyLimit) : nil
    }

    /// Seeds `historyLimitEnabled` once, from whether the user ever set a cap.
    ///
    /// The default flipped from "always capped at 200" to "unlimited". Applying
    /// that to everyone would silently start keeping everything for a user who
    /// deliberately capped their history - and, worse, applying the OLD default
    /// to a fresh install would delete data the new default promises to keep.
    /// The only honest reading of an existing install is the presence of an
    /// explicitly written `historyLimit`: `object(forKey:)` is nil when nobody
    /// ever wrote one, which is precisely "never chose", and non-nil when the
    /// user (or a restored settings snapshot) did choose.
    ///
    /// Runs once. After the first run `historyLimitEnabled` exists, so the
    /// `nil` check below is false for ever and the user's own later choice is
    /// never overwritten.
    static func migrateHistoryLimitPreference(_ defaults: UserDefaults = AppPaths.defaults) {
        guard defaults.object(forKey: "historyLimitEnabled") == nil else { return }
        defaults.set(defaults.object(forKey: "historyLimit") != nil, forKey: "historyLimitEnabled")
    }

    private let fileManager = FileManager.default
    private var historyURL: URL { historyDir.appendingPathComponent("history.json") }
    private var historyDir: URL { AppPaths.support }

    private init() {
        // Before `load()`, which applies the cap: reading the migration after
        // the first load would let one launch trim under the wrong default.
        Self.migrateHistoryLimitPreference()
        load()
        reloadViewPreferences()
    }

    /// Re-reads the sort order and search mode from preferences.
    ///
    /// Called at launch, and again when a settings document from another Mac
    /// changes either of them. Both are `@Published` with a persisting `didSet`,
    /// so writing `UserDefaults` alone leaves the live values untouched and the
    /// list keeps sorting the old way until a relaunch.
    ///
    /// Assigning only on an actual change keeps this from publishing a redundant
    /// update - and, more importantly, from writing the same value straight back
    /// through `didSet` on every sync.
    func reloadViewPreferences() {
        if let raw = AppPaths.defaults.string(forKey: "sortOrder"),
           let s = SortOrder(rawValue: raw), s != sortOrder { sortOrder = s }
        if let raw = AppPaths.defaults.string(forKey: "searchMode"),
           let m = SearchMode(rawValue: raw), m != searchMode { searchMode = m }
    }

    private func persistSetting(_ value: String, _ key: String) {
        AppPaths.defaults.set(value, forKey: key)
    }

    // MARK: - Sections

    func isPinned(_ id: UUID) -> Bool { pinnedSet.contains(id) }

    var pinnedItems: [ClipboardItem] {
        pinnedIDs.compactMap { id in items.first { $0.id == id } }
    }

    var promptItems: [ClipboardItem] { items(withRole: .prompt) }
    var noteItems: [ClipboardItem] { items(withRole: .note) }
    var skillItems: [ClipboardItem] { items(withRole: .skill) }

    func items(withRole role: ItemRole) -> [ClipboardItem] {
        let prepared = PreparedQuery(query)
        var out: [ClipboardItem] = []
        for item in items where item.role == role && matchesSearch(item, prepared) {
            out.append(item)
        }
        // A role listing IS a curated collection, so its arrangement counts.
        return applySort(out, prepared, isHistoryView: false)
    }

    func count(ofRole role: ItemRole) -> Int {
        items.lazy.filter { $0.role == role }.count
    }

    var fileCount: Int {
        items.lazy.filter { $0.kind == .file || $0.kind == .folder }.count
    }

    /// The active tab's definition, falling back to the first visible one.
    @MainActor
    var activeTab: TabSpec {
        TabConfiguration.shared.spec(for: activeTabID)
            ?? TabConfiguration.shared.visible.first
            ?? TabSpec(.all)
    }

    /// Everything the current tab shows, already filtered and sorted.
    /// Pinned items lead the history views so they stay reachable.
    @MainActor
    var visibleItems: [ClipboardItem] {
        let key = derivationKey
        if let cached = derivedCache, cached.key == key { return cached.items }
        Perf.count("visibleItems")
        let computed = Perf.measure("visibleItems") { computeVisibleItems() }
        var indexByID: [UUID: Int] = [:]
        indexByID.reserveCapacity(computed.count)
        for (index, item) in computed.enumerated() { indexByID[item.id] = index }
        derivedCache = (key, computed, indexByID)
        return computed
    }

    /// A real, uncached read of the visible list, for the `perfReadList`
    /// probe command.
    ///
    /// `visibleItems` itself cannot answer "what does a read cost": its whole
    /// point is that a read at an unchanged derivation key is a dictionary
    /// lookup, not a recomputation, so a loop of `perfReadList` reads against
    /// the SAME query/tab/filters hit the cache after the first one and timed
    /// nothing at every item count. That is a real bug in the metric, not in
    /// the cache - the fix is not to weaken the memoization real callers rely
    /// on, it is to give the probe a path that always does the work the cache
    /// exists to skip, exactly like a cache MISS would (an item added, a
    /// keystroke, a tab switch), which is the case the metric is meant to
    /// bound. Deliberately does not touch `derivedCache`: this is a
    /// measurement, not a read on behalf of the UI, and must not leave the
    /// cache holding a value nothing asked to see rendered.
    @MainActor
    @discardableResult
    func perfMeasuredRead() -> Int {
        Perf.count("visibleItems")
        return Perf.measure("visibleItems") { computeVisibleItems() }.count
    }

    /// The command-number badge a row draws ("⌘1" through "⌘9"), looked up
    /// rather than carried by `Array(visibleItems.enumerated())`.
    ///
    /// `ListView` and `GalleryView` used to build that enumerated array fresh
    /// on every body evaluation - one allocation of `(Int, ClipboardItem)`
    /// pairs, sized to the whole visible list, on every store publish, whether
    /// or not the list itself had changed. The index is exactly as much a
    /// function of `visibleItems` as the array is, so it belongs behind the
    /// same `DerivationKey` guard: built once per derivation, alongside the
    /// list it indexes, and looked up in O(1) per row instead.
    @MainActor
    func visibleIndex(of id: UUID) -> Int {
        // Reading `visibleItems` first guarantees `derivedCache` is fresh for
        // the CURRENT derivation key before the index lookup below - the two
        // are written together, but only `visibleItems` re-derives on a stale
        // key.
        _ = visibleItems
        return derivedCache?.indexByID[id] ?? 0
    }

    /// Everything the visible list is a function of.
    ///
    /// The list was a plain computed property, so it re-ran its four filters and
    /// its sort on every read - and a read happens on every SwiftUI body
    /// evaluation, of which there is one per view per published change. This
    /// store publishes 24 properties, most of them nothing to do with which
    /// items are visible. Measured: pressing the down arrow ten times ran the
    /// whole pipeline **thirty** times over 745 items, to arrive at the same
    /// list every time. Selection is not an input to the list.
    ///
    /// Anything absent from this key is a correctness bug, so the rule is that
    /// a new input to `computeVisibleItems` must be added here in the same
    /// commit.
    @MainActor
    private var derivationKey: DerivationKey {
        DerivationKey(
            revision: contentRevision,
            query: query,
            tab: activeTabID,
            tabs: TabConfiguration.shared.revision,
            filters: activeFilters,
            time: timeFilter,
            timeBucket: Self.timeBucket(for: timeFilter),
            sort: sortOrder,
            mode: searchMode,
            pins: pinRevision
        )
    }

    private struct DerivationKey: Equatable {
        let revision: Int
        let query: String
        let tab: String
        let tabs: Int
        let filters: Set<ItemCategory>
        let time: TimeFilter
        let timeBucket: Int
        let sort: SortOrder
        let mode: SearchMode
        let pins: Int
    }

    /// A relative time filter answers a different question as time passes.
    ///
    /// "Last 24 hours" is not a fixed set: an item drops out of it while nobody
    /// touches anything. Without this the cache would hold a stale list until
    /// some unrelated change happened to evict it. A one-minute bucket bounds
    /// that staleness to a minute on a window measured in hours, and costs one
    /// recomputation per minute only while such a filter is switched on.
    ///
    /// `.range` returning 0 (constant, never stale) is SAFE, not an oversight -
    /// verified against both places a `.range` is actually built
    /// (`HeaderView`'s custom-range picker and the QA bridge's `timeFilter
    /// range` command), not assumed from the case name:
    ///
    /// 1. `TimeFilter.contains(_:now:)` for `.range` never reads its `now`
    ///    parameter at all - unlike `.lastDay`/`.lastWeek`/`.lastMonth`, which
    ///    all subtract from it. A range's membership test is a function of the
    ///    item's timestamp and the two stored bounds ONLY, so there is no
    ///    "the window slid, an item should now drop out" case for it to miss -
    ///    the thing `timeBucket` exists to catch for the relative filters.
    /// 2. Both bounds are absolute `Date`s fixed at the moment the filter is
    ///    set, not live offsets recomputed from "now" on every check. Picking
    ///    "To: today" in `HeaderView` does default `to` to `Date()` (line
    ///    ~463), including the current time-of-day - but `contains` (in
    ///    `TimeFilter.swift`) immediately reduces both bounds to
    ///    `calendar.startOfDay`, so the end boundary that is actually compared
    ///    against is "midnight starting the day AFTER whichever bound is
    ///    later" - a fixed point on the calendar the moment Apply is pressed,
    ///    not a rolling "now". Crossing that midnight in real life does not
    ///    move it, and an item copied later the same day the filter was
    ///    applied already falls before it (same-day, still `< end`), so it is
    ///    never silently excluded either.
    /// 3. Any actual CHANGE to the range (a different `from`/`to`, or a
    ///    different filter entirely) already invalidates the cache through
    ///    `time: timeFilter` in `DerivationKey` above, independently of
    ///    `timeBucket` - `TimeFilter` carries its associated values into
    ///    `Equatable`, so a new range is already a new key.
    ///
    /// If a future range type is added whose bound is relative to "now" (a
    /// rolling window a user can drag, say), it must NOT be folded into this
    /// `case .range` line without re-deriving a live bucket for it - the
    /// safety argument above is specific to bounds being fixed `Date`s.
    private static func timeBucket(for filter: TimeFilter) -> Int {
        switch filter {
        case .any, .range: return 0
        default: return Int(Date().timeIntervalSince1970 / 60)
        }
    }

    private var derivedCache: (key: DerivationKey, items: [ClipboardItem], indexByID: [UUID: Int])?

    // MARK: - Filter chips

    /// Which type chips the current tab offers, and how many items each holds.
    ///
    /// `FilterChips` worked this out inside its own `body`: one pass over
    /// `items` to decide which chips exist, then a further pass per chip to
    /// count it. A body evaluation happens on every published change of a store
    /// with two dozen published properties, so moving the selection re-walked
    /// the whole library once per chip to arrive at the same row of chips.
    ///
    /// Cached exactly like `visibleItems`, against the same kind of key and
    /// with the same instrumentation, so the two derivations can be reasoned
    /// about the same way. The key is deliberately smaller: the chip row is not
    /// a function of the search, the sort or which filters are on - only of
    /// what is in the library and which tab is showing.
    @MainActor
    var filterChips: FilterChipSet {
        let key = FilterChipKey(revision: contentRevision,
                                tab: activeTabID,
                                tabs: TabConfiguration.shared.revision)
        if let cached = filterChipCache, cached.key == key { return cached.value }
        Perf.count("filterChips")
        let computed = Perf.measure("filterChips") { computeFilterChips() }
        filterChipCache = (key, computed)
        return computed
    }

    /// The chips to draw, and the count behind each one.
    struct FilterChipSet: Equatable {
        var categories: [ItemCategory] = []
        var counts: [ItemCategory: Int] = [:]

        /// Zero for a chip that is offered but empty - which is a real state on
        /// the All tab, where every recognised type is listed whether or not
        /// anything of it has been copied.
        func count(_ category: ItemCategory) -> Int { counts[category] ?? 0 }
    }

    private struct FilterChipKey: Equatable {
        let revision: Int
        let tab: String
        let tabs: Int
    }

    private var filterChipCache: (key: FilterChipKey, value: FilterChipSet)?

    /// One pass over the tab's items, counting every candidate chip as it goes.
    ///
    /// On the All tab every content type is listed, whether or not anything of
    /// that type has been copied yet - the row doubles as a map of what Clip
    /// can recognise, and empty chips are dimmed rather than hidden so the set
    /// does not shuffle as history changes. Inside a narrower tab only what is
    /// actually there is offered, because a chip that can only ever match
    /// nothing is noise. 17 link services would swamp the row, so those always
    /// wait until they exist.
    @MainActor
    private func computeFilterChips() -> FilterChipSet {
        let tab = activeTab.category
        let isAllTab = tab == .all
        let kinds = ItemKind.filterable.map { ItemCategory.kind($0) }
        let platforms = LinkPlatform.allCases.map { ItemCategory.platform($0) }

        var counts: [ItemCategory: Int] = [:]
        for item in items where tab.contains(item) {
            for category in kinds where category.contains(item) {
                counts[category, default: 0] += 1
            }
            for category in platforms where category.contains(item) {
                counts[category, default: 0] += 1
            }
        }

        var out: [ItemCategory] = []
        for category in kinds where isAllTab || (counts[category] ?? 0) > 0 {
            out.append(category)
        }
        for category in platforms where (counts[category] ?? 0) > 0 {
            out.append(category)
        }
        return FilterChipSet(categories: out, counts: counts)
    }

    /// The uncached answer. Internal so the derivation audit can compare the
    /// cache against a fresh computation for the same inputs.
    @MainActor
    func computeVisibleItems() -> [ClipboardItem] {
        let stageStart = FilterStageTimings.isEnabled ? CFAbsoluteTimeGetCurrent() : 0
        let category = activeTab.category
        let prepared = PreparedQuery(query)

        // One pass, not four. The chained version allocated an intermediate
        // array per filter, so a 745-item library built three arrays it
        // immediately threw away.
        var matching: [ClipboardItem] = []
        matching.reserveCapacity(items.count)
        for item in items where category.contains(item)
            && matchesSearch(item, prepared)
            && matchesFilter(item)
            && timeFilter.contains(item.timestamp) {
            matching.append(item)
        }
        let afterFilter = FilterStageTimings.isEnabled ? CFAbsoluteTimeGetCurrent() : 0

        // Only the unfiltered history view floats pins to the top; inside a
        // narrow tab that reordering is noise.
        guard case .all = category else {
            let out = applySort(matching, prepared, isHistoryView: false)
            FilterStageTimings.record(items: items.count, matched: matching.count,
                                      start: stageStart, afterFilter: afterFilter,
                                      afterPartition: afterFilter)
            return out
        }
        var pinned: [ClipboardItem] = []
        var rest: [ClipboardItem] = []
        for item in matching {
            if pinnedSet.contains(item.id) { pinned.append(item) } else { rest.append(item) }
        }
        let afterPartition = FilterStageTimings.isEnabled ? CFAbsoluteTimeGetCurrent() : 0
        let out = pinned + applySort(rest, prepared, isHistoryView: true)
        FilterStageTimings.record(items: items.count, matched: matching.count,
                                  start: stageStart, afterFilter: afterFilter,
                                  afterPartition: afterPartition)
        return out
    }

    /// Kept for the older call sites / number shortcuts.
    @MainActor
    var filteredItems: [ClipboardItem] { visibleItems }

    /// Chips are a union: an item shown by any one of them stays.
    private func matchesFilter(_ item: ClipboardItem) -> Bool {
        guard !activeFilters.isEmpty else { return true }
        return activeFilters.contains { $0.contains(item) }
    }

    /// Adds or removes one chip, leaving the rest alone.
    @MainActor
    func toggleFilter(_ category: ItemCategory) {
        if activeFilters.contains(category) {
            activeFilters.remove(category)
        } else {
            activeFilters.insert(category)
        }
        select(visibleItems.first?.id)
    }

    @MainActor
    func clearFilters() {
        activeFilters = []
        select(visibleItems.first?.id)
    }

    /// Lowercased search text per item, keyed so a stale entry is impossible.
    ///
    /// The key carries `updatedAt` as well as the id, so editing an item
    /// invalidates its blob without anyone having to remember to clear a cache.
    private var searchBlobs: [UUID: (stamp: Double, blob: String)] = [:]

    /// Keyed by id with a stamp, NOT by an interpolated string.
    ///
    /// The first version built its key with string interpolation, which meant
    /// 74 string allocations per keystroke - and once ranked search called this
    /// a second time per item, 148. Measured, that alone took steady-state
    /// typing from 37ms to 245ms: the cache was paying for itself twice over.
    private func blob(for item: ClipboardItem) -> String {
        let stamp = item.updatedAt.timeIntervalSince1970
        if let cached = searchBlobs[item.id], cached.stamp == stamp { return cached.blob }
        let built = item.searchBlob
        // Bounded: a runaway cache is a memory leak wearing a performance costume.
        //
        // The bound used to be a flat 4000 with `removeAll` on overflow, and
        // that pair is a cliff, not a bound. Under 4000 items the cache holds
        // and a keystroke costs nothing; over it, the first pipeline run fills
        // to 4001, wipes ALL of it, and refills - so every keystroke rebuilds
        // every blob in the library from scratch, twice over once ranked search
        // asks a second time per item. Measured across that edge: 0.75 ms per
        // keystroke at 672 items, 80 ms at 5,206. A 7.7x library was 107x the
        // cost, which is the signature of a cache that has stopped being one.
        //
        // Unlimited history is now the default, so being over 4000 items is the
        // normal case rather than the exotic one, and the cliff had to go. The
        // bound is now relative to the library, and overflow prunes entries for
        // items that no longer exist instead of discarding live work.
        if searchBlobs.count > Self.derivedCacheSlack + items.count {
            pruneDerivedCaches()
        }
        searchBlobs[item.id] = (stamp, built)
        return built
    }

    /// Headroom over `items.count` before the derived caches are pruned.
    ///
    /// Not zero: deletions and folds leave entries behind, and pruning on every
    /// one of them would walk the whole cache far more often than the saving is
    /// worth. Not unbounded either, or a long session's churn accumulates.
    private static let derivedCacheSlack = 512

    /// Drops cached blobs and identities for ids that are no longer in `items`.
    ///
    /// Prunes rather than empties: everything still in the library is still
    /// correct, still stamped, and still about to be asked for on the very next
    /// keystroke. Emptying is what turned the bound into the cliff described
    /// above. If a prune frees nothing - every entry is live, so the library
    /// itself is simply larger than the bound - the caches are left alone,
    /// because the alternative is to throw away work that is all in use.
    private func pruneDerivedCaches() {
        let live = Set(items.map(\.id))
        searchBlobs = searchBlobs.filter { live.contains($0.key) }
        identityCache = identityCache.filter { live.contains($0.key) }
    }

    /// The query, parsed once per pipeline run instead of once per item.
    ///
    /// `matchesSearch` called `query.lowercased()` per item and `relevance`
    /// called `query.lowercased().split(...)` per item as well. On a 745-item
    /// library that is 745 lowercase operations and 745 array allocations to
    /// answer a question about a string the user typed once. The work is
    /// identical for every item, so it belongs outside the loop.
    struct PreparedQuery {
        let raw: String
        let lowercased: String
        let terms: [String]
        let tag: String?
        let isEmpty: Bool

        init(_ query: String) {
            raw = query
            lowercased = query.lowercased()
            isEmpty = query.isEmpty
            // "#tag" is a tag filter rather than a text search.
            tag = (query.hasPrefix("#") && query.count > 1)
                ? String(query.dropFirst()).lowercased() : nil
            terms = lowercased.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }
    }

    /// How well an item answers the current query.
    ///
    /// Deliberately simple and free: where the words land matters more than how
    /// often. A title match is what you meant; a body match is what you might
    /// have meant.
    private func relevance(of item: ClipboardItem, _ prepared: PreparedQuery) -> Int {
        let terms = prepared.terms
        guard !terms.isEmpty else { return 0 }
        let title = (item.title ?? "").lowercased()
        let tags = item.tags.joined(separator: " ").lowercased()
        let body = blob(for: item)
        var score = 0
        for term in terms {
            if title == term { score += 120 }
            else if title.hasPrefix(term) { score += 80 }
            else if title.contains(term) { score += 50 }
            if tags.contains(term) { score += 30 }
            if body.range(of: term, options: .literal) != nil { score += 10 }
            // Every term present beats one term present many times.
            if !title.contains(term) && !tags.contains(term)
                && body.range(of: term, options: .literal) == nil {
                score -= 25
            }
        }
        // A curated document you kept on purpose outranks a passing clipping.
        if item.role.isCurated { score += 8 }
        return score
    }

    private func matchesSearch(_ item: ClipboardItem, _ prepared: PreparedQuery) -> Bool {
        if let wanted = prepared.tag {
            return item.tags.contains { $0.lowercased() == wanted }
        }
        return item.matches(prepared.lowercased, mode: searchMode,
                            blob: blob(for: item), alreadyLowercased: true)
    }

    /// Kept for the call sites that have no prepared query to hand.
    private func matchesSearch(_ item: ClipboardItem) -> Bool {
        matchesSearch(item, PreparedQuery(query))
    }

    /// Every distinct tag across prompts, for the tag rail.
    var allTags: [String] {
        Array(Set(items.filter { $0.role.isCurated }.flatMap(\.tags))).sorted()
    }

    var promptCount: Int { count(ofRole: .prompt) }

    /// Says whether a combination would be accepted, without taking it.
    ///
    /// The editors need to tell you "that one is taken" as you record it, while
    /// still leaving the change unsaved until you press Save. Doing that with
    /// `setShortcut` meant validation *was* the commit: recording a shortcut
    /// bound it immediately, so Cancel could not undo it and Save had nothing
    /// left to do - which is why clearing one left Save greyed out.
    func validateShortcut(_ shortcut: String?, for id: UUID) -> String? {
        guard let shortcut, !shortcut.isEmpty else { return nil }
        return ShortcutManager.shared.conflictReason(for: shortcut, excluding: id, items: items)
    }

    /// Assigns (or clears) a per-item hotkey, keeping registration in sync.
    /// Returns nil on success, or the reason it was refused.
    @discardableResult
    func setShortcut(_ shortcut: String?, for id: UUID) -> String? {
        guard let shortcut, !shortcut.isEmpty else {
            ShortcutManager.shared.unregisterItem(id)
            update(id) { $0.shortcut = nil }
            return nil
        }
        if let reason = ShortcutManager.shared.conflictReason(for: shortcut, excluding: id, items: items) {
            return reason
        }
        guard ShortcutManager.shared.registerItem(id, shortcut: shortcut) else {
            return "macOS refused that combination"
        }
        update(id) { $0.shortcut = shortcut }
        return nil
    }

    /// Commits everything the detail editor can change - the single place
    /// both the Save button and the QA harness go through, so a test of this
    /// exercises the exact path the UI takes rather than a lookalike.
    ///
    /// Text, title and tags always commit (`update` has no failure path).
    /// The shortcut is the one part that can be refused - a conflict with
    /// another item's binding, or macOS declining the combination - so it is
    /// committed last and its outcome decides whether the session closes.
    /// On success the detail session ends, same as Cancel does when there is
    /// nothing to discard. On refusal the session stays open (`isEditing`
    /// left as-is) so the caller can show the reason and let the user fix or
    /// clear the shortcut instead of losing that context behind a closed
    /// editor.
    ///
    /// Returns the shortcut's refusal reason, or nil on a clean save.
    @discardableResult
    func commitDetailEdit(_ id: UUID, text: String?, title: String, tags: String,
                          shortcut: String, previousShortcut: String?) -> String? {
        // What the item WAS, before the edit. Read from `ItemMerge` directly
        // rather than through `cachedIdentity`, whose cache key is `updatedAt`
        // - `update` moves that, so the cached answer would be recomputed from
        // the already-edited item and every Save would look like a change.
        let identityBefore = item(id).map { ItemMerge.identity($0) }

        update(id) {
            if let text { $0.text = text }
            $0.title = title.isEmpty ? nil : title
            $0.tags = tags.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        var shortcutError: String? = nil
        if shortcut != (previousShortcut ?? "") {
            shortcutError = setShortcut(shortcut.isEmpty ? nil : shortcut, for: id)
        }
        // An edit is the other way to author a duplicate, and the one the
        // insert-path fold cannot see: two notes created separately are
        // genuinely different until somebody types the same body into the
        // second one. Without this the app holds two identical items that only
        // fold later, on some other device, when a sync happens to combine the
        // histories - so the count differs between two Macs showing the same
        // library, which is exactly the disagreement the fold exists to prevent.
        //
        // Two conditions, both added by M20/S1, because this path DELETES a row
        // and writes a tombstone that sync pushes:
        //
        // - `deduplicate` is the user's answer to "should this app fold two
        //   identical things into one". It gated capture and nothing else, so
        //   turning it off did not stop the one fold that destroys data. A
        //   preference that does not hold on the destructive path is not a
        //   preference, it is a broken setting.
        // - The identity has to have actually CHANGED. Saving an editor without
        //   typing anything ran the fold anyway, and with a deliberate
        //   duplicate on the list that Save deleted a row the user had just
        //   asked for - three clicks from Duplicate to gone, on both Macs. A
        //   Save that changes nothing must change nothing.
        let identityAfter = item(id).map { ItemMerge.identity($0) }
        if deduplicate, let identityBefore, let identityAfter,
           identityAfter != identityBefore {
            foldAfterEdit(id)
        }
        if shortcutError == nil {
            closeDetail()
        } else {
            isEditing = false
        }
        return shortcutError
    }

    // MARK: - Hand-arranged collections

    /// True when this collection has been arranged by hand.
    ///
    /// One item with an order is enough: the rest fall in behind it by date,
    /// which is what dragging one card to the top is asking for.
    private func isManuallyOrdered(_ list: [ClipboardItem]) -> Bool {
        list.contains { $0.manualOrder != nil }
    }

    /// Moves `ids` so they sit before `target`, or at the end when it is nil.
    ///
    /// Writes a contiguous order across the whole collection rather than only
    /// the moved rows. Sparse indices work until two items collide on the same
    /// number after enough drags, and then the order silently stops being the
    /// one on screen. Renumbering every time costs an update per item and
    /// removes the whole class of problem.
    @MainActor
    func reorder(_ ids: [UUID], before target: UUID?, in collection: [ClipboardItem]) {
        let moving = collection.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }

        var arranged = collection.filter { !ids.contains($0.id) }
        let insertAt = target.flatMap { id in arranged.firstIndex { $0.id == id } } ?? arranged.count
        arranged.insert(contentsOf: moving, at: insertAt)

        for (index, item) in arranged.enumerated() where item.manualOrder != index {
            update(item.id) { $0.manualOrder = index }
        }
    }

    /// Forgets the hand-arrangement of a collection, so the sort takes over.
    @MainActor
    func clearManualOrder(in collection: [ClipboardItem]) {
        for item in collection where item.manualOrder != nil {
            update(item.id) { $0.manualOrder = nil }
        }
    }

    private func applySort(_ list: [ClipboardItem]) -> [ClipboardItem] {
        applySort(list, PreparedQuery(query), isHistoryView: false)
    }

    private func applySort(_ list: [ClipboardItem], _ prepared: PreparedQuery,
                           isHistoryView: Bool) -> [ClipboardItem] {
        // A hand-arranged collection keeps its arrangement - but only while the
        // user is not asking a different question. A search is a question, and
        // so is choosing a sort other than the default; either one means "show
        // me this a different way", and silently ignoring that in favour of an
        // order set weeks ago would be the app overruling the control the user
        // just touched.
        // A hand arrangement belongs to the tab it was made in, and NEVER to the
        // unfiltered history.
        //
        // This was the bug that made copying look broken. `reorder` renumbers a
        // whole collection, so one drag inside the Designs tab gave all 74
        // design documents a manual order - and because the All tab contains
        // them, the All tab counted as hand-arranged from then on. New clips,
        // having never been dragged, sorted after all 74. On a panel that shows
        // nine rows, everything the user copied was invisible: they copied
        // something and it "did not appear".
        //
        // All is the history view. Newest first, always. The arrangement is
        // still honoured inside the curated tab where it was made.
        if prepared.isEmpty, sortOrder == .newest, !isHistoryView, isManuallyOrdered(list) {
            return list.sorted { left, right in
                switch (left.manualOrder, right.manualOrder) {
                case let (l?, r?): return l < r
                // Anything never dragged sorts FIRST, newest first, above the
                // arranged block. The other way round - which is how this
                // shipped - hides every new item behind the arrangement, and a
                // clipboard whose newest entry is off the bottom of the list is
                // not a clipboard.
                case (nil, _?):    return true
                case (_?, nil):    return false
                default:           return left.timestamp > right.timestamp
                }
            }
        }

        // A search is a question, and the best answer goes first. Without this,
        // typing "typography" returned matches in date order, so the design
        // system actually about typography could be fortieth.
        if !prepared.isEmpty, prepared.tag == nil, searchMode == .exact {
            var scored: [(item: ClipboardItem, score: Int)] = []
            scored.reserveCapacity(list.count)
            for candidate in list {
                scored.append((candidate, relevance(of: candidate, prepared)))
            }
            scored.sort { left, right in
                if left.score != right.score { return left.score > right.score }
                return left.item.timestamp > right.item.timestamp
            }
            return scored.map { $0.item }
        }
        switch sortOrder {
        case .newest:   return list.sorted { $0.timestamp > $1.timestamp }
        case .oldest:   return list.sorted { $0.timestamp < $1.timestamp }
        case .mostUsed: return list.sorted { ($0.useCount, $0.timestamp) > ($1.useCount, $1.timestamp) }
        case .kind:
            return list.sorted {
                $0.kind == $1.kind ? $0.timestamp > $1.timestamp : $0.kind.rawValue < $1.kind.rawValue
            }
        }
    }

    @MainActor
    func item(atVisibleIndex index: Int) -> ClipboardItem? {
        let list = visibleItems
        return list.indices.contains(index) ? list[index] : nil
    }

    // MARK: - Session lifecycle

    /// Called when the panel opens: land on a sensible selection.
    @MainActor
    func beginSession() {
        isDetailOpen = false
        isEditing = false
        // If the remembered tab has nothing in it, fall back to the full history
        // rather than opening on an empty panel.
        if visibleItems.isEmpty, !items.isEmpty, activeTab.category != .all {
            activeTabID = "all"
        }
        selectedID = visibleItems.first?.id
    }

    func endSession() {
        // An abandoned variable form must not outlive the panel: the hotkey
        // path is guarded on this being nil, so a stale value made the next
        // placeholder hotkey do nothing at all (proved by section 122's
        // placeholder assertion failing after section 130 left one behind).
        fillingVariablesFor = nil
        // Same rule, and the same bug, for the two pickers.
        //
        // `cancelMove` only ever ran from `KeyRouter`'s move branch (Escape
        // while the picker holds the keyboard) and from the picker's own Cancel
        // button. Every other way a panel closes - the global hotkey toggling
        // it, clicking away, `close` from the bridge - left `movingItemID` set.
        // A live `movingItemID` makes `KeyRouter` swallow the whole keyboard
        // into the move branch on the NEXT open, so the arrow walk to the Move
        // action never lands and the panel reads as dead. That is the
        // cross-section state leak the probe saw as "Move is reachable by
        // keyboard" failing in a section that never opened the picker.
        //
        // Cleared here rather than at each call site because "the panel closed"
        // is the one condition that is true of every exit path, including the
        // ones nobody has written yet.
        movingItemID = nil
        moveChoice = 0
        openingItemID = nil
        openChoice = 0
        isDetailOpen = false
        isEditing = false
        query = ""
    }

    // MARK: - Selection

    var selectedItem: ClipboardItem? {
        guard let id = selectedID else { return nil }
        return items.first { $0.id == id }
    }

    @MainActor
    var selectedIndex: Int? {
        guard let id = selectedID else { return nil }
        return visibleItems.firstIndex { $0.id == id }
    }

    func select(_ id: UUID?) {
        selectedID = id
        focusedActionIndex = nil        // a new row starts on the row itself
    }

    /// Actions available on the selected item, in the order they are drawn.
    @MainActor
    var actionsForSelection: [ItemAction] {
        guard let item = selectedItem else { return [] }
        return ItemAction.available(for: item, isPinned: isPinned(item.id))
    }

    // MARK: - Empty-tab toolbar focus

    /// Which toolbar button is focused when a curated tab has nothing in it.
    ///
    /// An empty tab has no rows to arrow through, so the arrow keys would do
    /// nothing at all — the one moment a keyboard user most needs a way in. When
    /// the list is empty the same arrows walk the toolbar instead.
    @Published var focusedEmptyAction: Int?

    /// The toolbar actions offered on an empty curated tab.
    enum EmptyAction: Int, CaseIterable {
        case create, pasteInto
        func title(_ role: ItemRole) -> String {
            switch self {
            case .create:    return "New \(role.title.lowercased())"
            case .pasteInto: return "Paste as \(role.title.lowercased())"
            }
        }
        var symbol: String { self == .create ? "plus" : "doc.on.clipboard" }
    }

    /// True when the arrow keys should drive the toolbar rather than a list.
    @MainActor
    var isEmptyTabFocusable: Bool {
        visibleItems.isEmpty && activeTab.category.roleValue != nil
    }

    @MainActor
    func stepEmptyAction(_ delta: Int) -> Bool {
        guard isEmptyTabFocusable else { return false }
        let count = EmptyAction.allCases.count
        let next = (focusedEmptyAction.map { $0 + delta }) ?? (delta > 0 ? 0 : count - 1)
        focusedEmptyAction = min(max(next, 0), count - 1)
        return true
    }

    @MainActor
    func runEmptyAction() -> Bool {
        guard isEmptyTabFocusable,
              let index = focusedEmptyAction,
              let action = EmptyAction(rawValue: index),
              let role = activeTab.category.roleValue else { return false }
        performEmpty(action, role: role)
        return true
    }

    @MainActor
    func performEmpty(_ action: EmptyAction, role: ItemRole) {
        switch action {
        case .create:
            createItem(role: role, title: "Untitled \(role.title.lowercased())")
        case .pasteInto:
            let text = TestIsolation.board.string(forType: .string) ?? ""
            guard !text.isEmpty else {
                NSSound.beep()
                NoticeCenter.shared.report("There is nothing on the clipboard to paste.", kind: .transient)
                return
            }
            createItem(role: role, title: "Pasted \(role.title.lowercased())", body: text)
        }
        focusedEmptyAction = nil
        isDetailOpen = true
    }

    // MARK: - Dropped in

    /// Accepts a file dragged onto a tab.
    ///
    /// Readable text becomes an item whose role the content earns, falling back
    /// to the tab it was dropped on. Anything else - an image, a PDF, a binary -
    /// is kept as a file reference, which is what the Files tab already holds.
    @MainActor
    func acceptDroppedFile(_ url: URL, preferredRole: ItemRole?) {
        let readable: Set<String> = ["md", "markdown", "txt", "json", "yaml", "yml",
                                     "swift", "js", "ts", "py", "rb", "go", "rs",
                                     "css", "html", "sh", "toml", "csv", "xml"]
        let ext = url.pathExtension.lowercased()

        if readable.contains(ext),
           let text = try? String(contentsOf: url, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fallbackTitle = url.deletingPathExtension().lastPathComponent
            var item = ItemClassifier.item(fromText: text,
                                           preferredRole: preferredRole,
                                           sourceAppName: "Dropped")
            // A recognised document names itself; anything else takes the
            // filename, which is what the person dragging it was looking at.
            if item.title == nil || item.role == preferredRole {
                item.title = item.title ?? fallbackTitle
            }
            addExisting(item)
            selectedID = item.id
            NoticeCenter.shared.report(
                "Added \(item.title ?? fallbackTitle) as a \(item.role.title.lowercased())",
                kind: .transient)
            return
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            NoticeCenter.shared.report("That file could not be read.", kind: .transient)
            return
        }

        let item = ClipboardItem(kind: url.hasDirectoryPath ? .folder : .file,
                                 text: url.path, filePaths: [url.path],
                                 sourceAppName: "Dropped",
                                 title: url.lastPathComponent)
        addExisting(item)
        selectedID = item.id
        NoticeCenter.shared.report("Added \(url.lastPathComponent)", kind: .transient)
    }

    /// Accepts text dragged onto a tab from another app.
    @MainActor
    func acceptDroppedText(_ text: String, preferredRole: ItemRole?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            NSSound.beep()
            NoticeCenter.shared.report("There was no text in that drop.", kind: .transient)
            return
        }
        let item = ItemClassifier.item(fromText: text,
                                       preferredRole: preferredRole,
                                       sourceAppName: "Dropped")
        // No `selectedID = item.id` here: `addExisting` may have folded this
        // into an item that is already present, and selecting the id it folded
        // away selects nothing. `addExisting` already selects the survivor.
        addExisting(item)
        NoticeCenter.shared.report("Added a \(item.role.title.lowercased())", kind: .transient)
    }

    // MARK: - Opening a link elsewhere

    /// The link whose destination app is being chosen.
    @Published var openingItemID: UUID?
    @Published var openChoice: Int = 0
    @Published private(set) var openTargets: [OpenTarget] = []

    @MainActor
    func beginOpenWith(_ id: UUID) {
        select(id)
        guard let item = item(id) else { return }
        let targets = LinkOpener.targets(for: item)
        // One option is not a choice: just open it.
        guard targets.count > 1 else {
            LinkOpener.open(item, with: targets.first)
            return
        }
        openTargets = targets
        openChoice = 0
        openingItemID = id
    }

    @MainActor
    func cancelOpenWith() {
        openingItemID = nil
        openTargets = []
    }

    @discardableResult
    @MainActor
    func commitOpenWith(_ target: OpenTarget? = nil) -> Bool {
        guard let id = openingItemID, let item = item(id) else { return false }
        let chosen = target ?? (openTargets.indices.contains(openChoice)
                                ? openTargets[openChoice] : nil)
        openingItemID = nil
        openTargets = []
        LinkOpener.open(item, with: chosen)
        Database.shared.log("open", "Opened a link in \(chosen?.name ?? "the default app")")
        return true
    }

    @MainActor
    func stepOpenChoice(_ delta: Int) {
        guard !openTargets.isEmpty else { return }
        let count = openTargets.count
        openChoice = (openChoice + delta + count) % count
    }

    // MARK: - Moving between collections

    /// The item whose destination is being chosen, if any.
    @Published var movingItemID: UUID?
    /// Which destination is highlighted in the picker.
    @Published var moveChoice: Int = 0

    /// Where an item can go. Its current home is listed but marked.
    var moveDestinations: [ItemRole] { ItemRole.allCases }

    @MainActor
    func beginMove(_ id: UUID) {
        select(id)
        movingItemID = id
        moveChoice = moveDestinations.firstIndex(of: item(id)?.role ?? .clip) ?? 0
    }

    @MainActor
    func cancelMove() {
        movingItemID = nil
    }

    /// Commits the move. Returns false when there was nothing to move.
    @discardableResult
    @MainActor
    func commitMove(to role: ItemRole? = nil) -> Bool {
        guard let id = movingItemID else { return false }
        let target = role ?? moveDestinations[min(moveChoice, moveDestinations.count - 1)]
        movingItemID = nil
        guard let current = item(id)?.role, current != target else { return true }
        setRole(id, to: target)
        return true
    }

    @MainActor
    func stepMoveChoice(_ delta: Int) {
        let count = moveDestinations.count
        moveChoice = (moveChoice + delta + count) % count
    }

    /// Right arrow: into the actions, then along them.
    @MainActor
    func focusNextAction() -> Bool {
        let actions = actionsForSelection
        guard !actions.isEmpty else { return false }
        let next = (focusedActionIndex.map { $0 + 1 }) ?? 0
        guard next < actions.count else { return false }
        focusedActionIndex = next
        return true
    }

    /// Left arrow: back along the actions, then out to the row itself.
    @MainActor
    func focusPreviousAction() -> Bool {
        guard let current = focusedActionIndex else { return false }
        focusedActionIndex = current == 0 ? nil : current - 1
        return true
    }

    /// Return on a focused action runs it instead of pasting.
    @MainActor
    func runFocusedAction() -> Bool {
        guard let index = focusedActionIndex,
              let item = selectedItem else { return false }
        let actions = actionsForSelection
        guard actions.indices.contains(index) else { return false }
        perform(actions[index], on: item)
        return true
    }

    @MainActor
    func perform(_ action: ItemAction, on item: ClipboardItem) {
        switch action {
        case .copy:
            copyOnly(item)
            // No banner (user, 03/09): the menu-bar icon already animates the
            // copy, and the copy button shows a "Copied" tooltip for 4 s.
        case .pin:    togglePin(item.id)
        case .move:   beginMove(item.id)
        case .openWith: beginOpenWith(item.id)
        case .edit:   select(item.id); isDetailOpen = true
        case .finder: revealInFinder(item)
        case .delete: deleteKeepingSelection(item.id)
        }
    }

    /// Moves the selection by `delta`, clamped to the ends of the visible list.
    @MainActor
    func moveSelection(by delta: Int) {
        let list = visibleItems
        guard !list.isEmpty else { return }
        let current = selectedIndex ?? 0
        let next = min(max(current + delta, 0), list.count - 1)
        selectedID = list[next].id
    }

    /// The single way the active tab changes.
    ///
    /// Selection has to be re-seeded here: a tab you land on with nothing
    /// selected swallows the next arrow key and looks broken. Both the tab bar
    /// and the keyboard route through this so they cannot drift apart.
    @MainActor
    func setTab(_ id: String) {
        guard id != activeTabID else { return }
        activeTabID = id
        // Each of these is its own `@Published` property, and `@Published`
        // fires `objectWillChange` on assignment regardless of whether the
        // new value equals the old one - so writing all four unconditionally
        // published four separate change notifications for one tab switch.
        // Every view holding `@EnvironmentObject var store` (the panel, the
        // tab bar, the content view, both collection views) re-evaluates its
        // whole body once per notification: `Self._printChanges()` during
        // M10b showed `PanelRootView` alone re-running ten times for a
        // single switch. Guarding each write against its current value cuts
        // that to only the publishes a switch actually needs - almost always
        // just `activeTabID` and `selectedID`, since a tab rarely has filters
        // or a focused empty-state action left over from before.
        if !activeFilters.isEmpty { activeFilters = [] }   // filters from another tab mean nothing here
        if focusedEmptyAction != nil { focusedEmptyAction = nil }
        let firstVisible = visibleItems.first?.id
        if selectedID != firstVisible { selectedID = firstVisible }
    }

    @MainActor
    func cycleTab(forward: Bool) {
        let all = TabConfiguration.shared.visible.map(\.id)
        guard !all.isEmpty else { return }
        let i = all.firstIndex(of: activeTabID) ?? 0
        let next = forward ? (i + 1) % all.count : (i - 1 + all.count) % all.count
        setTab(all[next])
    }

    func toggleDetail() { isDetailOpen.toggle() }

    func closeDetail() {
        isEditing = false
        isDetailOpen = false
    }

    // MARK: - Adding

    /// Fills in a link's page title in the background.
    ///
    /// Deliberately after the item is already in the list. Waiting on a website
    /// before showing what you copied would make the panel feel like a browser,
    /// and a site that never answers would mean a clip that never appears.
    @MainActor
    private func fetchPageTitle(for id: UUID) {
        guard PreferencesModel.shared.fetchLinkTitles,
              let item = self.item(id), item.kind == .url,
              item.pageTitle == nil, let url = URL(string: item.fullText) else { return }

        Task { [weak self] in
            guard let title = await LinkMetadata.title(for: url) else { return }
            await MainActor.run {
                // Only if the user has not named it themselves in the meantime.
                guard let current = self?.item(id), current.pageTitle == nil else { return }
                self?.update(id) { $0.pageTitle = title }
            }
        }
    }

    func add(_ item: ClipboardItem) {
        // The item that actually ends up in the library, which is NOT the one
        // passed in when a duplicate was folded into an existing entry.
        //
        // This distinction was a real bug. The version record was written for
        // the throwaway duplicate, and `addVersion` calls `_saveItem` so the
        // foreign key it is about to write has a row to point at. So every
        // deduplicated copy inserted an `items` row for an item the app had
        // just decided not to keep. Nothing in memory referenced it, and the
        // old save path was upsert-only and never deleted anything, so it sat
        // there until the next launch loaded it back as a real item. Copying
        // the same thing fifty times left fifty rows, and the duplicates the
        // user was being spared reappeared after a restart.
        var stored = item
        // `deduplicate` is the user's preference about CAPTURE: whether copying
        // the same thing twice makes a second row. It gates this path only. The
        // other insert paths fold unconditionally, because a note and a synced
        // item are not captures and the preference was never about them.
        if deduplicate, let folded = foldDuplicate(of: item) {
            stored = folded
        } else {
            items.insert(item, at: 0)
        }
        trim()
        if !stored.fullText.isEmpty {
            Database.shared.addVersion(for: stored, body: stored.fullText,
                                       title: stored.title, note: "Captured")
        }
        save()

        if item.kind == .url {
            let id = items.first(where: { $0.fullText == item.fullText })?.id ?? item.id
            MainActor.assumeIsolated { fetchPageTitle(for: id) }
        }
    }

    /// Folds `item` into an existing identical item, if there is one.
    ///
    /// The single insert-time answer to "is this already in the library", used
    /// by every path that puts an item in: capture, note/skill creation, and
    /// insertion of an item built elsewhere. Returns the surviving item when it
    /// folded, or `nil` when `item` is genuinely new.
    ///
    /// Identity and the survivor both come from `ItemMerge`, deliberately - the
    /// same two functions sync replay uses. Before this, capture had its own
    /// `duplicate(of:)` predicate (kind plus exact `fullText`) while
    /// `createItem` and `addExisting` had none at all, so "the same item" meant
    /// three different things depending on how it arrived, and two notes with
    /// identical bodies survived locally, survived token creation, and reached
    /// the second device as two items. One predicate is the only way the local
    /// answer and the cross-device answer can agree.
    ///
    /// `ItemMerge.combine` decides the survivor, so the merged item keeps the
    /// newest timestamp and the best field from either side - a pin, a title, a
    /// shortcut or a tag present on either copy survives on the one that stays.
    @discardableResult
    private func foldDuplicate(of item: ClipboardItem) -> ClipboardItem? {
        let key = cachedIdentity(of: item)
        guard let candidates = currentIdentityIndex[key] else { return nil }
        guard let existing = candidates.lazy
            .filter({ $0 != item.id })
            .compactMap({ id in self.items.first { $0.id == id } })
            .first else { return nil }

        var combined = ItemMerge.combine(existing, item)
        // The survivor keeps the ESTABLISHED id, not whichever id `combine`
        // picked by timestamp. The existing row is the one the database, any
        // per-item hotkey and the server already point at; handing the entry a
        // brand new id here would orphan all three to save nothing.
        combined.id = existing.id
        // A fold is a change, or the incremental save cannot tell the row is
        // stale and sync keeps serving the older copy.
        combined.updatedAt = Date()

        items.removeAll { $0.id == existing.id }
        items.insert(combined, at: 0)
        replaceShortcutRegistration(from: existing, to: combined)
        // `ItemMerge.combine` ORs `isPinned`, so a pin on either side survives
        // in the row - but `pinnedIDs` is the record the pinned section and
        // `trim`'s exemption actually read, and this path never touched it.
        combined.isPinned = adoptPins(losers: [item.id], survivor: combined.id)
        replace(combined)
        return combined
    }

    /// Moves the union of the folded items' pins onto the survivor.
    ///
    /// Pinning has two records: `pinnedIDs`, which the pinned section and
    /// `trim`'s exemption read, and each item's own `isPinned` flag, which is
    /// what syncs and what `merge` rebuilds `pinnedIDs` from. A fold that
    /// updated one and not the other made a pin vanish from the section, lose
    /// the trim exemption that was protecting the item from the cap, and then
    /// come back on the next sync when the flags were replayed. A pin that
    /// disappears and returns on its own is worse than either state.
    ///
    /// Returns the flag the survivor should carry, so the row and the list
    /// always agree - including when the pin cannot be honoured because the
    /// cap of four is already full, in which case the honest answer is "not
    /// pinned" rather than a flag pointing at a list that does not have it.
    @discardableResult
    private func adoptPins(losers: [UUID], survivor: UUID) -> Bool {
        let wasPinned = losers.contains { pinnedSet.contains($0) } || pinnedSet.contains(survivor)
        // The survivor takes the earliest slot any of the folded ids held, so a
        // fold does not reorder the pinned section.
        let slot = ([survivor] + losers)
            .compactMap { id in pinnedIDs.firstIndex(of: id) }
            .min()
        pinnedIDs.removeAll { losers.contains($0) || $0 == survivor }
        guard wasPinned else { return false }
        guard pinnedIDs.count < Self.maxPinnedItems else { return false }
        pinnedIDs.insert(survivor, at: min(slot ?? pinnedIDs.count, pinnedIDs.count))
        return true
    }

    /// Folds an item that an edit has just made identical to another one.
    ///
    /// Separate from `foldDuplicate` because the item is already IN the list
    /// here, so it has to come out before the fold can look for a partner -
    /// otherwise it finds itself. The survivor is written back through the same
    /// `ItemMerge.combine`, and the losing id gets the full deletion treatment
    /// (row, tombstone, hotkey) so the server hears about it exactly as it
    /// hears about a fold that happened during sync.
    private func foldAfterEdit(_ id: UUID) {
        guard let edited = item(id) else { return }
        let key = cachedIdentity(of: edited)
        guard let partner = items.first(where: {
            $0.id != id && cachedIdentity(of: $0) == key
        }) else { return }

        var combined = ItemMerge.combine(partner, edited)
        combined.id = partner.id
        combined.updatedAt = Date()

        items.removeAll { $0.id == partner.id || $0.id == id }
        items.insert(combined, at: 0)
        replaceShortcutRegistration(from: partner, to: combined)

        // The edited id is gone from this Mac, so it has to be gone from the
        // server too - the same rule `merge` applies to everything it absorbs.
        ShortcutManager.shared.unregisterItem(id)
        Database.shared.deleteItem(id)
        Database.shared.recordTombstone(id)
        if edited.isLocalOnly { Database.shared.markLocalOnlyTombstone(id) }
        if selectedID == id { selectedID = combined.id }
        // The union of both sides' pins, on both records. This used to drop the
        // edited id from `pinnedIDs` and add nothing back, while
        // `ItemMerge.combine` had already ORed `isPinned` on to the survivor.
        combined.isPinned = adoptPins(losers: [id], survivor: combined.id)
        replace(combined)
        saveNow()
    }

    /// Keeps Carbon in step when a fold changes an entry's shortcut.
    private func replaceShortcutRegistration(from old: ClipboardItem, to new: ClipboardItem) {
        guard old.shortcut != new.shortcut else { return }
        if let shortcut = new.shortcut, !shortcut.isEmpty {
            ShortcutManager.shared.registerItem(new.id, shortcut: shortcut)
        } else {
            ShortcutManager.shared.unregisterItem(new.id)
        }
    }

    /// `ItemMerge.identity` to the ids carrying it.
    ///
    /// The fold has to ask "is this already here" on the capture path, which is
    /// the one path in the app that must stay instant. A linear scan calling
    /// `ItemMerge.identity` on every item would trim and allocate a copy of
    /// every body in the library - megabytes for a library holding design
    /// documents - once per copy. The index answers in one lookup, and the
    /// identity strings behind it are cached per item, so rebuilding it after a
    /// change costs a dictionary hit per item rather than a re-trim of every
    /// body.
    private var identityIndex: [String: [UUID]] = [:]
    private var identityIndexRevision: Int = -1

    /// Cached `ItemMerge.identity`, keyed by id with an `updatedAt` stamp, so
    /// editing an item invalidates its own entry and nothing else's. Same shape
    /// as `searchBlobs` above, for the same reason.
    private var identityCache: [UUID: (stamp: Double, key: String)] = [:]

    private func cachedIdentity(of item: ClipboardItem) -> String {
        let stamp = item.updatedAt.timeIntervalSince1970
        if let hit = identityCache[item.id], hit.stamp == stamp { return hit.key }
        let key = ItemMerge.identity(item)
        // Bounded the same way the blob cache is, and pruned to the live set
        // rather than emptied - see `pruneDerivedCaches`.
        if identityCache.count > Self.derivedCacheSlack + items.count {
            pruneDerivedCaches()
        }
        identityCache[item.id] = (stamp, key)
        return key
    }

    private var currentIdentityIndex: [String: [UUID]] {
        if identityIndexRevision == contentRevision { return identityIndex }
        var index: [String: [UUID]] = [:]
        index.reserveCapacity(items.count)
        for item in items {
            index[cachedIdentity(of: item), default: []].append(item.id)
        }
        identityIndex = index
        identityIndexRevision = contentRevision
        return index
    }

    /// Applies the current cap to the library that is already here.
    ///
    /// `trim` otherwise only runs from `add`, so lowering the limit in Settings
    /// did nothing visible until the next thing was copied - the setting looked
    /// like it had been ignored, and on a Mac nobody was copying on, it had
    /// been.
    @MainActor
    func applyHistoryLimitNow() { trim() }

    #if CLIP_TESTING
    /// Runs the trim on demand, so the tombstone it writes can be checked.
    func trimForTesting() { trim() }
    #endif

    /// Deletes the media files that nothing else points at.
    ///
    /// `MediaStore` is content-addressed: the filename IS the payload, so two
    /// rows holding the same picture hold the same file. With "Remove
    /// duplicates" off, capturing one image twice is exactly that state.
    /// Deleting per dropped row therefore blanked the surviving row's
    /// thumbnail, and the app then reported missing media for an item the user
    /// had never touched. (M20/S5.)
    private static func releaseMedia(for dropped: [ClipboardItem],
                                     keeping kept: [ClipboardItem]) {
        let stillReferenced = Set(kept.compactMap(\.imageFile))
        for file in Set(dropped.compactMap(\.imageFile))
        where !stillReferenced.contains(file) {
            MediaStore.shared.delete(file)
        }
    }

    /// Applies the cap, dropping the oldest unprotected items.
    ///
    /// **A trim writes no tombstone.** (M20/S3.)
    ///
    /// A tombstone means **the user deleted this item**. It is news, it is
    /// pushed, and every other Mac acts on it by destroying its own copy.
    ///
    /// The history cap is not that. It is a LOCAL retention preference - "this
    /// Mac keeps at most N" - and it lives in `UserDefaults`, per machine, on
    /// purpose. Recording its evictions as tombstones made one Mac's shelf
    /// space a deletion order for every other Mac: an existing install whose
    /// old always-capped 200 the migration carries forward launches, `load()`
    /// drops 4,800 rows to fit, and the next sync tells a Mac that was promised
    /// unlimited history to delete 4,800 items it never capped. The user set a
    /// number in a preferences pane and lost their library on a different
    /// computer.
    ///
    /// So retention evictions are silent. The cost is honest and small: the
    /// server keeps its copy, a full pull can hand an evicted item back, and
    /// the cap drops it again. That churn is local, bounded by the cap, and
    /// entirely recoverable - the user raises the number and their items come
    /// back. The alternative was unrecoverable.
    ///
    /// Everything that IS a deletion still tombstones: `delete`, `clearAll`,
    /// `clearUnpinned`, the fold, and the sync merge's absorbed ids.
    private func trim() {
        // No cap set: unlimited saving is the default, and this is the one
        // guard that makes that true. Everything below is the capped path.
        guard let limit = effectiveHistoryLimit else { return }
        guard items.count > limit else { return }
        // Never trim pinned items or prompts — they are the ones users curate.
        var kept: [ClipboardItem] = []
        var dropped: [ClipboardItem] = []
        for item in items {
            // A shortcut is a stronger "keep this" than a pin: the user bound a
            // key to it. Dropping it would also leave Carbon firing that key
            // into "no item with that id".
            let hasShortcut = (item.shortcut ?? "").isEmpty == false
            if isPinned(item.id) || item.role.isCurated || hasShortcut || kept.count < limit {
                kept.append(item)
            } else {
                dropped.append(item)
            }
        }
        Self.releaseMedia(for: dropped, keeping: kept)
        // Defensive: nothing dropped can hold a shortcut after the exemption
        // above, but a registration must never outlive its item.
        for item in dropped where (item.shortcut ?? "").isEmpty == false {
            ShortcutManager.shared.unregisterItem(item.id)
        }
        // NO TOMBSTONE. See this function's own doc comment: an eviction to fit
        // a local cap is not a deletion, and must not travel as one.
        items = kept
        let valid = Set(items.map(\.id))
        pinnedIDs = pinnedIDs.filter { valid.contains($0) }
        // Write the removal through NOW rather than leaving it to the caller's
        // debounced `save()`. A trim is the one mutation whose whole point is
        // that rows go away on disk, and the two callers that are not `add`
        // (`trimForTesting`, and a limit lowered from Settings) never reach a
        // `save()` at all - which is exactly how a "trimmed" library came back
        // whole on the next launch.
        if !dropped.isEmpty { saveNow() }
    }

    // MARK: - Mutation

    private func replace(_ item: ClipboardItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) { items[idx] = item }
    }

    func update(_ id: UUID, _ mutate: (inout ClipboardItem) -> Void) {
        guard var item = items.first(where: { $0.id == id }) else { return }
        let before = item.fullText
        mutate(&item)
        // The one place a change is recorded as having happened. Sync compares
        // this against the server's copy; without it every edit is rejected as
        // "not newer than what I already have".
        item.updatedAt = Date()
        replace(item)
        // Any change to the body earns a version, so it can always be undone.
        if item.fullText != before {
            Database.shared.addVersion(for: item, body: item.fullText,
                                       title: item.title, note: "Edited")
        }
        save()
    }

    /// Restores an earlier revision, recording the current text first so the
    /// restore itself can be undone.
    func restore(_ version: ItemVersion, for id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        Database.shared.addVersion(for: item, body: item.fullText,
                                   title: item.title, note: "Before restore")
        update(id) {
            $0.text = version.body
            if let t = version.title { $0.title = t }
        }
        Database.shared.log("version", "Restored version \(version.id)")
    }

    func versions(for id: UUID) -> [ItemVersion] { Database.shared.versions(for: id) }

    func togglePin(_ id: UUID) {
        if let idx = pinnedIDs.firstIndex(of: id) {
            pinnedIDs.remove(at: idx)
            update(id) { $0.isPinned = false }
        } else {
            // The view disables the pin control at the cap, but this is the
            // one path a hotkey and the QA bridge both call directly, so the
            // guard has to live here too or either of them can still mint a
            // fifth pin with the button never having been enabled.
            guard pinnedIDs.count < Self.maxPinnedItems else { return }
            pinnedIDs.append(id)
            update(id) { $0.isPinned = true; $0.pinnedIndex = self.pinnedIDs.count - 1 }
        }
        save()
    }

    /// Straightens out the pinned row's ORDER from a settings snapshot that
    /// arrived from another Mac.
    ///
    /// Whether an item is pinned at all travels a different, faster path: the
    /// item's own `isPinned`/`pinnedIndex` sync as part of its ordinary row,
    /// and `merge` above rebuilds `pinnedIDs` from those flags the moment the
    /// item itself arrives. This is only the tie-breaker for the order the
    /// pinned row displays them in, sent on the settings channel's own slower
    /// cadence - so it can arrive before, after, or never relative to the
    /// items it names.
    ///
    /// An id that does not name an item on THIS Mac is dropped rather than
    /// remembered: it may be an item that has not synced yet, in which case
    /// the next settings push says the same thing again once it has, or it
    /// may be one this Mac already deleted, in which case resurrecting a pin
    /// for it is exactly the bug this guard exists to prevent.
    @MainActor
    func applyPinnedOrder(_ ids: [UUID]) {
        let valid = Set(items.map(\.id))
        let ordered = Array(ids.filter { valid.contains($0) }.prefix(Self.maxPinnedItems))
        guard !ordered.isEmpty else { return }
        pinnedIDs = ordered
        for (index, id) in ordered.enumerated() {
            update(id) { $0.isPinned = true; $0.pinnedIndex = index }
        }
        saveNow()
    }

    /// Copies an item, including its body, title and tags.
    ///
    /// Deliberately not in the hover cluster: duplicating is occasional and
    /// slightly destructive-adjacent (it grows the list), so it belongs in the
    /// context menu where you go looking for it, not under a cursor that happens
    /// to pass by.
    @MainActor
    @discardableResult
    func duplicate(_ id: UUID) -> ClipboardItem? {
        guard let original = item(id) else { return nil }
        var copy = ClipboardItem(
            kind: original.kind,
            text: original.text,
            richText: original.richText,
            imageFile: original.imageFile,
            filePaths: original.filePaths,
            hexColor: original.hexColor,
            sourceApp: original.sourceApp,
            sourceAppName: original.sourceAppName,
            timestamp: Date(),
            // Named below, where the "already taken" check can see the list.
            title: nil,
            tags: original.tags,
            role: original.role,
            language: original.language,
            platform: original.platform,
            pixelWidth: original.pixelWidth,
            pixelHeight: original.pixelHeight
        )
        // A hotkey belongs to one item; two items cannot answer the same keys.
        copy.shortcut = nil
        copy.useCount = 0

        // The copy needs a name of its own, and a name nothing else is using.
        //
        // A name is part of `ItemMerge.identity` (M20/S1). Without one, an
        // untitled clip and its copy are the same item to every fold in the
        // app - the edit fold deletes one on the next Save, and the sync fold
        // absorbs one on the next round trip. Naming it is what makes the
        // duplicate a second row that stays a second row. The counter is for
        // duplicating twice: "Text copy" and "Text copy" would fold into each
        // other for exactly the same reason.
        let base = original.title ?? original.kind.displayName
        var name = "\(base) copy"
        var attempt = 2
        while items.contains(where: { $0.title == name }) {
            name = "\(base) copy \(attempt)"
            attempt += 1
        }
        copy.title = name

        items.insert(copy, at: 0)
        Database.shared.addVersion(for: copy, body: copy.fullText,
                                   title: copy.title, note: "Duplicated")
        save()
        select(copy.id)
        return copy
    }

    func togglePrompt(_ id: UUID) {
        setRole(id, to: item(id)?.role == .prompt ? .clip : .prompt)
    }

    func item(_ id: UUID) -> ClipboardItem? { items.first { $0.id == id } }

    /// Moves an item between the curated collections.
    func setRole(_ id: UUID, to role: ItemRole) {
        update(id) { $0.role = role }
        Database.shared.log("role", "\(id.uuidString.prefix(8)) -> \(role.rawValue)")
    }

    /// Creates an empty note or skill and selects it for editing.
    @discardableResult
    @MainActor
    func createItem(role: ItemRole, title: String, body: String = "") -> ClipboardItem {
        let item = ClipboardItem(kind: .text, text: body,
                                 sourceAppName: "Clip",
                                 title: title,
                                 role: role)
        // A note created with content identical to one already here IS that
        // note. This path used to insert unconditionally, which is how two
        // notes with the same body survived locally, survived token creation,
        // and arrived at the second device as two items.
        //
        // Empty-bodied creation is exempt on purpose: `ItemMerge.identity`
        // distinguishes a body-less note by its title alone, so folding here
        // would make "New note" twice return the first one and look like the
        // button had stopped working. There is no duplicate content yet to
        // merge - the fold applies the moment something is typed in.
        let stored: ClipboardItem
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let folded = foldDuplicate(of: item) {
            stored = folded
        } else {
            items.insert(item, at: 0)
            stored = item
        }
        Database.shared.addVersion(for: stored, body: body, title: title, note: "Created")
        save()
        selectedID = stored.id
        return stored
    }

    /// Inserts an item that was built elsewhere, exactly as given.
    ///
    /// `add` is for captures: it deduplicates against recent history and stamps
    /// a "Captured" version. A skill taken from the library is neither, and
    /// routing it through capture would file it under the wrong story.
    @MainActor
    func addExisting(_ item: ClipboardItem) {
        // Also folds. Taking the same skill from the library twice is the most
        // ordinary way to end up with two identical items, and "exactly as
        // given" was never meant to include "even if it is already here".
        let stored = foldDuplicate(of: item) ?? {
            items.insert(item, at: 0)
            return item
        }()
        Database.shared.addVersion(for: stored, body: stored.fullText,
                                   title: stored.title, note: "Added from the library")
        save()
        selectedID = stored.id
    }

    /// Opens Finder with the item's file selected.
    func revealInFinder(_ item: ClipboardItem) {
        var paths = item.filePaths
        // An image or video captured from the pasteboard lives in our media
        // folder rather than having a user-visible path of its own.
        if paths.isEmpty, let media = item.imageFile,
           let url = MediaStore.shared.url(for: media) {
            paths = [url.path]
        }
        guard !paths.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }

    /// Deletes an item.
    ///
    /// `recordDeletion` writes a tombstone so the other Macs learn about it. It
    /// is false only when the local list is being cleared to make room for a
    /// token's copy: that user asked to *receive* everything, and tombstoning
    /// their old items would delete the incoming data everywhere instead.
    func delete(_ id: UUID, recordDeletion: Bool = true) {
        var wasLocalOnly = false
        if let idx = items.firstIndex(where: { $0.id == id }) {
            wasLocalOnly = items[idx].isLocalOnly
            if let f = items[idx].imageFile { MediaStore.shared.delete(f) }
            if let s = items[idx].shortcut, !s.isEmpty { ShortcutManager.shared.unregisterItem(id) }
            items.remove(at: idx)
        }
        pinnedIDs.removeAll { $0 == id }
        if selectedID == id { selectedID = nil }
        Database.shared.deleteItem(id)
        if recordDeletion {
            Database.shared.recordTombstone(id)
            // The item never left this Mac, so its deletion is not news
            // anywhere else - the tombstone stays local and is never pushed.
            if wasLocalOnly { Database.shared.markLocalOnlyTombstone(id) }
        }
        save()
    }

    /// Delete but keep the cursor somewhere sensible, so ⌥⌫ can be repeated.
    ///
    /// Every way a person deletes a row - ⌥⌫, the row's own action, the context
    /// menu - arrives here, which is why the undo window is armed here rather
    /// than at each of those three call sites.
    @MainActor
    func deleteKeepingSelection(_ id: UUID) {
        let list = visibleItems
        let idx = list.firstIndex { $0.id == id }
        deleteWithUndo(id)
        let updated = visibleItems
        if let idx, !updated.isEmpty {
            selectedID = updated[min(idx, updated.count - 1)].id
        } else {
            selectedID = updated.first?.id
        }
    }

    // MARK: - Delete with undo

    /// Takes a row out of the list at once and holds every irreversible part of
    /// the delete for `undoDeleteWindow` seconds.
    ///
    /// The order matters and is the whole reason this is not "delete, then put
    /// it back if asked". A real delete destroys the item's media file, drops
    /// its database row and writes a tombstone that tells every other Mac to
    /// drop it too. None of that can be undone locally, and the tombstone least
    /// of all: resurrecting an id another Mac has already buried is exactly the
    /// shape of the data-loss defects this file has been bitten by before. So
    /// nothing is destroyed until the window closes. Undo simply means the
    /// destruction never happened.
    ///
    /// The hotkey is the one thing released immediately, because leaving it
    /// registered would let a global shortcut paste a row that is no longer in
    /// the list; it is re-registered by `undoPendingDelete`.
    @MainActor
    func deleteWithUndo(_ id: UUID) {
        // One pending delete at a time. A second delete finishes the first,
        // rather than the first quietly losing its undo while its notice is
        // still on screen offering it.
        commitPendingDelete()

        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        let pinIndex = pinnedIDs.firstIndex(of: id)

        if let s = item.shortcut, !s.isEmpty { ShortcutManager.shared.unregisterItem(id) }
        items.remove(at: index)
        pinnedIDs.removeAll { $0 == id }
        if selectedID == id { selectedID = nil }

        // No full stop after a preview that was already cut short: the limit
        // ends it with an ellipsis, and "Deleted func greet(name: String)…."
        // is what appending one blindly reads like.
        let preview = item.copyConfirmation(limit: 28)
        let ends = preview.last.map { ".…!?".contains($0) } ?? true
        let notice = NoticeCenter.shared.report(
            "Deleted \(preview)\(ends ? "" : ".")",
            action: .init(title: "Undo") { HistoryStore.shared.undoPendingDelete() })

        pendingDelete = PendingDelete(item: item, index: index,
                                      pinIndex: pinIndex, noticeID: notice.id)

        let work = DispatchWorkItem { MainActor.assumeIsolated { HistoryStore.shared.commitPendingDelete() } }
        pendingDeleteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoDeleteWindow, execute: work)
    }

    /// Puts the row back where it was, with its pin and its hotkey.
    @MainActor
    func undoPendingDelete() {
        guard let pending = pendingDelete else { return }
        pendingDeleteWork?.cancel()
        pendingDeleteWork = nil
        pendingDelete = nil

        // Nothing was tombstoned, so the other Macs still have this row and a
        // pull inside the window can put it back on its own. Inserting again
        // would make two of it.
        if !items.contains(where: { $0.id == pending.item.id }) {
            items.insert(pending.item, at: min(pending.index, items.count))
        }
        if let pinIndex = pending.pinIndex {
            pinnedIDs.insert(pending.item.id, at: min(pinIndex, pinnedIDs.count))
        }
        if let s = pending.item.shortcut, !s.isEmpty,
           !ShortcutManager.shared.registerItem(pending.item.id, shortcut: s) {
            // Not swallowed: the row is back but one of its behaviours is not,
            // and a hotkey that stops working with no explanation reads as the
            // undo having half failed.
            NoticeCenter.shared.report(
                "\(pending.item.displayTitle) is back, but its shortcut \(s) could not be registered again.",
                remedy: "Another app may have taken it. Set it again from the item's own menu.")
        }
        selectedID = pending.item.id
        NoticeCenter.shared.dismiss(pending.noticeID)
        // The row left the list without a save, so the database may still hold
        // it or may have been diffed since. Either way this makes disk agree
        // with the list again.
        save()
    }

    /// Ends the window and does the destructive part for real.
    ///
    /// Safe to call when nothing is pending, which is what lets the delete path,
    /// the timer and quit all call it without checking first.
    @MainActor
    func commitPendingDelete() {
        guard let pending = pendingDelete else { return }
        pendingDeleteWork?.cancel()
        pendingDeleteWork = nil
        pendingDelete = nil
        NoticeCenter.shared.dismiss(pending.noticeID)

        // The row is already out of the list, so put it back for the one call
        // that knows how to destroy it properly: media file, database row,
        // tombstone and hotkey, in the order `delete` established.
        items.insert(pending.item, at: min(pending.index, items.count))
        delete(pending.item.id)
    }

    @MainActor
    func clearUnpinned() {
        // A row waiting inside its undo window is already out of the list.
        // Finishing it here keeps it out: undoing after a clear would put a
        // single row back into a list the person had just emptied.
        commitPendingDelete()
        let survivors = items.filter { isPinned($0.id) || $0.role.isCurated }
        for item in items where !survivors.contains(where: { $0.id == item.id }) {
            if let f = item.imageFile { MediaStore.shared.delete(f) }
            Database.shared.recordTombstone(item.id)
            if item.isLocalOnly { Database.shared.markLocalOnlyTombstone(item.id) }
        }
        items = survivors
        selectedID = visibleItems.first?.id
        save()
    }

    /// Folds another Mac's items into this one's without duplicating anything.
    ///
    /// Used by sync and by import. Both sides keep their pins, titles, tags and
    /// hotkeys because `ItemMerge` picks the configured value from either copy
    /// rather than letting one list win wholesale.
    @discardableResult
    func merge(_ incoming: [ClipboardItem]) -> (added: Int, combined: Int) {
        let before = items.count
        // Snapshot of what each surviving id was bound to before the merge, so
        // the Carbon reconciliation below can register only what actually
        // changed instead of tearing down and rebuilding every hotkey.
        let previousShortcuts = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.shortcut) })
        // Whether each id being folded away named a local-only item, read
        // BEFORE the merge - once `ItemMerge.combine` has folded two ids into
        // one, the losing id's own kind is gone. `uniquingKeysWith` because the
        // same id can appear in both `items` and `incoming` (an id-match merge).
        let wasLocalOnly = Dictionary((items + incoming).map { ($0.id, $0.isLocalOnly) },
                                      uniquingKeysWith: { a, b in a || b })
        let result = ItemMerge.merge(incoming, into: items)
        let merged = result.items
        let added = merged.count - before
        items = merged

        // An id that lost its identity to another item is gone from this Mac, so
        // it has to be gone from the token too. Without this the server keeps
        // every duplicate, sends them all back on the next sync, and the two
        // sides disagree about the item count permanently.
        for id in result.absorbed {
            Database.shared.deleteItem(id)
            Database.shared.recordTombstone(id)
            // Folding two local-only items (or a local-only item into itself
            // by id) never told the server about the losing id either - see
            // `delete(_:recordDeletion:)` for the same rule at the ordinary
            // deletion path.
            if wasLocalOnly[id] == true { Database.shared.markLocalOnlyTombstone(id) }
            // The absorbed id no longer names an item, so any hotkey Carbon
            // still holds for it would fire into nothing. `setShortcut` is
            // the only other place that unregisters, and it never sees this
            // id once ItemMerge has folded it away.
            ShortcutManager.shared.unregisterItem(id)
        }

        // `ItemMerge` preserves a hotkey from either device, but writes it
        // straight into `items` rather than going through `setShortcut` - the
        // only other path that talks to Carbon. Left alone, a shortcut that
        // arrived by sync sits in the model registered nowhere, and pressing
        // it does nothing. Reconcile just what changed: register an id whose
        // shortcut is new or different from before the merge, unregister one
        // whose shortcut was cleared by the merge. Comparing to the pre-merge
        // snapshot (rather than blanket re-registering every item) means an
        // id whose shortcut did not change is skipped entirely, so it is
        // never double-registered here.
        for item in merged {
            let previous = previousShortcuts[item.id] ?? nil
            guard previous != item.shortcut else { continue }
            if let shortcut = item.shortcut, !shortcut.isEmpty {
                ShortcutManager.shared.registerItem(item.id, shortcut: shortcut)
            } else {
                ShortcutManager.shared.unregisterItem(item.id)
            }
        }
        // A pin can arrive from the other side, so the pin list is rebuilt from
        // the merged items rather than kept as it was. Two devices can each be
        // at the cap independently, so their union can still be over it - this
        // is the one mutation path that never goes through `togglePin`'s own
        // guard, so the cap is re-applied here explicitly. Anything past the
        // cap has its flag cleared too, or the next merge would compute the
        // same overflow again from a pin nothing local ever asked for.
        //
        // Sorted by `pinnedIndex` before either the cap or the display order
        // is decided: without this, both were taken straight from `merged`'s
        // own order, which is whatever ordinary sort or arrival order the
        // items happen to sit in - not the order either Mac actually pinned
        // them in. That let a resync silently reshuffle the pinned row, and
        // let the cap drop the item pinned FIRST while a later pin survived.
        let allPinned = merged.filter(\.isPinned).sorted { $0.pinnedIndex < $1.pinnedIndex }
        let kept = allPinned.prefix(Self.maxPinnedItems)
        let keptIDs = Set(kept.map(\.id))
        for item in allPinned where !keptIDs.contains(item.id) {
            update(item.id) { $0.isPinned = false }
        }
        pinnedIDs = kept.map(\.id)
        saveNow()
        Database.shared.log("merge", "Merged \(incoming.count) item(s): \(added) new, \(incoming.count - added) combined")
        return (added, incoming.count - added)
    }

    /// Empties the list.
    ///
    /// See `delete(_:recordDeletion:)` for why the flag exists: clearing to make
    /// room for a token's data must not tell the server to delete that data.
    func clearAll(recordDeletions: Bool = true) {
        for item in items { if let f = item.imageFile { MediaStore.shared.delete(f) } }
        if recordDeletions {
            for item in items {
                Database.shared.recordTombstone(item.id)
                if item.isLocalOnly { Database.shared.markLocalOnlyTombstone(item.id) }
            }
        }
        ShortcutManager.shared.unregisterAllItems()
        items = []
        pinnedIDs = []
        selectedID = nil
        // A mark pointing at an item that no longer exists is a leak: the
        // footer would offer to paste a set that is not there any more.
        markedIDs = []
        Database.shared.deleteAllItems()
        persisted = [:]
        saveNow()
    }

    /// Kept for the Clear button / terminate hook.
    func clearHistory() { clearAll() }

    // MARK: - Persistence (SQLite; see Database.swift for why)

    /// Debounced so a burst of edits doesn't hit the disk once per keystroke.
    private var saveWorkItem: DispatchWorkItem?

    /// Every database write from `save()` or `saveNow()` runs on this one
    /// serial queue, never the global concurrent pool - so two writes are
    /// never literally concurrent with each other, only ever ordered.
    private static let writeQueue = DispatchQueue(label: "com.clip.historystore.write")

    /// Every call to `save()` (not `saveNow()`, which always writes) takes
    /// the next number here, at call time, on the caller's (main) thread.
    private var nextWriteGeneration = 0

    /// The generation of the debounced write that most recently actually
    /// reached the database, or 0 if none has. Read and written ONLY from
    /// `writeQueue`, guarding against the one case ordering alone cannot
    /// fix: `cancel()` is a documented no-op once a block has started
    /// running, so `flushPending()` below (called synchronously from
    /// `saveNow`) and the original timer can both attempt to run the SAME
    /// debounced write. Whichever reaches `commit` first wins; the other is
    /// skipped, never double-applying it.
    private static var lastCommittedGeneration = 0

    /// What a still-pending debounced `save()` will write, captured at
    /// `save()`'s call time - `nil` once it has been committed (by its own
    /// timer or by an earlier `flushPending()`) or superseded.
    private var pendingWrite: (generation: Int, snapshot: [ClipboardItem],
                                known: [UUID: Date], pins: [UUID])?

    /// Applies one write if (and only if) nothing newer has already
    /// committed. Must run on `writeQueue`.
    private static func commit(generation: Int, snapshot: [ClipboardItem],
                                known: [UUID: Date], pins: [UUID]) -> [UUID: Date]? {
        guard generation > lastCommittedGeneration else { return nil }
        let written = writeDiff(snapshot, known: known, pins: pins)
        lastCommittedGeneration = generation
        return written
    }

    /// What the database is believed to already hold: id to the `updatedAt` that
    /// was written for it.
    ///
    /// Every mutation funnels through `update`, which stamps `updatedAt`, so
    /// comparing against this map says exactly which items changed. Anything in
    /// the map that is no longer in `items` was removed and its row has to go.
    private var persisted: [UUID: Date] = [:]

    /// Persists only what changed.
    ///
    /// This used to re-encode and re-write **every item in the library** for a
    /// single copy, edit or pin toggle: `saveItems` is a loop of upserts over
    /// the whole array, and each upsert JSON-encodes its item. With a library
    /// that includes 20 KB design documents that is megabytes of encoding per
    /// keystroke-sized change. It ran on a background queue, so it did not
    /// block the UI directly, but `Database` funnels every statement through
    /// one serial queue that main-thread reads also use, so a large save
    /// blocked the next read from the UI.
    ///
    /// It also never deleted anything. `saveItems` is upsert-only, so items
    /// dropped by `trim` stayed in the database and came back on the next
    /// launch: `historyLimit` bounded what was in memory and nothing at all on
    /// disk. Making the write a diff fixes the performance problem and that bug
    /// with one mechanism, because "make the database match the list" has to
    /// consider removals to be correct at all.
    func save() {
        saveWorkItem?.cancel()
        // Snapshot at schedule time, on the caller's thread. The previous
        // version read `self.items` from a background queue while the main
        // thread was free to mutate it.
        let snapshot = items
        let pins = pinnedIDs
        let known = persisted
        nextWriteGeneration += 1
        let myGeneration = nextWriteGeneration
        pendingWrite = (myGeneration, snapshot, known, pins)
        let work = DispatchWorkItem { [weak self] in
            // Already running ON writeQueue (see the asyncAfter below) - no
            // further hop needed.
            guard let self, let written = Self.commit(generation: myGeneration, snapshot: snapshot,
                                                       known: known, pins: pins) else { return }
            DispatchQueue.main.async {
                self.persisted = written
                if self.pendingWrite?.generation == myGeneration { self.pendingWrite = nil }
            }
        }
        saveWorkItem = work
        Self.writeQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    #if CLIP_TESTING
    /// Makes the next `saveNow()` report failure without touching the
    /// database at all, so `applicationWillTerminate`'s emergency-snapshot
    /// path (M4 row 25) can be proved without a real disk fault. Reset
    /// automatically after it fires once - a forced quit-time failure is a
    /// one-shot event to test, not a standing condition.
    static var forceNextSaveFailureForTesting = false
    #endif

    /// Writes immediately - used on quit, where a debounce would lose the tail.
    ///
    /// Returns whether the write actually happened. `applicationWillTerminate`
    /// used to call this and walk away regardless of the answer - the one
    /// moment there is no next tick to retry on. A real per-write failure
    /// signal from `Database` is tracked separately (M1/M3); this return
    /// value is wired up and ready for it, and today the forced-failure hook
    /// above is what lets M4's row 25 own the emergency-snapshot behaviour
    /// without waiting on that.
    @discardableResult
    func saveNow() -> Bool {
        saveWorkItem?.cancel()
        #if CLIP_TESTING
        if HistoryStore.forceNextSaveFailureForTesting {
            HistoryStore.forceNextSaveFailureForTesting = false
            return false
        }
        #endif
        // Flush any pending debounced write FIRST, using ITS OWN captured
        // snapshot, so `persisted` reflects what was true before this call
        // (a trim, most of the time) - not what was true when it was last
        // written to disk. Skipping this and computing our own diff
        // straight against a `persisted` that has never heard of the rows a
        // trim just dropped leaves `writeDiff`'s explicit `removed` list
        // empty for every one of them, so they fall through to
        // `reconcileItems`' safety valve (M3.6), which refuses to remove
        // more than a handful of rows at once - exactly the shape of a
        // retention cap, so the rows never leave the database at all.
        // `commit`'s generation check keeps this safe even if the original
        // timer also goes on to fire despite `cancel()` above having been a
        // documented no-op: whichever of the two reaches `commit` first
        // wins, the other is skipped, so the same pending write can never
        // apply twice.
        if let pending = pendingWrite {
            pendingWrite = nil
            Self.writeQueue.sync {
                if let written = Self.commit(generation: pending.generation, snapshot: pending.snapshot,
                                              known: pending.known, pins: pending.pins) {
                    persisted = written
                }
            }
        }
        // Now our own fresh diff, against whatever `persisted` is now -
        // current, whether it just got updated above or was already so.
        let snapshot = items
        let pins = pinnedIDs
        nextWriteGeneration += 1
        let myGeneration = nextWriteGeneration
        Self.writeQueue.sync {
            if let written = Self.commit(generation: myGeneration, snapshot: snapshot,
                                          known: persisted, pins: pins) {
                persisted = written
            }
        }
        return true
    }

    /// Brings the database into line with `snapshot`, and returns the new
    /// record of what it holds.
    private static func writeDiff(_ snapshot: [ClipboardItem],
                                  known: [UUID: Date],
                                  pins: [UUID]) -> [UUID: Date] {
        var changed: [ClipboardItem] = []
        var next: [UUID: Date] = [:]
        next.reserveCapacity(snapshot.count)
        for item in snapshot {
            next[item.id] = item.updatedAt
            if known[item.id] != item.updatedAt { changed.append(item) }
        }
        let removed = known.keys.filter { next[$0] == nil }

        guard !changed.isEmpty || !removed.isEmpty else {
            Database.shared.reconcileItems(with: Set(next.keys))
            Database.shared.setPreference("pinnedIDs", pins.map(\.uuidString).joined(separator: ","))
            return next
        }
        Database.shared.applyChanges(saving: changed, deleting: removed)
        // Then make the stored set match the list exactly. `applyChanges` can
        // only remove what this layer remembers writing, and it is not the only
        // writer.
        Database.shared.reconcileItems(with: Set(next.keys))
        Database.shared.setPreference("pinnedIDs", pins.map(\.uuidString).joined(separator: ","))
        return next
    }

    /// Discards memory and reads the database back. Test-facing.
    @MainActor
    func reloadFromDisk() {
        derivedCache = nil
        filterChipCache = nil
        identityIndexRevision = -1
        load()
    }

    private func load() {
        var loaded = Database.shared.loadItems()

        // A tombstoned row must never come back as an item.
        //
        // `trim` records a tombstone and the save diff deletes the row, so in a
        // healthy library these two agree and this filter removes nothing. They
        // can disagree: the delete and the tombstone are separate statements, a
        // sync pull can re-insert a row whose tombstone this Mac already holds,
        // and a crash between the two leaves the row behind. Every one of those
        // shows up to the user as an item they deleted reappearing at launch,
        // which is the failure this filter exists to make impossible. The
        // tombstone is the record of intent, so it wins over the row.
        let deleted = Set(Database.shared.tombstones().map(\.id))
        if !deleted.isEmpty {
            loaded.removeAll { deleted.contains($0.id) }
        }

        // The cap applies to what is read back, not only to what is added.
        // Without this a library that grew while the cap was off (or on another
        // Mac) is fully re-inflated on the next launch, and the cap only ever
        // describes the session it was set in. Same exemptions as `trim`, for
        // the same reasons - a pinned or curated item is never what the user
        // meant to drop.
        if let limit = effectiveHistoryLimit, loaded.count > limit {
            var kept: [ClipboardItem] = []
            var dropped: [ClipboardItem] = []
            let pins = Set((Database.shared.preference("pinnedIDs") ?? "")
                .split(separator: ",").compactMap { UUID(uuidString: String($0)) })
            for item in loaded {
                let hasShortcut = (item.shortcut ?? "").isEmpty == false
                if pins.contains(item.id) || item.role.isCurated || hasShortcut || kept.count < limit {
                    kept.append(item)
                } else {
                    dropped.append(item)
                }
            }
            // Same bookkeeping the in-session trim does, and the same limit on
            // it: the rows go, the shared media file goes only when nothing
            // kept still points at it (M20/S5), and NO TOMBSTONE is written
            // (M20/S3 - see `trim`). This is the launch-time copy of the cap,
            // so before M20 an existing install's migrated 200 could hand
            // thousands of delete rows to a Mac that had never set a cap, one
            // second after it started up.
            Self.releaseMedia(for: dropped, keeping: kept)
            for item in dropped {
                Database.shared.deleteItem(item.id)
            }
            loaded = kept
        }

        items = loaded
        // Seed the watermark from what was just read, or the first save would
        // consider the entire library changed and write all of it.
        persisted = Dictionary(items.map { ($0.id, $0.updatedAt) },
                               uniquingKeysWith: { a, _ in a })
        let valid = Set(items.map(\.id))
        // Capped defensively too: a preference written by an older build (or
        // edited by hand) predates the cap and could still hold more than
        // four, and reading it back is a fifth mutation path this store does
        // not control.
        pinnedIDs = (Database.shared.preference("pinnedIDs") ?? "")
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
            .filter { valid.contains($0) }
            .prefix(Self.maxPinnedItems)
            .map { $0 }
    }

    // MARK: - Paste

    /// Single model-level entry point for primary activation across all panel surfaces.
    @MainActor
    @discardableResult
    func activatePrimary(_ item: ClipboardItem, presentation: PrimaryActivationPresentation = .historyList) -> PrimaryActivationOutcome {
        select(item.id)

        switch presentation {
        case .historyList, .historyGallery, .curatedGallery:
            if PromptVariables.hasVariables(item.fullText), fillingVariablesFor == nil {
                requestPaste(item)
                return .awaitingVariables
            }
            requestPaste(item)
            return .pasted

        case .curatedList:
            if item.role == .prompt || item.kind == .file || item.kind == .folder {
                if PromptVariables.hasVariables(item.fullText), fillingVariablesFor == nil {
                    requestPaste(item)
                    return .awaitingVariables
                }
                requestPaste(item)
                return .pasted
            } else {
                isDetailOpen = true
                return .openedDetail
            }
        }
    }

    /// Writes the item to the pasteboard and asks the delegate to send ⌘V.
    func requestPaste(_ item: ClipboardItem, plain: Bool = false) {
        // A prompt with placeholders asks for them before it goes anywhere.
        // Pasting it raw would put "{{client}}" into someone's chat window,
        // which is the failure this feature exists to prevent.
        if PromptVariables.hasVariables(item.fullText), fillingVariablesFor == nil {
            PasteTrace.note("filling-variables")
            fillingVariablesFor = item
            return
        }
        ClipboardWriter.write(item, plain: plain)
        update(item.id) { $0.useCount += 1 }
        PasteTrace.note("ticket")
        pasteTicket = PasteTicket(item: item, plain: plain)
    }

    /// Copies to the pasteboard without synthesising a keystroke.
    func copyOnly(_ item: ClipboardItem) {
        ClipboardWriter.write(item, plain: false)
        update(item.id) { $0.useCount += 1 }
    }
}

// MARK: - Primary Activation Types

/// The UI context in which a primary activation gesture occurred.
enum PrimaryActivationPresentation: String, Equatable, CaseIterable {
    case historyList
    case historyGallery
    case curatedList
    case curatedGallery
}

/// The explicit outcome of a primary activation gesture.
enum PrimaryActivationOutcome: String, Equatable {
    case pasted
    case openedDetail
    case awaitingVariables
    case unavailable
}

// MARK: - Path Resolution

enum PathResolver {
    /// Resolves file paths for .file and .folder items.
    /// Prefers persisted `filePaths`, deduplicates while preserving order, ignores empty paths.
    /// If `filePaths` is empty and kind is .file or .folder, falls back to `item.text`.
    static func resolvePaths(for item: ClipboardItem) -> [String] {
        guard item.kind == .file || item.kind == .folder else { return [] }
        var result: [String] = []
        var seen = Set<String>()
        for p in item.filePaths {
            let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }
        if result.isEmpty, let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            result.append(text)
        }
        return result
    }
}

// MARK: - Writing to the pasteboard

enum ClipboardWriter {

    /// `plain` strips formatting (Maccy's ⌥⇧↩ behaviour).
    static func write(_ item: ClipboardItem, plain: Bool) {
        let pb = TestIsolation.board

        switch item.kind {
        case .text, .url, .code, .emoji:
            pb.clearContents()
            pb.setString(item.fullText, forType: .string)

        case .richText:
            pb.clearContents()
            if plain {
                pb.setString(item.fullText, forType: .string)
            } else {
                if let d = item.richText { pb.setData(d, forType: .rtf) }
                // Always include plain text so non-rich targets still paste.
                pb.setString(item.fullText, forType: .string)
            }

        case .image:
            // The payload is built BEFORE anything is cleared. This used to
            // clear the pasteboard first and only THEN check whether the
            // media file was still on disk, so a missing image emptied the
            // pasteboard and pasted nothing - the worst outcome, because it
            // looks exactly like a paste that worked. Now clearContents only
            // runs once there is something to put in its place, and when the
            // image is gone that something is the item's own title, with the
            // person told why.
            if let f = item.imageFile, let data = MediaStore.shared.data(for: f) {
                pb.clearContents()
                pb.setData(data, forType: .png)
                if let img = NSImage(data: data), let tiff = img.tiffRepresentation {
                    pb.setData(tiff, forType: .tiff)
                }
            } else {
                pb.clearContents()
                pb.setString(item.displayTitle, forType: .string)
                MainActor.assumeIsolated {
                    NoticeCenter.shared.report(.mediaMissing(file: item.imageFile ?? "unknown"))
                }
            }

        case .file, .folder:
            // File and folder items paste only their filesystem path as plain text.
            // They must never place a file URL, NSURL, or file reference on the pasteboard.
            // PathResolver prefers persisted filePaths and falls back to item.text for legacy items.
            let paths = PathResolver.resolvePaths(for: item)
            guard let path = paths.first, !path.isEmpty else {
                // If no valid path can be resolved, leave the clipboard untouched
                // and inform the person via a transient notice.
                MainActor.assumeIsolated {
                    NoticeCenter.shared.report("Could not resolve path for item.", kind: .transient)
                }
                return
            }
            pb.clearContents()
            pb.setString(path, forType: .string)

        case .video:
            pb.clearContents()
            // A video came from copied paths, so paste the file itself as a file URL.
            // `imageFile` on a video is only a poster frame for the preview and
            // must never be what gets pasted.
            //
            // Only paths that still exist are written as file URLs. A path typed
            // from its shape alone - copied from another Mac, or out of a chat -
            // has no file behind it, and a file URL pointing at nothing pastes as
            // nothing at all. The plain text always goes on, so it pastes somewhere.
            let paths = item.filePaths.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let present = paths.filter { FileManager.default.fileExists(atPath: $0) }
            let urls = present.map { URL(fileURLWithPath: $0) as NSURL }

            if plain {
                if let first = paths.first { pb.setString(first, forType: .string) }
            } else {
                if !urls.isEmpty {
                    let success = pb.writeObjects(urls)
                    if !success {
                        _ = MainActor.assumeIsolated {
                            NoticeCenter.shared.report("Could not write file reference to clipboard.", kind: .transient)
                        }
                    }
                } else if !paths.isEmpty {
                    _ = MainActor.assumeIsolated {
                        NoticeCenter.shared.report("This path no longer exists on disk.", kind: .transient)
                    }
                }
                if let first = paths.first { pb.setString(first, forType: .string) }
            }

        case .color, .colorData:
            pb.clearContents()
            if let h = item.hexColor { pb.setString(h, forType: .string) }
        }
    }
}
