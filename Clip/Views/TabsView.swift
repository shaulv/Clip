import SwiftUI

/// The tab bar. Which tabs exist, their order, and each one's layout and density
/// all come from `TabConfiguration`, so this view only draws what it is told.
struct TabsView: View {
    /// M21: the tab under the pointer, for the hover wash.
    @State private var hoveredTabID: String?
    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager
    @ObservedObject private var config = TabConfiguration.shared
    @Namespace private var indicator

    private var t: AppTheme { theme.theme }

    /// How many items a tab would show right now, for its badge.
    private func count(for spec: TabSpec) -> Int {
        store.items.lazy.filter { spec.category.contains($0) }.count
    }

    var body: some View {
        HStack(spacing: Spacing.inline) {
            ForEach(config.visible) { spec in
                tab(spec)
            }
        }
        .padding(Spacing.inline)
        .background(t.surfaceBackground.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous)
            .strokeBorder(t.border, lineWidth: 1))
    }

    private func tab(_ spec: TabSpec) -> some View {
        let active = store.activeTabID == spec.id
        let hovering = !active && hoveredTabID == spec.id
        let n = count(for: spec)
        return Button {
            guard !active else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                store.setTab(spec.id)
            }
        } label: {
            HStack(spacing: Spacing.inline) {
                Image(systemName: spec.symbol).font(.system(size: 10, weight: .semibold))
                Text(spec.title).font(.system(size: 11, weight: active ? .semibold : .medium))
                if n > 0 {
                    Text("\(n)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(t.textTertiary)
                        .padding(.horizontal, Spacing.inline).padding(.vertical, Spacing.inline)
                        .background(t.surfaceBackground, in: Capsule())
                }
            }
            // Weaker than selected: no ring, no shadow, and the label lifts
            // only from textTertiary to secondaryText - graded against the
            // wash it is actually painted on (`renderedTabHover()`), never
            // asserted from the theme's authored values.
            .foregroundStyle(active ? t.textPrimary
                             : (hovering ? t.secondaryText(on: t.renderedTabHover()) : t.textTertiary))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            // Every tab takes an equal share of the width.
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.tight)
            .background {
                // Hover is a wash only; selection is fill plus the selection
                // ring. The same distinction the cards draw, so the two can
                // never be mistaken for each other (user, 03/09).
                if !active, hoveredTabID == spec.id {
                    RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous)
                        .fill(t.tabHoverFill)
                }
                if active {
                    // The same treatment the selected card gets: a fill plus an
                    // accent/selection ring. The fill alone read as "slightly different
                    // background" rather than "this one is selected", which is
                    // the job the ring does on a card.
                    RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous)
                        .fill(t.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous)
                                .strokeBorder(t.selectionStroke, lineWidth: 2)
                        )
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                        .matchedGeometryEffect(id: "tab", in: indicator)
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hoveredTabID = spec.id } else if hoveredTabID == spec.id { hoveredTabID = nil }
            }
            // M19: background first (resting/active fill, the selection
            // ring), then the two foreground pieces (label, the count
            // badge).
            .themeTokens(["surfaceBackground", "cardBackground", "selectionStroke", "border",
                          "tabHoverFill", "textPrimary", "textTertiary"])
        }
        .buttonStyle(.plain)
        .help("\(spec.title): \(spec.layout.title) (Tab to cycle)")
        // Publishes where this tab actually landed, so a test can click the
        // REAL button rather than call `store.setTab` and hope the two agree.
        // Compiled to `self` outside the Testing configuration - see the two
        // halves of `realTarget` in QABridge.swift.
        .realTarget("tab:" + spec.id)
    }
}

/// Footer: contextual keyboard hints and the destructive actions.
///
/// Density used to live here; it is a Settings concern now, and per tab.
struct FooterView: View {
    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var theme: ThemeManager
    private var t: AppTheme { theme.theme }

    @ObservedObject private var config = TabConfiguration.shared

    var body: some View {
        HStack(spacing: Spacing.related) {
            layoutToggle

            Text("\(store.visibleItems.count) item\(store.visibleItems.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(t.textTertiary)

            Spacer(minLength: Spacing.tight)

            // What you have gathered, and what you can do with it. Shown only
            // when there is a set, so the footer stays quiet the rest of the time.
            if !store.markedIDs.isEmpty {
                HStack(spacing: Spacing.tight) {
                    Text("\(store.markedIDs.count) marked")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(t.accentOnCard)
                    ClipLink("Paste together", size: .small) {
                        let n = store.composePaste()
                        if n > 0 {
                            NoticeCenter.shared.report("\(n) items joined and copied", kind: .transient)
                        } else {
                            NoticeCenter.shared.report(
                                "Nothing to paste: the selected items are empty", kind: .transient)
                        }
                    }
                    ClipLink("Clear", size: .small) { store.clearMarks() }
                }
                .padding(.horizontal, Spacing.tight).padding(.vertical, Spacing.inline)
                .background(t.accent.opacity(0.14), in: Capsule())
            }

            hint("↑↓", "Move")
            hint("↩", "Paste")
            hint("⌥→", "Actions")
            hint("⌘1–9", "Quick paste")
            hint("⎋", "Close")

            // No trash here. "Clear Everything" sat one unguarded click from the
            // keyboard hints, in the footer of a panel opened dozens of times a
            // day, with nothing between the click and losing the history. It
            // lives in Settings now, where a destructive action belongs, behind
            // a confirmation.
        }
        // M19: the footer's own tokens - the layout toggle above tags itself
        // separately with a smaller frame, which wins when the pointer is
        // actually over it.
        .themeTokens(["textTertiary", "accentOnCard", "accent", "textSecondary", "surfaceBackground"])
    }

    /// Grid or list, for this tab, remembered.
    ///
    /// The right layout is a property of what you are looking at — files want a
    /// list, screenshots want a grid — so the switch lives next to the content
    /// and writes straight back to that tab's settings.
    @ViewBuilder
    private var layoutToggle: some View {
        let spec = config.spec(for: store.activeTabID) ?? store.activeTab
        Group {
            HStack(spacing: Spacing.inline) {
                ForEach(TabLayout.allCases) { layout in
                    let active = spec.layout == layout
                    Button {
                        var updated = spec
                        updated.layout = layout
                        config.update(updated)
                    } label: {
                        Image(systemName: layout.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(active ? t.textPrimary : t.textTertiary)
                            // 34x26, not 24x20. The glyph is the same size; the
                            // target around it is not. A segmented control this
                            // small is one people miss and hit the other half of,
                            // which silently changes the layout of the tab they
                            // are looking at.
                            .frame(width: 34, height: 26)
                            .background {
                                if active {
                                    RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous)
                                        .fill(t.cardBackground)
                                }
                            }
                            // Without this the gaps between glyph strokes are
                            // not the button, so half the "target" was never
                            // clickable in the first place.
                            .contentShape(RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("\(layout.title) view for \(spec.title)")
                }
            }
            .padding(Spacing.inline)
            .background(t.surfaceBackground, in: RoundedRectangle(cornerRadius: t.radiusControl, style: .continuous))
        }
        // M19: the grid/list segmented toggle - its own smaller frame wins
        // over FooterView's own wider tag below it.
        .themeTokens(["surfaceBackground", "cardBackground", "textPrimary", "textTertiary"])
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: Spacing.inline) {
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(t.textSecondary)
                .padding(.horizontal, Spacing.inline).padding(.vertical, Spacing.inline)
                .background(t.surfaceBackground, in: RoundedRectangle(cornerRadius: t.radiusControl))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(t.textTertiary)
        }
    }
}
