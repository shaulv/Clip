import SwiftUI
import AppKit

/// Settings > Getting Started (M15, added 03/09) - a hero card, a progress
/// line, and one card per step: a status glyph, the title, one paragraph in
/// this document's voice, the action for that step, and a manual override.
///
/// Placed first in the sidebar (`SettingsTab.gettingStarted`) so it is the
/// first thing anyone opening Settings for the first time sees.
struct SettingsGettingStartedPane: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @ObservedObject private var checklist = SetupChecklist.shared
    // Held so this view re-renders when any of the three observable
    // conditions changes on its own - a connection validating, a tab
    // turned on, a sync space appearing. Accessibility has no publisher of
    // its own; `checklist.refresh()` below covers that one.
    @ObservedObject private var ai = AIService.shared
    @ObservedObject private var tabConfiguration = TabConfiguration.shared
    @ObservedObject private var sync = SyncManager.shared

    /// The SETTINGS theme, not the panel's. This pane draws cards inside the
    /// Settings window, so pinning Settings to Light while the Mac is dark has
    /// to lighten them too: reading `theme` left every step card dark on a
    /// light page, which is 55% of this pane (measured 07/09).
    private var t: AppTheme { themeManager.settingsTheme }

    // M9: was a raw `ScrollView` - the same shape `SettingsHub.swift`'s own
    // doc comment records failing every offscreen capture technique tried
    // against it (`layer.render(in:)` AND `cacheDisplay(in:to:)`, both
    // came back blank, byte-identical, verified against a real
    // `screencapture`). This pane captured blank through
    // `m8b_snapshotSettings` for exactly that reason - its visual design
    // had never actually been looked at. `List`, stripped to draw
    // pixel-identically to the `ScrollView` it replaces, is the fix that
    // held up there and holds up here.
    var body: some View {
        List {
            hero
                .padding(.bottom, Spacing.group)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            progressLine
                .padding(.bottom, Spacing.group)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            ForEach(checklist.steps) { step in
                card(for: step)
                    .padding(.bottom, Spacing.related)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            reopenGuideRow
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        // No inset of its own: the shell insets every page identically, and
        // this page's extra 24pt made it the widest-margined page in Settings
        // (measured 51pt where every other page sits at 27pt).
        // Granting Accessibility happens in System Settings, a different
        // app with no notification back to this one - the only reliable
        // moment to notice is when Clip itself regains focus.
        .onAppear { checklist.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checklist.refresh()
        }
    }

    // MARK: - Hero

    private var hero: some View {
        SettingsHero(icon: "checklist", title: "Getting Started",
                     purpose: "Four steps and Clip is fully yours.")
    }

    // MARK: - Progress

    private var progressLine: some View {
        Text("\(checklist.doneCount) of \(checklist.steps.count) done")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(checklist.remainingCount == 0 ? t.success : t.textSecondary)
    }

    // MARK: - Reopen the guide

    // Moved here from General > Startup and opening (T3-M5 phase 2): this
    // pane is already the app's declared "checklist that points at every
    // other tab", so a second, un-badged entry point to onboarding sitting
    // inside General split that one job across two panes. One home now.
    private var reopenGuideRow: some View {
        HStack {
            Spacer(minLength: 0)
            SecondaryButton("Reopen the Welcome Guide", size: .small) {
                OnboardingWindowController.shared.show()
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Spacing.related)
    }

    // MARK: - Step card

    @ViewBuilder
    private func card(for step: SetupStep) -> some View {
        let done = checklist.isDone(step)
        let manualOnly = checklist.isManualOnly(step)
        let isNext = checklist.nextUndone?.id == step.id

        VStack(alignment: .leading, spacing: Spacing.related) {
            HStack(alignment: .top, spacing: Spacing.related) {
                // Green means done (user, 06/09). `t.success` is the PANEL's
                // green, lightened until it clears contrast on the panel's
                // three card grounds - on a dark theme that lightening ran all
                // the way to near-white, so a finished step read as an ordinary
                // white tick. This card is a SETTINGS card, so it takes the
                // Settings green, which is resolved against this surface.
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(done ? SettingsPalette.success : SettingsPalette.note)

                VStack(alignment: .leading, spacing: Spacing.inline) {
                    Text(step.title)
                        .font(Typography.subheading)
                        .foregroundStyle(t.textPrimary)
                    Text(step.explanation)
                        .font(.caption)
                        .foregroundStyle(SettingsPalette.note)
                        .fixedSize(horizontal: false, vertical: true)
                    if manualOnly {
                        Text("Marked by you.")
                            .font(.caption)
                            .italic()
                            .foregroundStyle(SettingsPalette.note)
                    }
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: Spacing.related) {
                if isNext {
                    PrimaryButton(actionTitle(for: step), size: .small) { step.deepLink() }
                } else {
                    SecondaryButton(actionTitle(for: step), size: .small) { step.deepLink() }
                }
                // The permission can also be simply missing rather than
                // stale, which "reset and ask again" alone does not solve -
                // this is the second route `PanelController`'s own notice
                // already offers beside it (`AccessibilityGate.openSettingsAction`).
                if step.id == "accessibility" {
                    ClipLink("Open Accessibility Settings", size: .small) {
                        AccessibilityGate.openSettingsPane()
                    }
                }

                Spacer(minLength: 0)

                ClipLink(done ? "Mark as Not Done" : "Mark as Done", size: .small) {
                    checklist.setManual(step.id, done: !done)
                }
            }
        }
        .padding(Spacing.comfortable)
        .background(t.cardBackground, in: RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous)
            .strokeBorder(t.border, lineWidth: 1))
    }

    private func actionTitle(for step: SetupStep) -> String {
        switch step.id {
        case "accessibility": return AccessibilityGate.resetAction.title
        case "ai":             return "Connect a Model"
        case "tabs":           return "Customize Tabs"
        case "sync":           return "Sync Your Account"
        default:               return "Open"
        }
    }
}
