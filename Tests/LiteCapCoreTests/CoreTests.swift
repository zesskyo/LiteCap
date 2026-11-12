import Foundation
import XCTest
@testable import LiteCapCore
#if canImport(Glibc)
import Glibc
#endif

final class ProtocolTests: XCTestCase {
    func testEBMLSizes() {
        XCTAssertEqual(EBML.size(126), [0xFE])
        XCTAssertEqual(EBML.size(127), [0x40, 0x7F])
        XCTAssertEqual(EBML.size(5, length: 8), [0x01, 0, 0, 0, 0, 0, 0, 5])
    }

    func testAudioSpecificConfig() {
        XCTAssertEqual(AAC.audioSpecificConfig(), Data([0x11, 0x90])) // AAC-LC, 48 kHz, stereo
        XCTAssertEqual(AAC.audioSpecificConfig(sampleRate: 44_100, channels: 1), Data([0x12, 0x08]))
    }

    func testAMF0RoundTrip() throws {
        let values: [AMF0] = [
            .string("connect"), .number(1),
            .object([("app", .string("app")), ("n", .number(2.5)), ("b", .bool(true))]),
            .null, .ecmaArray([("x", .strictArray([.number(1), .string("y")]))])
        ]
        XCTAssertEqual(try AMF0.decodeAll(AMF0.encode(values)), values)
    }

    func testRTMPURL() {
        XCTAssertEqual(RTMPURL("rtmp://live.twitch.tv/app"), RTMPURL("rtmp://live.twitch.tv:1935/app/"))
        XCTAssertEqual(RTMPURL("rtmps://a.rtmp.youtube.com/live2")?.port, 443)
        XCTAssertEqual(RTMPURL("rtmp://example.com:1940/live/sub")?.app, "live/sub")
        XCTAssertNil(RTMPURL("http://example.com/app"))
        XCTAssertNil(RTMPURL("rtmp://example.com"))
    }

    func testChunkRoundTrip() throws {
        for chunkSize in [128, 4096, 60_000] {
            var writer = ChunkWriter()
            writer.chunkSize = chunkSize
            var reader = ChunkReader()
            reader.chunkSize = chunkSize
            let payloads = (0..<20).map { i in Data((0..<(i * 997 % 9000)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ i) }) }
            var stream = Data()
            for (i, payload) in payloads.enumerated() {
                stream.append(writer.encode(csid: UInt8(3 + i % 4), type: 9, streamID: 1,
                                            timestamp: i == 7 ? 0x1_000_000 : UInt32(i * 33), payload: payload))
            }
            var messages: [RTMPMessage] = []
            var offset = 0
            while offset < stream.count {
                let n = min(777, stream.count - offset)
                messages += try reader.feed(stream.subdata(in: offset..<(offset + n)))
                offset += n
            }
            XCTAssertEqual(messages.map(\.payload), payloads, "chunk size \(chunkSize)")
            XCTAssertEqual(messages[7].timestamp, 0x1_000_000, "extended timestamp")
        }
    }

    func testVODTrackTagMatchesOBS() {
        XCTAssertEqual(FLV.multitrackAAC(Data([0xAA]), trackID: 1, isSequenceHeader: false),
                       Data([0x95, 0x01, 0x6D, 0x70, 0x34, 0x61, 0x01, 0xAA]))
        XCTAssertEqual(FLV.multitrackAAC(Data([0x11, 0x90]), trackID: 1, isSequenceHeader: true),
                       Data([0x95, 0x00, 0x6D, 0x70, 0x34, 0x61, 0x01, 0x11, 0x90]))
    }

    func testAudioRing() {
        let ring = AudioRing(capacityFrames: 4800, targetLatencyFrames: 100, maxLatencyFrames: 1000)
        var left = [Float](repeating: -1, count: 300), right = left
        let source = (0..<300).map(Float.init)
        source.withUnsafeBufferPointer { ring.write(left: $0.baseAddress!, right: $0.baseAddress!, frames: 300) }
        ring.read(left: &left, right: &right, frames: 200)
        XCTAssertEqual(left[0], 0)
        XCTAssertEqual(left[199], 199)
        XCTAssertEqual(ring.fillFrames, 100)
        for _ in 0..<10 {
            source.withUnsafeBufferPointer { ring.write(left: $0.baseAddress!, right: $0.baseAddress!, frames: 300) }
        }
        XCTAssertLessThanOrEqual(ring.fillFrames, 1000, "drift is capped")
    }
}

// MARK: - Matroska

final class MatroskaTests: XCTestCase {
    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("litecap-\(UUID().uuidString)-\(name)")
    }

    /// Structural check that needs no external tools.
    func testFinishedFileStructure() throws {
        let url = tempURL("structure.mkv")
        defer { try? FileManager.default.removeItem(at: url) }
        let video = VideoTrackInfo(codec: .h264, width: 640, height: 360, fps: 30, codecPrivate: Data([1, 2, 3]))
        let writer = try MatroskaWriter(url: url, video: video, audio: [AudioTrackInfo(name: "Track 1")])
        for i in 0..<90 {
            try writer.write(EncodedPacket(kind: .video, pts: Int64(i) * 33_333, isKeyframe: i % 30 == 0, data: Data(repeating: 7, count: 100)))
        }
        for i in 0..<140 {
            try writer.write(EncodedPacket(kind: .audio(index: 0), pts: Int64(i) * 21_333, isKeyframe: true, data: Data(repeating: 9, count: 20)))
        }
        let size = try writer.finish()
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(UInt64(bytes.count), size)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x1A, 0x45, 0xDF, 0xA3], "EBML magic")
        XCTAssertNotNil(bytes.range(of: Data([0x1C, 0x53, 0xBB, 0x6B])), "has Cues")
        XCTAssertNotNil(bytes.range(of: Data([0x11, 0x4D, 0x9B, 0x74])), "has SeekHead")
        XCTAssertNotNil(bytes.range(of: Data([0x44, 0x89, 0x88])), "has Duration")
        XCTAssertNil(bytes.range(of: Data([0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF])), "segment size patched")
    }

    /// Real H.264/AAC through the muxer, validated by ffmpeg (skipped if ffmpeg isn't installed).
    func testFFmpegDecodesRecording() throws {
        let fixtures = try Fixtures.make()
        let url = tempURL("real.mkv")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try MatroskaWriter(url: url, video: fixtures.videoInfo,
                                        audio: [AudioTrackInfo(name: "Track 1"), AudioTrackInfo(name: "Track 2")])
        for packet in fixtures.packets(audioTracks: 2) { try writer.write(packet) }
        try writer.finish()
        let probe = try Fixtures.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_name:stream_tags=title",
                                      "-of", "csv=p=0", url.path])
        XCTAssertEqual(probe.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n"),
                       ["h264", "aac,Track 1", "aac,Track 2"])
        XCTAssertEqual(try Fixtures.run(["ffmpeg", "-v", "error", "-i", url.path, "-map", "0", "-f", "null", "-"]), "")
    }

    /// A file that is never finished (app crashed) must still play.
    func testCrashedRecordingIsPlayable() throws {
        let fixtures = try Fixtures.make()
        let url = tempURL("crash.mkv")
        defer { try? FileManager.default.removeItem(at: url) }
        var writer: MatroskaWriter? = try MatroskaWriter(url: url, video: fixtures.videoInfo, audio: [AudioTrackInfo(name: "Track 1")])
        for packet in fixtures.packets(audioTracks: 1) { try writer!.write(packet) }
        writer = nil // no finish()
        _ = writer
        let frames = try Fixtures.run(["ffprobe", "-v", "error", "-count_frames", "-select_streams", "v",
                                       "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", url.path])
        let count = Int(frames.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertGreaterThanOrEqual(count, 80, "at most ~1.3 s of 4 s lost")
    }
}

// MARK: - RTMP against ffmpeg's RTMP server (Linux CI)

#if os(Linux)
final class RTMPIntegrationTests: XCTestCase {
    func testPublishToFFmpeg() async throws {
        let fixtures = try Fixtures.make()
        let port = Int.random(in: 20_000...40_000)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("rtmp-\(UUID().uuidString).flv")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["ffmpeg", "-v", "error", "-y", "-listen", "1", "-f", "flv",
                            "-i", "rtmp://127.0.0.1:\(port)/app/key", "-map", "0", "-c", "copy", output.path]
        try server.run()
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let publisher = try RTMPPublisher(transport: PosixTransport(), serverURL: "rtmp://127.0.0.1:\(port)/app", streamKey: "key")
        try await publisher.connect()
        await publisher.sendMetadata(width: 640, height: 360, fps: 30, videoKbps: 1000, audioKbps: 128)
        await publisher.sendVideoHeader(avcC: fixtures.videoInfo.codecPrivate)
        await publisher.sendAudioHeader(asc: AAC.audioSpecificConfig(), track: 0)
        for packet in fixtures.packets(audioTracks: 1) { await publisher.send(packet) }
        try await Task.sleep(nanoseconds: 500_000_000)
        await publisher.close()
        server.waitUntilExit()

        let probe = try Fixtures.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_name", "-of", "csv=p=0", output.path])
        XCTAssertEqual(probe.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n"), ["h264", "aac"])
    }
}

private final class PosixTransport: ByteTransport, @unchecked Sendable {
    private var fd: Int32 = -1
    private let sendQueue = DispatchQueue(label: "send")

    func connect(host: String, port: Int, tls: Bool) async throws {
        fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 { throw RTMPPublisher.Error.disconnected }
    }

    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        sendQueue.async { [fd] in
            let ok = data.withUnsafeBytes { buffer -> Bool in
                var offset = 0
                while offset < buffer.count {
                    let n = Glibc.send(fd, buffer.baseAddress! + offset, buffer.count - offset, Int32(MSG_NOSIGNAL))
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
            completion(ok ? nil : RTMPPublisher.Error.disconnected)
        }
    }

    func receive() async throws -> Data {
        let fd = self.fd
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                var buffer = [UInt8](repeating: 0, count: 65_536)
                let n = recv(fd, &buffer, buffer.count, 0)
                if n <= 0 { continuation.resume(throwing: RTMPPublisher.Error.disconnected) }
                else { continuation.resume(returning: Data(buffer[0..<n])) }
            }
        }
    }

    func close() {
        if fd >= 0 {
            shutdown(fd, Int32(SHUT_RDWR))
            Glibc.close(fd)
            fd = -1
        }
    }
}
#endif

// MARK: - Fixtures (real H.264 + AAC made by ffmpeg)

enum Fixtures {
    struct Media {
        let videoInfo: VideoTrackInfo
        let frames: [(Data, Bool)]
        let aacFrames: [Data]

        func packets(audioTracks: Int) -> [EncodedPacket] {
            let t0: Int64 = 5_000_000_000
            var packets: [EncodedPacket] = []
            for (i, frame) in frames.enumerated() {
                packets.append(EncodedPacket(kind: .video, pts: t0 + Int64(i) * 1_000_000 / 30, isKeyframe: frame.1, data: frame.0))
            }
            for track in 0..<audioTracks {
                for (i, frame) in aacFrames.enumerated() {
                    packets.append(EncodedPacket(kind: .audio(index: track),
                                                 pts: t0 - 20_000 + Int64(i) * 1024 * 1_000_000 / 48_000,
                                                 isKeyframe: true, data: frame))
                }
            }
            // Arrival order like real encoders: video a little late.
            return packets.sorted { ($0.pts + ($0.kind == .video ? 30_000 : 0)) < ($1.pts + ($1.kind == .video ? 30_000 : 0)) }
        }
    }

    private static var cached: Media?

    static func make() throws -> Media {
        if let cached { return cached }
        guard (try? run(["ffmpeg", "-version"])) != nil else { throw XCTSkip("ffmpeg not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("litecap-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let h264 = dir.appendingPathComponent("v.h264").path, aac = dir.appendingPathComponent("a.aac").path
        _ = try run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30", "-t", "4",
                     "-c:v", "libx264", "-bf", "0", "-g", "60", "-x264-params", "aud=1", "-pix_fmt", "yuv420p", "-f", "h264", h264])
        _ = try run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "4",
                     "-ac", "2", "-c:a", "aac", "-b:a", "128k", "-f", "adts", aac])

        // Annex B → length-prefixed access units (split on AUD), plus avcC from SPS/PPS.
        let bytes = Array(try Data(contentsOf: URL(fileURLWithPath: h264)))
        var nals: [[UInt8]] = []
        var i = 0, start = -1
        while i + 3 <= bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start && bytes[end - 1] == 0 { end -= 1 }
                    nals.append(Array(bytes[start..<end]))
                }
                start = i + 3
                i += 3
            } else {
                i += 1
            }
        }
        if start >= 0 { nals.append(Array(bytes[start...])) }
        var sps: [UInt8] = [], pps: [UInt8] = []
        var frames: [(Data, Bool)] = []
        var current = Data(), key = false, begun = false
        for nal in nals {
            switch nal[0] & 0x1F {
            case 9:
                if begun { frames.append((current, key)) }
                current = Data(); key = false; begun = true
            case 7: sps = nal
            case 8: pps = nal
            case 6: break
            default:
                if nal[0] & 0x1F == 5 { key = true }
                var w = ByteWriter(); w.u32(UInt32(nal.count)); w.bytes(nal)
                current.append(w.data)
            }
        }
        if !current.isEmpty { frames.append((current, key)) }
        var avcC = ByteWriter()
        avcC.bytes([1, sps[1], sps[2], sps[3], 0xFF, 0xE1]); avcC.u16(UInt16(sps.count)); avcC.bytes(sps)
        avcC.u8(1); avcC.u16(UInt16(pps.count)); avcC.bytes(pps)

        let adts = Array(try Data(contentsOf: URL(fileURLWithPath: aac)))
        var aacFrames: [Data] = []
        var p = 0
        while p + 7 <= adts.count {
            let length = (Int(adts[p + 3] & 0x03) << 11) | (Int(adts[p + 4]) << 3) | (Int(adts[p + 5]) >> 5)
            let header = (adts[p + 1] & 0x01) == 1 ? 7 : 9
            aacFrames.append(Data(adts[(p + header)..<(p + length)]))
            p += length
        }
        let media = Media(videoInfo: VideoTrackInfo(codec: .h264, width: 640, height: 360, fps: 30, codecPrivate: avcC.data),
                          frames: frames, aacFrames: aacFrames)
        cached = media
        return media
    }

    /// Runs a command via /usr/bin/env; returns stdout+stderr, throws on non-zero exit.
    @discardableResult
    static func run(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Fixtures", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
        }
        return text
    }
}
