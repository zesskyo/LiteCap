import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let studio = Studio()
    lazy var updater = Updater(isLive: { [unowned self] in self.studio.isLive })

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppWindows.studio = studio
        AppWindows.updater = updater
        AppWindows.showMain()
    }

    /// Clicking the Dock icon brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppWindows.showMain()
        return true
    }

    /// Finish the recording file / end the stream cleanly before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard studio.isLive else {
            studio.saveNow()
            return .terminateNow
        }
        studio.stopAll {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct LiteCapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // LiteCap makes its own square windows (see AppWindows); this scene only supplies menu commands.
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { AppWindows.showSettings() }.keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(after: .appInfo) { CheckForUpdatesButton(updater: delegate.updater) }
                CommandGroup(replacing: .newItem) {}
            }
    }
}
