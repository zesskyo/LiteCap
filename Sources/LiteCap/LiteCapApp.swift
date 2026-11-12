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
                // ⌘Z / ⇧⌘Z: undo scene and source edits (text fields keep their own text undo).
                CommandGroup(replacing: .undoRedo) {
                    Button("Undo") { UndoRouter.undo(delegate.studio) }.keyboardShortcut("z", modifiers: .command)
                    Button("Redo") { UndoRouter.redo(delegate.studio) }.keyboardShortcut("z", modifiers: [.command, .shift])
                }
            }
    }
}

/// Sends ⌘Z to the text field being edited, if any; otherwise to LiteCap's own undo.
@MainActor
enum UndoRouter {
    private static var textUndo: UndoManager? {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSText else { return nil }
        return responder.undoManager
    }

    static func undo(_ studio: Studio) {
        if let manager = textUndo, manager.canUndo { manager.undo() } else { studio.undo() }
    }

    static func redo(_ studio: Studio) {
        if let manager = textUndo, manager.canRedo { manager.redo() } else { studio.redo() }
    }
}
