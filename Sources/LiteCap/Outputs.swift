import AVFoundation
import LiteCapCore

// MARK: - Recording (MKV, multi-track)

/// Encodes the canvas + chosen audio tracks and writes a crash-safe .mkv.
final class RecordingOutput: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "litecap.recording", qos: .userInitiated)
    private let video: VideoEncoder
    private var audio: [Int: AACEncoder] = [:]
    /// project track number → index in the file's audio tracks
    private let trackIndex: [Int: Int]
    private let audioInfo: [AudioTrackInfo]
    private var writer: MatroskaWriter?
    private var failed = false
    private let fps: Int
    let consumerID = UUID()
    var onError: ((String) -> Void)?

    init(folder: URL, settings: RecordSettings, canvas: VideoSettings, trackNames: [String]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        url = folder.appendingPathComponent("\(formatter.string(from: Date())).mkv")
        fps = canvas.fps
        video = try VideoEncoder(.init(codec: settings.codec, width: canvas.width, height: canvas.height,
                                       fps: canvas.fps, bitrateKbps: settings.bitrateKbps, constantBitrate: false))
        let tracks = settings.tracks.sorted().filter { (1...Project.trackCount).contains($0) }
        var index: [Int: Int] = [:]
        var info: [AudioTrackInfo] = []
        for (i, track) in tracks.enumerated() {
            index[track] = i
            info.append(AudioTrackInfo(name: trackNames[track - 1]))
        }
        trackIndex = index
        audioInfo = info
        for (track, i) in index {
            guard let encoder = AACEncoder(bitrateKbps: settings.audioKbps) else { continue }
            encoder.onPacket = { [weak self] pts, data in
                self?.write(EncodedPacket(kind: .audio(index: i), pts: pts, isKeyframe: true, data: data))
            }
            audio[track] = encoder
        }
        video.onPacket = { [weak self] packet, config in
            guard let self else { return }
            self.queue.async {
                if self.writer == nil, packet.isKeyframe, let config {
                    do {
                        self.writer = try MatroskaWriter(
                            url: self.url,
                            video: VideoTrackInfo(codec: settings.codec, width: canvas.width, height: canvas.height,
                                                  fps: Double(self.fps), codecPrivate: config),
                            audio: self.audioInfo
                        )
                    } catch {
                        self.fail("Couldn't create \(self.url.lastPathComponent): \(error)")
                    }
                }
                self.writeOnQueue(packet)
            }
        }
    }

    func appendVideo(_ buffer: CVPixelBuffer, pts: CMTime) { video.encode(buffer, pts: pts) }

    func appendAudio(track: Int, _ buffer: AVAudioPCMBuffer, pts: Int64) {
        guard let encoder = audio[track] else { return }
        queue.async { encoder.encode(buffer, pts: pts) }
    }

    private func write(_ packet: EncodedPacket) { writeOnQueue(packet) } // AAC callbacks already run on `queue`

    private func writeOnQueue(_ packet: EncodedPacket) {
        guard !failed, let writer else { return }
        do { try writer.write(packet) } catch { fail("Disk write failed: \(error.localizedDescription)") }
    }

    private func fail(_ message: String) {
        guard !failed else { return }
        failed = true
        onError?(message)
    }

    var bytesWritten: UInt64 { queue.sync { writer?.bytesWritten ?? 0 } }

    func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        video.finish()
        queue.async { [self] in
            do {
                guard let writer else {
                    throw NSError(domain: "LiteCap", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video frames were recorded."])
                }
                try writer.finish()
                completion(.success(url))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

// MARK: - Streaming (RTMP, optional Twitch VOD track)

final class StreamOutput: @unchecked Sendable {
    enum State: Equatable {
        case connecting
        case live
        case reconnecting(attempt: Int)
        case stopped
    }

    let consumerID = UUID()
    private let settings: StreamSettings
    private let key: String
    private let width: Int
    private let height: Int
    private let fps: Int
    private let queue = DispatchQueue(label: "litecap.stream", qos: .userInitiated)
    private let encoder: VideoEncoder
    private let scaler: PixelScaler?
    /// project track number → RTMP audio track id (0 = main, 1 = VOD)
    private var audio: [Int: (encoder: AACEncoder, rtmpTrack: Int)] = [:]
    private var publisher: RTMPPublisher?
    private enum Outgoing { case videoHeader(Data), packet(EncodedPacket) }
    /// Single ordered pipe to the publisher (actor calls from separate Tasks could reorder).
    private var pipe: AsyncStream<Outgoing>.Continuation?
    private var pumpTask: Task<Void, Never>?
    private var avcC: Data?
    private var sentVideoHeader = false
    private var ready = false
    private var stopped = false
    private let stateLock = NSLock()
    private var _state: State = .connecting
    private var lastBytes: Int64 = 0
    private var lastBytesTime = CFAbsoluteTimeGetCurrent()

    var onState: ((State, String?) -> Void)?

    var state: State { stateLock.withLock { _state } }

    init(settings: StreamSettings, key: String, canvas: VideoSettings) throws {
        self.settings = settings
        self.key = key
        fps = canvas.fps
        var w = canvas.width, h = canvas.height
        if settings.outputHeight > 0, settings.outputHeight < canvas.height {
            w = (canvas.width * settings.outputHeight / canvas.height) & ~1
            h = settings.outputHeight & ~1
            scaler = PixelScaler(width: w, height: h)
        } else {
            scaler = nil
        }
        width = w
        height = h
        encoder = try VideoEncoder(.init(codec: .h264, width: w, height: h, fps: canvas.fps,
                                         bitrateKbps: settings.bitrateKbps, constantBitrate: settings.cbr))
        var tracks: [(Int, Int)] = [(settings.track, 0)]
        if settings.vodTrackEnabled, settings.vodTrack != settings.track { tracks.append((settings.vodTrack, 1)) }
        for (track, rtmpTrack) in tracks {
            guard let aac = AACEncoder(bitrateKbps: settings.audioKbps) else { continue }
            aac.onPacket = { [weak self] pts, data in
                self?.send(EncodedPacket(kind: .audio(index: rtmpTrack), pts: pts, isKeyframe: true, data: data))
            }
            audio[track] = (aac, rtmpTrack)
        }
        encoder.onPacket = { [weak self] packet, config in
            guard let self else { return }
            self.queue.async {
                if let config { self.avcC = config }
                self.send(packet)
            }
        }
    }

    // MARK: Lifecycle

    func start() async throws {
        setState(.connecting, nil)
        try await connect()
        setState(.live, nil)
    }

    func stop() async {
        let current: RTMPPublisher? = queue.sync {
            stopped = true
            ready = false
            pipe?.finish()
            pipe = nil
            return publisher
        }
        encoder.finish()
        await pumpTask?.value
        await current?.close()
        setState(.stopped, nil)
    }

    private func connect() async throws {
        let publisher = try RTMPPublisher(transport: NWTransport(), serverURL: settings.server, streamKey: key)
        await publisher.setBitrate(totalKbps: settings.bitrateKbps + settings.audioKbps * audio.count)
        try await publisher.connect()
        await publisher.sendMetadata(width: width, height: height, fps: Double(fps),
                                     videoKbps: settings.bitrateKbps, audioKbps: settings.audioKbps)
        for (_, entry) in audio {
            await publisher.sendAudioHeader(asc: AAC.audioSpecificConfig(), track: entry.rtmpTrack)
        }
        await publisher.setDisconnectHandler { [weak self] error in self?.connectionLost(error) }
        let (stream, continuation) = AsyncStream.makeStream(of: Outgoing.self)
        pumpTask = Task {
            for await item in stream {
                switch item {
                case .videoHeader(let data): await publisher.sendVideoHeader(avcC: data)
                case .packet(let packet): await publisher.send(packet)
                }
            }
        }
        queue.sync {
            pipe?.finish()
            pipe = continuation
            self.publisher = publisher
            sentVideoHeader = false
            ready = true
        }
        encoder.requestKeyframe()
    }

    private func connectionLost(_ error: Error) {
        let shouldRetry: Bool = queue.sync {
            ready = false
            publisher = nil
            pipe?.finish()
            pipe = nil
            return !stopped
        }
        guard shouldRetry else { return }
        Task { await reconnectLoop(firstError: error) }
    }

    private func reconnectLoop(firstError: Error) async {
        var attempt = 1
        var delay: UInt64 = 2
        while !queue.sync(execute: { stopped }) {
            setState(.reconnecting(attempt: attempt), "Connection lost (\(firstError.localizedDescription)) — reconnecting…")
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            if queue.sync(execute: { stopped }) { return }
            do {
                try await connect()
                setState(.live, "Reconnected")
                return
            } catch {
                attempt += 1
                delay = min(delay * 2, 30)
            }
        }
    }

    private func setState(_ state: State, _ message: String?) {
        stateLock.withLock { _state = state }
        onState?(state, message)
    }

    // MARK: Media

    func appendVideo(_ buffer: CVPixelBuffer, pts: CMTime) {
        guard queue.sync(execute: { ready }) else { return }
        if let scaler {
            if let scaled = scaler.scale(buffer) { encoder.encode(scaled, pts: pts) }
        } else {
            encoder.encode(buffer, pts: pts)
        }
    }

    func appendAudio(track: Int, _ buffer: AVAudioPCMBuffer, pts: Int64) {
        guard let entry = audio[track] else { return }
        queue.async { [self] in
            guard ready else { return }
            entry.encoder.encode(buffer, pts: pts)
        }
    }

    /// Called on `queue`.
    private func send(_ packet: EncodedPacket) {
        guard ready, let pipe else { return }
        if packet.kind == .video, !sentVideoHeader {
            guard packet.isKeyframe, let avcC else { return }
            sentVideoHeader = true
            pipe.yield(.videoHeader(avcC))
        }
        pipe.yield(.packet(packet))
    }

    /// Current upload rate in kbps and frames dropped for congestion.
    func stats() async -> (kbps: Int, dropped: Int, congested: Bool) {
        guard let publisher = queue.sync(execute: { publisher }) else { return (0, 0, false) }
        let bytes = await publisher.bytesSent
        let dropped = await publisher.droppedFrames
        let congested = await publisher.isCongested
        let now = CFAbsoluteTimeGetCurrent()
        let kbps = Int(Double(bytes - lastBytes) * 8 / 1000 / max(0.1, now - lastBytesTime))
        lastBytes = bytes
        lastBytesTime = now
        return (max(0, kbps), dropped, congested)
    }
}
