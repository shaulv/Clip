import SwiftUI
import AppKit

/// The draft `ThemeBuilderWindowController` (AppKit) and `ThemeBuilderView`
/// (SwiftUI) both act on - see the window controller's own doc comment for
/// why this exists as a separate object rather than either side reaching
/// into the other's private state.
@MainActor
final class ThemeBuilderState: ObservableObject {
    @Published var theme: CustomTheme = .from(AppTheme.presets[0], name: "My theme")
    /// The token the contrast matrix and the token column both highlight -
    /// set by tapping a swatch in either place (M17: "selecting a swatch
    /// highlights its row and column").
    @Published var selectedToken: String? = nil
    /// M30: the contrast matrix's own "Show the full check" disclosure -
    /// on the shared state (not a plain `@State` inside the view) so a
    /// fresh `open()` can genuinely reset it every time, and so the QA
    /// bridge can drive it directly at any point, not only before the
    /// view's very first `onAppear` (the window's SwiftUI content is built
    /// once and reused across every open/close - see `ThemeBuilder
    /// WindowController.hasBuiltContent` - so a plain one-shot "force this
    /// open on appear" flag would only ever work on the first open of a
    /// process's whole lifetime).
    @Published var matrixFullAuditOpen: Bool = false
    var onSave: ((CustomTheme) -> Void)?
    var onCancel: (() -> Void)?
}

/// M17: the theme builder's own full-height window content.
///
/// Replaces the M9 sheet entirely - no mini-preview (the user's own words:
/// "it's enough that we have the right side panel to see the preview on
/// him"), no `DisclosureGroup` anywhere (the user's own words: "i don't want
/// the colors in collapsible/expandable tab and i want all of the colors
/// open for scroll and use all the screen height"). Every token group is
/// simply always open; the real clipboard panel docked beside this window
/// (`PanelController.enterThemeEditing`) IS the preview.
struct ThemeBuilderView: View {
    /// Every group's title, in display order - all of them are ALWAYS
    /// rendered open (no `DisclosureGroup`, no collapse of any kind), so
    /// this doubles as the QA bridge's `m17_groupsOpen` answer: the list a
    /// probe expects to see reported open is exactly the list of groups
    /// that exist, because there is no other state for a group to be in.
    static let groupTitles = ["Surfaces", "Text", "Accent", "Interaction",
                              "Status", "Buttons and links", "Element colors"]
    /// The scroll-anchor id on the "Buttons and links" group, so a probe
    /// can bring it into view (`ComponentPreviewScrollBridge`) before
    /// snapshotting the live component row that now lives inside it.
    static let buttonsGroupID = "m11_buttonsGroup"

    @EnvironmentObject private var state: ThemeBuilderState
    @ObservedObject private var scrollBridge = ComponentPreviewScrollBridge.shared
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject private var ai = AIService.shared
    /// M19: "Inspect element" - hovering the real panel shows which tokens
    /// paint whatever is under the pointer; clicking scrolls and flashes
    /// this column's own rows. See `ThemeTokenTagging.swift`.
    @ObservedObject private var inspect = ThemeInspectRegistry.shared

    /// Collapsed every time the builder opens, never remembered open (M9
    /// 9.4's own reasoning, unchanged by M17): a theme built entirely by
    /// hand never has to look past it. Not a `DisclosureGroup` - a plain
    /// `@State` bool driving a hand-rolled header, the same pattern
    /// `SettingsSyncPane`'s "Advanced" row already uses.
    @State private var assistantExpanded = false
    @State private var instruction = ""
    @State private var aiError: String?
    @State private var history: [CustomTheme] = []

    #if CLIP_TESTING
    @ObservedObject private var draftBridge = ThemeDraftTestBridge.shared
    #endif
    @ObservedObject private var componentBridge = M11ComponentTestBridge.shared

    private var theme: Binding<CustomTheme> {
        Binding(get: { state.theme }, set: { state.theme = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            identityHeader
            if ai.isAvailable { assistantStrip }
            Divider()
            HStack(spacing: 0) {
                // `ScrollViewReader` so a probe can bring "Buttons and
                // links" into view before snapshotting it - the live
                // component row now lives INSIDE that group (the user's own
                // words: "place the button preview where it's relevant ...
                // not where it is now"), which is not always the first
                // thing visible in a long scrolling column.
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.group) {
                            tokenGroups
                        }
                        .padding(Spacing.group)
                    }
                    #if CLIP_TESTING
                    .onChange(of: scrollBridge.scrollRequested) { _, _ in
                        proxy.scrollTo(Self.buttonsGroupID, anchor: .top)
                    }
                    #endif
                    // M19: a click in Inspect mode scrolls the token column
                    // to the first of the clicked element's own tokens.
                    // Keyed on `scrollRequestToken`, not `scrolledToken`
                    // itself, so a second click on the SAME element still
                    // re-scrolls (a `String?` unchanged across two clicks
                    // would not fire `.onChange` at all).
                    .onChange(of: inspect.scrollRequestToken) { _, _ in
                        if let token = inspect.scrolledToken {
                            state.selectedToken = token
                            withAnimation { proxy.scrollTo(token, anchor: .center) }
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                Divider()

                ContrastMatrixView(theme: theme, selectedToken: $state.selectedToken,
                                   showFullAudit: $state.matrixFullAuditOpen)
                    .frame(width: 340)
            }
            Divider()
            footer
        }
        // NOT minWidth: 720 - an explicit SwiftUI minWidth on the
        // window's own root content propagates to NSHostingView's
        // size negotiation and silently overrides `window.minSize`
        // (already lowered to 400 in ThemeBuilderWindowController for
        // exactly this reason): measured directly, THIS line - not the
        // AppKit-level minSize - was what kept reopening the window at
        // 720pt wide on a real 1512pt-wide screen where the M17 formula
        // legitimately computes 668pt. Height has no such fight (the
        // formula always uses the full visible height), so minHeight
        // stays.
        .frame(minHeight: 480)
        .onChange(of: state.theme) { _, updated in themeManager.updatePreview(updated) }
        #if CLIP_TESTING
        // Lets the QA bridge change the DRAFT directly, the same reasoning
        // `m7_setPreviewAccent` already uses for the live panel's own
        // preview - M11's "prove red" needs exactly this distinction.
        .onChange(of: draftBridge.accentToken) { _, _ in
            state.theme.accent = draftBridge.pendingAccent
        }
        .onChange(of: draftBridge.expandAssistantToken) { _, _ in
            assistantExpanded = true
        }
        .onChange(of: draftBridge.buttonTokenChanged) { _, _ in
            state.theme.setToken(draftBridge.pendingButtonTokenKey, hex: draftBridge.pendingButtonTokenHex)
        }
        #endif
    }

    // MARK: - Header

    /// TOP: the theme's own identity - name and Dark/Light, unchanged from
    /// M9's own reasoning. Flipping "Dark theme" re-derives the WHOLE
    /// surface ramp, not only the boolean (`CustomTheme.rederiveSurfaces`).
    private var identityHeader: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.tight) {
                // The same boxed input every Settings pane uses (user, 03/09):
                // rounded border, body type, not a heading in a box. Unlike
                // a Settings pane (which always follows the SYSTEM'S own
                // appearance on purpose), this field edits a DRAFT theme
                // that can be light while the system is in Dark Mode or the
                // reverse - `.roundedBorder`'s chrome is a real AppKit
                // control (`NSTextField`), and its fill/border/text colors
                // resolve against whatever appearance is in effect when it
                // draws, not against this theme's own tokens. T3-M10:
                // forcing `.colorScheme` to the theme's own mode makes that
                // native chrome draw as THIS theme's mode regardless of the
                // system's, the same fix applied to the Toggle switch right
                // below it - no hex, no opacity nudge, just telling AppKit
                // which appearance is actually in effect here.
                TextField("Theme name", text: theme.name)
                    .textFieldStyle(.roundedBorder)
                    .font(Typography.body)
                    .colorScheme(state.theme.isDark ? .dark : .light)
                inspectToggle
            }

            // T3-M9: this used the plain-string initializer, whose label is a
            // bare `Text` painted in the default (system-appearance-bound)
            // foreground - invisible against a light custom theme's own
            // `panelBackground` whenever the SYSTEM is in Dark Mode, leaving
            // only the switch's own white knob visible (the "stray white
            // pill" under the name field). The explicit label reads through
            // `theme.appTheme.textPrimary`, the same per-mode token every
            // other label in this header already uses.
            //
            // T3-M10: the switch's own knob and track are native AppKit
            // chrome too (`NSSwitch`), same class of bug as the TextField
            // above - forced to the theme's own mode for the same reason.
            Toggle(isOn: Binding(
                get: { state.theme.isDark },
                set: { state.theme.rederiveSurfaces(dark: $0) }
            )) {
                Text("Dark theme").foregroundStyle(state.theme.appTheme.textPrimary)
            }
            .toggleStyle(.switch)
            .colorScheme(state.theme.isDark ? .dark : .light)
        }
        .padding(.horizontal, Spacing.group)
        .padding(.top, Spacing.group)
        .padding(.bottom, Spacing.tight)
    }

    /// M19: "Inspect element" - the user's own words: "same like dev tools
    /// in the browser". On while `inspect.isInspecting`; toggling it also
    /// opens/closes the real overlay window over the panel
    /// (`ThemeInspectController`), which is the AppKit half this button
    /// cannot do by itself.
    private var inspectToggle: some View {
        // A labelled button with the dev-tools inspect glyph (a cursor over a
        // frame), selected while inspecting; the tooltip says how to use it
        // (user, 03/09).
        // T3-M10: this call omitted `theme:`, so `SecondaryButton` fell back
        // to `themeManager.theme` - the LIVE app theme, which is not
        // necessarily this DRAFT (a light draft edited while the live theme
        // is dark painted this button in the wrong mode's colors). Every
        // themed control in this file must read the DRAFT, explicitly.
        SecondaryButton("Inspect", systemImage: "cursorarrow.square", size: .small,
                        isSelected: inspect.isInspecting, theme: state.theme.appTheme) {
            ThemeInspectController.shared.toggle()
        }
        // Bare "I", exactly as the plan spells it - the same key a real
        // dev-tools inspector answers to.
        .keyboardShortcut("i", modifiers: [])
        .help(inspect.isInspecting
              ? "Inspecting: hover any element in the panel to see the colors that paint it, click to jump to them. Press I or Escape to stop."
              : "Inspect (I): hover any element in the panel to see the colors that paint it, click to jump to them here.")
        .accessibilityIdentifier("themeBuilder.inspectToggle")
    }

    /// TOP, collapsed by default, hidden entirely with no AI connection -
    /// M9 9.4/9.5 unchanged by M17 beyond moving file and losing the
    /// `DisclosureGroup` it used to be built from.
    private var assistantStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.tight) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text("Theme assistant").font(Typography.labelStrong)
                Spacer()
                if ai.isWorking { ProgressView().controlSize(.small) }
                Image(systemName: assistantExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(state.theme.appTheme.secondaryText(on: state.theme.appTheme.cardBackground))
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { assistantExpanded.toggle() } }
            .settingsHover(cornerRadius: state.theme.appTheme.radiusControl)

            if assistantExpanded {
                // Tight: the editor's own meta line ("0 characters") sits
                // right above the presets (user, 03/09).
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text("Ask for a change")
                        .font(Typography.labelStrong)
                        .foregroundStyle(state.theme.appTheme.secondaryText(on: state.theme.appTheme.cardBackground))
                    MarkdownPromptEditor(text: $instruction,
                                         placeholder: "warmer, more contrast, less blue…",
                                         theme: state.theme.appTheme, minHeight: 44, maxHeight: 140,
                                         testID: "m9_instructionPrompt",
                                         showsPreview: true, showsAI: true)
                    HStack {
                        if ai.isWorking { ProgressView().controlSize(.small) }
                        Spacer()
                        PrimaryButton("Apply", size: .small,
                                      isDisabled: instruction.trimmingCharacters(in: .whitespaces).isEmpty
                                                  || ai.isWorking, theme: state.theme.appTheme, action: refine)
                    }
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text("Or choose one").font(Typography.caption)
                            .foregroundStyle(state.theme.appTheme.secondaryText(on: state.theme.appTheme.cardBackground))
                        HStack(spacing: Spacing.tight) {
                            ForEach(["Warmer", "Cooler", "More contrast", "Softer", "More vivid"], id: \.self) { hint in
                                SecondaryButton(hint, size: .small, isDisabled: ai.isWorking,
                                                theme: state.theme.appTheme) {
                                    instruction = hint.lowercased(); refine()
                                }
                            }
                        }
                    }
                    if let aiError {
                        // T3-M10: was `SettingsPalette.danger` (system-appearance
                        // bound); `destructive` is this theme's OWN token, already
                        // audited for "delete and error text" on this exact ground.
                        Text(aiError).font(Typography.caption)
                            .foregroundStyle(state.theme.appTheme.destructive).lineLimit(2)
                    }
                }
                .padding(.top, Spacing.tight)
            }
        }
        .padding(Spacing.related)
        // T3-M10: was `Color(nsColor: .controlBackgroundColor)`, a native
        // system-appearance-bound fill; `cardBackground` is this theme's
        // OWN "where each item sits" token.
        .background(state.theme.appTheme.cardBackground,
                    in: RoundedRectangle(cornerRadius: state.theme.appTheme.radiusCard, style: .continuous))
        .elevation(Shadows.card)
        .padding(.horizontal, Spacing.comfortable)
        .padding(.top, Spacing.tight)
        .padding(.bottom, Spacing.tight)
    }

    private func refine() {
        let text = instruction.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        aiError = nil
        let before = state.theme
        Task {
            do {
                let refined = try await ai.refineTheme(before, instruction: text)
                history.append(before)
                state.theme = refined
                instruction = ""
            } catch {
                aiError = AIDiagnosis.read(error).message
            }
        }
    }

    // MARK: - Body: every group, always open

    /// M17: "all of the colors open for scroll" - one flat run of sections,
    /// no `DisclosureGroup`, no collapse affordance of any kind. `group(_:)`
    /// is a header label over its rows, nothing more.
    @ViewBuilder
    private var tokenGroups: some View {
        group("Surfaces") {
            ColorTokenRow(label: "Panel background", token: "panelBackground",
                         role: "The base surface behind everything else.",
                         hex: theme.panelBackground, selection: $state.selectedToken)
            ColorTokenRow(label: "Card", token: "cardBackground",
                         role: "Where each item sits.", hex: theme.cardBackground,
                         selection: $state.selectedToken)
            ColorTokenRow(label: "Card hover", token: "cardHoverBackground",
                         role: "A row under the pointer.", hex: theme.cardHoverBackground,
                         selection: $state.selectedToken)
            ColorTokenRow(label: "Selection", token: "selectedBackground",
                         role: "The chosen row or card.", hex: theme.selectedBackground,
                         selection: $state.selectedToken)
            ColorTokenRow(label: "Surface", token: "surfaceBackground",
                         role: "Toolbars, search, footer hints.", hex: theme.surfaceBackground,
                         selection: $state.selectedToken)
            ColorTokenRow(label: "Border", token: "border",
                         role: "Hairlines around cards and controls.", hex: theme.border,
                         selection: $state.selectedToken)
        }

        group("Text") {
            ColorTokenRow(label: "Text, primary", token: "textPrimary",
                         role: "Titles: the text read first.", hex: theme.textPrimary,
                         selection: $state.selectedToken)
            ColorTokenRow(label: "Text, secondary", token: "textSecondary",
                         role: "Previews and supporting text.", hex: theme.textSecondary,
                         selection: $state.selectedToken)
            ColorTokenRow(label: "Text, tertiary", token: "textTertiary",
                         role: "Timestamps: the smallest real text in the app.",
                         hex: theme.textTertiary, selection: $state.selectedToken)
        }

        group("Accent") {
            ColorTokenRow(label: "Accent", token: "accent",
                         role: "Selection rings, links, the brand mark.", hex: theme.accent,
                         selection: $state.selectedToken)
            ColorTokenRow(label: "Accent, secondary", token: nil,
                         role: "The gradient's second stop.", hex: theme.accentSecondary,
                         selection: $state.selectedToken)
        }

        group("Interaction") {
            note("Hover, focus, and selection share defaults until an explicit role is set, while tab hover is independently controllable.")
            optionalRow("Interaction base", token: nil, role: "What hover, focus and selection derive from.",
                       binding: theme.interaction, auto: state.theme.appTheme.interaction)
            optionalRow("Hover ring", token: "hoverStroke", role: "The outline of a hovered row.",
                       binding: theme.hoverStroke, auto: state.theme.appTheme.hoverStroke)
            optionalRow("Selected border", token: "selectionStroke", role: "The outline of the chosen row.",
                       binding: theme.selectionStroke, auto: state.theme.appTheme.selectionStroke)
            optionalRow("Focus ring", token: "focusRing", role: "Keyboard focus: must never be missed.",
                       binding: theme.focusRing, auto: state.theme.appTheme.focusRing)
            optionalRow("Hovered action disc", token: nil, role: "The tinted disc behind a hovered icon.",
                       binding: theme.actionHoverFill, auto: state.theme.appTheme.actionHoverFill)
            optionalRow("Tab hover fill", token: "tabHoverFill", role: "The fill behind an unselected main tab under the pointer.",
                       binding: theme.tabHoverFill, auto: state.theme.appTheme.tabHoverFill)
        }

        group("Status") {
            note("Each of these is read on the card, on a hovered row and on the selected row, so it has to work on all three.")
            optionalRow("Destructive", token: "destructive", role: "Delete and error text.",
                       binding: theme.destructive, auto: state.theme.appTheme.destructive)
            optionalRow("Success", token: "success", role: "Something that worked.",
                       binding: theme.success, auto: state.theme.appTheme.success)
            optionalRow("Warning", token: "warning", role: "Something needing attention.",
                       binding: theme.warning, auto: state.theme.appTheme.warning)
        }

        group("Buttons and links") {
            componentGallery(state.theme.appTheme)
            Text("Primary CTA").font(Typography.labelStrong).foregroundStyle(state.theme.appTheme.secondaryText(on: state.theme.appTheme.panelBackground))
            optionalRow("Fill", token: "buttonPrimaryFill", role: "The one blue CTA's fill.",
                       binding: theme.buttonPrimaryFill, auto: state.theme.appTheme.buttonPrimaryFill)
            optionalRow("Label", token: "buttonPrimaryText", role: "Label on the primary CTA.",
                       binding: theme.buttonPrimaryText, auto: state.theme.appTheme.buttonPrimaryText)
            optionalRow("Hover fill", token: "buttonPrimaryHoverFill", role: "The CTA under the pointer.",
                       binding: theme.buttonPrimaryHoverFill, auto: state.theme.appTheme.buttonPrimaryHoverFill)
            optionalRow("Pressed fill", token: "buttonPrimaryPressedFill", role: "The CTA while clicked.",
                       binding: theme.buttonPrimaryPressedFill, auto: state.theme.appTheme.buttonPrimaryPressedFill)

            Divider()
            Text("Sub button").font(Typography.labelStrong).foregroundStyle(state.theme.appTheme.secondaryText(on: state.theme.appTheme.panelBackground))
            optionalRow("Fill", token: "buttonSecondaryFill", role: "The sub button's quiet surface.",
                       binding: theme.buttonSecondaryFill, auto: state.theme.appTheme.buttonSecondaryFill)
            optionalRow("Label", token: "buttonSecondaryText", role: "Label on the sub button.",
                       binding: theme.buttonSecondaryText, auto: state.theme.appTheme.buttonSecondaryText)
            optionalRow("Border", token: "buttonSecondaryBorder", role: "The sub button's outline.",
                       binding: theme.buttonSecondaryBorder, auto: state.theme.appTheme.buttonSecondaryBorder)
            optionalRow("Hover fill", token: "buttonSecondaryHoverFill", role: "The sub button under the pointer.",
                       binding: theme.buttonSecondaryHoverFill, auto: state.theme.appTheme.buttonSecondaryHoverFill)
            optionalRow("Pressed fill", token: "buttonSecondaryPressedFill", role: "The sub button while clicked.",
                       binding: theme.buttonSecondaryPressedFill, auto: state.theme.appTheme.buttonSecondaryPressedFill)

            Divider()
            Text("Ghost button").font(Typography.labelStrong).foregroundStyle(state.theme.appTheme.secondaryText(on: state.theme.appTheme.panelBackground))
            optionalRow("Label", token: "buttonGhostText", role: "No fill until touched.",
                       binding: theme.buttonGhostText, auto: state.theme.appTheme.buttonGhostText)
            optionalRow("Hover fill", token: "buttonGhostHoverFill", role: "The wash behind a hovered ghost button.",
                       binding: theme.buttonGhostHoverFill, auto: state.theme.appTheme.buttonGhostHoverFill)
            optionalRow("Pressed fill", token: "buttonGhostPressedFill", role: "The wash while a ghost button is pressed.",
                       binding: theme.buttonGhostPressedFill, auto: state.theme.appTheme.buttonGhostPressedFill)

            Divider()
            Text("Link").font(Typography.labelStrong).foregroundStyle(state.theme.appTheme.secondaryText(on: state.theme.appTheme.panelBackground))
            optionalRow("Idle", token: "link", role: "An inline link.",
                       binding: theme.link, auto: state.theme.appTheme.link)
            optionalRow("Hover", token: "linkHover", role: "A link under the pointer.",
                       binding: theme.linkHover, auto: state.theme.appTheme.linkHover)
            optionalRow("Pressed", token: "linkPressed", role: "A link while clicked.",
                       binding: theme.linkPressed, auto: state.theme.appTheme.linkPressed)

            Divider()
            Text("Disabled").font(Typography.labelStrong).foregroundStyle(state.theme.appTheme.secondaryText(on: state.theme.appTheme.panelBackground))
            optionalRow("Fill", token: "controlDisabledFill", role: "Shared by every disabled button.",
                       binding: theme.controlDisabledFill, auto: state.theme.appTheme.controlDisabledFill)
            optionalRow("Label", token: "controlDisabledText", role: "Shared by every disabled label.",
                       binding: theme.controlDisabledText, auto: state.theme.appTheme.controlDisabledText)
        }
        .id(Self.buttonsGroupID)

        group("Element colors") {
            Text("Left on Auto, each of these is worked out from the colors above so it stays readable on whatever it lands on.")
                .font(Typography.caption).foregroundStyle(state.theme.appTheme.secondaryText(on: state.theme.appTheme.panelBackground))
            optionalRow("Accent, as text", token: "accent",
                       role: "Accent's own color used as small text.",
                       binding: theme.accentTextOverride, auto: state.theme.appTheme.accentOnCard)
            optionalRow("Text on the selected row", token: nil,
                       role: "Overrides the derived text color for the selected row.",
                       binding: theme.selectionTextOverride,
                       auto: state.theme.appTheme.text(on: state.theme.appTheme.selectedBackground))
            Divider()
            Text("Type colors").font(Typography.caption).foregroundStyle(state.theme.appTheme.secondaryText(on: state.theme.appTheme.panelBackground))
            ForEach(ItemKind.allCases.filter { $0 != .colorData }) { kind in
                typeTintRow(kind)
            }
        }

        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text("Corner radius: \(Int(state.theme.cornerRadius))")
                .font(Typography.subheading).foregroundStyle(state.theme.appTheme.secondaryText(on: state.theme.appTheme.panelBackground))
            // T3-M10: `Slider` is native AppKit chrome (`NSSlider`), same
            // class of system-appearance-bound control as the name field
            // and the Dark theme switch above - forced to this theme's own
            // mode for the same reason.
            Slider(value: theme.cornerRadius, in: 4...22, step: 1)
                .colorScheme(state.theme.isDark ? .dark : .light)
        }

        accessibilitySummary
    }

    private func typeTintRow(_ kind: ItemKind) -> some View {
        let auto = state.theme.appTheme.tint(for: kind, on: state.theme.appTheme.cardBackground)
        return optionalRow(kind.rawValue, token: "typeTint.\(kind.rawValue)",
                          role: "The \(kind.rawValue) glyph and badge.",
                          binding: Binding(
                            get: { state.theme.typeTints?[kind.rawValue] },
                            set: { newValue in
                                var tints = state.theme.typeTints ?? [:]
                                if let newValue { tints[kind.rawValue] = newValue }
                                else { tints.removeValue(forKey: kind.rawValue) }
                                state.theme.typeTints = tints.isEmpty ? nil : tints
                            }),
                          auto: auto)
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(title).font(Typography.subheading).foregroundStyle(state.theme.appTheme.secondaryText(on: state.theme.appTheme.panelBackground))
            VStack(alignment: .leading, spacing: Spacing.tight) { content() }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(state.theme.appTheme.secondaryText(on: state.theme.appTheme.panelBackground))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A row for an OPTIONAL token: Auto until touched, still a full
    /// `ColorTokenRow` (large swatch, role, hex+alpha, contrast badge) once
    /// it has a real value - `token` is `nil` for a field the audit does not
    /// grade on its own (it only ever appears composited into something
    /// else), which is exactly `ColorTokenRow`'s own "no badge is honest
    /// here" rule.
    private func optionalRow(_ label: String, token: String?, role: String,
                             binding: Binding<String?>, auto: Color) -> some View {
        ColorTokenRow(label: label, token: token, role: role,
                     hex: Binding(get: { binding.wrappedValue ?? auto.hexString },
                                  set: { binding.wrappedValue = $0 }),
                     selection: $state.selectedToken,
                     isAuto: binding.wrappedValue == nil,
                     onResetToAuto: { binding.wrappedValue = nil })
    }

    // MARK: - Footer

    private var accessibilitySummary: some View {
        let report = ThemeRules.audit(state.theme.appTheme)
        return VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.tight) {
                Image(systemName: report.passes ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(report.passes ? state.theme.appTheme.success : state.theme.appTheme.warning)
                Text(report.passes
                     ? "Readable: all \(report.findings.count) color pairs pass"
                     : "\(report.failures.count) of \(report.findings.count) color pairs are hard to read")
                    .font(Typography.body.weight(.semibold))
                    // T3-M10: had no `foregroundStyle` at all, so it painted
                    // in SwiftUI's default label color - which follows the
                    // real system appearance, not this draft theme's mode.
                    .foregroundStyle(state.theme.appTheme.textPrimary)
            }
            if !report.passes {
                // T3-M10: omitted `theme:`, so it fell back to the LIVE
                // `themeManager.theme` instead of this draft.
                SecondaryButton("Fix the colors that fail", size: .small, theme: state.theme.appTheme) {
                    history.append(state.theme)
                    state.theme = ThemeDoctor.repaired(state.theme)
                }
                .help("Moves only the failing colors, and only in brightness, so the theme keeps its character.")
            }
        }
        .padding(Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // T3-M10: was `Color(nsColor: .controlBackgroundColor)` (native,
        // system-appearance bound); `cardBackground` is this theme's own
        // "where each item sits" token.
        .background(state.theme.appTheme.cardBackground,
                    in: RoundedRectangle(cornerRadius: state.theme.appTheme.radiusCard))
    }

    private var footer: some View {
        HStack {
            // T3-M10: every button below omitted `theme:`, so each one fell
            // back to `themeManager.theme` - the app's LIVE theme, which the
            // Cancel/Undo/Save footer must not do while editing a DRAFT that
            // can differ from it in mode (this is the exact class of bug
            // the milestone was opened for: "the Inspect button, Cancel and
            // the footer" painting from the wrong theme).
            SecondaryButton("Cancel", theme: state.theme.appTheme) {
                themeManager.endPreview()
                state.onCancel?()
                ThemeBuilderWindowController.shared.close()
            }
            if !history.isEmpty {
                GhostButton("Undo", theme: state.theme.appTheme) {
                    if let last = history.popLast() { state.theme = last }
                }
            }
            Spacer()
            PrimaryButton("Save theme",
                          isDisabled: state.theme.name.trimmingCharacters(in: .whitespaces).isEmpty,
                          theme: state.theme.appTheme) {
                let saved = state.theme
                state.onSave?(saved)
                ThemeBuilderWindowController.shared.close()
            }
        }
        .padding(Spacing.comfortable)
    }

    // MARK: - M11: the four components, every state, for tuning button tokens

    /// A small, always-visible state gallery for the four shared components -
    /// NOT the removed mini-preview (that duplicated the real panel's own
    /// card list; this shows something the real panel cannot: all four
    /// interaction states side by side while a button token is being tuned).
    /// Registered into `MiniPreviewTestRegistry` so `m11_renderComponent`/
    /// `m9_snapshotMiniPreview` keep working unchanged.
    private func componentGallery(_ t: AppTheme) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text("Live sample").font(Typography.labelStrong)
                .foregroundStyle(t.secondaryText(on: t.panelBackground))
            liveComponentRow(t)
            Divider()
            Text("Components: every state").font(Typography.labelStrong)
                .foregroundStyle(t.secondaryText(on: t.panelBackground))
            componentStateRow(t, name: "primary") { state in
                PrimaryButton("Continue", size: .small, forcedState: state, theme: t) {}
            }
            componentStateRow(t, name: "secondary") { state in
                SecondaryButton("Cancel", size: .small, forcedState: state, theme: t) {}
            }
            componentStateRow(t, name: "ghost") { state in
                GhostButton("Skip", size: .small, forcedState: state, theme: t) {}
            }
            componentStateRow(t, name: "link") { state in
                ClipLink("Learn more", size: .small, forcedState: state, theme: t) {}
            }
        }
        .padding(Spacing.related)
        .background(t.panelBackground, in: RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous).stroke(t.border))
        #if CLIP_TESTING
        .background(ComponentGalleryProbe())
        #endif
    }

    /// The real, interactive instances of the four shared components,
    /// idle unless a probe forces one - the "live sample" the user asked
    /// to sit beside the button/link tokens it demonstrates, in "Buttons
    /// and links" itself now, not the window header. Distinct from
    /// `componentStateRow`'s STATIC four-state matrix just below it (which
    /// always shows true idle/hover/pressed/focused regardless of any
    /// override, so it stays honest as a reference). `QABridge`'s
    /// `m11_renderComponent` forces exactly ONE of these four into a state
    /// and re-snapshots the WHOLE window, so a before/after diff attributes
    /// its entire pixel delta to the one component that changed - nothing
    /// else in this view reads the bridge.
    private func liveComponentRow(_ t: AppTheme) -> some View {
        HStack(spacing: Spacing.related) {
            PrimaryButton("Primary action", size: .small,
                          forcedState: componentBridge.forced(for: "primary"), theme: t) {}
            SecondaryButton("Sub action", size: .small,
                            forcedState: componentBridge.forced(for: "secondary"), theme: t) {}
            GhostButton("Ghost", size: .small,
                        forcedState: componentBridge.forced(for: "ghost"), theme: t) {}
            ClipLink("A link", size: .small,
                     forcedState: componentBridge.forced(for: "link"), theme: t) {}
            Spacer()
        }
    }

    private func componentStateRow<V: View>(
        _ t: AppTheme, name: String, @ViewBuilder swatch: @escaping (ClipButtonForcedState?) -> V
    ) -> some View {
        HStack(spacing: Spacing.related) {
            ForEach(M11PreviewState.allCases, id: \.self) { previewState in
                VStack(spacing: Spacing.inline) {
                    swatch(previewState.forced)
                    Text(previewState.rawValue)
                        .font(Typography.caption)
                        .foregroundStyle(t.tertiaryText(on: t.panelBackground))
                }
            }
        }
    }
}

/// The four states the component gallery shows side by side, in display
/// order - unchanged from M11.
enum M11PreviewState: String, CaseIterable {
    case idle, hover, pressed, focused

    var forced: ClipButtonForcedState? {
        switch self {
        case .idle:    return nil
        case .hover:   return .hover
        case .pressed: return .pressed
        case .focused: return .focused
        }
    }
}

/// Forces ONE named component into a visual state on command, for
/// `QABridge`'s `m11_renderComponent` - unchanged from M11 beyond moving file.
@MainActor
final class M11ComponentTestBridge: ObservableObject {
    static let shared = M11ComponentTestBridge()
    @Published private var forcedByName: [String: ClipButtonForcedState?] = [:]
    private init() {}

    func forced(for name: String) -> ClipButtonForcedState? {
        forcedByName[name].flatMap { $0 }
    }
    func setForced(name: String, state: String) {
        forcedByName[name] = ClipButtonForcedState(rawValue: state)
    }
    func clear() { forcedByName = [:] }
}

/// Brings the "Buttons and links" group into view before a probe snapshots
/// the live component row now living inside it (the user's own words:
/// "place the button preview where it's relevant ... not where it is now" -
/// moved out of the always-visible header into the group it demonstrates,
/// which is not always scrolled into view). `QABridge`'s `m11_renderComponent`
/// bumps this before every render; `ThemeBuilderView` answers by scrolling
/// its `ScrollViewReader` to `Self.buttonsGroupID`.
@MainActor
final class ComponentPreviewScrollBridge: ObservableObject {
    static let shared = ComponentPreviewScrollBridge()
    @Published var scrollRequested = 0
    private init() {}
    func requestScroll() { scrollRequested += 1 }
}

#if CLIP_TESTING
/// Registers the component gallery's own `NSView` so `QABridge`'s
/// `m9_snapshotMiniPreview`/`m11_renderComponent` can render exactly that
/// region to a PNG - the same `renderLayerToPNG` technique the old
/// mini-preview used, retargeted at the one thing M17 keeps live-rendered.
struct ComponentGalleryProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView()
        func tryRegister(_ attemptsLeft: Int) {
            if let contentView = probe.window?.contentView {
                MiniPreviewTestRegistry.shared.register(contentView)
            } else if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    tryRegister(attemptsLeft - 1)
                }
            }
        }
        DispatchQueue.main.async { tryRegister(10) }
        return probe
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
final class MiniPreviewTestRegistry {
    static let shared = MiniPreviewTestRegistry()
    private var view: NSView?
    func register(_ view: NSView) { self.view = view }
    func current() -> NSView? { view }
}

/// Changes the builder's own DRAFT theme directly, without reaching into the
/// view's private state - unchanged from M11/M9 beyond moving file.
@MainActor
final class ThemeDraftTestBridge: ObservableObject {
    static let shared = ThemeDraftTestBridge()
    @Published var accentToken = 0
    private(set) var pendingAccent = "#FF00AA"
    @Published var expandAssistantToken = 0
    @Published var buttonTokenChanged = 0
    private(set) var pendingButtonTokenKey = ""
    private(set) var pendingButtonTokenHex = ""
    private init() {}
    func setAccent(_ hex: String) {
        pendingAccent = hex
        accentToken += 1
    }
    func expandAssistant() { expandAssistantToken += 1 }
    func setButtonToken(_ key: String, _ hex: String) {
        pendingButtonTokenKey = key
        pendingButtonTokenHex = hex
        buttonTokenChanged += 1
    }
}
#endif
