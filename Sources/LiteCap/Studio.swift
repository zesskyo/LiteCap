import AppKit
import AVFoundation
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
    let appName: String
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
    @Published var skipped = 0
    @Published var cpu = 0.0
    @Published var gpu: Double?
    @Published var sourceProblems: [String] = []
}

/// Routes canvas frames and track audio to whichever outputs are running (any thread).
final class OutputHub: @unchecked Sendable {
    private let lock = NSLock()
    private var recording: Recorder?
    private var stream: StreamOutput?

    func set(recording: Recorder?) { lock.withLock { self.recording = recording } }
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
    @Published var selectedItemID: UUID? {
        didSet { updateOverlay() }
    }
    @Published var editingSourceID: UUID?
    @Published var filtersSourceID: UUID?
    @Published var showingTracks = false
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
    private var knownSizes: [UUID: CGSize] = [:]
    private var dragOverride: (item: UUID, frame: CanvasRect, crop: Crop)?
    private var dragGuides: [(vertical: Bool, position: Double)] = []

    // Undo / redo of project edits (⌘Z / ⇧⌘Z).
    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var lastUndoRecord = Date.distantPast
    private var isRestoring = false
    private var undoSuppressed = 0
    private var recording: Recorder?
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
        Task { await refreshPickers() }
    }

    // MARK: - Activity
    // Video (capture + compositor) runs while the preview is showing or you're live.
    // Audio (mixer, meters, monitoring) runs while the main window is open or you're live.

    @Published var previewHidden = UserDefaults.standard.bool(forKey: "previewHidden") {
        didSet {
            UserDefaults.standard.set(previewHidden, forKey: "previewHidden")
            updateActive()
        }
    }
    private var windowClients = 0
    private(set) var isAudioActive = false
    private let usage = UsageSampler()

    func windowAppeared() {
        windowClients += 1
        updateActive()
    }

    func windowDisappeared() {
        windowClients = max(0, windowClients - 1)
        updateActive()
    }

    func previewAppeared() {
        previewClients += 1
        updateActive()
    }

    func previewDisappeared() {
        previewClients = max(0, previewClients - 1)
        updateActive()
    }

    private func updateActive() {
        // Hidden preview = low-power mode: the mixer only runs when live or when monitoring.
        let monitoring = project.audioSources.contains { $0.monitor }
        let wantAudio = isLive || monitoring || (windowClients > 0 && !previewHidden)
        if wantAudio != isAudioActive {
            isAudioActive = wantAudio
            if wantAudio { audio.start() } else { audio.stop() }
        }
        // Meters redraw 20×/s, so they only run while the preview is showing.
        setMeters(running: isAudioActive && !previewHidden)
        // Status-bar numbers (1×/s) whenever the window is open or we're live.
        setStats(running: windowClients > 0 || isLive)
        let wantVideo = previewClients > 0 || isLive
        guard wantVideo != isActive else { return }
        isActive = wantVideo
        if wantVideo {
            compositor.configure(width: project.video.width, height: project.video.height, fps: project.video.fps)
            compositor.start()
            renderedSceneID = nil
            syncVideo()
        } else {
            sceneSwitch?.cancel()
            sources.values.forEach { $0.stop() }
            sources.removeAll()
            renderedSceneID = nil
            compositor.setLayers([])
            compositor.stop()
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

    private func setMeters(running: Bool) {
        if running, meterTimer == nil {
            meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    var levels: [UUID: AudioEngine.Levels] = [:]
                    for source in self.project.audioSources { levels[source.id] = self.audio.levels(source.id) }
                    self.meters.levels = levels
                }
            }
        } else if !running, let timer = meterTimer {
            timer.invalidate()
            meterTimer = nil
            meters.levels = [:]
        }
    }

    private func setStats(running: Bool) {
        if running, statsTimer == nil {
            statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.updateStats() }
            }
        } else if !running, let timer = statsTimer {
            timer.invalidate()
            statsTimer = nil
        }
    }

    private func updateStats() async {
        stats.fps = isActive ? compositor.fpsMeasured : 0
        stats.skipped = compositor.skippedFrames
        let sample = usage.sample()
        stats.cpu = sample.cpu
        stats.gpu = sample.gpu
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
        if !isRestoring && undoSuppressed == 0 { recordUndo(old) }
        // Keep typed-in values sane (encoders need even sizes) — written back once, only if needed.
        var fixed = project
        fixed.video.width = max(16, min(7680, fixed.video.width)) & ~1
        fixed.video.height = max(16, min(4320, fixed.video.height)) & ~1
        fixed.video.fps = max(1, min(240, fixed.video.fps))
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
        if old.audioSources != project.audioSources {
            audio.sync(project.audioSources)
            updateActive() // monitoring on/off can start or stop the mixer
        }
        if old.video != project.video, isActive {
            compositor.configure(width: project.video.width, height: project.video.height, fps: project.video.fps)
            if old.video.fps != project.video.fps || old.video.width != project.video.width
                || old.video.height != project.video.height {
                // Sources capture at the canvas frame rate and size: rebuild them.
                sources.values.forEach { $0.stop() }
                sources.removeAll()
                renderedSceneID = nil
            }
        }
        syncVideo()
    }

    // MARK: - Undo / redo

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Changes less than ~0.6 s apart (a fader move, typing) become one undo step.
    private func recordUndo(_ old: Project) {
        let now = Date()
        if undoStack.isEmpty || now.timeIntervalSince(lastUndoRecord) > 0.6 {
            undoStack.append(old)
            if undoStack.count > 100 { undoStack.removeFirst() }
        }
        lastUndoRecord = now
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        restore(next)
    }

    private func restore(_ state: Project) {
        isRestoring = true
        project = state
        isRestoring = false
        lastUndoRecord = .distantPast
        if item(selectedItemID) == nil { selectedItemID = nil }
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
        let source = VideoSource.make(config, fps: project.video.fps,
                                      canvas: CGSize(width: project.video.width, height: project.video.height))
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
            guard item.visible, var frame = item.frame, let source = sources[item.sourceID] else { return nil }
            var crop = item.crop
            if let drag = dragOverride, drag.item == item.id {
                frame = drag.frame
                crop = drag.crop
            }
            return Compositor.Layer(source: source, frame: frame, crop: crop)
        }
        compositor.setLayers(layers)
        updateOverlay()
    }

    /// The selection box and snap guides the preview draws (in Metal, in step with the picture).
    private func updateOverlay() {
        var overlay = Compositor.PreviewOverlay()
        if let item = item(selectedItemID), item.visible {
            overlay.rect = dragOverride?.item == item.id ? dragOverride?.frame : item.frame
            overlay.locked = item.locked
        }
        overlay.guides = dragGuides
        compositor.setOverlay(overlay)
    }

    func setGuides(_ guides: [(vertical: Bool, position: Double)]) {
        dragGuides = guides
        updateOverlay()
    }

    /// A source's pixel size became known or changed (e.g. a captured window was resized).
    /// New items get placed; existing ones keep their scale, so the box grows/shrinks
    /// with the source instead of stretching it.
    private func sourceSized(_ id: UUID, _ size: CGSize) {
        undoSuppressed += 1
        defer { undoSuppressed -= 1 }
        let previous = knownSizes[id]
        knownSizes[id] = size
        let canvasW = Double(project.video.width), canvasH = Double(project.video.height)
        var scenes = project.scenes
        for s in scenes.indices {
            for i in scenes[s].items.indices where scenes[s].items[i].sourceID == id {
                var item = scenes[s].items[i]
                if item.frame == nil {
                    // Bigger than the canvas: fit it. Otherwise native size, snapped to the top-left corner.
                    item.frame = Double(size.width) > canvasW || Double(size.height) > canvasH
                        ? Self.fit(size, canvasW, canvasH, stretch: false)
                        : CanvasRect(x: 0, y: 0, w: Double(size.width), h: Double(size.height))
                } else if let previous, previous != size, var f = item.frame {
                    let c = item.crop
                    let sx = f.w / max(1, Double(previous.width) - c.left - c.right)
                    let sy = f.h / max(1, Double(previous.height) - c.top - c.bottom)
                    f.w = max(1, Double(size.width) - c.left - c.right) * sx
                    f.h = max(1, Double(size.height) - c.top - c.bottom) * sy
                    item.frame = f
                }
                scenes[s].items[i] = item
            }
        }
        if scenes != project.scenes { project.scenes = scenes }
    }

    /// Source size in pixels (live frame, or the last one seen).
    func sourcePixelSize(_ id: UUID) -> CGSize? { sourceSize(id) ?? knownSizes[id] }

    // MARK: - Fast dragging (only the video layer updates until the mouse is released)

    func previewDrag(_ itemID: UUID, frame: CanvasRect, crop: Crop) {
        dragOverride = (itemID, frame, crop)
        updateLayers()
    }

    func endDrag() {
        dragGuides = []
        guard let drag = dragOverride else {
            updateOverlay()
            return
        }
        dragOverride = nil
        updateItem(drag.item) { item in
            item.frame = drag.frame
            item.crop = drag.crop
        }
        updateLayers()
    }

    /// Crop that removes content instead of stretching: the frame shrinks/grows with the crop.
    func setCrop(_ itemID: UUID, _ crop: Crop) {
        guard let item = item(itemID) else { return }
        guard let size = sourcePixelSize(item.sourceID) else {
            updateItem(itemID) { $0.crop = crop }
            return
        }
        updateItem(itemID) { $0 = Self.applyCrop($0, crop, size: size) }
    }

    static func applyCrop(_ item: SceneItem, _ crop: Crop, size: CGSize) -> SceneItem {
        var result = item
        let W = Double(size.width), H = Double(size.height)
        var c = crop
        c.left = max(0, min(c.left, W - 8))
        c.right = max(0, min(c.right, W - 8 - c.left))
        c.top = max(0, min(c.top, H - 8))
        c.bottom = max(0, min(c.bottom, H - 8 - c.top))
        result.crop = c
        guard var f = item.frame else { return result }
        let old = item.crop
        let sx = f.w / max(1, W - old.left - old.right)
        let sy = f.h / max(1, H - old.top - old.bottom)
        f.x += (c.left - old.left) * sx
        f.y += (c.top - old.top) * sy
        f.w = (W - c.left - c.right) * sx
        f.h = (H - c.top - c.bottom) * sy
        result.frame = f
        return result
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
        let removedAudio = Set(project.videoSources.filter { !used.contains($0.id) }.compactMap(\.audioSourceID))
        project.videoSources.removeAll { !used.contains($0.id) }
        if !removedAudio.isEmpty { project.audioSources.removeAll { removedAudio.contains($0.id) } }
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
        syncLinkedAudio(id)
    }

    /// Window capture "Capture audio": keeps a mixer channel for the window's app in step.
    private func syncLinkedAudio(_ id: UUID) {
        guard let i = project.videoSources.firstIndex(where: { $0.id == id }) else { return }
        let config = project.videoSources[i]
        var bundleID = ""
        if case .window(_, let bid, _) = config.kind { bundleID = bid }
        // Java apps (Minecraft, …) have no bundle ID: match those by app name.
        let appName = config.appName ?? apps.first { $0.id == bundleID }?.title ?? ""
        let linked = config.audioSourceID.flatMap { aid in project.audioSources.firstIndex { $0.id == aid } }
        if config.captureAudio == true && bundleID.isEmpty && appName.isEmpty {
            message = "Couldn't tell which app owns that window. Pick the window again in Properties."
        }
        if config.captureAudio == true, !bundleID.isEmpty || !appName.isEmpty {
            let kind = AudioSourceKind.app(bundleID: bundleID, name: appName.isEmpty ? config.name : appName)
            if let j = linked {
                if project.audioSources[j].kind != kind { project.audioSources[j].kind = kind }
            } else {
                let audio = AudioSourceConfig(name: "\(config.name) Audio", kind: kind, tracks: [1, 2])
                project.audioSources.append(audio)
                project.videoSources[i].audioSourceID = audio.id
            }
        } else if let j = linked {
            project.audioSources.remove(at: j)
            project.videoSources[i].audioSourceID = nil
        }
    }

    /// Moves a mixer channel to a new position.
    func moveAudioSource(_ id: UUID, to index: Int) {
        guard let from = project.audioSources.firstIndex(where: { $0.id == id }) else { return }
        var list = project.audioSources
        let source = list.remove(at: from)
        list.insert(source, at: max(0, min(index, list.count)))
        if list != project.audioSources { project.audioSources = list }
    }

    func moveAudioSource(_ id: UUID, by delta: Int) {
        guard let from = project.audioSources.firstIndex(where: { $0.id == id }) else { return }
        moveAudioSource(id, to: from + delta)
    }

    // MARK: - Audio editing

    func addAudioSource(_ kind: AudioSourceKind, name: String) {
        project.audioSources.append(AudioSourceConfig(name: name, kind: kind, tracks: [1, 2]))
    }

    func removeAudioSource(_ id: UUID) {
        project.audioSources.first { $0.id == id }?.filters.forEach { PluginWindows.close($0.id) }
        project.audioSources.removeAll { $0.id == id }
        // Removing a window's linked audio channel switches its "Capture audio" off.
        for i in project.videoSources.indices where project.videoSources[i].audioSourceID == id {
            project.videoSources[i].audioSourceID = nil
            project.videoSources[i].captureAudio = nil
        }
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
                               windowTitle: w.title ?? "",
                               appName: w.owningApplication?.applicationName ?? "")
                }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            // Apps without a bundle ID (Java games, …) are listed by name: id "name:<app name>".
            apps = content.applications
                .filter { !$0.applicationName.isEmpty && ($0.bundleIdentifier.isEmpty || $0.bundleIdentifier != me) }
                .map { app in
                    PickerItem(id: app.bundleIdentifier.isEmpty ? "name:" + app.applicationName : app.bundleIdentifier,
                               title: app.applicationName)
                }
                .reduce(into: [PickerItem]()) { list, item in
                    if !list.contains(where: { $0.id == item.id }) { list.append(item) }
                }
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
            let output = try Recorders.make(
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
                    if self?.project.record.autoRemux == true, url.pathExtension == "mkv" { self?.remuxToMP4(url) }
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
