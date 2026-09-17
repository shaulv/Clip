import SwiftUI

/// Menu-bar (agent) app: there is no main window.
///
/// The status item, the panel and the settings window are all built in AppKit
/// (`AppDelegate`, `PanelController`, `SettingsWindowController`). SwiftUI still
/// requires a Scene, so this is an empty `Settings` scene — using `MenuBarExtra`
/// here would put a second, duplicate icon in the menu bar.
@main
struct ClipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
