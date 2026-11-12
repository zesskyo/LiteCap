import Foundation

// MARK: - Transport

/// A byte pipe (TCP or TLS). macOS uses Network.framework; tests use POSIX sockets.
public protocol ByteTransport: AnyObject, Sendable {
    func connect(host: String, port: Int, tls: Bool) async throws
    /// Queues bytes for sending, in call order. `completion` fires once written.
    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void)
    /// Returns at least one byte, or throws when the connection ends.
    func receive() async throws -> Data
    func close()
}

// MARK: - URL

public struct RTMPURL: Sendable, Equatable {
    public var tls: Bool
    public var host: String
    public var port: Int
    public var app: String
    public var tcURL: String

    /// Parses `rtmp://host[:port]/app` or `rtmps://…`.
    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let rest: Substring
        if lower.hasPrefix("rtmps://") {
            tls = true
            rest = trimmed.dropFirst(8)
        } else if lower.hasPrefix("rtmp://") {
            tls = false
            rest = trimmed.dropFirst(7)
        } else {
            return nil
        }
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let hostPort = rest[..<slash]
        var app = String(rest[rest.index(after: slash)...])
        while app.hasSuffix("/") { app.removeLast() }
        guard !hostPort.isEmpty, !app.isEmpty else { return nil }
        if let colon = hostPort.lastIndex(of: ":"), let p = Int(hostPort[hostPort.index(after: colon)...]) {
            host = String(hostPort[..<colon])
            port = p
        } else {
            host = String(hostPort)
            port = tls ? 443 : 1935
        }
        self.app = app
        let defaultPort = tls ? 443 : 1935
        let portPart = port == defaultPort ? "" : ":\(port)"
        tcURL = "\(tls ? "rtmps" : "rtmp")://\(host)\(portPart)/\(app)"
    }
}

// MARK: - Chunking

public struct RTMPMessage: Sendable {
    public var type: UInt8
    public var streamID: UInt32
    public var timestamp: UInt32
    public var payload: Data
}

public enum RTMPMessageType {
    public static let setChunkSize: UInt8 = 1
    public static let abort: UInt8 = 2
    public static let acknowledgement: UInt8 = 3
    public static let userControl: UInt8 = 4
    public static let windowAckSize: UInt8 = 5
    public static let setPeerBandwidth: UInt8 = 6
    public static let audio: UInt8 = 8
    public static let video: UInt8 = 9
    public static let dataAMF0: UInt8 = 18
    public static let commandAMF0: UInt8 = 20
}

public struct ChunkWriter: Sendable {
    public var chunkSize = 128
    public init() {}

    /// Encodes one message with a type-0 header (absolute timestamp) and type-3 continuations.
    public func encode(csid: UInt8, type: UInt8, streamID: UInt32, timestamp: UInt32, payload: Data) -> Data {
        precondition(csid >= 2 && csid < 64)
        let extended = timestamp >= 0xFFFFFF
        var w = ByteWriter(capacity: payload.count + 16 + payload.count / max(chunkSize, 1) * 5)
        w.u8(csid)
        w.u24(extended ? 0xFFFFFF : timestamp)
        w.u24(UInt32(payload.count))
        w.u8(type)
        w.u32le(streamID)
        if extended { w.u32(timestamp) }
        var offset = payload.startIndex
        var first = true
        while first || offset < payload.endIndex {
            if !first {
                w.u8(0xC0 | csid)
                if extended { w.u32(timestamp) }
            }
            let end = min(offset + chunkSize, payload.endIndex)
            w.bytes(payload[offset..<end])
            offset = end
            first = false
        }
        return w.data
    }
}

public struct ChunkReader: Sendable {
    public enum Error: Swift.Error { case invalidChunk }

    public var chunkSize = 128
    private var buffer = Data()

    private struct StreamState {
        var timestamp: UInt32 = 0
        var delta: UInt32 = 0
        var length = 0
        var type: UInt8 = 0
        var streamID: UInt32 = 0
        var extended = false
        var payload = Data()
    }

    private var streams: [UInt32: StreamState] = [:]

    public init() {}

    public mutating func feed(_ data: Data) throws -> [RTMPMessage] {
        buffer.append(data)
        var messages: [RTMPMessage] = []
        while true {
            var reader = ByteReader(buffer)
            let result: RTMPMessage??
            do {
                result = try parseChunk(&reader)
            } catch ByteReader.Error.truncated {
                break
            }
            buffer = Data(buffer[reader.offset...])
            if let message = result ?? nil { messages.append(message) }
            if buffer.isEmpty { break }
        }
        return messages
    }

    /// Returns `.some(nil)` when a chunk was consumed but the message isn't complete.
    private mutating func parseChunk(_ r: inout ByteReader) throws -> RTMPMessage?? {
        let b0 = try r.u8()
        let fmt = b0 >> 6
        var csid = UInt32(b0 & 0x3F)
        if csid == 0 {
            csid = 64 + UInt32(try r.u8())
        } else if csid == 1 {
            let lo = UInt32(try r.u8()), hi = UInt32(try r.u8())
            csid = 64 + lo + hi * 256
        }
        var s = streams[csid] ?? StreamState()
        let startingMessage = s.payload.isEmpty
        switch fmt {
        case 0:
            var ts = try r.u24()
            s.length = Int(try r.u24())
            s.type = try r.u8()
            s.streamID = try r.u32le()
            s.extended = ts == 0xFFFFFF
            if s.extended { ts = try r.u32() }
            s.timestamp = ts
            s.delta = 0
        case 1:
            var d = try r.u24()
            s.length = Int(try r.u24())
            s.type = try r.u8()
            s.extended = d == 0xFFFFFF
            if s.extended { d = try r.u32() }
            s.delta = d
            if startingMessage { s.timestamp &+= d }
        case 2:
            var d = try r.u24()
            s.extended = d == 0xFFFFFF
            if s.extended { d = try r.u32() }
            s.delta = d
            if startingMessage { s.timestamp &+= d }
        default:
            if s.extended { _ = try r.u32() }
            if startingMessage { s.timestamp &+= s.delta }
        }
        guard s.length >= 0, s.length < 16 * 1024 * 1024 else { throw Error.invalidChunk }
        let need = min(chunkSize, s.length - s.payload.count)
        s.payload.append(try r.bytes(need))
        if s.payload.count >= s.length {
            let message = RTMPMessage(type: s.type, streamID: s.streamID, timestamp: s.timestamp, payload: s.payload)
            s.payload = Data()
            streams[csid] = s
            return .some(message)
        }
        streams[csid] = s
        return .some(nil)
    }
}

// MARK: - Publisher

private final class SendCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _queued = 0
    private var _sent: Int64 = 0
    var queued: Int { lock.withLock { _queued } }
    var sent: Int64 { lock.withLock { _sent } }
    func add(_ n: Int) { lock.withLock { _queued += n } }
    func done(_ n: Int) { lock.withLock { _queued -= n; _sent += Int64(n) } }
}

/// Publishes one live stream to an RTMP server.
public actor RTMPPublisher {
    public enum Error: Swift.Error, LocalizedError {
        case badURL
        case handshakeFailed
        case rejected(String)
        case timeout(String)
        case disconnected

        public var errorDescription: String? {
            switch self {
            case .badURL: return "Server URL must look like rtmp://host/app"
            case .handshakeFailed: return "The server didn't complete the RTMP handshake."
            case .rejected(let why): return "Server refused the stream: \(why)"
            case .timeout(let step): return "Timed out waiting for the server (\(step))."
            case .disconnected: return "Connection closed."
            }
        }
    }

    private enum CSID {
        static let control: UInt8 = 2
        static let command: UInt8 = 3
        static let audio: UInt8 = 4
        static let data: UInt8 = 5
        static let video: UInt8 = 6
    }

    private let transport: ByteTransport
    private let url: RTMPURL
    private let streamKey: String
    private var writer = ChunkWriter()
    private var reader = ChunkReader()
    private var streamID: UInt32 = 0
    private var nextTransaction: Double = 1
    private var pendingResults: [Double: CheckedContinuation<[AMF0], Swift.Error>] = [:]
    private var statusWaiter: CheckedContinuation<AMF0, Swift.Error>?
    private var readTask: Task<Void, Never>?
    private var baseTime: Int64?
    private var receivedBytes: Int64 = 0
    private var lastAck: Int64 = 0
    private var ackWindow: Int64 = 2_500_000
    private var closed = false
    private var droppingVideo = false
    private let counter = SendCounter()
    private var maxQueuedBytes = 3_000_000

    public private(set) var droppedFrames = 0
    public var bytesSent: Int64 { counter.sent }
    private var disconnectHandler: (@Sendable (Swift.Error) -> Void)?

    public init(transport: ByteTransport, serverURL: String, streamKey: String) throws {
        guard let url = RTMPURL(serverURL) else { throw Error.badURL }
        self.transport = transport
        self.url = url
        self.streamKey = streamKey
    }

    public func setDisconnectHandler(_ handler: @escaping @Sendable (Swift.Error) -> Void) {
        disconnectHandler = handler
    }

    /// Roughly how much unsent data to tolerate before dropping video frames (≈ 3 s).
    public func setBitrate(totalKbps: Int) {
        maxQueuedBytes = max(500_000, totalKbps * 1000 / 8 * 3)
    }

    // MARK: Connect

    public func connect(timeout seconds: Double = 10) async throws {
        try await transport.connect(host: url.host, port: url.port, tls: url.tls)
        let leftover = try await withTimeout(seconds, step: "handshake") { [self] in try await handshake() }
        startReading(initial: leftover)

        writer.chunkSize = 4096
        sendRaw(csid: CSID.control, type: RTMPMessageType.setChunkSize, streamID: 0, timestamp: 0,
                payload: { var w = ByteWriter(); w.u32(4096); return w.data }())

        let connectReply = try await withTimeout(seconds, step: "connect") { [self] in
            try await command("connect", [.object([
                ("app", .string(url.app)),
                ("type", .string("nonprivate")),
                ("flashVer", .string("FMLE/3.0 (compatible; FMSc/1.0)")),
                ("swfUrl", .string(url.tcURL)),
                ("tcUrl", .string(url.tcURL))
            ])])
        }
        if let info = connectReply.dropFirst().first(where: { $0["code"] != nil }),
           let code = info["code"]?.stringValue, code != "NetConnection.Connect.Success" {
            throw Error.rejected(info["description"]?.stringValue ?? code)
        }

        sendCommand("releaseStream", transaction: nextTxn(), [.null, .string(streamKey)])
        sendCommand("FCPublish", transaction: nextTxn(), [.null, .string(streamKey)])
        let created = try await withTimeout(seconds, step: "createStream") { [self] in
            try await command("createStream", [.null])
        }
        guard let id = created.last?.numberValue else { throw Error.rejected("createStream returned no stream id") }
        streamID = UInt32(id)

        let status = try await withTimeout(seconds, step: "publish") { [self] in try await publishAndWait() }
        let code = status["code"]?.stringValue ?? ""
        guard code == "NetStream.Publish.Start" else {
            throw Error.rejected(status["description"]?.stringValue ?? code)
        }
    }

    private func publishAndWait() async throws -> AMF0 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AMF0, Swift.Error>) in
            statusWaiter = continuation
            sendCommand("publish", transaction: 0, [.null, .string(streamKey), .string("live")], streamID: streamID)
        }
    }

    private func handshake() async throws -> Data {
        var c1 = ByteWriter(capacity: 1537)
        c1.u8(0x03)
        c1.u32(0)
        c1.u32(0)
        c1.bytes((0..<1528).map { _ in UInt8.random(in: 0...255) })
        transport.send(c1.data) { _ in }

        var received = Data()
        while received.count < 1 + 1536 + 1536 {
            received.append(try await transport.receive())
        }
        guard received[received.startIndex] == 0x03 else { throw Error.handshakeFailed }
        let s1 = received.subdata(in: (received.startIndex + 1)..<(received.startIndex + 1537))
        transport.send(s1) { _ in } // C2 echoes S1
        return Data(received.dropFirst(1 + 1536 + 1536))
    }

    // MARK: Media

    public func sendMetadata(width: Int, height: Int, fps: Double, videoKbps: Int, audioKbps: Int) {
        let body = FLV.metadata(width: width, height: height, fps: fps, videoKbps: videoKbps, audioKbps: audioKbps)
        sendRaw(csid: CSID.data, type: RTMPMessageType.dataAMF0, streamID: streamID, timestamp: 0, payload: body)
    }

    public func sendVideoHeader(avcC: Data) {
        sendRaw(csid: CSID.video, type: RTMPMessageType.video, streamID: streamID, timestamp: 0,
                payload: FLV.avcSequenceHeader(avcC))
    }

    /// Track 0 is the main stream audio; track 1+ are extra tracks (Twitch VOD track).
    public func sendAudioHeader(asc: Data, track: Int) {
        let body = track == 0
            ? FLV.aacSequenceHeader(asc)
            : FLV.multitrackAAC(asc, trackID: UInt8(track), isSequenceHeader: true)
        sendRaw(csid: CSID.audio, type: RTMPMessageType.audio, streamID: streamID, timestamp: 0, payload: body)
    }

    public func send(_ packet: EncodedPacket) {
        guard !closed else { return }
        if baseTime == nil { baseTime = packet.pts }
        let ms = max(0, (packet.pts - (baseTime ?? packet.pts)) / 1000)
        let timestamp = UInt32(truncatingIfNeeded: ms)
        let queued = counter.queued
        switch packet.kind {
        case .video:
            if queued > maxQueuedBytes { droppingVideo = true }
            if droppingVideo {
                if packet.isKeyframe && queued < maxQueuedBytes / 2 {
                    droppingVideo = false
                } else {
                    droppedFrames += 1
                    return
                }
            }
            sendRaw(csid: CSID.video, type: RTMPMessageType.video, streamID: streamID, timestamp: timestamp,
                    payload: FLV.avcFrame(packet.data, keyframe: packet.isKeyframe))
        case .audio(let index):
            if queued > maxQueuedBytes * 3 { return }
            let body = index == 0
                ? FLV.aacFrame(packet.data)
                : FLV.multitrackAAC(packet.data, trackID: UInt8(index), isSequenceHeader: false)
            sendRaw(csid: CSID.audio, type: RTMPMessageType.audio, streamID: streamID, timestamp: timestamp, payload: body)
        }
    }

    /// True while frames are being dropped because the network is too slow.
    public var isCongested: Bool { droppingVideo }

    public func close() {
        guard !closed else { return }
        if streamID != 0 {
            sendCommand("FCUnpublish", transaction: nextTxn(), [.null, .string(streamKey)])
            sendCommand("deleteStream", transaction: nextTxn(), [.null, .number(Double(streamID))])
        }
        closed = true
        readTask?.cancel()
        failWaiters(Error.disconnected)
        let transport = self.transport
        // Give the goodbye messages a moment to flush.
        Task.detached {
            try? await Task.sleep(nanoseconds: 200_000_000)
            transport.close()
        }
    }

    // MARK: Plumbing

    private func nextTxn() -> Double {
        nextTransaction += 1
        return nextTransaction
    }

    private func sendRaw(csid: UInt8, type: UInt8, streamID: UInt32, timestamp: UInt32, payload: Data) {
        let bytes = writer.encode(csid: csid, type: type, streamID: streamID, timestamp: timestamp, payload: payload)
        let count = bytes.count
        counter.add(count)
        let counter = self.counter
        transport.send(bytes) { [weak self] error in
            counter.done(count)
            if let error, let self { Task { await self.connectionFailed(error) } }
        }
    }

    private func sendCommand(_ name: String, transaction: Double, _ args: [AMF0], streamID: UInt32 = 0) {
        let payload = AMF0.encode([.string(name), .number(transaction)] + args)
        sendRaw(csid: CSID.command, type: RTMPMessageType.commandAMF0, streamID: streamID, timestamp: 0, payload: payload)
    }

    private func command(_ name: String, _ args: [AMF0]) async throws -> [AMF0] {
        let txn = name == "connect" ? 1 : nextTxn()
        return try await withCheckedThrowingContinuation { continuation in
            pendingResults[txn] = continuation
            sendCommand(name, transaction: txn, args)
        }
    }

    private func startReading(initial: Data) {
        readTask = Task { [weak self, transport] in
            var chunk = initial
            do {
                while !Task.isCancelled {
                    if !chunk.isEmpty { try await self?.ingest(chunk) }
                    chunk = try await transport.receive()
                }
            } catch {
                await self?.connectionFailed(error)
            }
        }
    }

    private func ingest(_ data: Data) throws {
        receivedBytes += Int64(data.count)
        if receivedBytes - lastAck >= ackWindow / 2 {
            lastAck = receivedBytes
            var w = ByteWriter()
            w.u32(UInt32(truncatingIfNeeded: receivedBytes))
            sendRaw(csid: CSID.control, type: RTMPMessageType.acknowledgement, streamID: 0, timestamp: 0, payload: w.data)
        }
        for message in try reader.feed(data) { handle(message) }
    }

    private func handle(_ message: RTMPMessage) {
        var r = ByteReader(message.payload)
        switch message.type {
        case RTMPMessageType.setChunkSize:
            if let size = try? r.u32() { reader.chunkSize = Int(size & 0x7FFF_FFFF) }
        case RTMPMessageType.windowAckSize:
            if let size = try? r.u32() { ackWindow = Int64(size) }
        case RTMPMessageType.userControl:
            // Ping request (6) → pong (7) with the same timestamp.
            if let event = try? r.u16(), event == 6, let ts = try? r.u32() {
                var w = ByteWriter()
                w.u16(7); w.u32(ts)
                sendRaw(csid: CSID.control, type: RTMPMessageType.userControl, streamID: 0, timestamp: 0, payload: w.data)
            }
        case RTMPMessageType.commandAMF0:
            guard let values = try? AMF0.decodeAll(message.payload),
                  let name = values.first?.stringValue else { return }
            let txn = values.count > 1 ? values[1].numberValue ?? 0 : 0
            switch name {
            case "_result", "_error":
                if let waiter = pendingResults.removeValue(forKey: txn) {
                    if name == "_error" {
                        let info = values.dropFirst(2).first { $0["code"] != nil }
                        waiter.resume(throwing: Error.rejected(
                            info?["description"]?.stringValue ?? info?["code"]?.stringValue ?? "error"
                        ))
                    } else {
                        waiter.resume(returning: Array(values.dropFirst(2)))
                    }
                }
            case "onStatus":
                if let info = values.dropFirst(2).first(where: { $0["code"] != nil }) {
                    if let waiter = statusWaiter {
                        statusWaiter = nil
                        waiter.resume(returning: info)
                    } else if let code = info["code"]?.stringValue,
                              code.contains("Failed") || code.contains("Closed") || code.contains("Error") {
                        connectionFailed(Error.rejected(info["description"]?.stringValue ?? code))
                    }
                }
            default:
                break
            }
        default:
            break
        }
    }

    private func connectionFailed(_ error: Swift.Error) {
        guard !closed else { return }
        closed = true
        failWaiters(error)
        transport.close()
        disconnectHandler?(error)
    }

    private func abort(_ error: Swift.Error) {
        failWaiters(error)
        transport.close()
    }

    private func failWaiters(_ error: Swift.Error) {
        pendingResults.values.forEach { $0.resume(throwing: error) }
        pendingResults.removeAll()
        statusWaiter?.resume(throwing: error)
        statusWaiter = nil
    }

    private func withTimeout<T: Sendable>(_ seconds: Double, step: String,
                                          _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                // Unblock the other child (it may be waiting on a reply that never comes).
                await self?.abort(Error.timeout(step))
                throw Error.timeout(step)
            }
            guard let result = try await group.next() else { throw Error.timeout(step) }
            group.cancelAll()
            return result
        }
    }
}
