import SwiftUI

/// Which tabs the panel shows, in what order, and how each one looks.
///
/// Rebuilt 05/09 against three jobs, in the user's own priority order:
/// **see the tabs you have**, **add one from the ones you do not**, **change
/// how a tab shows its content**. The page before it did all three at once and
/// signposted none of them: reordering was a bare `onMove` with nothing on the
/// row to say a row could be dragged, and the tabs you could add were behind a
/// collapsed disclosure below the fold, so "where do I add a tab" had no
/// visible answer at all.
///
/// The pattern is the one every app that ships this screen has converged on
/// (Garmin Connect's Edit Tabs, Yahoo News' Edit Navigation, Todoist's
/// Navigation, all on Mobbin): two labelled lists, a minus on each row of the
/// first and a plus on each row of the second, and a grip that says the row
/// moves. The affordance is drawn, never implied.
struct TabsPane: View {
    @ObservedObject private var config = TabConfiguration.shared
    @EnvironmentObject var store: HistoryStore

    private var visible: [TabSpec] { config.tabs.filter(\.isVisible) }
    private var available: [TabSpec] { config.tabs.filter { !$0.isVisible } }

    var body: some View {
        VStack(spacing: 0) {
            List {
                SettingsHero(icon: "rectangle.split.3x1", title: "Tabs",
                             purpose: "Which tabs the panel shows, in what order, and how each one looks.")
                    .listRowInsets(EdgeInsets(top: Spacing.tight, leading: 0,
                                              bottom: Spacing.related, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                Section {
                    ForEach(visible) { spec in
                        visibleRow(spec)
                    }
                    .onMove { offsets, destination in move(offsets, destination) }
                    if visible.isEmpty {
                        Text("No tabs are on. Add one below.")
                            .font(.caption).foregroundStyle(SettingsPalette.note)
                    }
                } header: {
                    header("In the panel", detail: "Drag the grip to reorder.")
                }

                Section {
                    if available.isEmpty {
                        Text("Every tab is already in the panel.")
                            .font(.caption).foregroundStyle(SettingsPalette.note)
                    }
                    ForEach(available) { spec in
                        availableRow(spec)
                    }
                } header: {
                    header("Available", detail: "Press + to put one in the panel.")
                }
            }
            // The themed page shows through. This List painted its own native
            // ground, which stayed WHITE with the window pinned to Dark - 64%
            // of the pane, measured 07/09 from a real screen capture. The
            // offscreen path renders any List light either way, so it could
            // not have told this apart from an artifact.
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                SecondaryButton("Restore Defaults", size: .small) { config.resetToDefaults() }
                Spacer()
                Text("\(config.visible.count) in the panel · \(available.count) available")
                    .font(.caption).foregroundStyle(SettingsPalette.note)
            }
            .padding(12)
        }
    }

    /// A section heading that also says what can be done in that section - the
    /// two instructions the old page left to be discovered.
    private func header(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(SettingsPalette.note)
                .textCase(nil)
        }
    }

    // MARK: - Job 1: see what you have

    private func visibleRow(_ spec: TabSpec) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Remove, drawn as the same red minus every one of these
                // screens uses - not a toggle at the far end of the row, which
                // is the one control that reads as "is this row switched on"
                // rather than "take this out of the panel".
                Button {
                    config.setVisible(spec.id, false)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(SettingsPalette.danger)
                }
                .buttonStyle(.plain)
                .help("Take \(spec.title) out of the panel")

                Image(systemName: spec.symbol)
                    .frame(width: 20)
                    .foregroundStyle(SettingsPalette.note)

                VStack(alignment: .leading, spacing: 1) {
                    Text(spec.title)
                    Text("\(count(spec)) item\(count(spec) == 1 ? "" : "s") · \(spec.layout.title.lowercased())")
                        .font(.caption).foregroundStyle(SettingsPalette.note)
                }

                Spacer()

                // Job 3, on the row itself (user, 06/09: "I want to see the
                // view over the card like before"). It was behind a chevron
                // for one redesign, which put a click between the user and the
                // control they came here to use.
                displayOptions(spec)

                // The grip. `onMove` did the work before and nothing said so:
                // a row that can be dragged has to look like one.
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(SettingsPalette.note)
                    .help("Drag to reorder")
            }
            .padding(.vertical, 2)
        }
        .settingsRowHover()
    }

    // MARK: - Job 2: add one

    private func availableRow(_ spec: TabSpec) -> some View {
        HStack(spacing: 10) {
            Button {
                config.setVisible(spec.id, true)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(SettingsPalette.success)
            }
            .buttonStyle(.plain)
            .help("Put \(spec.title) in the panel")

            Image(systemName: spec.symbol)
                .frame(width: 20)
                .foregroundStyle(SettingsPalette.note)

            VStack(alignment: .leading, spacing: 1) {
                Text(spec.title)
                Text("\(count(spec)) item\(count(spec) == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(SettingsPalette.note)
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .settingsRowHover()
    }

    // MARK: - Job 3: how a tab shows its content

    private func displayOptions(_ spec: TabSpec) -> some View {
        HStack(spacing: Spacing.tight) {
            Picker("Layout", selection: layoutBinding(spec)) {
                ForEach(TabLayout.allCases) { Image(systemName: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 70)

            // A list has no density, so the control is absent rather than
            // present and dead - a question that can never be answered is
            // worse than no question.
            if spec.layout == .gallery {
                Picker("Density", selection: densityBinding(spec)) {
                    ForEach(GalleryDensity.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
                .settingsFieldHover(cornerRadius: 6)
            }

        }
    }

    private func move(_ offsets: IndexSet, _ destination: Int) {
        // The List shows only visible tabs, so translate those positions back
        // into indices in the full ordered array.
        let visibleIDs = visible.map(\.id)
        let movingIDs = offsets.map { visibleIDs[$0] }
        let anchorID: String? = destination < visibleIDs.count ? visibleIDs[destination] : nil

        var all = config.tabs
        let moving = all.filter { movingIDs.contains($0.id) }
        all.removeAll { movingIDs.contains($0.id) }
        let insertAt = anchorID.flatMap { id in all.firstIndex { $0.id == id } } ?? all.count
        all.insert(contentsOf: moving, at: insertAt)

        config.replaceAll(all)
    }

    private func count(_ spec: TabSpec) -> Int {
        store.items.lazy.filter { spec.category.contains($0) }.count
    }

    private func layoutBinding(_ spec: TabSpec) -> Binding<TabLayout> {
        Binding(get: { spec.layout },
                set: { var s = spec; s.layout = $0; config.update(s) })
    }

    private func densityBinding(_ spec: TabSpec) -> Binding<GalleryDensity> {
        Binding(get: { spec.density },
                set: { var s = spec; s.density = $0; config.update(s) })
    }
}
