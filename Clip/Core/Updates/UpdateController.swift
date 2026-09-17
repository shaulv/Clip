import Foundation
import Sparkle

/// Clip's one entry point onto Sparkle - the only place `SPUStandardUpdaterController`
/// is constructed, and the only place `checkForUpdates()` is called from.
///
/// **Why this exists at all.** Before this file, Clip had no update mechanism
/// whatsoever: a user on 2.0 could never receive a fix, a feature or a
/// security patch short of downloading a new DMG by hand and dragging it over
/// the old install themselves - and most never would. That is the
/// highest-consequence structural gap the audit named, and it is what this
/// file, `docs/UPDATES.md`, `appcast.xml` and `release.sh` together close.
///
/// **Why `SPUStandardUpdaterController` and not the raw `SPUUpdater`.** The
/// standard controller supplies its own "Checking for updates…" /
/// "You're up to date" / "A new version is available" UI out of the box -
/// exactly the one window this app needs and none it would otherwise have
/// had to hand-build. Clip is `LSUIElement` (no Dock icon, no menu bar by
/// default beyond its own status item), so unlike a normal app there is no
/// existing "Check for Updates…" item in an App menu for Sparkle to attach
/// itself to automatically; this controller is driven by hand from the
/// status-bar menu and from Settings > General > Updates instead (see
/// `AppDelegate` and `SettingsView.swift`).
///
/// **Why `startingUpdater: false`.** The controller is created once, at
/// launch, but its automatic-check timer is not armed until
/// `activateAutomaticChecksIfNeeded()` runs - which reads
/// `SUEnableAutomaticChecks` out of `PreferencesModel` rather than trusting
/// Sparkle's own Info.plist-backed default, so a user who turns automatic
/// checks off in Settings sees that decision take effect immediately, not
/// after a relaunch.
@MainActor
final class UpdateController {
    static let shared = UpdateController()

    let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: false,
                                                    updaterDelegate: nil,
                                                    userDriverDelegate: nil)
    }

    /// Called once from `AppDelegate.applicationDidFinishLaunching`. Starting
    /// the updater is what makes `checkForUpdates()` and the automatic
    /// background check both possible - an unstarted `SPUUpdater` silently
    /// does nothing, which reads exactly like "the feature does not exist"
    /// from the outside and would have been a second version of the same bug
    /// this file exists to close.
    func start() {
        do {
            try controller.updater.start()
        } catch {
            // Not fatal: Clip still runs with no update checking, which is
            // the same as before this file existed. Logged so a silent
            // updater failure is at least visible in Activity Log, rather
            // than looking indistinguishable from "no update is available".
            Database.shared.log("updates", "Sparkle failed to start: \(error.localizedDescription)")
        }
    }

    /// The one call a user-initiated "Check for Updates…" makes, from either
    /// the status-bar menu or Settings. Sparkle owns the whole UI for this -
    /// progress, "you're up to date", the download-and-relaunch flow - so
    /// there is nothing else for this method to do.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// Mirrors `PreferencesModel.checkForUpdatesAutomatically` onto Sparkle's
    /// own flag. Read on launch and whenever the Settings toggle changes,
    /// rather than left to Sparkle's Info.plist default, so the user's choice
    /// takes effect without a relaunch.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// nil until the first successful check this launch.
    var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }
}
