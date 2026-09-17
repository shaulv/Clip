import SwiftUI

/// One component set with full interaction states (M11, 02/09).
///
/// The user's own words: "have a idle, hover, press, focus, selected (if
/// needed), make sure all have one and make sure to add the colors by need
/// to the theme builder. make sure to use one link component where we need
/// a link, one main CTA (blue one), one sub button and one ghost button only
/// if necessary, change it in all the app UI". Four files answer that:
/// `PrimaryButton` (the CTA), `SecondaryButton` (the sub button),
/// `GhostButton`, and `ClipLink` - plus the icon-only chrome that already
/// existed (`iconButtonChrome` in `MediaPreview.swift`), which this task
/// does not touch. Every `Button(...)` and link-styled `Text` in
/// `Clip/Views/**` is one of these five; `qa-probe.py`'s section 140 fails
/// the build on a raw `Button(` anywhere else.
///
/// This file is the shared engine the three box-shaped buttons render
/// through, so "one component set" is true in the code, not just in name -
/// a fourth kind cannot exist without a new case here, and every existing
/// kind cannot drift out of step with the others by being tuned separately.

/// Sizes shared by every component in this folder.
enum ClipControlSize {
    case regular
    case small
}

/// The three fill emphases a button in Clip can have, and nothing else.
enum ClipButtonKind {
    case primary
    case secondary
    case ghost
}

/// Forces a visual state regardless of the real pointer/keyboard - used ONLY
/// by the theme builder's mini-preview (so idle/hover/pressed/focused can sit
/// side by side as static swatches, per M11's "the theme builder shows the
/// four components in its mini-preview in all states") and by `QABridge`'s
/// `m11_renderComponent`, which renders one forced state at a time so the
/// probe can measure a real pixel delta between two states without
/// synthesizing a mouse event. Every real, interactive button in the app
/// leaves this `nil` and reads the genuine `configuration.isPressed`/hover/
/// focus it always has.
enum ClipButtonForcedState: String, CaseIterable {
    case hover, pressed, focused
}

/// Idle, hover, pressed, focused, disabled, selected - one state machine,
/// read from theme tokens only. `configuration.isPressed` is SwiftUI's own
/// real press state (not a hand-rolled `@GestureState`), so "pressed" here
/// is the actual mouse-down state AppKit reports, not an approximation.
struct ClipButtonStyle: ButtonStyle {
    let theme: AppTheme
    let kind: ClipButtonKind
    var size: ClipControlSize = .regular
    /// Persists, unlike hover - a chosen filter chip or tab built from
    /// `SecondaryButton`/`GhostButton` stays visually distinct from the one
    /// the pointer happens to be over. Not offered on `.primary`: there is
    /// exactly one CTA per screen, and a CTA does not toggle.
    var isSelected: Bool = false
    /// Keyboard focus, supplied by the wrapping view's own `@FocusState` -
    /// a `ButtonStyle` has no way to ask SwiftUI for that itself.
    var focused: Bool = false
    /// See `ClipButtonForcedState`. `nil` in every real button.
    var forcedState: ClipButtonForcedState? = nil
    /// Tints the label (and, on `.secondary`, the border) with `theme.
    /// destructive` - the SAME token every other destructive control in the
    /// app already reads (`iconButtonChrome`'s own `destructive:` parameter).
    /// Never offered on `.primary`: a CTA is never the delete action.
    var isDestructive: Bool = false

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private static let regularHeight: CGFloat = 28
    /// The floor every control in the app holds to, small size included -
    /// AppKit's own `.small` bezel renders thinner than this, which is why
    /// the buttons this style replaced (the theme assistant's five hint
    /// chips) used to force an explicit `.frame(minHeight: 24)` on top of it.
    private static let smallHeight: CGFloat = 24

    private var height: CGFloat { size == .regular ? Self.regularHeight : Self.smallHeight }
    private var horizontalPadding: CGFloat { size == .regular ? Spacing.related : Spacing.tight }
    private var font: Font { size == .regular ? Typography.buttonLabel : Typography.buttonLabelSmall }
    private var radius: CGFloat { theme.radiusControl }
    private var enabled: Bool { isEnabled }
    private var effectiveHovering: Bool { hovering || forcedState == .hover }
    private func effectivePressed(_ pressed: Bool) -> Bool { pressed || forcedState == .pressed }

    private func fill(pressed: Bool) -> Color {
        let pressed = effectivePressed(pressed)
        guard enabled else { return theme.controlDisabledFill }
        if isSelected { return theme.selectedBackground }
        switch kind {
        case .primary:
            return pressed ? theme.buttonPrimaryPressedFill
                : (effectiveHovering ? theme.buttonPrimaryHoverFill : theme.buttonPrimaryFill)
        case .secondary:
            return pressed ? theme.buttonSecondaryPressedFill
                : (effectiveHovering ? theme.buttonSecondaryHoverFill : theme.buttonSecondaryFill)
        case .ghost:
            return pressed ? theme.buttonGhostPressedFill
                : (effectiveHovering ? theme.buttonGhostHoverFill : .clear)
        }
    }

    private func textColor(pressed: Bool) -> Color {
        let pressed = effectivePressed(pressed)
        guard enabled else { return theme.controlDisabledText }
        if isDestructive { return theme.destructive }
        if isSelected { return theme.text(on: theme.selectedBackground) }
        switch kind {
        case .primary:   return theme.buttonPrimaryText
        case .secondary: return theme.buttonSecondaryText
        case .ghost:     return (effectiveHovering || pressed) ? theme.textPrimary : theme.buttonGhostText
        }
    }

    private var borderColor: Color {
        guard enabled else { return .clear }
        if isSelected { return theme.selectionStroke }
        if isDestructive && kind == .secondary { return theme.destructive }
        return kind == .secondary ? theme.buttonSecondaryBorder : .clear
    }

    private var borderWidth: CGFloat { (kind == .secondary || isSelected) ? 1 : 0 }
    private var effectiveFocused: Bool { focused || forcedState == .focused }

    /// M19: every token this ONE style can paint with, across its three
    /// kinds and every state (idle/hover/pressed/focused/disabled/selected/
    /// destructive) - `PrimaryButton`/`SecondaryButton`/`GhostButton` all
    /// render through this style, so tagging it once covers all three.
    private var tagTokens: [String] {
        var tokens: [String]
        switch kind {
        case .primary:
            tokens = ["buttonPrimaryFill", "buttonPrimaryHoverFill",
                      "buttonPrimaryPressedFill", "buttonPrimaryText"]
        case .secondary:
            tokens = ["buttonSecondaryFill", "buttonSecondaryHoverFill",
                      "buttonSecondaryPressedFill", "buttonSecondaryBorder", "buttonSecondaryText"]
        case .ghost:
            tokens = ["buttonGhostHoverFill", "buttonGhostPressedFill", "buttonGhostText", "textPrimary"]
        }
        if isSelected { tokens.append(contentsOf: ["selectedBackground", "selectionStroke"]) }
        if isDestructive { tokens.append("destructive") }
        tokens.append(contentsOf: ["controlDisabledFill", "controlDisabledText", "focusRing"])
        return tokens
    }

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return configuration.label
            .font(font)
            .foregroundStyle(textColor(pressed: configuration.isPressed))
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .frame(minWidth: size == .regular ? Self.regularHeight * 2 : Self.smallHeight * 2)
            .background(shape.fill(fill(pressed: configuration.isPressed)))
            .overlay(shape.strokeBorder(borderColor, lineWidth: borderWidth))
            .overlay(
                shape.strokeBorder(effectiveFocused && enabled ? theme.focusRing : .clear,
                                   lineWidth: effectiveFocused && enabled ? IconButtonChrome.ringWidth : 0)
            )
            .contentShape(shape)
            .onHover { hovering = enabled ? $0 : false }
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .themeTokens(tagTokens)
    }
}
