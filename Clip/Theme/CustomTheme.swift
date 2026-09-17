import SwiftUI
import AppKit

/// A user-made theme, stored as hex strings so it survives a round trip through
/// JSON, the database and an AI reply without depending on `Color`'s internals.
struct CustomTheme: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var accent: String
    var accentSecondary: String
    var panelBackground: String
    var cardBackground: String
    var cardHoverBackground: String
    var selectedBackground: String
    var surfaceBackground: String
    var textPrimary: String
    var textSecondary: String
    var textTertiary: String
    var border: String
    var isDark: Bool
    var cornerRadius: Double

    /// Optional pins for the colors the app otherwise derives.
    ///
    /// Optional so a theme saved before these existed still decodes: a missing
    /// key means "derive it", which is exactly what those themes were doing.
    var accentTextOverride: String? = nil
    var selectionTextOverride: String? = nil
    /// Keyed by `ItemKind.rawValue`.
    var typeTints: [String: String]? = nil
    /// How much desktop shows through the panel, 0 being opaque.
    var translucency: Double? = nil

    /// Interaction states. Optional, so a theme written before they existed
    /// decodes unchanged and simply derives them.
    var interaction: String? = nil
    var hoverStroke: String? = nil
    var selectionStroke: String? = nil
    var focusRing: String? = nil
    var actionHoverFill: String? = nil
    var tabHoverFill: String? = nil

    /// Status colors. `destructive` used to be a hard-coded red no theme could
    /// touch and no audit graded.
    var destructive: String? = nil
    var success: String? = nil
    var warning: String? = nil

    /// Buttons and links (M11). Optional, same reasoning as every override
    /// above: a theme saved before these existed decodes unchanged and
    /// derives them from `accent`/the surface ramp.
    var buttonPrimaryFill: String? = nil
    var buttonPrimaryText: String? = nil
    var buttonPrimaryHoverFill: String? = nil
    var buttonPrimaryPressedFill: String? = nil
    var buttonSecondaryFill: String? = nil
    var buttonSecondaryText: String? = nil
    var buttonSecondaryBorder: String? = nil
    var buttonSecondaryHoverFill: String? = nil
    var buttonSecondaryPressedFill: String? = nil
    var buttonGhostText: String? = nil
    var buttonGhostHoverFill: String? = nil
    var buttonGhostPressedFill: String? = nil
    var link: String? = nil
    var linkHover: String? = nil
    var linkPressed: String? = nil
    var controlDisabledFill: String? = nil
    var controlDisabledText: String? = nil

    /// An independent copy of this theme, under a new id.
    ///
    /// `self` is copied wholesale and only the identity is changed. The previous
    /// duplicate re-listed every field by hand and, in doing so, dropped four of
    /// them - `accentTextOverride`, `selectionTextOverride`, `typeTints` and
    /// `translucency` - so duplicating a tuned theme quietly returned an
    /// untuned one. A field added later would have been dropped too.
    func duplicated(named name: String) -> CustomTheme {
        var copy = self
        copy.id = UUID().uuidString
        copy.name = name
        return copy
    }

    /// "Aurora" becomes "Aurora (copy)", and a second one "Aurora (copy 2)".
    ///
    /// A list holding three themes all called "Aurora (copy)" is a list you
    /// cannot use, so the name says which copy it is.
    static func copyName(for base: String, existing: [String]) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let first = "\(trimmed) (copy)"
        guard existing.contains(first) else { return first }
        var n = 2
        while existing.contains("\(trimmed) (copy \(n))") { n += 1 }
        return "\(trimmed) (copy \(n))"
    }

    /// Starting point for the builder: the current theme, so editing feels like
    /// tweaking what you already see rather than starting from nothing.
    static func from(_ theme: AppTheme, name: String) -> CustomTheme {
        CustomTheme(
            name: name,
            accent: theme.accent.hexString,
            accentSecondary: theme.accentSecondary.hexString,
            panelBackground: theme.panelBackground.hexString,
            cardBackground: theme.cardBackground.hexString,
            cardHoverBackground: theme.cardHoverBackground.hexString,
            selectedBackground: theme.selectedBackground.hexString,
            surfaceBackground: theme.surfaceBackground.hexString,
            textPrimary: theme.textPrimary.hexString,
            textSecondary: theme.textSecondary.hexString,
            textTertiary: theme.textTertiary.hexString,
            border: theme.border.hexString,
            isDark: theme.isDark,
            cornerRadius: Double(theme.cornerRadius),
            accentTextOverride: theme.accentTextOverride?.hexString,
            selectionTextOverride: theme.selectionTextOverride?.hexString,
            typeTints: theme.typeTintOverrides.isEmpty
                ? nil : theme.typeTintOverrides.mapValues(\.hexString),
            translucency: theme.translucency,
            interaction: theme.interactionOverride?.hexString,
            hoverStroke: theme.hoverStrokeOverride?.hexString,
            selectionStroke: theme.selectionStrokeOverride?.hexString,
            focusRing: theme.focusRingOverride?.hexString,
            actionHoverFill: theme.actionHoverFillOverride?.hexString,
            tabHoverFill: theme.tabHoverFillOverride?.hexString,
            destructive: theme.destructiveOverride?.hexString,
            success: theme.successOverride?.hexString,
            warning: theme.warningOverride?.hexString,
            buttonPrimaryFill: theme.buttonPrimaryFillOverride?.hexString,
            buttonPrimaryText: theme.buttonPrimaryTextOverride?.hexString,
            buttonPrimaryHoverFill: theme.buttonPrimaryHoverFillOverride?.hexString,
            buttonPrimaryPressedFill: theme.buttonPrimaryPressedFillOverride?.hexString,
            buttonSecondaryFill: theme.buttonSecondaryFillOverride?.hexString,
            buttonSecondaryText: theme.buttonSecondaryTextOverride?.hexString,
            buttonSecondaryBorder: theme.buttonSecondaryBorderOverride?.hexString,
            buttonSecondaryHoverFill: theme.buttonSecondaryHoverFillOverride?.hexString,
            buttonSecondaryPressedFill: theme.buttonSecondaryPressedFillOverride?.hexString,
            buttonGhostText: theme.buttonGhostTextOverride?.hexString,
            buttonGhostHoverFill: theme.buttonGhostHoverFillOverride?.hexString,
            buttonGhostPressedFill: theme.buttonGhostPressedFillOverride?.hexString,
            link: theme.linkOverride?.hexString,
            linkHover: theme.linkHoverOverride?.hexString,
            linkPressed: theme.linkPressedOverride?.hexString,
            controlDisabledFill: theme.controlDisabledFillOverride?.hexString,
            controlDisabledText: theme.controlDisabledTextOverride?.hexString
        )
    }

    /// Builds from an AI reply. Every field falls back to a sane value so one
    /// missing key never costs the whole theme.
    /// Builds a theme from a model's JSON reply.
    ///
    /// Two things this has to survive. Models wrap the answer - `{"theme": {...}}`
    /// is common - so the object carrying the colors is searched for rather than
    /// assumed to be the outermost one. And every field has a fallback, which
    /// means a reply with *no* colors in it would silently produce the default
    /// theme: the user asks for "coral sunset" and gets stock navy, with no error
    /// to explain it. So a reply that carries none of the expected keys is
    /// rejected here instead, and the caller can retry or say what went wrong.
    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = Self.themeObject(in: root)
        else { return nil }

        func hex(_ key: String, _ fallback: String) -> String {
            guard var v = d[key] as? String else { return fallback }
            v = v.trimmingCharacters(in: .whitespaces)
            if !v.hasPrefix("#") { v = "#" + v }
            return NSColor(hex: v) != nil ? v : fallback
        }

        let dark = (d["isDark"] as? Bool) ?? true
        self.id = UUID().uuidString
        self.name = (d["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? "Custom"
        self.isDark = dark
        self.accent = hex("accent", "#5A5AFF")
        self.accentSecondary = hex("accentSecondary", "#BF47FF")
        self.panelBackground = hex("panelBackground", dark ? "#0D0F1C" : "#F5F6FA")
        self.cardBackground = hex("cardBackground", dark ? "#1C1F33" : "#FFFFFF")
        self.cardHoverBackground = hex("cardHoverBackground", dark ? "#262A42" : "#EDEFF5")
        self.selectedBackground = hex("selectedBackground", dark ? "#38356B" : "#DDE3FF")
        self.surfaceBackground = hex("surfaceBackground", dark ? "#171A2B" : "#EAECF3")
        self.textPrimary = hex("textPrimary", dark ? "#FFFFFF" : "#12141C")
        self.textSecondary = hex("textSecondary", dark ? "#B8BCCC" : "#454A5C")
        self.textTertiary = hex("textTertiary", dark ? "#7A7F94" : "#8A8FA3")
        self.border = hex("border", dark ? "#2A2E44" : "#D6DAE5")
        self.cornerRadius = min(max((d["cornerRadius"] as? Double) ?? 14, 4), 22)
    }

    /// The color keys a real theme reply must carry at least some of.
    private static let expectedKeys: Set<String> = [
        "accent", "accentSecondary", "panelBackground", "cardBackground",
        "cardHoverBackground", "selectedBackground", "surfaceBackground",
        "textPrimary", "textSecondary", "textTertiary", "border"
    ]

    /// Finds the object that actually holds the colors, one level down if need be.
    private static func themeObject(in root: [String: Any]) -> [String: Any]? {
        if root.keys.contains(where: expectedKeys.contains) { return root }
        for value in root.values {
            if let nested = value as? [String: Any],
               nested.keys.contains(where: expectedKeys.contains) {
                return nested
            }
        }
        return nil
    }

    /// Generated from the stored properties, every one of them.
    ///
    /// The previous hand-written init listed a subset and silently dropped
    /// anything added later. A probe assertion now binds this list to the
    /// property list, so the two cannot drift.
    init(
         id: String = UUID().uuidString,
         name: String,
         accent: String,
         accentSecondary: String,
         panelBackground: String,
         cardBackground: String,
         cardHoverBackground: String,
         selectedBackground: String,
         surfaceBackground: String,
         textPrimary: String,
         textSecondary: String,
         textTertiary: String,
         border: String,
         isDark: Bool,
         cornerRadius: Double,
         accentTextOverride: String? = nil,
         selectionTextOverride: String? = nil,
         typeTints: [String: String]? = nil,
         translucency: Double? = nil,
         interaction: String? = nil,
         hoverStroke: String? = nil,
         selectionStroke: String? = nil,
         focusRing: String? = nil,
         actionHoverFill: String? = nil,
         tabHoverFill: String? = nil,
         destructive: String? = nil,
         success: String? = nil,
         warning: String? = nil,
         buttonPrimaryFill: String? = nil,
         buttonPrimaryText: String? = nil,
         buttonPrimaryHoverFill: String? = nil,
         buttonPrimaryPressedFill: String? = nil,
         buttonSecondaryFill: String? = nil,
         buttonSecondaryText: String? = nil,
         buttonSecondaryBorder: String? = nil,
         buttonSecondaryHoverFill: String? = nil,
         buttonSecondaryPressedFill: String? = nil,
         buttonGhostText: String? = nil,
         buttonGhostHoverFill: String? = nil,
         buttonGhostPressedFill: String? = nil,
         link: String? = nil,
         linkHover: String? = nil,
         linkPressed: String? = nil,
         controlDisabledFill: String? = nil,
         controlDisabledText: String? = nil
    ) {
        self.id = id
        self.name = name
        self.accent = accent
        self.accentSecondary = accentSecondary
        self.panelBackground = panelBackground
        self.cardBackground = cardBackground
        self.cardHoverBackground = cardHoverBackground
        self.selectedBackground = selectedBackground
        self.surfaceBackground = surfaceBackground
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.border = border
        self.isDark = isDark
        self.cornerRadius = cornerRadius
        self.accentTextOverride = accentTextOverride
        self.selectionTextOverride = selectionTextOverride
        self.typeTints = typeTints
        self.translucency = translucency
        self.interaction = interaction
        self.hoverStroke = hoverStroke
        self.selectionStroke = selectionStroke
        self.focusRing = focusRing
        self.actionHoverFill = actionHoverFill
        self.tabHoverFill = tabHoverFill
        self.destructive = destructive
        self.success = success
        self.warning = warning
        self.buttonPrimaryFill = buttonPrimaryFill
        self.buttonPrimaryText = buttonPrimaryText
        self.buttonPrimaryHoverFill = buttonPrimaryHoverFill
        self.buttonPrimaryPressedFill = buttonPrimaryPressedFill
        self.buttonSecondaryFill = buttonSecondaryFill
        self.buttonSecondaryText = buttonSecondaryText
        self.buttonSecondaryBorder = buttonSecondaryBorder
        self.buttonSecondaryHoverFill = buttonSecondaryHoverFill
        self.buttonSecondaryPressedFill = buttonSecondaryPressedFill
        self.buttonGhostText = buttonGhostText
        self.buttonGhostHoverFill = buttonGhostHoverFill
        self.buttonGhostPressedFill = buttonGhostPressedFill
        self.link = link
        self.linkHover = linkHover
        self.linkPressed = linkPressed
        self.controlDisabledFill = controlDisabledFill
        self.controlDisabledText = controlDisabledText
    }

    /// The runtime theme this describes.
    var appTheme: AppTheme {
        func c(_ hex: String, _ fallback: Color) -> Color {
            NSColor(hex: hex).map(Color.init(nsColor:)) ?? fallback
        }
        return AppTheme(
            id: "custom:\(id)", name: name, symbol: "paintbrush.pointed",
            accent: c(accent, .blue),
            accentSecondary: c(accentSecondary, .purple),
            panelBackground: c(panelBackground, isDark ? .black : .white),
            cardBackground: c(cardBackground, isDark ? .black : .white),
            cardHoverBackground: c(cardHoverBackground, .gray),
            selectedBackground: c(selectedBackground, .blue),
            surfaceBackground: c(surfaceBackground, .gray),
            textPrimary: c(textPrimary, isDark ? .white : .black),
            textSecondary: c(textSecondary, .secondary),
            textTertiary: c(textTertiary, .secondary),
            border: c(border, .gray),
            cornerRadius: CGFloat(cornerRadius),
            usesGradientHeader: true,
            defaultLayout: .gallery,
            defaultDensity: .comfortable,
            isDark: isDark,
            translucency: translucency ?? 0.12,
            accentTextOverride: accentTextOverride.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            selectionTextOverride: selectionTextOverride.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            interactionOverride: interaction.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            hoverStrokeOverride: hoverStroke.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            selectionStrokeOverride: selectionStroke.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            focusRingOverride: focusRing.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            actionHoverFillOverride: actionHoverFill.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            tabHoverFillOverride: tabHoverFill.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            destructiveOverride: destructive.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            successOverride: success.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            warningOverride: warning.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            typeTintOverrides: (typeTints ?? [:]).compactMapValues {
                NSColor(hex: $0).map(Color.init(nsColor:))
            },
            buttonPrimaryFillOverride: buttonPrimaryFill.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            buttonPrimaryTextOverride: buttonPrimaryText.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            buttonPrimaryHoverFillOverride: buttonPrimaryHoverFill.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            buttonPrimaryPressedFillOverride: buttonPrimaryPressedFill.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            buttonSecondaryFillOverride: buttonSecondaryFill.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            buttonSecondaryTextOverride: buttonSecondaryText.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            buttonSecondaryBorderOverride: buttonSecondaryBorder.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            buttonSecondaryHoverFillOverride: buttonSecondaryHoverFill.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            buttonSecondaryPressedFillOverride: buttonSecondaryPressedFill.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            buttonGhostTextOverride: buttonGhostText.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            buttonGhostHoverFillOverride: buttonGhostHoverFill.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            buttonGhostPressedFillOverride: buttonGhostPressedFill.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            linkOverride: link.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            linkHoverOverride: linkHover.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            linkPressedOverride: linkPressed.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            controlDisabledFillOverride: controlDisabledFill.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:)),
            controlDisabledTextOverride: controlDisabledText.flatMap { NSColor(hex: $0) }.map(Color.init(nsColor:))
        )
    }

    /// Re-derives every surface and text colour for `dark`, leaving `accent`,
    /// `accentSecondary` and `cornerRadius` - the parts that make a theme
    /// recognisably itself - untouched.
    ///
    /// M9 9.1, the user's own words: "when clicking dark theme and switching
    /// to light theme then i expect to see a white glass background and not
    /// the same one like now". Before this, the "Dark theme" control changed
    /// one boolean and nothing else: `isDark` flipped but the ramp authored
    /// for a near-black panel came along for the ride, so "Light" kept
    /// rendering as the same dark glass it always was. `panelBackground`
    /// lands pure white here.
    ///
    /// `translucency` moves too, from `run_m9_theme_builder`'s own W1
    /// measurement: the panel is real `NSVisualEffectView` vibrancy
    /// (`PanelRootView.VisualEffectView`), and it renders its INACTIVE-state
    /// material while a theme is being edited (the panel deliberately never
    /// takes key status then - see `PanelController.enterThemeEditing`),
    /// which measured noticeably darker than the active-state material this
    /// was first tuned against. Real translucent light materials in macOS
    /// (a light popover, say) read as closer to opaque than dark ones (a
    /// HUD) to begin with, so trusting the SAME 0.12 for both was the
    /// untested assumption, not the fix: light drops to 0.05, dark is
    /// unchanged.
    mutating func rederiveSurfaces(dark: Bool) {
        let panel = dark ? "#0D0F1C" : "#FFFFFF"
        panelBackground = panel
        cardBackground = DesignDocTheme.shifted(panel, towardsLight: !dark, by: 0.06)
        cardHoverBackground = DesignDocTheme.shifted(panel, towardsLight: !dark, by: 0.10)
        selectedBackground = DesignDocTheme.shifted(panel, towardsLight: !dark, by: 0.16)
        surfaceBackground = DesignDocTheme.shifted(panel, towardsLight: !dark, by: 0.03)
        border = DesignDocTheme.shifted(panel, towardsLight: !dark, by: 0.20)
        textPrimary = dark ? "#FFFFFF" : "#12141C"
        textSecondary = dark ? "#B8BCCC" : "#454A5C"
        textTertiary = dark ? "#7A7F94" : "#8A8FA3"
        translucency = dark ? 0.12 : 0.05
        isDark = dark
    }

    /// Worst text-on-background contrast in the theme, so the builder can warn
    /// before someone saves something unreadable.
    var lowestContrast: Double {
        let pairs = [(textPrimary, cardBackground), (textSecondary, cardBackground),
                     (textPrimary, panelBackground), (textTertiary, surfaceBackground)]
        return pairs.map { Contrast.ratio($0.0, $0.1) }.min() ?? 0
    }

    // MARK: - M17: every editable token, reached by name

    /// The current hex (alpha included, exactly as stored) for a token named
    /// as `ThemeRules.Pairing.foregroundToken`/`backgroundToken` spells it -
    /// the builder's `ColorTokenRow` and QABridge's `m17_setTokenHex`/
    /// `m17_applyNudge` both read a token by the same name the audit grades
    /// it under, so a probe can address "the same colour the matrix is
    /// showing" without a second naming scheme to keep in sync.
    func hex(forToken token: String) -> String? {
        switch token {
        case "accent": return accent
        case "accentSecondary": return accentSecondary
        case "panelBackground": return panelBackground
        case "cardBackground": return cardBackground
        case "cardHoverBackground": return cardHoverBackground
        case "selectedBackground": return selectedBackground
        case "surfaceBackground": return surfaceBackground
        case "textPrimary": return textPrimary
        case "textSecondary": return textSecondary
        case "textTertiary": return textTertiary
        case "border": return border
        case "interaction": return interaction
        case "hoverStroke": return hoverStroke
        case "selectionStroke": return selectionStroke
        case "focusRing": return focusRing
        case "actionHoverFill": return actionHoverFill
        case "tabHoverFill": return tabHoverFill
        case "destructive": return destructive
        case "success": return success
        case "warning": return warning
        case "buttonPrimaryFill": return buttonPrimaryFill
        case "buttonPrimaryText": return buttonPrimaryText
        case "buttonPrimaryHoverFill": return buttonPrimaryHoverFill
        case "buttonPrimaryPressedFill": return buttonPrimaryPressedFill
        case "buttonSecondaryFill": return buttonSecondaryFill
        case "buttonSecondaryText": return buttonSecondaryText
        case "buttonSecondaryBorder": return buttonSecondaryBorder
        case "buttonSecondaryHoverFill": return buttonSecondaryHoverFill
        case "buttonSecondaryPressedFill": return buttonSecondaryPressedFill
        case "buttonGhostText": return buttonGhostText
        case "buttonGhostHoverFill": return buttonGhostHoverFill
        case "buttonGhostPressedFill": return buttonGhostPressedFill
        case "link": return link
        case "linkHover": return linkHover
        case "linkPressed": return linkPressed
        case "controlDisabledFill": return controlDisabledFill
        case "controlDisabledText": return controlDisabledText
        default: return nil
        }
    }

    /// Sets a token by name to `hex`, kept WITH its alpha exactly as given
    /// (M17's "every colour keeps alpha in its stored hex" rule) - returns
    /// whether the name was recognised, so a probe driving an unknown token
    /// fails loudly rather than silently doing nothing.
    @discardableResult
    mutating func setToken(_ token: String, hex: String) -> Bool {
        switch token {
        case "accent": accent = hex
        case "accentSecondary": accentSecondary = hex
        case "panelBackground": panelBackground = hex
        case "cardBackground": cardBackground = hex
        case "cardHoverBackground": cardHoverBackground = hex
        case "selectedBackground": selectedBackground = hex
        case "surfaceBackground": surfaceBackground = hex
        case "textPrimary": textPrimary = hex
        case "textSecondary": textSecondary = hex
        case "textTertiary": textTertiary = hex
        case "border": border = hex
        case "interaction": interaction = hex
        case "hoverStroke": hoverStroke = hex
        case "selectionStroke": selectionStroke = hex
        case "focusRing": focusRing = hex
        case "actionHoverFill": actionHoverFill = hex
        case "tabHoverFill": tabHoverFill = hex
        case "destructive": destructive = hex
        case "success": success = hex
        case "warning": warning = hex
        case "buttonPrimaryFill": buttonPrimaryFill = hex
        case "buttonPrimaryText": buttonPrimaryText = hex
        case "buttonPrimaryHoverFill": buttonPrimaryHoverFill = hex
        case "buttonPrimaryPressedFill": buttonPrimaryPressedFill = hex
        case "buttonSecondaryFill": buttonSecondaryFill = hex
        case "buttonSecondaryText": buttonSecondaryText = hex
        case "buttonSecondaryBorder": buttonSecondaryBorder = hex
        case "buttonSecondaryHoverFill": buttonSecondaryHoverFill = hex
        case "buttonSecondaryPressedFill": buttonSecondaryPressedFill = hex
        case "buttonGhostText": buttonGhostText = hex
        case "buttonGhostHoverFill": buttonGhostHoverFill = hex
        case "buttonGhostPressedFill": buttonGhostPressedFill = hex
        case "link": link = hex
        case "linkHover": linkHover = hex
        case "linkPressed": linkPressed = hex
        case "controlDisabledFill": controlDisabledFill = hex
        case "controlDisabledText": controlDisabledText = hex
        default: return false
        }
        return true
    }

    /// Every name `hex(forToken:)`/`setToken(_:hex:)` recognise, as one list
    /// so a probe can iterate rather than hard-code, and so the two switches
    /// and this array cannot silently drift apart from one another.
    static let allTokenNames: [String] = [
        "accent", "accentSecondary", "panelBackground", "cardBackground",
        "cardHoverBackground", "selectedBackground", "surfaceBackground",
        "textPrimary", "textSecondary", "textTertiary", "border",
        "interaction", "hoverStroke", "selectionStroke", "focusRing", "actionHoverFill", "tabHoverFill",
        "destructive", "success", "warning",
        "buttonPrimaryFill", "buttonPrimaryText", "buttonPrimaryHoverFill", "buttonPrimaryPressedFill",
        "buttonSecondaryFill", "buttonSecondaryText", "buttonSecondaryBorder",
        "buttonSecondaryHoverFill", "buttonSecondaryPressedFill",
        "buttonGhostText", "buttonGhostHoverFill", "buttonGhostPressedFill",
        "link", "linkHover", "linkPressed", "controlDisabledFill", "controlDisabledText"
    ]
}

/// WCAG relative-luminance contrast, used to keep generated themes legible.
enum Contrast {
    static func ratio(_ a: String, _ b: String) -> Double {
        guard let ca = NSColor(hex: a), let cb = NSColor(hex: b) else { return 0 }
        return ratio(ca, cb)
    }

    /// Ratio between two colors that are already opaque.
    ///
    /// Alpha is *not* handled here on purpose: a translucent color has no
    /// contrast of its own, only the contrast of what it becomes over something.
    /// Callers composite first, which is what `composite(_:over:)` is for. The
    /// audit used to skip that step and grade `white.opacity(0.45)` as pure
    /// white, which made every theme look better than it rendered.
    static func ratio(_ a: NSColor, _ b: NSColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        let (hi, lo) = la > lb ? (la, lb) : (lb, la)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// `foreground` painted onto `background`, giving the color that reaches
    /// the screen.
    static func composite(_ foreground: NSColor, over background: NSColor) -> NSColor {
        guard let f = foreground.usingColorSpace(.sRGB),
              let b = background.usingColorSpace(.sRGB) else { return foreground }
        let a = f.alphaComponent
        if a >= 1 { return f }
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x * a + y * (1 - a) }
        return NSColor(srgbRed: mix(f.redComponent, b.redComponent),
                       green: mix(f.greenComponent, b.greenComponent),
                       blue: mix(f.blueComponent, b.blueComponent),
                       alpha: 1)
    }

    /// Not `private`: M17's `APCA` (`Theme/ThemeRules.swift`) starts from the
    /// exact same sRGB relative luminance WCAG uses - the two contrast
    /// models differ only in what they do with the two numbers, not in how
    /// each is computed - so this is the one place that number is worked
    /// out, kept `internal` rather than duplicated in the other file.
    static func relativeLuminance(_ color: NSColor) -> Double { luminance(color) }

    private static func luminance(_ color: NSColor) -> Double {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ v: CGFloat) -> Double {
            let d = Double(v)
            return d <= 0.03928 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent)
             + 0.7152 * channel(c.greenComponent)
             + 0.0722 * channel(c.blueComponent)
    }
}

extension Color {
    /// `#RRGGBB` for storage.
    /// Alpha is kept as `#RRGGBBAA` when there is any.
    ///
    /// Dropping it was quietly wrong: a token written as `white.opacity(0.45)`
    /// came back as `#FFFFFF`, so the audit graded a color ten times more
    /// contrasty than the one on screen and reported the theme as accessible.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        let a = Int((ns.alphaComponent * 255).rounded())
        return a >= 255 ? String(format: "#%02X%02X%02X", r, g, b)
                        : String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}

/// One or more themes, as a file.
///
/// A theme the user built is theirs, so it has to be able to leave the app:
/// onto a second Mac, into a backup, to somebody else. The wrapper carries the
/// two facts a reader needs before it trusts the payload - which format this
/// is, and which app wrote it - because a bare `[CustomTheme]` array cannot say
/// "this is from a newer Clip than you are" and would fail as a decode error
/// with no remedy in it.
struct ThemeFile: Codable {

    /// The only version this app writes. A file from the future is refused with
    /// its version named, never half-read.
    static let currentVersion = 1
    /// The extension the panels filter on and the writer appends.
    static let fileExtension = "cliptheme"

    var version = Self.currentVersion
    var app: String
    var themes: [CustomTheme]

    enum ReadError: LocalizedError {
        case notAThemeFile
        case fromTheFuture(Int)
        case empty

        var errorDescription: String? {
            switch self {
            case .notAThemeFile:
                return "That file is not a Clip theme."
            case .fromTheFuture(let version):
                return "That theme file was written by a newer version of Clip "
                     + "(format \(version)). Update Clip and try again."
            case .empty:
                return "That theme file has no themes in it."
            }
        }
    }

    /// The bytes for a save panel.
    static func data(for themes: [CustomTheme]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return try encoder.encode(ThemeFile(app: "Clip \(version)", themes: themes))
    }

    /// What is in a file, validated, before anything is saved.
    static func read(_ data: Data) throws -> [CustomTheme] {
        guard let file = try? JSONDecoder().decode(ThemeFile.self, from: data) else {
            throw ReadError.notAThemeFile
        }
        guard file.version <= currentVersion else {
            throw ReadError.fromTheFuture(file.version)
        }
        guard !file.themes.isEmpty else { throw ReadError.empty }
        return file.themes
    }
}

/// Persists user themes and tracks which one is selected.
@MainActor
final class CustomThemeStore: ObservableObject {
    static let shared = CustomThemeStore()

    @Published private(set) var themes: [CustomTheme] = []

    /// Bumped whenever the stored themes change.
    ///
    /// `ThemeManager` caches the built theme, and editing a custom theme keeps
    /// the same id, so an id alone cannot tell the cache it is stale. A counter
    /// can. Saving a theme the user is not currently using bumps this too, which
    /// costs one rebuild and is the safe direction to be wrong in.
    @Published private(set) var revision: Int = 0

    private init() { load() }

    private func touch() { revision &+= 1 }

    func theme(withID id: String) -> CustomTheme? {
        themes.first { "custom:\($0.id)" == id || $0.id == id }
    }

    func save(_ theme: CustomTheme) {
        if let i = themes.firstIndex(where: { $0.id == theme.id }) { themes[i] = theme }
        else { themes.append(theme) }
        persist(theme)
        touch()
    }

    /// Lands themes read from a file as NEW themes.
    ///
    /// Never by their own id: an import that reused it would silently overwrite
    /// a theme the user is still using, and the only signal would be their work
    /// disappearing. A fresh id and a non-colliding name mean an import can be
    /// undone by deleting what it added.
    @discardableResult
    func adopt(_ incoming: [CustomTheme]) -> [CustomTheme] {
        var landed: [CustomTheme] = []
        for theme in incoming {
            let name = themes.contains(where: { $0.name == theme.name })
                ? CustomTheme.copyName(for: theme.name, existing: themes.map(\.name))
                : theme.name
            let copy = theme.duplicated(named: name)
            save(copy)
            landed.append(copy)
        }
        return landed
    }

    func remove(_ id: String) {
        themes.removeAll { $0.id == id }
        touch()
        Database.shared.run("DELETE FROM custom_themes WHERE id = ?;", [id])
        if ThemeManager.shared.themeID == "custom:\(id)" {
            ThemeManager.shared.themeID = AppTheme.presets[0].id
        }
    }

    private func persist(_ theme: CustomTheme) {
        guard let data = try? JSONEncoder().encode(theme),
              let json = String(data: data, encoding: .utf8) else { return }
        Database.shared.run("""
            INSERT INTO custom_themes (id, name, payload, created_at) VALUES (?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, payload=excluded.payload;
            """, [theme.id, theme.name, json, Date()])
    }

    private func load() {
        // Already one row per theme, so a bad row was never able to wipe the
        // others - what was missing is saying so. `compactMap` used to drop
        // an unreadable theme with nobody told it had ever existed.
        let rows = Database.shared.query("SELECT payload FROM custom_themes ORDER BY created_at;")
        var loaded: [CustomTheme] = []
        var quarantined = 0
        for row in rows {
            guard let json = row["payload"] as? String, let data = json.data(using: .utf8),
                  let theme = try? JSONDecoder().decode(CustomTheme.self, from: data) else {
                quarantined += 1
                continue
            }
            loaded.append(theme)
        }
        themes = loaded
        if quarantined > 0 {
            NoticeCenter.shared.report(.decodeFailed(entity: "theme", count: quarantined))
        }
        touch()
    }
}
