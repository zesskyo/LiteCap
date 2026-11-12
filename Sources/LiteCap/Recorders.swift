import AVFoundation
import LiteCapCore

enum RecordFormat: String, Codable, CaseIterable, Identifiable {
    case mkv, mp4, mov
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

/// A running recording, whatever the file format.
protocol Recorder: AnyObject, Sendable {
    var url: URL { get }
    var bytesWritten: UInt64 { get }
    var onError: ((String) -> Void)? { get set }
    func appendVideo(_ buffer: CVPixelBuffer, pts: CMTime)
    func appendAudio(track: Int, _ buffer: AVAudioPCMBuffer, pts: Int64)
    func finish(completion: @escaping (Result<URL, Error>) -> Void)
}

extension RecordingOutput: Recorder {}

enum Recorders {
    static func make(folder: URL, settings: RecordSettings, canvas: VideoSettings, trackNames: [String]) throws -> Recorder {
        switch settings.format ?? .mkv {
        case .mkv: return try RecordingOutput(folder: folder, settings: settings, canvas: canvas, trackNames: trackNames)
        case .mp4: return try MovieRecordingOutput(folder: folder, settings: settings, canvas: canvas, fileType: .mp4)
        case .mov: return try MovieRecordingOutput(folder: folder, settings: settings, canvas: canvas, fileType: .mov)
        }
    }

    static func fileURL(folder: URL, extension ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return folder.appendingPathComponent("\(formatter.string(from: Date())).\(ext)")
    }
}

/// MP4 / MOV via AVAssetWriter: hardware H.264/H.265 plus one AAC track per selected audio track.
/// MOV is written in 5-second fragments, so a crash keeps everything but the last few seconds.
final class MovieRecordingOutput: Recorder, @unchecked Sendable {
    let url: URL
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "litecap.recording.movie", qos: .userInitiated)
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private var audioInputs: [Int: AVAssetWriterInput] = [:]
    private var started = false
    private var startTime: CMTime = .invalid
    private var lastVideoTime: CMTime = .invalid
    private var finishing = false
    private var failed = false

    init(folder: URL, settings: RecordSettings, canvas: VideoSettings, fileType: AVFileType) throws {
        url = try Recorders.fileURL(folder: folder, extension: fileType == .mov ? "mov" : "mp4")
        writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        if fileType == .mov { writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600) }

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.bitrateKbps * 1000,
            AVVideoExpectedSourceFrameRateKey: canvas.fps,
            AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            AVVideoAllowFrameReorderingKey: false
        ]
        if settings.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: canvas.width,
            AVVideoHeightKey: canvas.height,
            AVVideoCompressionPropertiesKey: compression
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw Self.error("These video settings can't be recorded to \(url.pathExtension.uppercased()).") }
        writer.add(videoInput)

        for track in settings.tracks.sorted() where (1...Project.trackCount).contains(track) {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: settings.audioKbps * 1000
            ])
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInputs[track] = input
            }
        }
        guard writer.startWriting() else {
            throw writer.error ?? Self.error("Couldn't start writing \(url.lastPathComponent).")
        }
    }

    var bytesWritten: UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    func appendVideo(_ buffer: CVPixelBuffer, pts: CMTime) {
        queue.async { [self] in
            guard !finishing, !failed else { return }
            if !started {
                writer.startSession(atSourceTime: pts)
                startTime = pts
                started = true
            }
            guard pts > lastVideoTime || !lastVideoTime.isValid else { return }
            if videoInput.isReadyForMoreMediaData {
                if videoInput.append(pixelBuffer: buffer, pts: pts) { lastVideoTime = pts } else { checkFailure() }
            }
        }
    }

    func appendAudio(track: Int, _ buffer: AVAudioPCMBuffer, pts: Int64) {
        guard let input = audioInputs[track] else { return }
        queue.async { [self] in
            guard !finishing, !failed, started else { return }
            let time = CMTime(value: pts, timescale: 1_000_000)
            guard time >= startTime, input.isReadyForMoreMediaData,
                  let sample = Self.sampleBuffer(buffer, pts: time) else { return }
            if !input.append(sample) { checkFailure() }
        }
    }

    func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [self] in
            finishing = true
            guard started, writer.status == .writing else {
                writer.cancelWriting()
                completion(.failure(writer.error ?? Self.error("No video frames were recorded.")))
                return
            }
            if lastVideoTime.isValid { writer.endSession(atSourceTime: lastVideoTime) }
            videoInput.markAsFinished()
            audioInputs.values.forEach { $0.markAsFinished() }
            writer.finishWriting { [writer, url] in
                if writer.status == .completed {
                    completion(.success(url))
                } else {
                    completion(.failure(writer.error ?? Self.error("Couldn't finish the file.")))
                }
            }
        }
    }

    private func checkFailure() {
        guard writer.status == .failed, !failed else { return }
        failed = true
        onError?("Recording failed: \(writer.error?.localizedDescription ?? "unknown error")")
    }

    /// Wraps mixer audio (48 kHz stereo float) as a CMSampleBuffer for the writer.
    private static func sampleBuffer(_ buffer: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer? {
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: buffer.format.streamDescription, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        ) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: buffer.audioBufferList
        ) == noErr else { return nil }
        return sample
    }

    private static func error(_ text: String) -> NSError {
        NSError(domain: "LiteCap", code: 4, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

private extension AVAssetWriterInput {
    /// Appends a raw frame (BGRA from the compositor); the writer encodes it.
    func append(pixelBuffer: CVPixelBuffer, pts: CMTime) -> Bool {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format
        ) == noErr, let format else { return false }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr, let sample else { return false }
        return append(sample)
    }
}
