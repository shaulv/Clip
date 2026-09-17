import SwiftUI
import AppKit
import Combine

/// Current theme plus the layout options that go with it.
@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var themeID: String {
        didSet {
            AppPaths.defaults.set(themeID, forKey: "themeID")
            // Choosing a theme is a claim, stamped now. Without it, a settings
            // document arriving from another Mac (or from this Mac's own older
            // row) could carry a newer stamp for `themeID` and quietly put the
            // old theme back - which reads as "I cannot switch themes", with
            // nothing on screen saying why.
            SettingsDocument.claimNow("themeID")
        }
    }
    @Published var density: GalleryDensity {
        didSet { AppPaths.defaults.set(density.rawValue, forKey: "density") }
    }
    /// Id of the tab the panel opens on (a `TabSpec.id`).
    @Published var initialTabID: String {
        didSet { AppPaths.defaults.set(initialTabID, forKey: "initialTabID") }
    }

    /// How the Settings window decides between a theme's light and dark form.
    ///
    /// Settings draws the chosen theme's surfaces (07/09), so its light or dark
    /// look is the THEME's, and until now that meant the OS decided it through
    /// `systemIsDark`. This lets Settings be pinned instead, without touching
    /// what the panel does: the panel keeps following the system, because a
    /// clipboard panel that appears over whatever app you are in should look
    /// like the rest of the desktop.
    ///
    /// Only a theme carrying BOTH forms can honour a pin. `Aurora` is dark and
    /// only dark; asking it to be light has nothing to resolve to. The control
    /// says so rather than sitting there doing nothing (see `SettingsThemePane`).
    enum SettingsAppearance: String, CaseIterable, Identifiable {
        case automatic, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .light:     return "Light"
            case .dark:      return "Dark"
            }
        }
        /// What `resolvedForSystem` should be told, given what the OS is doing.
        func isDark(whenSystemIsDark systemIsDark: Bool) -> Bool {
            switch self {
            case .automatic: return systemIsDark
            case .light:     return false
            case .dark:      return true
            }
        }
    }

    @Published var settingsAppearance: SettingsAppearance {
        didSet {
            AppPaths.defaults.set(settingsAppearance.rawValue, forKey: "settingsAppearance")
            // Stamped for the same reason `themeID` is: a settings document
            // from another Mac must not quietly put the old choice back.
            SettingsDocument.claimNow("settingsAppearance")
        }
    }

    /// The theme as the Settings window should draw it.
    ///
    /// The same theme the panel uses, resolved against `settingsAppearance`
    /// instead of the OS. Identical to `theme` while that is `.automatic`, and
    /// identical for any theme that pins one appearance.
    var settingsTheme: AppTheme {
        let base = AppTheme.theme(for: "clip")
        return base
            .resolvedForSystem(isDark: settingsAppearance.isDark(whenSystemIsDark: systemIsDark))
            .prepared()
    }

    /// True when `settingsAppearance` can actually change anything: the theme
    /// in force carries both a light and a dark form.
    var settingsAppearanceApplies: Bool {
        true
    }

    /// A theme being tried out, overriding the saved one everywhere.
    ///
    /// The builder previews against the *real* panel, so the override sits at the
    /// source every view already reads. Cancelling clears it and the saved theme
    /// comes straight back, because nothing was ever written.
    @Published var previewTheme: AppTheme?

    /// Whether the OS is currently in dark appearance.
    ///
    /// This is what makes a system-following theme actually follow the
    /// system: it is read once at launch and then kept live by observing
    /// `NSApp.effectiveAppearance` via KVO, so flipping the OS between light
    /// and dark WHILE THE PANEL IS OPEN changes `theme` on its own, the same
    /// turn the observation fires — nothing is read once and cached forever.
    @Published private(set) var systemIsDark: Bool
    private var appearanceObservation: NSKeyValueObservation?

    /// The theme in force, built once per change rather than once per read.
    ///
    /// This was `previewTheme ?? AppTheme.theme(for: themeID)`, evaluated on
    /// every access. For a custom theme that meant a store lookup and eleven
    /// hex strings parsed back into colors, every time any view asked what
    /// color anything was. On top of that sat the derived-color searches, which
    /// were measured at 1.5 ms per row. Both are now paid once, when the theme
    /// actually changes.
    ///
    /// `resolvedForSystem` is a no-op for every theme that pins one
    /// appearance — only a theme that carries both a light and a dark form
    /// (`followsSystemAppearance`) is affected, and it is resolved AFTER the
    /// preview override, so previewing a fixed-appearance custom theme in the
    /// builder is unaffected by the OS setting either way.
    var theme: AppTheme {
        if let cached = cachedTheme, cachedKey == themeCacheKey { return cached }
        let base = previewTheme ?? AppTheme.theme(for: themeID)
        let built = base.resolvedForSystem(isDark: systemIsDark).prepared()
        cachedTheme = built
        cachedKey = themeCacheKey
        return built
    }

    /// Everything that can change which theme is in force.
    ///
    /// `previewTheme` is compared by value, not by "is it nil": the theme
    /// builder mutates it on every slider drag while keeping the same id, and a
    /// key that only noticed nil-ness would freeze the live preview.
    private var themeCacheKey: ThemeKey {
        ThemeKey(id: themeID, preview: previewTheme, storeRevision: CustomThemeStore.shared.revision,
                 systemIsDark: systemIsDark)
    }

    private struct ThemeKey: Equatable {
        let id: String
        let preview: AppTheme?
        let storeRevision: Int
        let systemIsDark: Bool
    }

    private var cachedTheme: AppTheme?
    private var cachedKey: ThemeKey?

    /// Starts previewing, and opens the panel so the theme can be *used*.
    /// Drops a preview that outlived the thing previewing it.
    ///
    /// A preview overrides the chosen theme EVERYWHERE while it is set, so one
    /// left behind by a builder window that went away is indistinguishable from
    /// "the theme will not change": the id changes, the colours do not. Cheap
    /// to check, and it can only ever run when there is no builder open.
    func dropOrphanedPreview() {
        guard previewTheme != nil, !ThemeBuilderWindowController.shared.isOpen else { return }
        previewTheme = nil
        PanelController.shared.closePreview()
    }

    func beginPreview(_ custom: CustomTheme) {
        previewTheme = custom.appTheme
        PanelController.shared.openForPreview()
    }

    func updatePreview(_ custom: CustomTheme) {
        guard previewTheme != nil else { return }
        previewTheme = custom.appTheme
    }

    /// Ends the preview. `keep` carries the saved id when the user saved.
    func endPreview(keep id: String? = nil) {
        previewTheme = nil
        if let id { themeID = id }
        PanelController.shared.closePreview()
    }

    private init() {
        // "Clip" is the new default: it matches the Settings design (its dark
        // form is Graphite, byte-for-byte) and follows the OS on its own.
        // Only a NEW user gets it — this is the nil-coalescing fallback, read
        // exactly once, and it is never reached for anyone who already has a
        // `themeID` written to defaults. A deliberate choice, including one
        // that happens to equal the OLD default ("aurora"), is a real stored
        // string and is never overwritten by this line.
        themeID = AppPaths.defaults.string(forKey: "themeID") ?? "clip"
        density = AppPaths.defaults.string(forKey: "density")
            .flatMap(GalleryDensity.init(rawValue:)) ?? .comfortable
        initialTabID = AppPaths.defaults.string(forKey: "initialTabID") ?? "all"
        // Automatic by default, which is exactly what Settings did before this
        // choice existed, so an existing user sees no change until they ask
        // for one.
        settingsAppearance = AppPaths.defaults.string(forKey: "settingsAppearance")
            .flatMap(SettingsAppearance.init(rawValue:)) ?? .automatic
        systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        // Live, not once-at-launch: a system-following theme must repaint the
        // instant the OS switches, panel open or not. KVO rather than a
        // notification because `effectiveAppearance` has no dedicated
        // "changed" notification of its own — it IS key-value observable,
        // and NSApplication is the documented place to observe it.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] app, _ in
            let dark = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            Task { @MainActor in self?.systemIsDark = dark }
        }
    }

    #if CLIP_TESTING
    /// Stands in for a real OS appearance flip, which a headless test cannot
    /// trigger. Goes through the same published property the live KVO
    /// observer writes, so "the theme repaints" is exercised for real rather
    /// than restated.
    func forceSystemAppearanceForTesting(dark: Bool) { systemIsDark = dark }
    #endif
}

/// Persisted user preferences surfaced in Settings.
final class PreferencesModel: ObservableObject {
    static let shared = PreferencesModel()

    @AppStorage("globalShortcut", store: AppPaths.defaults) var globalShortcut: String = "Command+Shift+Space"
    @AppStorage("launchAtLogin", store: AppPaths.defaults) var launchAtLogin: Bool = false
    @AppStorage("showStatusItem", store: AppPaths.defaults) var showStatusItem: Bool = true
    @AppStorage("pasteAutomatically", store: AppPaths.defaults) var pasteAutomatically: Bool = true
    @AppStorage("numberShortcuts", store: AppPaths.defaults) var numberShortcuts: Bool = true
    @AppStorage("showFooter", store: AppPaths.defaults) var showFooter: Bool = true
    @AppStorage("historyLimit", store: AppPaths.defaults) var historyLimit: Int = 200
    /// Off by default: saving is unlimited unless the user asks for a cap.
    /// See `HistoryStore.migrateHistoryLimitPreference` for how an existing
    /// install keeps the cap it already chose.
    @AppStorage("historyLimitEnabled", store: AppPaths.defaults) var historyLimitEnabled: Bool = false
    @AppStorage("clearOnQuit", store: AppPaths.defaults) var clearOnQuit: Bool = false
    /// Sparkle's own automatic-check flag, mirrored here so Settings has
    /// something to bind a Toggle to without reaching into `UpdateController`
    /// directly - and so the choice persists the ordinary way, in
    /// `AppPaths.defaults`, alongside every other preference.
    @AppStorage("checkForUpdatesAutomatically", store: AppPaths.defaults) var checkForUpdatesAutomatically: Bool = true

    /// Poll cadence in milliseconds. Maccy defaults to 500ms; 350 feels snappier
    /// and still costs almost nothing.
    @AppStorage("pollIntervalMS", store: AppPaths.defaults) var pollIntervalMS: Int = 350
    /// Skip anything larger than this so a giant paste can't bloat history.
    @AppStorage("maxTextKB", store: AppPaths.defaults) var maxTextKB: Int = 512
    /// Honour password managers' "do not record" pasteboard flags.
    @AppStorage("respectConcealedTypes", store: AppPaths.defaults) var respectConcealedTypes: Bool = true
    /// Comma-separated bundle identifiers to never record from.
    @AppStorage("ignoredApps", store: AppPaths.defaults) var ignoredApps: String = ""
    /// SF Symbol shown in the menu bar.
    /// Defaults to Clip's own mark rather than a generic system symbol. An app
    /// with a trademark should wear it.
    @AppStorage("statusIcon", store: AppPaths.defaults) var statusIcon: String = "clip.mark"
    /// Off by default: this is a menu-bar app first.
    @AppStorage("showInDock", store: AppPaths.defaults) var showInDock: Bool = false
    /// Set once a provider is configured and validated.
    @AppStorage("aiEnabled", store: AppPaths.defaults) var aiEnabled: Bool = false
    /// Whether the "connect a model" invitation has been answered.
    ///
    /// Answered means either dismissed with the X or satisfied by turning AI
    /// on. Both are permanent: an invitation that returns is an advertisement,
    /// and the features it names are listed in Settings for anyone who wants
    /// them later.
    @AppStorage("aiPromoDismissed", store: AppPaths.defaults) var aiPromoDismissed: Bool = false
    /// Briefly show what was copied next to the menu-bar icon.
    @AppStorage("showCopyConfirmation", store: AppPaths.defaults) var showCopyConfirmation: Bool = true
    @AppStorage("copyConfirmationSeconds", store: AppPaths.defaults) var copyConfirmationSeconds: Int = 3

    /// Keep the menu-bar icon out from under another app's menus.
    ///
    /// On, Clip drops the copy preview while the icon is crowded and asks the
    /// system for a spot further right. Off, it stays exactly where you put it
    /// - which is the right answer for anyone who has arranged their menu bar
    /// deliberately and does not want an app rearranging itself.
    @AppStorage("keepStatusItemVisible", store: AppPaths.defaults) var keepStatusItemVisible: Bool = true

    /// Pulse the icon when something is copied.
    ///
    /// Independent of the preview text on purpose: the pulse is what tells you
    /// a copy landed when there is no room for words, so turning the preview
    /// off is a reason to want this, not a reason to lose it.
    @AppStorage("animateStatusItemOnCopy", store: AppPaths.defaults) var animateStatusItemOnCopy: Bool = true

    /// Where the user dragged the panel, as "x,y". Empty means "decide for me",
    /// which is centred on the hotkey and under the icon on a click.
    @AppStorage("panelOrigin", store: AppPaths.defaults) var panelOriginRaw: String = ""

    /// How the panel decides where to open. See `PanelPlacement`.
    ///
    /// Stored as a raw string rather than the enum so an unknown value written
    /// by a newer build degrades to `automatic` instead of failing to decode.
    @AppStorage("panelPlacement", store: AppPaths.defaults) var panelPlacementRaw: String = "automatic"

    var panelPlacement: PanelPlacement {
        get { PanelPlacement(rawValue: panelPlacementRaw) ?? .automatic }
        set { panelPlacementRaw = newValue.rawValue }
    }

    /// The remembered panel position, or nil when Clip should place it.
    var rememberedPanelOrigin: NSPoint? {
        get {
            let parts = panelOriginRaw.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { return nil }
            return NSPoint(x: parts[0], y: parts[1])
        }
        set {
            guard let newValue else { panelOriginRaw = ""; return }
            panelOriginRaw = "\(Int(newValue.x)),\(Int(newValue.y))"
        }
    }
    /// Recognise copied AI skill documents and file them as skills.

    /// Turns every AI surface in the app off.
    ///
    /// Off means *gone*, not greyed out: the Settings pane disappears from the
    /// sidebar and no AI action is offered anywhere. A feature you have decided
    /// not to use should stop taking up room, and a disabled control that never
    /// becomes enabled is just clutter that raises a question every time it is
    /// seen. The switch lives in General, which is where it can be found again.
    ///
    /// Deliberately NOT the `aiEnabled` key: that one is *derived* - AIService
    /// writes it to mean "a connection is configured". Sharing the key would have
    /// let the app overwrite the user's choice the moment a connection changed.
    @AppStorage("aiFeaturesEnabled", store: AppPaths.defaults) var aiFeaturesEnabled: Bool = true

    /// Read a copied link's page title from the page itself.
    ///
    /// This makes one small request to the site. That is worth stating plainly
    /// rather than burying: it tells that site you copied the link. Nothing else
    /// is sent, and the reply is read only for its title.
    @AppStorage("fetchLinkTitles", store: AppPaths.defaults) var fetchLinkTitles: Bool = true

    /// The first-run welcome has been shown or dismissed.
    ///
    /// Set the moment the welcome window actually renders (see
    /// `OnboardingView.onAppear`), not when the app decides to show it - a
    /// launch that crashes or is killed before the window ever draws must not
    /// burn the one showing this preference is supposed to guarantee. It also
    /// stays reachable on purpose: `OnboardingWindowController.shared.show()`
    /// can be called again from Settings > General for anyone who skipped it,
    /// which never touches this flag.
    @AppStorage("hasSeenOnboarding", store: AppPaths.defaults) var hasSeenOnboarding: Bool = false

    /// Re-reads every synced preference from `UserDefaults`.
    ///
    /// `@AppStorage` caches. Writing `UserDefaults` underneath it - which is
    /// exactly what applying a settings snapshot from another Mac does - leaves
    /// the running app reading its old value while the stored value is the new
    /// one. Measured: a snapshot restored `historyLimit` to 20 in
    /// `UserDefaults`, and the app went on using 321 until it was relaunched.
    /// So settings sync appeared to work, wrote the right thing to disk, and
    /// changed nothing you could see.
    ///
    /// Assigning through the wrapper refreshes its cache and publishes the
    /// change, so the running app picks the new values up immediately.
    @MainActor
    func reloadFromDefaults() {
        let defaults = AppPaths.defaults
        func string(_ key: String, _ fallback: String) -> String {
            defaults.object(forKey: key) as? String ?? fallback
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        func int(_ key: String, _ fallback: Int) -> Int {
            defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
        }
        globalShortcut = string("globalShortcut", "Command+Shift+Space")
        launchAtLogin = bool("launchAtLogin", false)
        showStatusItem = bool("showStatusItem", true)
        pasteAutomatically = bool("pasteAutomatically", true)
        numberShortcuts = bool("numberShortcuts", true)
        showFooter = bool("showFooter", true)
        historyLimit = int("historyLimit", 200)
        historyLimitEnabled = bool("historyLimitEnabled", false)
        clearOnQuit = bool("clearOnQuit", false)
        pollIntervalMS = int("pollIntervalMS", 350)
        maxTextKB = int("maxTextKB", 512)
        respectConcealedTypes = bool("respectConcealedTypes", true)
        ignoredApps = string("ignoredApps", "")
        statusIcon = string("statusIcon", "clip.mark")
        showInDock = bool("showInDock", false)
        showCopyConfirmation = bool("showCopyConfirmation", true)
        copyConfirmationSeconds = int("copyConfirmationSeconds", 3)
        aiFeaturesEnabled = bool("aiFeaturesEnabled", true)
        fetchLinkTitles = bool("fetchLinkTitles", true)
    }

    var ignoredAppList: Set<String> {
        Set(ignoredApps
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    init() {}
}
