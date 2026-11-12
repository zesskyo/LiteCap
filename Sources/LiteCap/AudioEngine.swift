import AVFoundation
import LiteCapCore

/// The audio mixer.
///
///     source ──▶ [AU filters…] ──▶ fader ──┬──▶ track 1…6 mixers ──▶ taps → encoders
///                                          ├──▶ monitor mixer ──────▶ your output device
///                                          └──▶ meter sink (silent, keeps meters alive)
///     track N mixer ──▶ "listen" gain (0/1) ──▶ your output device
///
/// Graph changes are made on the main thread.
final class AudioEngine: @unchecked Sendable {
    struct Levels {
        var left: Float = 0
        var right: Float = 0
    }

    final class Channel {
        var config: AudioSourceConfig
        let ring = AudioRing()
        var sourceNode: AVAudioSourceNode!
        let fader = AVAudioMixerNode()
        var effects: [UUID: AVAudioUnit] = [:]
        var chain: [AVAudioNode] = []
        var capture: AudioCapture?
        let levelLock = NSLock()
        var levels = Levels()
        var loadGeneration = 0

        init(config: AudioSourceConfig) { self.config = config }
    }

    private let engine = AVAudioEngine()
    private var trackMixers: [AVAudioMixerNode] = []
    private var listenGains: [AVAudioMixerNode] = []
    private let meterSink = AVAudioMixerNode()
    private let monitorMixer = AVAudioMixerNode()
    private var channels: [UUID: Channel] = [:]
    private let consumerLock = NSLock()
    private var consumers: [UUID: (Int, AVAudioPCMBuffer, AVAudioTime) -> Void] = [:]
    private(set) var isRunning = false
    var onMessage: ((String) -> Void)?

    init() {
        let main = engine.mainMixerNode
        engine.attach(meterSink)
        engine.attach(monitorMixer)
        engine.connect(meterSink, to: main, format: mixFormat)
        engine.connect(monitorMixer, to: main, format: mixFormat)
        meterSink.outputVolume = 0
        for track in 1...Project.trackCount {
            let mixer = AVAudioMixerNode()
            let listen = AVAudioMixerNode()
            engine.attach(mixer)
            engine.attach(listen)
            engine.connect(mixer, to: listen, format: mixFormat)
            engine.connect(listen, to: main, format: mixFormat)
            listen.outputVolume = 0
            mixer.installTap(onBus: 0, bufferSize: 2048, format: mixFormat) { [weak self] buffer, when in
                self?.deliver(track: track, buffer, when)
            }
            trackMixers.append(mixer)
            listenGains.append(listen)
        }
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // Output device changed (headphones plugged in, etc.): the engine stopped itself.
            guard let self, self.isRunning else { return }
            try? self.engine.start()
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
            isRunning = true
            channels.values.forEach { $0.capture?.start() }
        } catch {
            onMessage?("Audio engine couldn't start: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        channels.values.forEach {
            $0.capture?.stop()
            $0.ring.reset()
        }
        engine.stop()
    }

    // MARK: Consumers (recording / streaming)

    func addConsumer(_ id: UUID, _ handler: @escaping (Int, AVAudioPCMBuffer, AVAudioTime) -> Void) {
        consumerLock.withLock { consumers[id] = handler }
    }

    func removeConsumer(_ id: UUID) { _ = consumerLock.withLock { consumers.removeValue(forKey: id) } }

    private func deliver(track: Int, _ buffer: AVAudioPCMBuffer, _ when: AVAudioTime) {
        let handlers = consumerLock.withLock { Array(consumers.values) }
        guard !handlers.isEmpty, let copy = buffer.deepCopy() else { return }
        handlers.forEach { $0(track, copy, when) }
    }

    // MARK: Listening

    func setListenTrack(_ track: Int) {
        for (i, gain) in listenGains.enumerated() { gain.outputVolume = (i + 1 == track) ? 1 : 0 }
    }

    func levels(_ id: UUID) -> Levels {
        guard let channel = channels[id] else { return Levels() }
        return channel.levelLock.withLock { channel.levels }
    }

    func captureStatus(_ id: UUID) -> String { channels[id]?.capture?.status ?? "" }

    func unit(source: UUID, filter: UUID) -> AVAudioUnit? { channels[source]?.effects[filter] }

    /// Current plugin settings, to save in the project.
    func filterStates() -> [UUID: [UUID: Data]] {
        var result: [UUID: [UUID: Data]] = [:]
        for (sourceID, channel) in channels {
            for (filterID, unit) in channel.effects {
                if let state = unit.auAudioUnit.fullState,
                   let data = try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0) {
                    result[sourceID, default: [:]][filterID] = data
                }
            }
        }
        return result
    }

    // MARK: Sync with the project

    func sync(_ sources: [AudioSourceConfig]) {
        let wanted = Set(sources.map(\.id))
        for (id, channel) in channels where !wanted.contains(id) { remove(channel) }
        for config in sources {
            if let channel = channels[config.id] { update(channel, config) } else { add(config) }
        }
    }

    private func add(_ config: AudioSourceConfig) {
        let channel = Channel(config: config)
        let ring = channel.ring
        channel.sourceNode = AVAudioSourceNode(format: mixFormat) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            ring.read(left: left, right: right, frames: Int(frameCount))
            return noErr
        }
        channels[config.id] = channel
        graphChange {
            engine.attach(channel.sourceNode)
            engine.attach(channel.fader)
            connectChain(channel)
            connectOutputs(channel)
        }
        channel.fader.installTap(onBus: 0, bufferSize: 1024, format: mixFormat) { [weak channel] buffer, _ in
            guard let channel, let data = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            var l: Float = 0, r: Float = 0
            for i in 0..<n {
                l = max(l, abs(data[0][i]))
                r = max(r, abs(data[1][i]))
            }
            channel.levelLock.withLock { channel.levels = Levels(left: l, right: r) }
        }
        applyVolume(channel)
        channel.capture = makeCapture(config.kind, ring: ring)
        if isRunning { channel.capture?.start() }
        loadEffects(channel)
    }

    private func update(_ channel: Channel, _ config: AudioSourceConfig) {
        let old = channel.config
        guard old != config else { return }
        channel.config = config
        if old.kind != config.kind {
            channel.capture?.stop()
            channel.ring.reset()
            channel.capture = makeCapture(config.kind, ring: channel.ring)
            if isRunning { channel.capture?.start() }
        }
        applyVolume(channel)
        if old.tracks != config.tracks || old.monitor != config.monitor {
            graphChange { connectOutputs(channel) }
        }
        let shape = { (filters: [AudioFilterConfig]) in filters.map { "\($0.id)\($0.type)\($0.subType)\($0.manufacturer)" } }
        if shape(old.filters) != shape(config.filters) {
            loadEffects(channel)
        } else {
            for filter in config.filters { channel.effects[filter.id]?.auAudioUnit.shouldBypassEffect = filter.bypass }
        }
    }

    private func remove(_ channel: Channel) {
        channel.capture?.stop()
        channel.fader.removeTap(onBus: 0)
        graphChange {
            engine.disconnectNodeOutput(channel.fader)
            engine.disconnectNodeOutput(channel.sourceNode)
            for node in channel.chain { engine.disconnectNodeOutput(node) }
            engine.detach(channel.fader)
            engine.detach(channel.sourceNode)
            for unit in channel.effects.values { engine.detach(unit) }
        }
        channels[channel.config.id] = nil
    }

    private func applyVolume(_ channel: Channel) {
        channel.fader.outputVolume = channel.config.muted ? 0 : Float(channel.config.volume)
    }

    private func makeCapture(_ kind: AudioSourceKind, ring: AudioRing) -> AudioCapture {
        switch kind {
        case .desktop: return SystemAudioCapture(appBundleID: nil, ring: ring)
        case .app(let bundleID, _): return SystemAudioCapture(appBundleID: bundleID, ring: ring)
        case .input(let deviceID): return InputDeviceCapture(deviceID: deviceID, ring: ring)
        }
    }

    // MARK: Graph helpers

    /// Pauses rendering while nodes are re-wired (a few ms), then resumes.
    private func graphChange(_ body: () -> Void) {
        let wasRunning = engine.isRunning
        if wasRunning { engine.pause() }
        body()
        if wasRunning { try? engine.start() }
    }

    private func connectChain(_ channel: Channel) {
        engine.disconnectNodeOutput(channel.sourceNode)
        channel.chain.forEach { engine.disconnectNodeOutput($0) }
        var previous: AVAudioNode = channel.sourceNode
        for node in channel.chain {
            engine.connect(previous, to: node, format: mixFormat)
            previous = node
        }
        engine.connect(previous, to: channel.fader, format: mixFormat)
    }

    private func connectOutputs(_ channel: Channel) {
        engine.disconnectNodeOutput(channel.fader)
        var points = [AVAudioConnectionPoint(node: meterSink, bus: meterSink.nextAvailableInputBus)]
        for track in channel.config.tracks.sorted() where (1...Project.trackCount).contains(track) {
            let mixer = trackMixers[track - 1]
            points.append(AVAudioConnectionPoint(node: mixer, bus: mixer.nextAvailableInputBus))
        }
        if channel.config.monitor {
            points.append(AVAudioConnectionPoint(node: monitorMixer, bus: monitorMixer.nextAvailableInputBus))
        }
        engine.connect(channel.fader, to: points, fromBus: 0, format: mixFormat)
    }

    private func loadEffects(_ channel: Channel) {
        channel.loadGeneration += 1
        let generation = channel.loadGeneration
        let filters = channel.config.filters
        Task { @MainActor in
            var units: [UUID: AVAudioUnit] = [:]
            for filter in filters {
                if let existing = channel.effects[filter.id] {
                    units[filter.id] = existing
                    continue
                }
                do {
                    units[filter.id] = try await AudioPlugins.instantiate(filter)
                } catch {
                    onMessage?("Couldn't load plugin \(filter.name): \(error.localizedDescription)")
                }
            }
            guard generation == channel.loadGeneration, channels[channel.config.id] === channel else { return }
            graphChange {
                channel.chain.forEach { engine.disconnectNodeOutput($0) }
                for (id, unit) in channel.effects where units[id] == nil { engine.detach(unit) }
                for (id, unit) in units where channel.effects[id] == nil { engine.attach(unit) }
                channel.effects = units
                channel.chain = filters.compactMap { units[$0.id] }
                for filter in filters { units[filter.id]?.auAudioUnit.shouldBypassEffect = filter.bypass }
                connectChain(channel)
            }
        }
    }
}

extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (s, t) in zip(source, target) {
            if let src = s.mData, let dst = t.mData { memcpy(dst, src, Int(min(s.mDataByteSize, t.mDataByteSize))) }
        }
        return copy
    }
}

/// Host-clock microseconds for an audio timestamp.
func hostMicros(_ when: AVAudioTime?) -> Int64 {
    let host = (when?.isHostTimeValid ?? false) ? when!.hostTime : mach_absolute_time()
    let time = CMClockMakeHostTimeFromSystemUnits(host)
    return CMTimeConvertScale(time, timescale: 1_000_000, method: .roundHalfAwayFromZero).value
}
