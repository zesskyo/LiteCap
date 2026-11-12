import AppKit
import AVFoundation
import CoreVideo
import ScreenCaptureKit
import WebKit

/// A running video source. The compositor pulls `latestFrame()` every tick.
class VideoSource: NSObject, @unchecked Sendable {
    private(set) var config: VideoSourceConfig
    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    private var frameHolder: AnyObject?
    private var _status = ""
    let canvasFPS: Int
    /// Captures are never made larger than this (the canvas), which saves a lot of GPU work.
    let canvasSize: CGSize

    /// Called (any thread) once the source's pixel size is known or changes.
    var onSize: ((CGSize) -> Void)?
    private var lastSize: CGSize = .zero

    init(config: VideoSourceConfig, fps: Int, canvas: CGSize) {
        self.config = config
        self.canvasFPS = fps
        self.canvasSize = canvas
    }

    var id: UUID { config.id }

    func latestFrame() -> CVPixelBuffer? { lock.withLock { frame } }
    var hasFrame: Bool { lock.withLock { frame != nil } }
    var status: String { lock.withLock { _status } }

    func setStatus(_ text: String) { lock.withLock { _status = text } }

    /// `holder` keeps the buffer's owner (e.g. an SCK sample buffer) alive.
    func publish(_ buffer: CVPixelBuffer, holder: AnyObject? = nil) {
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let changed: Bool = lock.withLock {
            frame = buffer
            frameHolder = holder
            _status = ""
            let c = size != lastSize
            lastSize = size
            return c
        }
        if changed { onSize?(size) }
    }

    func clearFrame() { lock.withLock { frame = nil; frameHolder = nil } }

    // Overridden by subclasses.
    func start() {}
    func stop() {}

    func replaceConfig(_ newConfig: VideoSourceConfig) { config = newConfig }

    /// Applies new settings. Default: restart if anything changed.
    func apply(_ newConfig: VideoSourceConfig) {
        guard newConfig != config else { return }
        let kindChanged = newConfig.kind != config.kind || newConfig.showCursor != config.showCursor
            || newConfig.hideSystemUI != config.hideSystemUI
        config = newConfig
        if kindChanged {
            stop()
            start()
        }
    }

    static func make(_ config: VideoSourceConfig, fps: Int, canvas: CGSize) -> VideoSource {
        switch config.kind {
        case .display, .window: return ScreenSource(config: config, fps: fps, canvas: canvas)
        case .camera: return CameraSource(config: config, fps: fps, canvas: canvas)
        case .image: return ImageSource(config: config, fps: fps, canvas: canvas)
        case .browser: return BrowserSource(config: config, fps: fps, canvas: canvas)
        }
    }
}

// MARK: - Display / window capture

final class ScreenSource: VideoSource, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "litecap.source.screen", qos: .userInteractive)
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var running = false
    private var generation = 0
    private var watchdog: DispatchSourceTimer?
    private var lastCallback = CFAbsoluteTimeGetCurrent()
    private var stallTimeout = 5.0
    private(set) var recoveries = 0

    override func start() {
        let gen: Int = stateLock.withLock {
            running = true
            generation += 1
            return generation
        }
        Task { await self.open(generation: gen) }
    }

    override func stop() {
        let old: SCStream? = stateLock.withLock {
            running = false
            generation += 1
            let s = stream
            stream = nil
            return s
        }
        queue.async { [self] in
            watchdog?.cancel()
            watchdog = nil
        }
        clearFrame()
        if let old { Task { try? await old.stopCapture() } }
    }

    private func open(generation gen: Int) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let filter = makeFilter(content) else {
                setStatus(config.kind.typeName == "Window Capture" ? "Window not found — pick it again" : "Display not found")
                return
            }
            let scale = CGFloat(filter.pointPixelScale)
            var width = filter.contentRect.width * scale
            var height = filter.contentRect.height * scale
            // Capture no bigger than the canvas needs: e.g. a 3024×1964 Retina screen on a
            // 1080p canvas is captured at 1662×1080. ScreenCaptureKit scales in hardware.
            let fit = min(1, canvasSize.width / max(1, width), canvasSize.height / max(1, height))
            width *= fit
            height *= fit
            let sc = SCStreamConfiguration()
            sc.width = max(2, Int(width) & ~1)
            sc.height = max(2, Int(height) & ~1)
            sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(canvasFPS))
            sc.pixelFormat = kCVPixelFormatType_32BGRA
            sc.colorSpaceName = CGColorSpace.sRGB
            sc.queueDepth = 5
            sc.showsCursor = config.showCursor
            sc.ignoreShadowsSingleWindow = true
            sc.capturesAudio = false

            let newStream = SCStream(filter: filter, configuration: sc, delegate: self)
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await newStream.startCapture()
            let keep: Bool = stateLock.withLock {
                guard running, generation == gen else { return false }
                stream = newStream
                return true
            }
            guard keep else {
                try? await newStream.stopCapture()
                return
            }
            queue.async { [self] in
                lastCallback = CFAbsoluteTimeGetCurrent()
                startWatchdog()
            }
        } catch {
            setStatus("Capture failed: \(error.localizedDescription)")
        }
    }

    private func makeFilter(_ content: SCShareableContent) -> SCContentFilter? {
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        switch config.kind {
        case .display(let id):
            let display = content.displays.first { $0.displayID == id }
                ?? content.displays.first { $0.displayID == CGMainDisplayID() }
                ?? content.displays.first
            guard let display else { return nil }
            if config.hideSystemUI == true {
                // Leave out LiteCap's windows plus the Dock (window level 20), menu bar (24) and
                // menu bar items (25). Excluding whole apps would also remove the wallpaper.
                let hidden = content.windows.filter { window in
                    window.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
                        || [20, 24, 25].contains(window.windowLayer)
                }
                return SCContentFilter(display: display, excludingWindows: hidden)
            }
            // Exclude LiteCap's own windows so the preview doesn't capture itself.
            return SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        case .window(let id, let bundleID, let title):
            let candidates = content.windows.filter { $0.windowLayer == 0 }
            let window = candidates.first { $0.windowID == id }
                ?? candidates.first { $0.owningApplication?.bundleIdentifier == bundleID && $0.title == title }
                ?? candidates.first { $0.owningApplication?.bundleIdentifier == bundleID && $0.isOnScreen }
            guard let window else { return nil }
            return SCContentFilter(desktopIndependentWindow: window)
        default:
            return nil
        }
    }

    // Freeze watchdog: if macOS stops sending callbacks, rebuild the stream.
    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if CFAbsoluteTimeGetCurrent() - self.lastCallback > self.stallTimeout {
                self.lastCallback = CFAbsoluteTimeGetCurrent()
                self.stallTimeout = min(self.stallTimeout * 2, 60)
                self.recover()
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func recover() {
        let old: SCStream? = stateLock.withLock {
            guard running else { return nil }
            recoveries += 1
            generation += 1
            let s = stream
            stream = nil
            return s
        }
        guard let old else { return }
        let gen = stateLock.withLock { generation }
        Task {
            try? await old.stopCapture()
            await self.open(generation: gen)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        lastCallback = CFAbsoluteTimeGetCurrent()
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            SCFrameStatus(rawValue: raw) == .complete,
            let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        if stallTimeout != 5 { stallTimeout = 5 }
        publish(pixelBuffer, holder: sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let current = stateLock.withLock { self.stream === stream }
        guard current else { return }
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userStopped.rawValue {
            setStatus("Stopped from the macOS menu bar")
            return
        }
        recover()
    }
}

// MARK: - Camera / capture card

final class CameraSource: VideoSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "litecap.source.camera", qos: .userInteractive)

    override func start() {
        guard case .camera(let deviceID) = config.kind else { return }
        queue.async { [self] in
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .video) { ok in granted = ok; semaphore.signal() }
            semaphore.wait()
            guard granted else { setStatus("Camera permission denied (System Settings → Privacy → Camera)"); return }
            let device = AVCaptureDevice(uniqueID: deviceID) ?? AVCaptureDevice.default(for: .video)
            guard let device, let input = try? AVCaptureDeviceInput(device: device) else {
                setStatus("Camera not found")
                return
            }
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            session.sessionPreset = .high
            if session.canAddInput(input) { session.addInput(input) }
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            session.startRunning()
        }
    }

    override func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
        clearFrame()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let pixelBuffer = sampleBuffer.imageBuffer { publish(pixelBuffer, holder: sampleBuffer) }
    }
}

// MARK: - Image

final class ImageSource: VideoSource {
    override func start() {
        guard case .image(let path) = config.kind else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard let image = NSImage(contentsOfFile: path),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let buffer = PixelBuffers.make(width: cg.width, height: cg.height) else {
                setStatus("Couldn't open image")
                return
            }
            PixelBuffers.draw(cg, into: buffer)
            publish(buffer)
        }
    }

    override func stop() { clearFrame() }
}

enum PixelBuffers {
    static func attributes(width: Int, height: Int) -> [CFString: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
    }

    static func make(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            attributes(width: width, height: height) as CFDictionary, &buffer)
        return buffer
    }

    static func makePool(width: Int, height: Int, minimum: Int = 4) -> CVPixelBufferPool? {
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: minimum] as CFDictionary,
                                attributes(width: width, height: height) as CFDictionary, &pool)
        return pool
    }

    /// Draws an image (premultiplied alpha) filling the whole buffer.
    static func draw(_ image: CGImage, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

// MARK: - Browser

/// Borderless off-screen window that can still take keyboard focus.
private final class OffscreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Renders a web page (alerts, chat, overlays) with a transparent background.
final class BrowserSource: VideoSource, WKNavigationDelegate, NSWindowDelegate {
    private var hostWindow: NSWindow?
    private var interactWindow: NSWindow?
    private var webView: WKWebView?
    private var timer: Timer?
    private var snapshotting = false
    private var pool: CVPixelBufferPool?
    private var loadedURL = ""
    private var loadedCSS = ""

    override func start() {
        DispatchQueue.main.async { self.setUp() }
    }

    override func stop() {
        DispatchQueue.main.async {
            self.timer?.invalidate()
            self.timer = nil
            self.webView?.stopLoading()
            self.interactWindow?.close()
            self.hostWindow?.orderOut(nil)
            self.webView = nil
            self.hostWindow = nil
            self.clearFrame()
        }
    }

    override func apply(_ newConfig: VideoSourceConfig) {
        guard newConfig != config else { return }
        let needsRestart = newConfig.kind != config.kind
        replaceConfig(newConfig)
        if needsRestart {
            stop()
            start()
        }
    }

    func reload() {
        DispatchQueue.main.async { self.webView?.reloadFromOrigin() }
    }

    /// Shows the page in a normal window so you can log in / click things.
    func interact() {
        DispatchQueue.main.async {
            guard let webView = self.webView, self.interactWindow == nil,
                  case .browser(_, let w, let h, _, _) = self.config.kind else { return }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "\(self.config.name) — close this window when done"
            window.isReleasedWhenClosed = false
            window.delegate = self
            webView.removeFromSuperview()
            window.contentView = webView
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            self.interactWindow = window
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let webView, let host = hostWindow, case .browser(_, let w, let h, _, _) = config.kind else { return }
        webView.removeFromSuperview()
        webView.frame = NSRect(x: 0, y: 0, width: w, height: h)
        host.contentView = webView
        interactWindow = nil
    }

    private func setUp() {
        guard case .browser(let url, let width, let height, let css, let fps) = config.kind else { return }
        let configuration = WKWebViewConfiguration()
        // Keep animations/timers running even though the page isn't visible.
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.mediaTypesRequiringUserActionForPlayback = []
        if !css.isEmpty {
            let escaped = css.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`")
            let js = "var s=document.createElement('style');s.innerHTML=`\(escaped)`;document.documentElement.appendChild(s);"
            configuration.userContentController.addUserScript(
                WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = self

        let window = OffscreenWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: height),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.contentView = webView
        window.orderFrontRegardless()

        self.webView = webView
        self.hostWindow = window
        pool = PixelBuffers.makePool(width: width, height: height)
        loadedURL = url
        loadedCSS = css
        if let u = Self.url(from: url) { webView.load(URLRequest(url: u)) } else { setStatus("Invalid URL") }

        let interval = 1.0 / Double(max(1, min(fps, 60)))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.snapshot()
        }
    }

    private static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed) }
        if trimmed.contains("://") { return URL(string: trimmed) }
        return URL(string: "https://" + trimmed)
    }

    private func snapshot() {
        guard !snapshotting, let webView, let window = hostWindow, let pool,
              case .browser(_, let width, let height, _, _) = config.kind else { return }
        snapshotting = true
        let snap = WKSnapshotConfiguration()
        // Snapshot width is in points; ask for exactly `width` pixels.
        snap.snapshotWidth = NSNumber(value: Double(width) / Double(window.backingScaleFactor))
        webView.takeSnapshot(with: snap) { [weak self] image, _ in
            guard let self else { return }
            self.snapshotting = false
            guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer, CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else { return }
            PixelBuffers.draw(cg, into: buffer)
            self.publish(buffer)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        setStatus("Page failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        setStatus("Page failed: \(error.localizedDescription)")
    }
}
