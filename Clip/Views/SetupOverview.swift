import SwiftUI

/// The "Set up Clip" promo card (M8.1, reshaped 03/09).
///
/// It used to list every standing condition; the user asked for "only a
/// promo for getting started with a main CTA named Set up Clip" that sells
/// the setup - the AI connection above all - so the person actually does it.
/// Conditions still reach `NoticeBar` underneath and Diagnostics; this card
/// has one job: send the person to the Getting Started checklist. Shown once
/// per launch, on the first panel open, while any checklist step remains.
struct SetupOverview: View {
    @ObservedObject private var checklist = SetupChecklist.shared
    @EnvironmentObject var theme: ThemeManager
    let onDismiss: () -> Void

    @State private var hoveringClose = false

    private var t: AppTheme { theme.theme }

    /// The pitch. It sells the four steps by what they unlock - above all
    /// the AI connection, which is where most of Clip's value sits - rather
    /// than listing chores. One sentence per benefit, no feature inventory.
    static let pitch = """
        Give Clip permission to paste, connect an AI model, shape your tabs and \
        sync your Macs. With AI connected, any clip can be translated, rewritten, \
        summarized or turned into code, a commit message or a reply straight from \
        its own menu, and Clip names and tags your library for you.
        """

    /// The one call to action - "Set up Clip" - lands on the Getting Started
    /// checklist, and the card leaves for the rest of the launch: the person
    /// has taken the offer, so repeating it under the checklist they just
    /// opened would only nag.
    private func setUp() {
        SettingsWindowController.shared.show(tab: .gettingStarted)
        onDismiss()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.related) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(t.accentOnPanel)
                Text("Get the most out of Clip")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(t.textPrimary)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(hoveringClose ? t.textPrimary : t.textTertiary)
                        .iconButtonChrome(t, variant: .dismiss, highlighted: hoveringClose)
                }
                .buttonStyle(.plain)
                .onHover { hoveringClose = $0 }
                .help("Dismiss for this launch. Getting Started stays in Settings.")
            }

            Text(Self.pitch)
                .font(.system(size: 11))
                .foregroundStyle(t.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            PrimaryButton("Set Up Clip", size: .small, theme: t) { setUp() }
        }
        .padding(Spacing.comfortable)
        .background(t.cardBackground, in: RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous)
            .strokeBorder(t.border, lineWidth: 1))
    }
}

/// Whether the promo has already been shown this launch, and the
/// "at least one step remains" gate `PanelController.open(from:)`
/// checks before showing it.
///
/// An `ObservableObject` rather than a plain flag on `PanelController`:
/// `PanelRootView`'s SwiftUI tree is torn down and rebuilt between opens
/// under `CLIP_HEADLESS=1` (the panel window itself is reused, but the
/// hosted view is not guaranteed to be), so the question "should the
/// overview be visible right now" has to live somewhere that survives that,
/// not in a view's own `@State`.
@MainActor
final class SetupOverviewCoordinator: ObservableObject {
    static let shared = SetupOverviewCoordinator()

    @Published private(set) var isVisible = false
    private var hasShownThisLaunch = false

    private init() {}

    /// Called on every panel open. Shows the promo exactly once per launch,
    /// the first time it finds a Getting Started step still undone - never
    /// again after that, dismissed or not. Once every step is done the card
    /// has nothing left to sell and never appears.
    func presentIfNeeded() {
        guard !hasShownThisLaunch else { return }
        guard SetupChecklist.shared.remainingCount > 0 else { return }
        hasShownThisLaunch = true
        isVisible = true
    }

    /// The launch-scoped Dismiss: takes the card down for the rest of this
    /// launch. The checklist and any standing conditions are untouched.
    func dismiss() {
        isVisible = false
    }

    #if CLIP_TESTING
    func resetForTesting() {
        hasShownThisLaunch = false
        isVisible = false
    }
    #endif
}
