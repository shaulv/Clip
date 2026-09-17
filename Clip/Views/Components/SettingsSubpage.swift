import SwiftUI

/// The header every M14 sub-page opens with: the back/forward pill, then the
/// page's own title - immediately left of it, replacing the previous title
/// exactly, the way Apple's own drill-down pages do (SETTINGS-DESIGN.md
/// section 2 "Back/forward", section 7 "a hero card exists only at the top
/// of a landing pane, never on a drilled-down sub-page" - a sub-page never
/// repeats the hub's own hero, it goes straight into its content).
///
/// Back and forward are supplied as plain callbacks/booleans rather than
/// reaching into `SettingsRouter` itself, so this stays a dumb, reusable
/// header - the caller (each hub-tab's own pane) owns the navigation
/// decision and this only draws it.
struct SettingsSubpage<Content: View>: View {
    /// Settings surfaces come from the chosen theme, not the system's own
    /// neutral greys: see `SettingsHero`'s note (user, 07/09).
    @EnvironmentObject private var settingsTheme: ThemeManager
    private var st: AppTheme { settingsTheme.settingsTheme }
    let title: String
    var canGoBack: Bool
    var onBack: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content()
                // No inset here: the shell applies the one every page shares.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.tight) {
            backButton
            Text(title).font(.title2.weight(.semibold))
            Spacer()
        }
        .padding(.top, Spacing.comfortable)
        .padding(.bottom, Spacing.tight)
    }

    /// One circular icon button, back only (user, 03/09 evening: "remove the
    /// right arrow from everywhere and make the arrow in a circle icon
    /// button"). Forward history stays in the router for the keyboard; the
    /// header no longer draws it.
    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.system(size: SettingsAppleMetrics.rowGlyphSize, weight: .semibold))
                .foregroundStyle(canGoBack ? Color.primary : SettingsPalette.note)
                .frame(width: Spacing.panel, height: Spacing.panel)
                .background(st.cardBackground, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canGoBack)
        .accessibilityLabel("Back")
        // The hover wash is clipped to the circle, never outside it.
        .settingsHover(cornerRadius: Spacing.panel / 2)
        .clipShape(Circle())
    }

}

extension SettingsSubpage {
    /// Wires back/forward straight to `router`'s own history for `tab`, so
    /// each hub-tab pane does not repeat the same four lines. Every M14
    /// pane's own sub-page content uses this rather than the memberwise
    /// initializer directly.
    init(tab: SettingsTab, title: String, router: SettingsRouter,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title,
                  canGoBack: router.canGoBack(in: tab),
                  onBack: { router.goBack(in: tab) },
                  content: content)
    }
}
