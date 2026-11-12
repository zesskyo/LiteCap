import AppKit
import AVFoundation
import Carbon.HIToolbox
import LiteCapCore
import ScreenCaptureKit

struct PickerItem: Identifiable, Hashable {
    let id: String
    let title: String
}

struct WindowItem: Identifiable, Hashable {
    let id: UInt32
    let title: String
    let bundleID: String
    let windowTitle: String
}

/// Audio meter values, kept apart from `Studio` so 20 Hz updates only redraw the meters.
@MainActor
final class MeterStore: ObservableObject {
    @Published var levels: [UUID: AudioEngine.Levels] = [:]
}

/// Once-a-second numbers for the status bar.
@MainActor
final class LiveStats: ObservableObject {
    @Published var fps = 0.0
    @Published var streamKbps = 0
    @Published var dropped = 0
    @Published var congested = false
    @Published var recordMB = 0.0
    @Published var sourceProblems: [String] = []
}

/// Routes canvas frames and track audio to whichever outputs are running (any thread).
final class OutputHub: @unchecked Sendable {
    private let lock = NSLock()
    private var recording: RecordingOutput?
    private var stream: StreamOutput?

    func set(recording: RecordingOutput?) { lock.withLock { self.recording = recording } }
    func set(stream: StreamOutput?) { lock.withLock { self.stream = stream } }
    var isEmpty: Bool { lock.withLock { recording == nil && stream == nil } }

    func video(_ buffer: CVPixelBuffer, _ pts: CMTime) {
        let (r, s) = lock.withLock { (recording, stream) }
        r?.appendVideo(buffer, pts: pts)
        s?.appendVideo(buffer, pts: pts)
    }

    func audio(_ track: Int, _ buffer: AVAudioPCMBuffer, _ when: AVAudioTime) {
        let (r, s) = lock.withLock { (recording, stream) }
        // Audio is ~20 ms behind real time after the capture FIFO; line it up with video.
        let pts = hostMicros(when) - 20_000
        r?.appendAudio(track: track, buffer, pts: pts)
        s?.appendAudio(track: track, buffer, pts: pts)
    }
}

@MainActor
final class Studio: ObservableObject {
    @Published var project: Project {
        didSet {
            // Ignore our own clean-up write below, or it would loop forever.
            guard !isNormalizing else { return }
            projectChanged(from: oldValue)
        }
    }
    @Published var selectedItemID: UUID?
    @Published var editingSourceID: UUID?
    @Published var filtersSourceID: UUID?
    @Published private(set) var isRecording = false
    @Published private(set) var isStreaming = false
    @Published private(set) var isBusy = false
    @Published private(set) var recordStarted: Date?
    @Published private(set) var streamStarted: Date?
    @Published private(set) var streamState: StreamOutput.State = .stopped
    @Published private(set) var lastRecording: URL?
    @Published var message = ""
    @Published var streamKey = Keychain.read("streamKey") { didSet { Keychain.write(streamKey, "streamKey") } }

    @Published private(set) var displays: [PickerItem] = []
    @Published private(set) var windows: [WindowItem] = []
    @Published private(set) var apps: [PickerItem] = []
    @Published private(set) var audioInputs: [PickerItem] = []
    @Published private(set) var cameras: [PickerItem] = []

    let meters = MeterStore()
    let stats = LiveStats()
    let compositor: Compositor
    let audio = AudioEngine()

    private let hub = OutputHub()
    private let audioConsumerID = UUID()
    private var sources: [UUID: VideoSource] = [:]
    private var sourceFPS = 0
    private var renderedSceneID: UUID?
    private var sceneSwitch: Task<Void, Never>?
    private var recording: RecordingOutput?
    private var stream: StreamOutput?
    private var previewClients = 0
    private var isNormalizing = false
    private(set) var isActive = false
    private var activity: NSObjectProtocol?
    private var saveWork: DispatchWorkItem?
    private var meterTimer: Timer?
    private var statsTimer: Timer?

    var isLive: Bool { isRecording || isStreaming }

    init() {
        guard let compositor = Compositor() else { fatalError("Metal is not available on this Mac.") }
        self.compositor = compositor
        project = Project.load()
        compositor.setFrameHandler { @Sendable [hub] buffer, pts in hub.video(buffer, pts) }
        audio.onMessage = { @Sendable [weak self] text in Task { @MainActor in self?.message = text } }
        audio.sync(project.audioSources)
        audio.setListenTrack(project.listenTrack)

        let mods = cmdKey | optionKey | controlKey
        HotKeys.shared.register(keyCode: kVK_ANSI_R, modifiers: mods) { [weak self] in
            Task { @MainActor in self?.toggleRecording() }
        }
        HotKeys.shared.register(keyCode: kVK_ANSI_S, modifiers: mods) { [weak self] in
            Task { @MainActor in self?.toggleStreaming() }
        }
        Task { await refreshPickers() }
    }

    // MARK: - Activity (nothing runs unless the preview is open or you're live)

    func previewAppeared() {
        previewClients += 1
        updateActive()
    }

    func previewDisappeared() {
        previewClients = max(0, previewClients - 1)
        updateActive()
    }

    private func updateActive() {
        let want = previewClients > 0 || isLive
        guard want != isActive else { return }
        isActive = want
        if want {
            compositor.configure(width: project.video.width, height: project.video.height, fps: project.video.fps)
            compositor.start()
            audio.start()
            renderedSceneID = nil
            syncVideo()
            startTimers()
        } else {
            sceneSwitch?.cancel()
            sources.values.forEach { $0.stop() }
            sources.removeAll()
            renderedSceneID = nil
            compositor.setLayers([])
            compositor.stop()
            audio.stop()
            stopTimers()
        }
    }

    private func updateLiveActivity() {
        if isLive, activity == nil {
            // Stops App Nap from throttling us and keeps the Mac awake while live.
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical], reason: "Recording / streaming"
            )
        } else if !isLive, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
        if hub.isEmpty { audio.removeConsumer(audioConsumerID) } else {
            audio.addConsumer(audioConsumerID) { @Sendable [hub] track, buffer, when in hub.audio(track, buffer, when) }
        }
    }

    private func startTimers() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                var levels: [UUID: AudioEngine.Levels] = [:]
                for source in self.project.audioSources { levels[source.id] = self.audio.levels(source.id) }
                self.meters.levels = levels
            }
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.updateStats() }
        }
    }

    private func stopTimers() {
        meterTimer?.invalidate()
        statsTimer?.invalidate()
        meterTimer = nil
        statsTimer = nil
        meters.levels = [:]
    }

    private func updateStats() async {
        stats.fps = compositor.fpsMeasured
        if let recording { stats.recordMB = Double(recording.bytesWritten) / 1_048_576 }
        if let stream {
            let s = await stream.stats()
            stats.streamKbps = s.kbps
            stats.dropped = s.dropped
            stats.congested = s.congested
        }
        var problems: [String] = []
        for source in sources.values where !source.status.isEmpty {
            problems.append("\(source.config.name): \(source.status)")
        }
        for source in project.audioSources {
            let status = audio.captureStatus(source.id)
            if !status.isEmpty { problems.append("\(source.name): \(status)") }
        }
        if stats.sourceProblems != problems { stats.sourceProblems = problems }
    }

    // MARK: - Project changes

    private func projectChanged(from old: Project) {
        // Keep typed-in values sane (encoders need even sizes) — written back once, only if needed.
        var fixed = project
        fixed.video.width = max(16, min(7680, fixed.video.width)) & ~1
        fixed.video.height = max(16, min(4320, fixed.video.height)) & ~1
        fixed.record.bitrateKbps = max(500, min(500_000, fixed.record.bitrateKbps))
        fixed.stream.bitrateKbps = max(300, min(100_000, fixed.stream.bitrateKbps))
        fixed.record.audioKbps = max(64, min(320, fixed.record.audioKbps))
        fixed.stream.audioKbps = max(64, min(320, fixed.stream.audioKbps))
        if fixed != project {
            isNormalizing = true
            project = fixed
            isNormalizing = false
        }
        scheduleSave()
        if old.audioSources != project.audioSources { audio.sync(project.audioSources) }
        if old.listenTrack != project.listenTrack { audio.setListenTrack(project.listenTrack) }
        if old.video != project.video, isActive {
            compositor.configure(width: project.video.width, height: project.video.height, fps: project.video.fps)
            if old.video.fps != project.video.fps {
                // Sources capture at the canvas frame rate: rebuild them.
                sources.values.forEach { $0.stop() }
                sources.removeAll()
                renderedSceneID = nil
            }
        }
        syncVideo()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func saveNow() {
        var copy = project
        let states = audio.filterStates()
        for i in copy.audioSources.indices {
            for j in copy.audioSources[i].filters.indices {
                if let data = states[copy.audioSources[i].id]?[copy.audioSources[i].filters[j].id] {
                    copy.audioSources[i].filters[j].state = data
                }
            }
        }
        copy.save()
    }

    // MARK: - Video sources & scenes

    private func syncVideo() {
        guard isActive else { return }
        let target = project.currentSceneID
        if renderedSceneID != target {
            switchScene(to: target)
            return
        }
        let needed = neededSources(for: target)
        for id in needed { _ = ensureSource(id) }
        for (id, source) in sources where !needed.contains(id) {
            source.stop()
            sources[id] = nil
        }
        updateLayers()
    }

    private func neededSources(for sceneID: UUID) -> Set<UUID> {
        Set(project.scenes.first { $0.id == sceneID }?.items.map(\.sourceID) ?? [])
    }

    private func ensureSource(_ id: UUID) -> VideoSource? {
        guard let config = project.videoSource(id) else { return nil }
        if let existing = sources[id] {
            existing.apply(config)
            return existing
        }
        let source = VideoSource.make(config, fps: project.video.fps)
        source.onSize = { @Sendable [weak self] size in
            Task { @MainActor in self?.sourceSized(id, size) }
        }
        sources[id] = source
        source.start()
        return source
    }

    /// Start the next scene's sources first and cut once they have pictures (≤ 0.7 s).
    private func switchScene(to sceneID: UUID) {
        sceneSwitch?.cancel()
        let incoming = neededSources(for: sceneID).compactMap { ensureSource($0) }
        if renderedSceneID == nil {
            finishSwitch(to: sceneID)
            return
        }
        sceneSwitch = Task { @MainActor in
            for _ in 0..<14 {
                if incoming.allSatisfy({ $0.hasFrame || !$0.status.isEmpty }) { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
                if Task.isCancelled { return }
            }
            finishSwitch(to: sceneID)
        }
    }

    private func finishSwitch(to sceneID: UUID) {
        renderedSceneID = sceneID
        let needed = neededSources(for: sceneID)
        for (id, source) in sources where !needed.contains(id) {
            source.stop()
            sources[id] = nil
        }
        updateLayers()
    }

    private func updateLayers() {
        guard let scene = project.scenes.first(where: { $0.id == renderedSceneID }) else {
            compositor.setLayers([])
            return
        }
        let layers = scene.items.compactMap { item -> Compositor.Layer? in
            guard item.visible, let frame = item.frame, let source = sources[item.sourceID] else { return nil }
            return Compositor.Layer(source: source, frame: frame, crop: item.crop)
        }
        compositor.setLayers(layers)
    }

    /// First time we learn a source's size: place it at native size, or fit it if it's bigger than the canvas.
    private func sourceSized(_ id: UUID, _ size: CGSize) {
        let canvasW = Double(project.video.width), canvasH = Double(project.video.height)
        for s in project.scenes.indices {
            for i in project.scenes[s].items.indices where project.scenes[s].items[i].sourceID == id
                && project.scenes[s].items[i].frame == nil {
                project.scenes[s].items[i].frame = Self.fit(size, canvasW, canvasH, stretch: false, onlyIfLarger: true)
            }
        }
    }

    static func fit(_ size: CGSize, _ W: Double, _ H: Double, stretch: Bool, onlyIfLarger: Bool = false) -> CanvasRect {
        if stretch { return CanvasRect(x: 0, y: 0, w: W, h: H) }
        var w = Double(size.width), h = Double(size.height)
        if !onlyIfLarger || w > W || h > H {
            let scale = min(W / max(1, w), H / max(1, h))
            w *= scale
            h *= scale
        }
        return CanvasRect(x: (W - w) / 2, y: (H - h) / 2, w: w, h: h)
    }

    func sourceSize(_ id: UUID) -> CGSize? {
        guard let frame = sources[id]?.latestFrame() else { return nil }
        return CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
    }

    func browserSource(_ id: UUID) -> BrowserSource? { sources[id] as? BrowserSource }

    // MARK: - Scene editing

    var currentSceneIndex: Int? { project.scenes.firstIndex { $0.id == project.currentSceneID } }

    func addScene() {
        let scene = StudioScene(name: "Scene \(project.scenes.count + 1)")
        project.scenes.append(scene)
        project.currentSceneID = scene.id
    }

    func duplicateScene(_ id: UUID) {
        guard let scene = project.scenes.first(where: { $0.id == id }) else { return }
        var copy = scene
        copy.id = UUID()
        copy.name = scene.name + " copy"
        copy.items = scene.items.map { var item = $0; item.id = UUID(); return item }
        project.scenes.append(copy)
        project.currentSceneID = copy.id
    }

    func removeScene(_ id: UUID) {
        guard project.scenes.count > 1, let index = project.scenes.firstIndex(where: { $0.id == id }) else { return }
        project.scenes.remove(at: index)
        if project.currentSceneID == id { project.currentSceneID = project.scenes[max(0, index - 1)].id }
        pruneUnusedSources()
    }

    func moveScene(_ id: UUID, by delta: Int) {
        guard let i = project.scenes.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard project.scenes.indices.contains(j) else { return }
        project.scenes.swapAt(i, j)
    }

    func addVideoSource(_ kind: VideoSourceKind, name: String? = nil) {
        guard let s = currentSceneIndex else { return }
        let base = name ?? kind.typeName
        let existing = Set(project.videoSources.map(\.name))
        var finalName = base
        var n = 2
        while existing.contains(finalName) { finalName = "\(base) \(n)"; n += 1 }
        let config = VideoSourceConfig(name: finalName, kind: kind)
        project.videoSources.append(config)
        let item = SceneItem(sourceID: config.id)
        project.scenes[s].items.append(item)
        selectedItemID = item.id
        editingSourceID = config.id
    }

    /// Adds an existing source (shared between scenes, like OBS's "Add Existing").
    func addExistingSource(_ id: UUID) {
        guard let s = currentSceneIndex else { return }
        let item = SceneItem(sourceID: id)
        project.scenes[s].items.append(item)
        selectedItemID = item.id
    }

    func removeItem(_ itemID: UUID) {
        guard let s = currentSceneIndex else { return }
        project.scenes[s].items.removeAll { $0.id == itemID }
        if selectedItemID == itemID { selectedItemID = nil }
        pruneUnusedSources()
    }

    private func pruneUnusedSources() {
        let used = Set(project.scenes.flatMap { $0.items.map(\.sourceID) })
        project.videoSources.removeAll { !used.contains($0.id) }
    }

    /// delta +1 = move up (towards the top of the stack).
    func moveItem(_ itemID: UUID, by delta: Int) {
        guard let s = currentSceneIndex, let i = project.scenes[s].items.firstIndex(where: { $0.id == itemID }) else { return }
        let j = i + delta
        guard project.scenes[s].items.indices.contains(j) else { return }
        project.scenes[s].items.swapAt(i, j)
    }

    func updateItem(_ itemID: UUID, _ change: (inout SceneItem) -> Void) {
        guard let s = currentSceneIndex, let i = project.scenes[s].items.firstIndex(where: { $0.id == itemID }) else { return }
        change(&project.scenes[s].items[i])
    }

    func item(_ itemID: UUID?) -> SceneItem? {
        guard let itemID, let scene = project.currentScene else { return nil }
        return scene.items.first { $0.id == itemID }
    }

    func transform(_ itemID: UUID, _ mode: TransformMode) {
        guard let item = item(itemID) else { return }
        let W = Double(project.video.width), H = Double(project.video.height)
        let raw = sourceSize(item.sourceID) ?? CGSize(width: item.frame?.w ?? W, height: item.frame?.h ?? H)
        let cropped = CGSize(width: raw.width - item.crop.left - item.crop.right,
                             height: raw.height - item.crop.top - item.crop.bottom)
        updateItem(itemID) { item in
            switch mode {
            case .fit: item.frame = Self.fit(cropped, W, H, stretch: false)
            case .stretch: item.frame = Self.fit(cropped, W, H, stretch: true)
            case .center:
                if var f = item.frame { f.x = (W - f.w) / 2; f.y = (H - f.h) / 2; item.frame = f }
            case .reset:
                item.crop = Crop()
                item.frame = CanvasRect(x: 0, y: 0, w: raw.width, h: raw.height)
            }
        }
    }

    enum TransformMode { case fit, stretch, center, reset }

    func updateVideoSource(_ id: UUID, _ change: (inout VideoSourceConfig) -> Void) {
        guard let i = project.videoSources.firstIndex(where: { $0.id == id }) else { return }
        change(&project.videoSources[i])
    }

    // MARK: - Audio editing

    func addAudioSource(_ kind: AudioSourceKind, name: String) {
        project.audioSources.append(AudioSourceConfig(name: name, kind: kind, tracks: [1, 2]))
    }

    func removeAudioSource(_ id: UUID) {
        project.audioSources.first { $0.id == id }?.filters.forEach { PluginWindows.close($0.id) }
        project.audioSources.removeAll { $0.id == id }
    }

    func updateAudioSource(_ id: UUID, _ change: (inout AudioSourceConfig) -> Void) {
        guard let i = project.audioSources.firstIndex(where: { $0.id == id }) else { return }
        change(&project.audioSources[i])
    }

    func addFilter(_ component: AVAudioUnitComponent, to sourceID: UUID) {
        let filter = AudioPlugins.config(for: component)
        updateAudioSource(sourceID) { $0.filters.append(filter) }
        // Open its editor once it has loaded.
        Task { @MainActor in
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if audio.unit(source: sourceID, filter: filter.id) != nil {
                    openFilterUI(sourceID: sourceID, filterID: filter.id)
                    return
                }
            }
        }
    }

    func openFilterUI(sourceID: UUID, filterID: UUID) {
        guard let unit = audio.unit(source: sourceID, filter: filterID),
              let source = project.audioSources.first(where: { $0.id == sourceID }),
              let filter = source.filters.first(where: { $0.id == filterID }) else {
            message = "That plugin is still loading or failed to load."
            return
        }
        PluginWindows.show(unit, id: filterID, title: "\(source.name) — \(filter.name)")
    }

    func removeFilter(_ filterID: UUID, from sourceID: UUID) {
        PluginWindows.close(filterID)
        updateAudioSource(sourceID) { $0.filters.removeAll { $0.id == filterID } }
    }

    func moveFilter(_ filterID: UUID, in sourceID: UUID, by delta: Int) {
        updateAudioSource(sourceID) { source in
            guard let i = source.filters.firstIndex(where: { $0.id == filterID }) else { return }
            let j = i + delta
            guard source.filters.indices.contains(j) else { return }
            source.filters.swapAt(i, j)
        }
    }

    // MARK: - Pickers

    func refreshPickers() async {
        if let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) {
            displays = content.displays.enumerated().map { i, d in
                let name = NSScreen.screens.first {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.displayID
                }?.localizedName ?? "Display \(i + 1)"
                return PickerItem(id: String(d.displayID), title: "\(name) (\(d.width)×\(d.height))")
            }
            let me = Bundle.main.bundleIdentifier
            windows = content.windows
                .filter { $0.windowLayer == 0 && $0.frame.width > 100 && !($0.title ?? "").isEmpty
                    && $0.owningApplication?.bundleIdentifier != me }
                .map { w in
                    WindowItem(id: w.windowID,
                               title: "\(w.owningApplication?.applicationName ?? "App") — \((w.title ?? "").prefix(60))",
                               bundleID: w.owningApplication?.bundleIdentifier ?? "",
                               windowTitle: w.title ?? "")
                }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            apps = content.applications
                .filter { !$0.applicationName.isEmpty && $0.bundleIdentifier != me && !$0.bundleIdentifier.isEmpty }
                .map { PickerItem(id: $0.bundleIdentifier, title: $0.applicationName) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        } else {
            message = "LiteCap needs Screen Recording permission: System Settings → Privacy & Security → "
                + "Screen & System Audio Recording → turn on LiteCap, then reopen the app."
        }
        audioInputs = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.map { PickerItem(id: $0.uniqueID, title: $0.localizedName) }
        cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified
        ).devices.map { PickerItem(id: $0.uniqueID, title: $0.localizedName) }
    }

    // MARK: - Recording

    func toggleRecording() { if isRecording { stopRecording() } else { startRecording() } }

    func startRecording() {
        guard !isRecording else { return }
        do {
            let output = try RecordingOutput(
                folder: URL(fileURLWithPath: project.record.folder), settings: project.record,
                canvas: project.video, trackNames: project.trackNames
            )
            output.onError = { @Sendable [weak self] text in
                Task { @MainActor in
                    self?.message = text
                    self?.stopRecording()
                }
            }
            recording = output
            hub.set(recording: output)
            isRecording = true
            recordStarted = Date()
            updateActive()
            updateLiveActivity()
            message = "Recording to \(output.url.lastPathComponent)"
        } catch {
            message = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording(completion: (() -> Void)? = nil) {
        guard let output = recording else { completion?(); return }
        hub.set(recording: nil)
        recording = nil
        isRecording = false
        recordStarted = nil
        stats.recordMB = 0
        updateLiveActivity()
        updateActive()
        output.finish { @Sendable [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let url):
                    self?.lastRecording = url
                    self?.message = "Saved \(url.lastPathComponent)"
                case .failure(let error):
                    self?.message = "Recording error: \(error.localizedDescription)"
                }
                completion?()
            }
        }
    }

    // MARK: - Streaming

    func toggleStreaming() { if isStreaming { stopStreaming() } else { startStreaming() } }

    func startStreaming() {
        guard !isStreaming, !isBusy else { return }
        let key = streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            message = "Add your stream key in Settings → Stream first."
            return
        }
        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            do {
                let output = try StreamOutput(settings: project.stream, key: key, canvas: project.video)
                output.onState = { @Sendable [weak self] state, text in
                    Task { @MainActor in
                        self?.streamState = state
                        if let text { self?.message = text }
                    }
                }
                stream = output
                hub.set(stream: output)
                isStreaming = true
                updateActive()
                updateLiveActivity()
                try await output.start()
                streamStarted = Date()
                message = "You're live"
            } catch {
                hub.set(stream: nil)
                stream = nil
                isStreaming = false
                streamState = .stopped
                updateLiveActivity()
                updateActive()
                message = "Couldn't go live: \(error.localizedDescription)"
            }
        }
    }

    func stopStreaming(completion: (() -> Void)? = nil) {
        guard let output = stream else { completion?(); return }
        hub.set(stream: nil)
        stream = nil
        isStreaming = false
        streamStarted = nil
        updateLiveActivity()
        updateActive()
        Task { @MainActor in
            await output.stop()
            streamState = .stopped
            message = "Stream ended"
            completion?()
        }
    }

    func stopAll(completion: @escaping () -> Void) {
        saveNow()
        stopStreaming { [weak self] in
            guard let self else { completion(); return }
            self.stopRecording(completion: completion)
        }
    }

    // MARK: - Misc

    func revealRecordings() {
        if let lastRecording, FileManager.default.fileExists(atPath: lastRecording.path) {
            NSWorkspace.shared.activateFileViewerSelecting([lastRecording])
        } else {
            let folder = URL(fileURLWithPath: project.record.folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }

    static var ffmpegPath: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Copies an .mkv into an .mp4 next to it (no re-encode), using ffmpeg if installed.
    func remuxToMP4(_ url: URL) {
        guard let ffmpeg = Self.ffmpegPath else {
            message = "Remuxing uses ffmpeg. Install it with: brew install ffmpeg"
            return
        }
        let output = url.deletingPathExtension().appendingPathExtension("mp4")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-y", "-v", "error", "-i", url.path, "-map", "0", "-c", "copy",
                             "-movflags", "+faststart", output.path]
        process.terminationHandler = { [weak self] p in
            Task { @MainActor in
                self?.message = p.terminationStatus == 0 ? "Remuxed to \(output.lastPathComponent)" : "Remux failed"
                if p.terminationStatus == 0 { NSWorkspace.shared.activateFileViewerSelecting([output]) }
            }
        }
        do {
            try process.run()
            message = "Remuxing \(url.lastPathComponent)…"
        } catch {
            message = "Remux failed: \(error.localizedDescription)"
        }
    }
}
