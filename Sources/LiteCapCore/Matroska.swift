import Foundation

/// EBML element encoding helpers.
enum EBML {
    static func idBytes(_ id: UInt32) -> [UInt8] {
        if id > 0xFFFFFF { return [UInt8(id >> 24), UInt8((id >> 16) & 0xFF), UInt8((id >> 8) & 0xFF), UInt8(id & 0xFF)] }
        if id > 0xFFFF { return [UInt8(id >> 16), UInt8((id >> 8) & 0xFF), UInt8(id & 0xFF)] }
        if id > 0xFF { return [UInt8(id >> 8), UInt8(id & 0xFF)] }
        return [UInt8(id)]
    }

    /// Minimal-length variable-size integer.
    static func size(_ n: UInt64) -> [UInt8] {
        var length = 1
        while length < 8 && n >= (UInt64(1) << (7 * UInt64(length))) - 1 { length += 1 }
        return size(n, length: length)
    }

    static func size(_ n: UInt64, length: Int) -> [UInt8] {
        let marked = n | (UInt64(1) << (7 * UInt64(length)))
        return (0..<length).reversed().map { UInt8((marked >> (8 * UInt64($0))) & 0xFF) }
    }

    /// "Unknown size" marker (8 bytes) — lets a file be read even if it's never finalized.
    static let unknownSize: [UInt8] = [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

    static func element(_ id: UInt32, _ payload: Data) -> Data {
        var d = Data(idBytes(id))
        d.append(contentsOf: size(UInt64(payload.count)))
        d.append(payload)
        return d
    }

    static func master(_ id: UInt32, _ children: [Data]) -> Data {
        element(id, children.reduce(into: Data()) { $0.append($1) })
    }

    static func uint(_ id: UInt32, _ v: UInt64) -> Data {
        var bytes: [UInt8] = []
        var x = v
        repeat { bytes.insert(UInt8(x & 0xFF), at: 0); x >>= 8 } while x > 0
        return element(id, Data(bytes))
    }

    static func uint8Bytes(_ id: UInt32, _ v: UInt64) -> Data {
        var w = ByteWriter(); w.u64(v)
        return element(id, w.data)
    }

    static func float(_ id: UInt32, _ v: Double) -> Data {
        var w = ByteWriter(); w.f64(v)
        return element(id, w.data)
    }

    static func string(_ id: UInt32, _ s: String) -> Data { element(id, Data(s.utf8)) }

    /// A Void element occupying exactly `total` bytes (total >= 2, < 129).
    static func void(total: Int) -> Data {
        precondition(total >= 2 && total < 129)
        var d = Data([0xEC])
        d.append(contentsOf: size(UInt64(total - 2), length: 1))
        d.append(Data(count: total - 2))
        return d
    }
}

private enum ID {
    static let ebml: UInt32 = 0x1A45DFA3, ebmlVersion: UInt32 = 0x4286, ebmlReadVersion: UInt32 = 0x42F7
    static let ebmlMaxIDLength: UInt32 = 0x42F2, ebmlMaxSizeLength: UInt32 = 0x42F3
    static let docType: UInt32 = 0x4282, docTypeVersion: UInt32 = 0x4287, docTypeReadVersion: UInt32 = 0x4285
    static let segment: UInt32 = 0x18538067
    static let seekHead: UInt32 = 0x114D9B74, seek: UInt32 = 0x4DBB, seekID: UInt32 = 0x53AB, seekPosition: UInt32 = 0x53AC
    static let info: UInt32 = 0x1549A966, timestampScale: UInt32 = 0x2AD7B1, duration: UInt32 = 0x4489
    static let muxingApp: UInt32 = 0x4D80, writingApp: UInt32 = 0x5741
    static let tracks: UInt32 = 0x1654AE6B, trackEntry: UInt32 = 0xAE, trackNumber: UInt32 = 0xD7, trackUID: UInt32 = 0x73C5
    static let trackType: UInt32 = 0x83, flagLacing: UInt32 = 0x9C, flagDefault: UInt32 = 0x88, name: UInt32 = 0x536E
    static let language: UInt32 = 0x22B59C, codecID: UInt32 = 0x86, codecPrivate: UInt32 = 0x63A2
    static let defaultDuration: UInt32 = 0x23E383
    static let video: UInt32 = 0xE0, pixelWidth: UInt32 = 0xB0, pixelHeight: UInt32 = 0xBA
    static let audio: UInt32 = 0xE1, samplingFrequency: UInt32 = 0xB5, channels: UInt32 = 0x9F
    static let cluster: UInt32 = 0x1F43B675, timestamp: UInt32 = 0xE7, simpleBlock: UInt32 = 0xA3
    static let cues: UInt32 = 0x1C53BB6B, cuePoint: UInt32 = 0xBB, cueTime: UInt32 = 0xB3
    static let cueTrackPositions: UInt32 = 0xB7, cueTrack: UInt32 = 0xF7, cueClusterPosition: UInt32 = 0xF1
}

/// Streams H.264/HEVC + AAC tracks into a Matroska (.mkv) file.
///
/// Crash-safe like OBS's MKV recording: clusters are flushed to disk about once
/// a second (plus a 0.4 s interleave buffer), and the segment is written with "unknown size", so a file from a
/// crashed session is still playable/remuxable up to the last flushed second.
/// Not thread-safe: call from one serial queue.
public final class MatroskaWriter {
    public enum Error: Swift.Error { case cannotCreate(String) }

    private let handle: FileHandle
    private let video: VideoTrackInfo
    private let audio: [AudioTrackInfo]
    private var segmentDataStart: UInt64 = 0
    private var seekVoidOffset: UInt64 = 0
    private var durationVoidOffset: UInt64 = 0
    private var infoPosition: UInt64 = 0
    private var tracksPosition: UInt64 = 0
    private var segmentSizeOffset: UInt64 = 0

    private var baseTime: Int64?
    private var pending: [EncodedPacket] = []
    private var newestPTS: Int64 = .min
    private var clusterStart: Int64?
    private var clusterData = Data()
    private var clusterStartsWithKeyframe = false
    private var cues: [(time: Int64, position: UInt64)] = []
    private var lastTimeMs: Int64 = 0
    private var finished = false

    private static let seekVoidSize = 100
    private static let interleaveWindow: Int64 = 400_000 // µs

    public private(set) var bytesWritten: UInt64 = 0

    public init(url: URL, video: VideoTrackInfo, audio: [AudioTrackInfo]) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            throw Error.cannotCreate(url.path)
        }
        self.handle = handle
        self.video = video
        self.audio = audio
        try writeHeader()
    }

    deinit { try? handle.close() }

    // MARK: Header

    private func writeHeader() throws {
        let ebml = EBML.master(ID.ebml, [
            EBML.uint(ID.ebmlVersion, 1), EBML.uint(ID.ebmlReadVersion, 1),
            EBML.uint(ID.ebmlMaxIDLength, 4), EBML.uint(ID.ebmlMaxSizeLength, 8),
            EBML.string(ID.docType, "matroska"), EBML.uint(ID.docTypeVersion, 4), EBML.uint(ID.docTypeReadVersion, 2)
        ])
        try put(ebml)

        var segmentHeader = Data(EBML.idBytes(ID.segment))
        segmentSizeOffset = bytesWritten + UInt64(segmentHeader.count)
        segmentHeader.append(contentsOf: EBML.unknownSize)
        try put(segmentHeader)
        segmentDataStart = bytesWritten

        seekVoidOffset = bytesWritten
        try put(EBML.void(total: Self.seekVoidSize))

        infoPosition = bytesWritten - segmentDataStart
        let infoChildren = [
            EBML.uint(ID.timestampScale, 1_000_000), // 1 ms ticks
            EBML.string(ID.muxingApp, "LiteCap"),
            EBML.string(ID.writingApp, "LiteCap")
        ]
        let infoPayloadPrefix = infoChildren.reduce(into: Data()) { $0.append($1) }
        let durationPlaceholder = EBML.void(total: 11)
        var info = Data(EBML.idBytes(ID.info))
        info.append(contentsOf: EBML.size(UInt64(infoPayloadPrefix.count + durationPlaceholder.count)))
        info.append(infoPayloadPrefix)
        durationVoidOffset = bytesWritten + UInt64(info.count)
        info.append(durationPlaceholder)
        try put(info)

        tracksPosition = bytesWritten - segmentDataStart
        var entries: [Data] = []
        var videoChildren = [
            EBML.uint(ID.trackNumber, 1),
            EBML.uint(ID.trackUID, UInt64.random(in: 1...UInt64(Int64.max))),
            EBML.uint(ID.trackType, 1),
            EBML.uint(ID.flagLacing, 0),
            EBML.string(ID.language, "und"),
            EBML.string(ID.codecID, video.codec == .hevc ? "V_MPEGH/ISO/HEVC" : "V_MPEG4/ISO/AVC"),
            EBML.element(ID.codecPrivate, video.codecPrivate),
            EBML.master(ID.video, [
                EBML.uint(ID.pixelWidth, UInt64(video.width)),
                EBML.uint(ID.pixelHeight, UInt64(video.height))
            ])
        ]
        if video.fps > 0 {
            videoChildren.append(EBML.uint(ID.defaultDuration, UInt64(1_000_000_000 / video.fps)))
        }
        entries.append(EBML.master(ID.trackEntry, videoChildren))
        for (i, track) in audio.enumerated() {
            entries.append(EBML.master(ID.trackEntry, [
                EBML.uint(ID.trackNumber, UInt64(2 + i)),
                EBML.uint(ID.trackUID, UInt64.random(in: 1...UInt64(Int64.max))),
                EBML.uint(ID.trackType, 2),
                EBML.uint(ID.flagLacing, 0),
                EBML.uint(ID.flagDefault, i == 0 ? 1 : 0),
                EBML.string(ID.name, track.name),
                EBML.string(ID.language, "und"),
                EBML.string(ID.codecID, "A_AAC"),
                EBML.element(ID.codecPrivate, track.codecPrivate),
                EBML.master(ID.audio, [
                    EBML.float(ID.samplingFrequency, track.sampleRate),
                    EBML.uint(ID.channels, UInt64(track.channels))
                ])
            ]))
        }
        try put(EBML.master(ID.tracks, entries))
    }

    // MARK: Packets

    public func write(_ packet: EncodedPacket) throws {
        guard !finished else { return }
        if baseTime == nil {
            // Start at the first video keyframe.
            guard packet.kind == .video, packet.isKeyframe else { return }
            baseTime = packet.pts
        }
        guard let base = baseTime, packet.pts >= base else { return }
        if case .audio(let index) = packet.kind, index >= audio.count { return }

        // Keep a short window so audio and video blocks land in time order.
        let insertAt = pending.lastIndex(where: { $0.pts <= packet.pts }).map { $0 + 1 } ?? 0
        pending.insert(packet, at: insertAt)
        newestPTS = max(newestPTS, packet.pts)
        while let first = pending.first, first.pts <= newestPTS - Self.interleaveWindow {
            pending.removeFirst()
            try emit(first, base: base)
        }
    }

    private func emit(_ packet: EncodedPacket, base: Int64) throws {
        let t = (packet.pts - base) / 1000
        let isVideoKey = packet.kind == .video && packet.isKeyframe
        if let start = clusterStart {
            let rel = t - start
            // Close about once per second (or early on a keyframe) so a crash loses little.
            if (isVideoKey && rel >= 500) || rel >= 1000 || rel > 30_000 || rel < -30_000 || clusterData.count > 16 * 1024 * 1024 {
                try closeCluster()
            }
        }
        if clusterStart == nil {
            clusterStart = t
            clusterStartsWithKeyframe = isVideoKey
            clusterData = EBML.uint(ID.timestamp, UInt64(max(0, t)))
        }
        let trackNumber: UInt8
        switch packet.kind {
        case .video: trackNumber = 1
        case .audio(let index): trackNumber = UInt8(2 + index)
        }
        var block = ByteWriter(capacity: packet.data.count + 4)
        block.u8(0x80 | trackNumber)
        block.u16(UInt16(bitPattern: Int16(clamping: t - (clusterStart ?? t))))
        let keyFlag: UInt8 = (packet.kind == .video ? packet.isKeyframe : true) ? 0x80 : 0x00
        block.u8(keyFlag)
        block.bytes(packet.data)
        clusterData.append(EBML.element(ID.simpleBlock, block.data))
        lastTimeMs = max(lastTimeMs, t)
    }

    private func closeCluster() throws {
        guard let start = clusterStart else { return }
        let position = bytesWritten - segmentDataStart
        try put(EBML.element(ID.cluster, clusterData))
        if clusterStartsWithKeyframe { cues.append((start, position)) }
        clusterStart = nil
        clusterData = Data()
    }

    // MARK: Finish

    /// Flushes everything and writes the seek index and duration. Returns the file size.
    @discardableResult
    public func finish() throws -> UInt64 {
        guard !finished else { return bytesWritten }
        finished = true
        if let base = baseTime {
            for packet in pending { try emit(packet, base: base) }
        }
        pending.removeAll()
        try closeCluster()

        let cuesPosition = bytesWritten - segmentDataStart
        let points = cues.map { cue in
            EBML.master(ID.cuePoint, [
                EBML.uint(ID.cueTime, UInt64(max(0, cue.time))),
                EBML.master(ID.cueTrackPositions, [
                    EBML.uint(ID.cueTrack, 1),
                    EBML.uint(ID.cueClusterPosition, cue.position)
                ])
            ])
        }
        if !points.isEmpty { try put(EBML.master(ID.cues, points)) }
        let end = bytesWritten

        // Seek head into the reserved space.
        var seeks = [
            seekEntry(ID.info, infoPosition),
            seekEntry(ID.tracks, tracksPosition)
        ]
        if !points.isEmpty { seeks.append(seekEntry(ID.cues, cuesPosition)) }
        var head = EBML.master(ID.seekHead, seeks)
        let spare = Self.seekVoidSize - head.count
        if spare >= 2 { head.append(EBML.void(total: spare)) }
        if head.count == Self.seekVoidSize { try patch(at: seekVoidOffset, head) }

        // Duration (ms, as a float).
        let frameMs = video.fps > 0 ? 1000 / video.fps : 0
        try patch(at: durationVoidOffset, EBML.float(ID.duration, Double(lastTimeMs) + frameMs))

        // Segment size.
        try patch(at: segmentSizeOffset, Data(EBML.size(end - segmentDataStart, length: 8)))
        try handle.seek(toOffset: end)
        try handle.synchronize()
        try handle.close()
        return end
    }

    private func seekEntry(_ id: UInt32, _ position: UInt64) -> Data {
        EBML.master(ID.seek, [
            EBML.element(ID.seekID, Data(EBML.idBytes(id))),
            EBML.uint8Bytes(ID.seekPosition, position)
        ])
    }

    private func put(_ data: Data) throws {
        try handle.write(contentsOf: data)
        bytesWritten += UInt64(data.count)
    }

    private func patch(at offset: UInt64, _ data: Data) throws {
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
    }
}
