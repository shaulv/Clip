import SwiftUI
import AppKit

/// The colors Settings paints text in, chosen by measurement.
///
/// Settings deliberately keeps native macOS chrome - a Settings window should
/// look like a Settings window, and native controls inherit Increase Contrast,
/// Reduce Transparency and VoiceOver behaviour that a repainted one would lose.
/// But the system's *text* colors are not a free pass. Measured against
/// `windowBackgroundColor`, compositing alpha rather than reading it raw:
///
/// | Color | Light | Dark |
/// |---|--:|--:|
/// | `.secondary` (every section note) | **3.95** | 5.89 |
/// | `.red` (errors, destructive) | **3.57** | 4.86 |
/// | `.green` (success) | **2.22** | 8.25 |
/// | `.orange` (warning) | **2.31** | 7.47 |
///
/// Four of those fail 4.5:1 in light appearance, and the notes are 11pt body
/// text, not large text. The roles below keep Apple's hues and are tuned to
/// clear 7:1 (AAA) in BOTH appearances; the probe computes the ratio rather
/// than trusting this comment.
enum SettingsPalette {
    /// The radius a row-sized hover wash uses. Named because it is a decision
    /// ("a row's wash is tighter than a card's"), and because a bare 6 in a
    /// token-audited file is a literal the gate rightly refuses.
    static var rowHoverRadius: CGFloat { 6 }


    // Apple's semantic roles (03/09 night: "create a color system of Apple
    // and make sure all is accessible ... AAA"). Each text role keeps the
    // hue and saturation of Apple's own system colour and moves lightness
    // until it clears 7:1 (WCAG AAA, body text) on both grounds Settings
    // paints on, in both appearances - measured in the running app by
    // `audit()` and gated by the probe, never assumed from this comment.

    /// `labelColor`: primary text. Apple's own value already clears 12:1.
    static let label = Color(nsColor: .labelColor)

    /// `secondaryLabelColor`'s role - section notes, hints, hub row
    /// summaries. Apple's value is 3.95:1 in light; this one is 7.3:1.
    static let note = adaptive(light: "#555555", dark: "#ACACAC")

    /// `linkColor`'s role - link-style buttons and the Settings tint.
    /// Apple's #0068DA is 5.6:1; this keeps the hue at 7.3:1.
    static let link = adaptive(light: "#0052AD", dark: "#66B0FF")

    /// `systemRed`'s role: something failed, or will destroy data.
    static let danger = adaptive(light: "#AE0004", dark: "#FF8A8C")

    /// `systemGreen`'s role: something worked.
    static let success = adaptive(light: "#1A6130", dark: "#34D25B")

    /// `systemOrange`'s role: needs attention, nothing broken.
    static let warning = adaptive(light: "#874000", dark: "#FF9536")

    /// `separatorColor`: hairlines. Not text, so not graded.
    static let separator = Color(nsColor: .separatorColor)

    /// Resolves per appearance at draw time, so a theme switch is picked up
    /// without the view having to observe anything.
    private static func adaptive(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance -> NSColor in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hexString: isDark ? dark : light)
        })
    }
}

extension NSColor {
    /// `#RRGGBB` to a color, for a palette written as hex.
    ///
    /// Named `hexString` rather than `hex`: the theme layer already defines an
    /// `init(hex:)` and a second one is a redeclaration, not an overload.
    convenience init(hexString: String) {
        var value: UInt64 = 0
        Scanner(string: hexString.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }
}

extension SettingsPalette {

    /// Every Settings text color measured against the grounds Settings
    /// actually paints on, in both appearances.
    ///
    /// `underPageBackgroundColor` is deliberately NOT a ground here. In light
    /// appearance it is a dark grey, so grading against it fails everything -
    /// and Settings never renders on it. A ratio is only meaningful on the
    /// color the thing is actually painted over.
    static func audit() -> [[String: Any]] {
        let tokens: [(String, String, String)] = [
            ("note", "#555555", "#ACACAC"),
            ("link", "#0052AD", "#66B0FF"),
            ("danger", "#AE0004", "#FF8A8C"),
            ("success", "#1A6130", "#34D25B"),
            ("warning", "#874000", "#FF9536")
        ]
        let grounds: [(String, NSColor)] = [("window", .windowBackgroundColor),
                                            ("control", .controlBackgroundColor)]
        var rows: [[String: Any]] = []
        for (mode, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                for (token, light, dark) in tokens {
                    let fg = NSColor(hexString: mode == "dark" ? dark : light)
                    for (groundName, ground) in grounds {
                        rows.append(["token": token, "mode": mode, "ground": groundName,
                                     "ratio": Self.ratio(fg, on: ground)])
                    }
                }
            }
        }
        return rows
    }

    /// The colors Settings USED to paint, measured in LIGHT appearance.
    ///
    /// Measured wherever the app happens to be running, this control passes -
    /// these colors are fine in dark. Light is where they fail, and a control
    /// taken in the appearance that passes proves nothing at all.
    static func systemControl() -> [String: Double] {
        var out: [String: Double] = [:]
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            out["secondary"] = ratio(.secondaryLabelColor, on: .windowBackgroundColor)
            out["green"] = ratio(.systemGreen, on: .windowBackgroundColor)
            out["red"] = ratio(.systemRed, on: .windowBackgroundColor)
            out["link"] = ratio(.linkColor, on: .windowBackgroundColor)
        }
        return out
    }

    /// The wash painted behind a Settings row or control while the pointer
    /// is over it (M8.4, 02/09).
    ///
    /// Not a new hue: a translucent `.primary`, so it reads correctly in
    /// both appearances the same way `.primary` itself does, and it never
    /// competes with a theme accent the way `Color.accentColor.opacity(_)`
    /// would have (ShortcutsPane's OWN "this row owns the clashing
    /// shortcut" flash already uses the accent color for that reason - a
    /// second, unrelated meaning painted in the same color would blur the
    /// two together).
    static let hover = Color.primary.opacity(0.07)

    /// WCAG 2.x relative-contrast, with the foreground composited over its
    /// ground first: a translucent color measured raw scores the ratio of a
    /// color nothing ever paints.
    static func ratio(_ foreground: NSColor, on ground: NSColor) -> Double {
        func channel(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        func luminance(_ color: NSColor) -> Double {
            guard let s = color.usingColorSpace(.sRGB) else { return 0 }
            return 0.2126 * channel(Double(s.redComponent))
                 + 0.7152 * channel(Double(s.greenComponent))
                 + 0.0722 * channel(Double(s.blueComponent))
        }
        guard let f = foreground.usingColorSpace(.sRGB),
              let b = ground.usingColorSpace(.sRGB) else { return 0 }
        let a = f.alphaComponent
        let composited = NSColor(srgbRed: f.redComponent * a + b.redComponent * (1 - a),
                                 green: f.greenComponent * a + b.greenComponent * (1 - a),
                                 blue: f.blueComponent * a + b.blueComponent * (1 - a),
                                 alpha: 1)
        let l1 = luminance(composited), l2 = luminance(b)
        return ((max(l1, l2) + 0.05) / (min(l1, l2) + 0.05) * 100).rounded() / 100
    }
}

/// The one hover treatment every custom-chrome Settings control uses
/// (M8.4, 02/09): `ThemeCard`, the sidebar's sync row, shortcut rows, the
/// ignored-apps list, the disclosure headers that toggle a group open with
/// a tap on the whole row rather than a 12pt chevron.
///
/// It is an `.overlay`, not a `.background` - several of the views this
/// wraps already paint their own opaque background (`ThemeCard`'s card
/// fill, a selected theme card's ring), and a hover wash added as a
/// `.background` would be drawn UNDER that and never seen. Painted on top
/// instead, with `allowsHitTesting(false)` so the wash itself never steals
/// a click or a drag meant for the content underneath it.
///
/// Deliberately NOT applied to a bare `Toggle("…", isOn:)`, a bare
/// `Picker("…", selection:) { … }`, a bare `Stepper(value:)`, or a
/// `Button("…") { }` styled `.automatic`/`.bordered`/`.borderedProminent`/
/// `.link` with a plain-text label and no surrounding composite row -
/// AppKit has drawn its own hover/press highlight on those standard
/// bezeled controls since Big Sur, and painting a second, differently
/// shaped wash behind an already-chromed control reads as two overlapping
/// effects fighting each other, not one. This exists for exactly the
/// controls and rows that opt OUT of that native chrome (`.buttonStyle(
/// .plain)`, a bare `.onTapGesture`, or a hand-built multi-element row),
/// which get nothing from AppKit otherwise. `run_m8_first_run_and_menu`'s
/// V6 gate greps every Settings pane for both categories and says, by
/// name, which allowlisted controls rely on that native chrome instead.
struct SettingsHoverModifier: ViewModifier {
    var cornerRadius: CGFloat = 8
    @State private var hovering = false
    /// Design rule (user, 03/09): a disabled control never draws hover.
    @Environment(\.isEnabled) private var isEnabled
    #if CLIP_TESTING
    @ObservedObject private var forced = SettingsHoverTestForce.shared
    #endif

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(effectiveHover ? SettingsPalette.hover : Color.clear)
                    .allowsHitTesting(false)
            )
            .onHover { hovering = $0 }
    }

    private var effectiveHover: Bool {
        guard isEnabled else { return false }
        #if CLIP_TESTING
        return hovering || forced.isForced
        #else
        return hovering
        #endif
    }
}

#if CLIP_TESTING
/// Forces every `.settingsHover()`-wrapped view in the process to show its
/// hover tint, regardless of the real pointer position - QABridge's
/// `m8b_forceSettingsHover` (M8.4, 02/09).
///
/// A real `.onHover` firing is AppKit's own mouse-tracking machinery, which
/// this suite has no reason to re-prove. What section 137's V6 rendered
/// check needs is narrower: when the hover state IS true, is the wash this
/// modifier paints actually a measurable pixel delta, or is it silently
/// invisible - hidden behind opaque content, zeroed out by a wrong opacity,
/// the kind of thing every assertion about a tooltip once missed because
/// nobody opened the picture (see `snapshotPanel`'s own doc comment).
/// Forcing the state directly, through a `@Published` flag every modifier
/// instance observes, proves that without needing a synthesized mouse
/// event to land on one specific row's real screen coordinates - which
/// would be a second, coordinate-dependent source of flakiness on top of
/// the one `can_post_hotkeys()` already exists to work around for keyboard
/// events.
@MainActor
final class SettingsHoverTestForce: ObservableObject {
    static let shared = SettingsHoverTestForce()
    @Published var isForced = false
    private init() {}
}
#endif

/// The row-wide version of `SettingsHoverModifier`: the same wash and the same
/// forced-on test hook, expanded past the row content to the row's own edges.
///
/// Two other mechanisms were tried and measured first. Clearing
/// `listRowInsets` left the trailing gutter untouched (29.5pt still bare), and
/// `listRowBackground` painted nothing at all inside `ExplainedSection`'s
/// Section. What works is the simplest thing: keep the overlay, and give it
/// negative padding equal to the gutters a grouped `Form` puts around every
/// row - measured from a real window capture, not guessed.
struct SettingsRowHoverModifier: ViewModifier {
    var cornerRadius: CGFloat = 6
    /// The grouped Form's own gutters, measured (`hover-measure.py`): the wash
    /// used to stop 11.5pt short on the left and 28.5pt short on the right.
    var leading: CGFloat = 16
    var trailing: CGFloat = 16
    var vertical: CGFloat = 5
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    #if CLIP_TESTING
    @ObservedObject private var forced = SettingsHoverTestForce.shared
    #endif

    func body(content: Content) -> some View {
        content
            // The row content stretches to the row first. An overlay cannot
            // paint outside the bounds the List clips it to, so widening the
            // wash alone hit a ceiling at 19.5pt short of the card - the row
            // itself has to be as wide as the row.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(lit ? SettingsPalette.hover : Color.clear)
                    .padding(.leading, -leading)
                    .padding(.trailing, -trailing)
                    .padding(.vertical, -vertical)
                    .allowsHitTesting(false)
            )
            .onHover { hovering = $0 }
    }

    private var lit: Bool {
        guard isEnabled else { return false }
        #if CLIP_TESTING
        return hovering || forced.isForced
        #else
        return hovering
        #endif
    }
}

/// The hover every Settings text field and menu picker wears (user, 03/09:
/// "the same hover effect like we have in the search"): a wash plus a
/// hairline stroke, drawn over the native bezel so the field reads as
/// something you can click, and never on a disabled control.
struct SettingsFieldHoverModifier: ViewModifier {
    var cornerRadius: CGFloat = 5
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    #if CLIP_TESTING
    @ObservedObject private var forced = SettingsHoverTestForce.shared
    #endif

    func body(content: Content) -> some View {
        content
            .multilineTextAlignment(.leading)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(lit ? SettingsPalette.hover : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(lit ? Color.primary.opacity(0.22) : Color.clear, lineWidth: 1)
                    )
                    .allowsHitTesting(false)
            )
            .onHover { hovering = $0 }
    }

    private var lit: Bool {
        guard isEnabled else { return false }
        #if CLIP_TESTING
        return hovering || forced.isForced
        #else
        return hovering
        #endif
    }

}

extension View {
    /// The shared field hover, for a `TextField`/`SecureField` (after its
    /// `.textFieldStyle(.roundedBorder)`) or a menu `Picker`.
    func settingsFieldHover(cornerRadius: CGFloat = 5) -> some View {
        modifier(SettingsFieldHoverModifier(cornerRadius: cornerRadius))
    }

    /// Applies the shared Settings hover treatment. `cornerRadius` should
    /// roughly match the shape of the row/card this sits behind - it is a
    /// wash, not a pixel-exact outline, so an approximate match is enough.
    func settingsHover(cornerRadius: CGFloat = 8) -> some View {
        modifier(SettingsHoverModifier(cornerRadius: cornerRadius))
    }

    /// The hover wash for a whole LIST ROW, covering the row rather than the
    /// content inside it.
    ///
    /// `settingsHover` draws its wash as an overlay on whatever it is attached
    /// to, so on a grouped `Form` it stopped at the row CONTENT: measured at
    /// 11.5pt short on the left and 28.5pt short on the right, and a different
    /// width on every row depending on how wide its own controls were (user,
    /// 06/09: "the hover should cover all the width and height"). Clearing
    /// `listRowInsets` did not fix the right-hand gutter - the Form re-applies
    /// it - so the wash is drawn as the row's BACKGROUND, which is the row's
    /// full rect by construction, insets included.
    ///
    /// `leading`/`trailing`/`vertical` default to the grouped Form's own
    /// gutters (see `SettingsRowHoverModifier`'s doc comment). A row that
    /// lives in a plain `.sidebar`-styled `List` instead - `SettingsShell`'s
    /// `syncRow`, the only caller outside a Form - has NO such gutter to
    /// compensate for: `.frame(maxWidth: .infinity, alignment: .leading)`
    /// already stretches the row to the List's own row slot, the same slot
    /// every native `Label(...).tag()` row in that List gets its selection
    /// highlight from. Stretching further with the Form's 16pt overshoots
    /// that slot on both sides (user, 06/09: measured 20px/10pt past the
    /// Themes selection highlight at 2x) - pass 0 there instead.
    func settingsRowHover(
        cornerRadius: CGFloat = 6,
        leading: CGFloat = 16,
        trailing: CGFloat = 16,
        vertical: CGFloat = 5
    ) -> some View {
        modifier(SettingsRowHoverModifier(
            cornerRadius: cornerRadius, leading: leading, trailing: trailing, vertical: vertical))
    }
}
