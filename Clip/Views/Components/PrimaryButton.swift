import SwiftUI

/// The app's one CTA - "the blue one" (the user's own words). Exactly one
/// per screen for the screen's primary action; every other affordance uses
/// `SecondaryButton` or `GhostButton`. States: idle, hover, pressed,
/// focused, disabled - every colour a theme token (`AppTheme.buttonPrimary*`).
struct PrimaryButton: View {
    let title: String
    /// An optional leading SF Symbol - "New theme", "Describe a theme".
    var systemImage: String? = nil
    var size: ClipControlSize = .regular
    var isDisabled: Bool = false
    /// Overrides the AppKit-reported state for a static swatch - the theme
    /// builder's mini-preview and `QABridge`'s `m11_renderComponent` only.
    var forcedState: ClipButtonForcedState? = nil
    /// Renders against a specific theme instead of the live
    /// `ThemeManager.theme` - the mini-preview's own DRAFT theme, which must
    /// never fall back to the committed one (M9 W5g).
    var theme: AppTheme? = nil
    let action: () -> Void

    @EnvironmentObject private var themeManager: ThemeManager
    /// The window's own chrome theme, when it differs from the panel's:
    /// see `clipChromeTheme`.
    @Environment(\.clipChromeTheme) private var chromeTheme
    @FocusState private var focused: Bool

    init(_ title: String, systemImage: String? = nil, size: ClipControlSize = .regular,
         isDisabled: Bool = false, forcedState: ClipButtonForcedState? = nil,
         theme: AppTheme? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.size = size
        self.isDisabled = isDisabled
        self.forcedState = forcedState
        self.theme = theme
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .buttonStyle(ClipButtonStyle(theme: theme ?? chromeTheme ?? themeManager.theme, kind: .primary,
                                     size: size, focused: focused, forcedState: forcedState))
        .focusable(!isDisabled)
        .focused($focused)
        .disabled(isDisabled)
    }
}
