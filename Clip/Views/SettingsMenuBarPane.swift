import SwiftUI
import AppKit

/// How Clip presents itself outside its own window: the menu-bar glyph, the
/// Dock, and the confirmation that appears beside the icon after a copy.
///
/// These lived in General, which had grown into eight unrelated sections. A
/// pane called General is a bin, not a category, and "where does Clip appear on
/// my screen" is a question with its own answer.
/// Menu Bar's own sub-pages (user, 03/09 evening: "split all menu bar
/// settings to tabs inside the menu bar main tab so it will be more divided
/// and ordered and easy to read"). One page per question: what the icon
/// looks like, what happens after a copy, what to do when the bar is
/// crowded, and where the panel itself opens.
enum MenuBarPage: String, CaseIterable, Identifiable, SettingsSubpageID {
    case icon, copyConfirmation, crowded, panel
    var id: String { rawValue }
    var title: String {
        switch self {
        case .icon:             return "Icon and Dock"
        case .copyConfirmation: return "Copy confirmation"
        case .crowded:          return "Crowded menu bar"
        case .panel:            return "Panel position"
        }
    }
    var symbol: String {
        switch self {
        case .icon:             return "menubar.rectangle"
        case .copyConfirmation: return "text.bubble"
        case .crowded:          return "rectangle.compress.vertical"
        case .panel:            return "macwindow"
        }
    }
}

struct MenuBarPane: View {
    @ObservedObject private var prefs = PreferencesModel.shared

    /// Glyphs that read well as a template image at menu-bar size.
    private static let iconChoices = [
        // Clip's own mark first. Everything after it is a system symbol.
        AppDelegate.markIconName,
        "square.on.square", "doc.on.clipboard", "list.clipboard", "paperclip",
        "tray.full", "square.stack.3d.up", "rectangle.portrait.on.rectangle.portrait",
        "scissors", "bookmark", "sparkles", "square.grid.2x2", "text.alignleft",
        "arrow.down.doc", "clipboard", "archivebox", "pin"
    ]

    @EnvironmentObject var router: SettingsRouter

    var body: some View {
        switch router.page(for: .menuBar).flatMap(MenuBarPage.init(rawValue:)) {
        case nil:               hub
        case .icon:             iconSubpage
        case .copyConfirmation: copyConfirmationSubpage
        case .crowded:          crowdedSubpage
        case .panel:            panelSubpage
        }
    }

    // MARK: - Hub

    private var hub: some View {
        SettingsHub(icon: "menubar.rectangle", title: "Menu Bar",
                    purpose: "How Clip shows itself outside its own window: the icon, the copy confirmation, and where the panel opens.",
                    groups: [
            SettingsHubGroup(id: "menuBar", rows: MenuBarPage.allCases.map { page in
                .init(id: page.rawValue, symbol: page.symbol, title: page.title, summary: summary(for: page))
            })
        ], onSelectRow: { id in router.openSubpage(id, in: .menuBar) })
    }

    /// One line of current state per row, so the hub answers "how is it set"
    /// without opening the page.
    private func summary(for page: MenuBarPage) -> String {
        switch page {
        case .icon:
            let icon = prefs.statusIcon == AppDelegate.markIconName ? "Clip mark" : prefs.statusIcon
            return icon + (prefs.showInDock ? ", also in the Dock" : ", menu bar only")
        case .copyConfirmation:
            var parts = [prefs.showCopyConfirmation ? "preview for \(prefs.copyConfirmationSeconds) s" : "no preview"]
            parts.append(prefs.animateStatusItemOnCopy ? "icon pulses" : "no pulse")
            return parts.joined(separator: ", ")
        case .crowded:
            return prefs.keepStatusItemVisible ? "preview hides while crowded" : "preview always shown"
        case .panel:
            return prefs.panelPlacement.title + (prefs.showFooter ? ", hint footer on" : ", hint footer off")
        }
    }

    private func subpage<Content: View>(_ page: MenuBarPage, @ViewBuilder content: @escaping () -> Content) -> some View {
        SettingsSubpage(tab: .menuBar, title: page.title, router: router) {
            Form { content() }.formStyle(.grouped)
        }
    }

    // MARK: - Icon and Dock

    private var iconSubpage: some View {
        subpage(.icon) {
            ExplainedSection("Menu bar and Dock", note: """
                Clip lives in the menu bar. If yours is crowded, you can put it in the Dock as well.
                """) {
                iconPicker
                Toggle("Also show Clip in the Dock", isOn: $prefs.showInDock)
            }
        }
    }

    // MARK: - Copy confirmation

    private var copyConfirmationSubpage: some View {
        subpage(.copyConfirmation) {
            ExplainedSection("Copy confirmation", note: """
                After you copy, Clip briefly shows the start of what it captured next to the menu-bar icon, so you get confirmation without opening anything.
                """) {
                // Named for what it shows. "Show what was copied in the menu
                // bar" described the mechanism; people looking for a copy
                // preview setting did not recognise it as one.
                Toggle("Show a preview of what was copied", isOn: $prefs.showCopyConfirmation)
                Stepper(value: $prefs.copyConfirmationSeconds, in: 1...10) {
                    Text("Show the preview for \(prefs.copyConfirmationSeconds) seconds")
                }
                .disabled(!prefs.showCopyConfirmation)

                Toggle("Pulse the icon when something is copied",
                       isOn: $prefs.animateStatusItemOnCopy)
                Text("""
                    Independent of the preview on purpose: the pulse is what tells you \
                    a copy landed when there is no room for words, so turning the \
                    preview off is a reason to want this rather than to lose it.
                    """)
                    .font(.caption).foregroundStyle(SettingsPalette.note)
            }
        }
    }

    // MARK: - Crowded menu bar

    private var crowdedSubpage: some View {
        subpage(.crowded) {
            ExplainedSection("When the menu bar is crowded", note: """
                Apps with long menus (Figma, Xcode, Word) cover the icons to their \
                right, and the copy preview makes Clip a wide target.

                With this on, Clip drops the preview until there is room again. The \
                pulse still tells you a copy landed.

                Clip cannot move itself in the menu bar; macOS gives no app that. \
                Drag it where you want it and it stays.
                """) {
                Toggle("Hide the preview while the icon is crowded",
                       isOn: $prefs.keepStatusItemVisible)
                if !prefs.keepStatusItemVisible {
                    Text("The preview will always be shown, even when that pushes the icon under another app's menus.")
                        .font(.caption).foregroundStyle(SettingsPalette.note)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label("""
                    To move Clip for good: hold Command and drag the icon along the \
                    menu bar, towards the clock. macOS remembers where you put it.
                    """, systemImage: "hand.draw")
                    .font(.caption).foregroundStyle(SettingsPalette.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Panel position

    private var panelSubpage: some View {
        subpage(.panel) {
            ExplainedSection("Where the panel opens", note: """
                Drag any of the four corners to move the panel. The middle is for \
                dragging cards, so it cannot move the window too.
                """) {
                Picker("Position", selection: Binding(
                    get: { prefs.panelPlacement },
                    set: { prefs.panelPlacement = $0 }
                )) {
                    ForEach(PanelPlacement.allCases) { placement in
                        Text(placement.title).tag(placement)
                    }
                }
                .settingsFieldHover(cornerRadius: 6)
                Text(prefs.panelPlacement.detail)
                    .font(.caption).foregroundStyle(SettingsPalette.note)
                    .fixedSize(horizontal: false, vertical: true)

                if prefs.panelPlacement == .remembered {
                    LabeledContent("Fixed at") {
                        Text(prefs.rememberedPanelOrigin.map {
                            "x \(Int($0.x)), y \(Int($0.y))"
                        } ?? "nowhere yet, drag a corner")
                            .foregroundStyle(SettingsPalette.note)
                    }
                    // Both directions, because the two ways of saying "here"
                    // are dragging the panel and pressing a button, and someone
                    // in Settings has the panel in front of them either way.
                    SecondaryButton("Use the Panel's Current Position",
                                    isDisabled: !PanelController.shared.isOpen) {
                        PanelController.shared.rememberCurrentPosition()
                    }
                    GhostButton("Forget It",
                                isDisabled: prefs.rememberedPanelOrigin == nil) {
                        prefs.rememberedPanelOrigin = nil
                        prefs.panelPlacement = .automatic
                    }
                }
            }

            ExplainedSection("In the panel", note: """
                The hint footer along the bottom of the panel lists the keys for
                whatever is selected.
                """) {
                Toggle("Show the keyboard hint footer", isOn: $prefs.showFooter)
            }
        }
    }

    private var iconPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Menu bar icon").font(.subheadline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 6), count: 8), spacing: 6) {
                ForEach(Self.iconChoices, id: \.self) { name in
                    let selected = prefs.statusIcon == name
                    Button {
                        prefs.statusIcon = name
                        AppDelegate.shared?.refreshStatusIcon()
                    } label: {
                        // The mark is asset art, not a system symbol, so it
                        // cannot be drawn with `Image(systemName:)` - that
                        // renders nothing at all for it.
                        Group {
                            if name == AppDelegate.markIconName {
                                Image("MenuBarIcon").renderingMode(.template)
                                    .resizable().scaledToFit()
                                    .frame(width: 15, height: 15)
                            } else {
                                Image(systemName: name).font(.system(size: 15))
                            }
                        }
                            .frame(width: 34, height: 30)
                            .background(selected ? Color.accentColor.opacity(0.22) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25),
                                              lineWidth: selected ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    // M8.4: `.plain`-styled grid button, no native chrome.
                    .settingsHover(cornerRadius: 7)
                    .help(name)
                }
            }
        }
    }
}
