import SwiftUI

/// The app's one ghost button - text with no fill and no border until it is
/// touched, for an action that would be too loud even as a sub button
/// ("Select all" beside "Select none", a toolbar's least prominent action).
/// Used only where a bordered `SecondaryButton` would compete with something
/// more important on the same row. States: idle, hover, pressed, focused,
/// disabled, selected - every colour a theme token (`AppTheme.buttonGhost*`).
struct GhostButton: View {
    let title: String
    var systemImage: String? = nil
    var size: ClipControlSize = .regular
    var isDisabled: Bool = false
    var isSelected: Bool = false
    /// See `ClipButtonStyle.isDestructive`.
    var isDestructive: Bool = false
    /// See `PrimaryButton`'s own doc comment on the same two properties.
    var forcedState: ClipButtonForcedState? = nil
    var theme: AppTheme? = nil
    let action: () -> Void

    @EnvironmentObject private var themeManager: ThemeManager
    /// The window's own chrome theme, when it differs from the panel's:
    /// see `clipChromeTheme`.
    @Environment(\.clipChromeTheme) private var chromeTheme
    @FocusState private var focused: Bool

    init(_ title: String, systemImage: String? = nil, size: ClipControlSize = .regular,
         isDisabled: Bool = false, isSelected: Bool = false, isDestructive: Bool = false,
         forcedState: ClipButtonForcedState? = nil,
         theme: AppTheme? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.size = size
        self.isDisabled = isDisabled
        self.isSelected = isSelected
        self.isDestructive = isDestructive
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
        .buttonStyle(ClipButtonStyle(theme: theme ?? chromeTheme ?? themeManager.theme, kind: .ghost,
                                     size: size, isSelected: isSelected, focused: focused,
                                     forcedState: forcedState, isDestructive: isDestructive))
        .focusable(!isDisabled)
        .focused($focused)
        .disabled(isDisabled)
    }
}
