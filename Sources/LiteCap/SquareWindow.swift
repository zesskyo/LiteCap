import AppKit
import SwiftUI

/// A borderless (square-cornered) window with LiteCap's own flat title bar.
/// macOS rounds the corners of every titled window, so we draw the title bar ourselves.
final class SquareWindow: NSWindow {
    /// What the close button and ⌘W do (default: hide the window).
    var onClose: (() -> Void)?
    /// Keeps a hosted view controller (e.g. a plugin editor) alive.
    var hostedController: NSViewController?
    private var restoreFrame: NSRect?

    static let titleBarHeight: CGFloat = 28

    init(title: String, content: NSView, size: NSSize, resizable: Bool = true) {
        var mask: NSWindow.StyleMask = [.borderless, .miniaturizable]
        if resizable { mask.insert(.resizable) }
        super.init(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height + Self.titleBarHeight),
                   styleMask: mask, backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false
        hasShadow = true
        backgroundColor = .windowBackgroundColor
        collectionBehavior.insert(.fullScreenPrimary)

        let bar = NSHostingView(rootView: SquareTitleBar(title: title, window: self, canZoom: resizable))
        let container = NSView()
        for view in [bar, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.titleBarHeight),
            content.topAnchor.constraint(equalTo: bar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        contentView = container
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // Borderless windows normally can't take keyboard focus.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Close button and ⌘W (a borderless window would otherwise just beep).
    override func performClose(_ sender: Any?) {
        if let onClose { onClose() } else { orderOut(nil) }
    }

    /// Double-click on the title bar: fill the screen, or go back.
    func toggleFill() {
        guard let screen = screen ?? NSScreen.main else { return }
        if let restore = restoreFrame {
            setFrame(restore, display: true, animate: true)
            restoreFrame = nil
        } else {
            restoreFrame = frame
            setFrame(screen.visibleFrame, display: true, animate: true)
        }
    }
}

/// Flat title bar: square close / minimize / full-screen buttons and a centered title.
private struct SquareTitleBar: View {
    let title: String
    weak var window: SquareWindow?
    let canZoom: Bool

    var body: some View {
        ZStack {
            WindowDragArea(window: window)
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .allowsHitTesting(false)
            HStack(spacing: 0) {
                barButton("xmark", help: "Close") { window?.performClose(nil) }
                barButton("minus", help: "Minimize") { window?.miniaturize(nil) }
                if canZoom {
                    barButton("arrow.up.left.and.arrow.down.right", help: "Full Screen") { window?.toggleFullScreen(nil) }
                }
                Spacer()
            }
        }
        .frame(height: SquareWindow.titleBarHeight)
        .background(Color.gray.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.gray.opacity(0.25)).frame(height: 1) }
    }

    private func barButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(TitleBarButtonStyle())
        .help(help)
    }
}

private struct TitleBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 34, height: SquareWindow.titleBarHeight)
            .background(configuration.isPressed ? Color.gray.opacity(0.35) : Color.clear)
            .contentShape(Rectangle())
    }
}

/// Drags the window; double-click fills the screen.
private struct WindowDragArea: NSViewRepresentable {
    weak var window: SquareWindow?

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window = window as? SquareWindow else { return }
            if event.clickCount == 2 { window.toggleFill() } else { window.performDrag(with: event) }
        }
    }
}

/// Owns LiteCap's main and Settings windows.
@MainActor
enum AppWindows {
    static var studio: Studio?
    static var updater: Updater?
    private static var main: SquareWindow?
    private static var settings: SquareWindow?

    static func showMain() {
        guard let studio else { return }
        if main == nil {
            let host = NSHostingView(rootView: MainView().environmentObject(studio))
            let window = SquareWindow(title: "LiteCap", content: host, size: NSSize(width: 1180, height: 820))
            window.contentMinSize = NSSize(width: 1040, height: 720 + SquareWindow.titleBarHeight)
            window.onClose = { NSApp.terminate(nil) } // like OBS: closing the main window quits
            if !window.setFrameUsingName("LiteCapMain") { window.center() }
            window.setFrameAutosaveName("LiteCapMain")
            main = window
        }
        main?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func showSettings() {
        guard let studio, let updater else { return }
        if settings == nil {
            let host = NSHostingView(rootView: SettingsView().environmentObject(studio).environmentObject(updater))
            let window = SquareWindow(title: "Settings", content: host, size: host.fittingSize, resizable: false)
            window.center()
            settings = window
        }
        settings?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
