import SwiftUI

/// The app's one link component - every place text triggers navigation or an
/// action rather than sitting inside a button ("Learn more", a credential's
/// "Open System Settings"). States: idle, hover (colour shift + underline),
/// pressed, focused, disabled - every colour a theme token
/// (`AppTheme.link`/`linkHover`/`linkPressed`). No fill, no border, and no
/// "selected" state - a link is never the chosen option among several, it is
/// always just an action.
struct ClipLink: View {
    let title: String
    var size: ClipControlSize = .regular
    var isDisabled: Bool = false
    /// Tints with `theme.destructive` instead of `theme.link*` - a quiet
    /// second choice inside an error notice ("reset and ask again" beside
    /// "open System Settings"), which reads as part of that error's family
    /// rather than as an ordinary navigation link.
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

    init(_ title: String, size: ClipControlSize = .regular, isDisabled: Bool = false,
         isDestructive: Bool = false, forcedState: ClipButtonForcedState? = nil,
         theme: AppTheme? = nil, action: @escaping () -> Void) {
        self.title = title
        self.size = size
        self.isDisabled = isDisabled
        self.isDestructive = isDestructive
        self.forcedState = forcedState
        self.theme = theme
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(ClipLinkStyle(theme: theme ?? chromeTheme ?? themeManager.theme, size: size,
                                   isDisabled: isDisabled, isDestructive: isDestructive,
                                   focused: focused, forcedState: forcedState))
        .focusable(!isDisabled)
        .focused($focused)
        .disabled(isDisabled)
    }
}

/// One state machine for the link: idle, hover, pressed, focused, disabled.
private struct ClipLinkStyle: ButtonStyle {
    let theme: AppTheme
    var size: ClipControlSize = .regular
    var isDisabled: Bool = false
    var isDestructive: Bool = false
    var focused: Bool = false
    var forcedState: ClipButtonForcedState? = nil

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var font: Font { size == .regular ? Typography.body : Typography.label }
    private var enabled: Bool { isEnabled && !isDisabled }
    private var effectiveHovering: Bool { hovering || forcedState == .hover }
    private var effectiveFocused: Bool { focused || forcedState == .focused }

    private func color(pressed: Bool) -> Color {
        let pressed = pressed || forcedState == .pressed
        guard enabled else { return theme.controlDisabledText }
        if isDestructive { return theme.destructive }
        if pressed { return theme.linkPressed }
        return effectiveHovering ? theme.linkHover : theme.link
    }

    /// M19: every token the app's one link component can paint with.
    private var tagTokens: [String] {
        var tokens = ["link", "linkHover", "linkPressed", "controlDisabledText", "focusRing"]
        if isDestructive { tokens.append("destructive") }
        return tokens
    }

    func makeBody(configuration: Configuration) -> some View {
        let c = color(pressed: configuration.isPressed)
        let underlined = effectiveHovering || configuration.isPressed
                        || forcedState == .pressed || effectiveFocused
        return configuration.label
            .font(font)
            .foregroundStyle(c)
            .underline(underlined, color: c)
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                    .strokeBorder(effectiveFocused && enabled ? theme.focusRing : .clear,
                                  lineWidth: effectiveFocused && enabled ? IconButtonChrome.ringWidth : 0)
                    .padding(-Spacing.inline)
            )
            .contentShape(Rectangle())
            .onHover { hovering = enabled ? $0 : false }
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .themeTokens(tagTokens)
    }
}
