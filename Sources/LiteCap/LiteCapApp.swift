import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let studio = Studio()
    lazy var updater = Updater(isLive: { [unowned self] in self.studio.isLive })

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

        MenuBarExtra {
            MenuContent().environmentObject(delegate.studio).environmentObject(delegate.updater)
        } label: {
            MenuBarIcon(studio: delegate.studio)
        }
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var studio: Studio
    var body: some View {
        Image(systemName: studio.isLive ? "record.circle.fill" : "record.circle")
    }
}

private struct MenuContent: View {
    @EnvironmentObject var studio: Studio
    @EnvironmentObject var updater: Updater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(studio.isStreaming ? "End Stream" : "Go Live") { studio.toggleStreaming() }
        Button(studio.isRecording ? "Stop Recording" : "Start Recording") { studio.toggleRecording() }
        Divider()
        Menu("Scene") {
            ForEach(studio.project.scenes) { scene in
                Button {
                    studio.project.currentSceneID = scene.id
                } label: {
                    if scene.id == studio.project.currentSceneID { Label(scene.name, systemImage: "checkmark") } else { Text(scene.name) }
                }
            }
        }
        Divider()
        Button("Open LiteCap") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Show Recordings") { studio.revealRecordings() }
        CheckForUpdatesButton(updater: updater)
        Divider()
        Button("Quit LiteCap") { NSApp.terminate(nil) }
    }
}
