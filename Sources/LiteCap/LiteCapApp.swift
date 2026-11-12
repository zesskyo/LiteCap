import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let studio = Studio()
    lazy var updater = Updater(isLive: { [unowned self] in self.studio.isLive })

    /// No menu bar icon, so closing the main window quits (like OBS); recordings still finish cleanly.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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

    var body: some Scene {
        Window("LiteCap", id: "main") {
            MainView().environmentObject(delegate.studio)
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesButton(updater: delegate.updater) }
        }

        Settings {
            SettingsView().environmentObject(delegate.studio).environmentObject(delegate.updater)
        }
    }
}
