import AVFoundation
import LiteCapCore
import Network
import VideoToolbox

// MARK: - Video (hardware H.264 / HEVC)

final class VideoEncoder: @unchecked Sendable {
    struct Settings: Equatable {
        var codec: VideoCodecKind
        var width: Int
        var height: Int
        var fps: Int
        var bitrateKbps: Int
        var constantBitrate: Bool
    }

    enum Error: Swift.Error, LocalizedError {
        case create(OSStatus)
        var errorDescription: String? {
            if case .create(let status) = self { return "Couldn't start the hardware encoder (\(status))." }
            return nil
        }
    }

    let settings: Settings
    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var forceKeyframe = true
    /// Encoded frame + the decoder config record (avcC/hvcC).
    var onPacket: ((EncodedPacket, Data?) -> Void)?

    init(_ settings: Settings) throws {
        self.settings = settings
        var created: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(settings.width), height: Int32(settings.height),
            codecType: settings.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created
        )
        guard status == noErr, let session = created else { throw Error.create(status) }
        self.session = session

        func set(_ key: CFString, _ value: CFTypeRef) { VTSessionSetProperty(session, key: key, value: value) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse) // no B-frames: simple timing
        set(kVTCompressionPropertyKey_ProfileLevel,
            settings.codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, settings.fps as NSNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as NSNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, settings.fps * 2 as NSNumber)
        let bitsPerSecond = settings.bitrateKbps * 1000
        let cbrOK = settings.constantBitrate
            && VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ConstantBitRate,
                                    value: bitsPerSecond as NSNumber) == noErr
        if !cbrOK {
            set(kVTCompressionPropertyKey_AverageBitRate, bitsPerSecond as NSNumber)
            let limits = [NSNumber(value: Double(bitsPerSecond) * 1.5 / 8), NSNumber(value: 1.0)] as CFArray
            set(kVTCompressionPropertyKey_DataRateLimits, limits)
        }
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func requestKeyframe() { lock.withLock { forceKeyframe = true } }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        let force = lock.withLock { () -> Bool in
            let f = forceKeyframe
            forceKeyframe = false
            return f
        }
        let properties: CFDictionary? = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self else { return }
            self.emit(sampleBuffer)
        }
    }

    private func emit(_ sampleBuffer: CMSampleBuffer) {
        guard let block = sampleBuffer.dataBuffer else { return }
        var keyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]], let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            keyframe = !notSync
        }
        var config: Data?
        if let format = sampleBuffer.formatDescription,
           let atoms = CMFormatDescriptionGetExtension(
               format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
           ) as? [String: Any] {
            config = (atoms["avcC"] ?? atoms["hvcC"]) as? Data
        }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let ok = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!) == noErr
        }
        guard ok else { return }
        let pts = CMTimeConvertScale(sampleBuffer.presentationTimeStamp, timescale: 1_000_000,
                                     method: .roundHalfAwayFromZero).value
        onPacket?(EncodedPacket(kind: .video, pts: pts, isKeyframe: keyframe, data: data), config)
    }

    func finish() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }
}

// MARK: - Downscaler for the stream

final class PixelScaler {
    private var session: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?

    init(width: Int, height: Int) {
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        if let session {
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                                 value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                                 value: kCVImageBufferColorPrimaries_ITU_R_709_2)
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationTransferFunction,
                                 value: kCVImageBufferTransferFunction_ITU_R_709_2)
        }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    }

    func scale(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let session, let pool else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let output, VTPixelTransferSessionTransferImage(session, from: source, to: output) == noErr else { return nil }
        return output
    }
}

// MARK: - AAC

/// PCM (48 kHz stereo float) → AAC-LC packets with drift-free timestamps.
final class AACEncoder {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private var pending: [AVAudioPCMBuffer] = []
    private var anchor: Int64?
    private var framesIn: Int64 = 0
    private var packetsOut: Int64 = 0
    /// (pts in µs, raw AAC frame)
    var onPacket: ((Int64, Data) -> Void)?

    init?(bitrateKbps: Int) {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0
        )
        guard let format = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: mixFormat, to: format) else { return nil }
        outputFormat = format
        self.converter = converter
        converter.bitRate = bitrateKbps * 1000
    }

    func encode(_ buffer: AVAudioPCMBuffer, pts: Int64) {
        // Timestamps come from counting samples; re-anchor only after a real gap.
        let expected = anchor.map { $0 + framesIn * 1_000_000 / 48_000 }
        if expected == nil || abs(pts - expected!) > 250_000 {
            if anchor != nil {
                converter.reset()
                pending.removeAll()
            }
            anchor = pts
            framesIn = 0
            packetsOut = 0
        }
        framesIn += Int64(buffer.frameLength)
        pending.append(buffer)
        drain()
    }

    private func drain() {
        while true {
            let output = AVAudioCompressedBuffer(
                format: outputFormat, packetCapacity: 8, maximumPacketSize: max(converter.maximumOutputPacketSize, 2048)
            )
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { [weak self] _, inputStatus in
                guard let self, !self.pending.isEmpty else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return self.pending.removeFirst()
            }
            emit(output)
            if status != .haveData || output.packetCount == 0 { break }
        }
    }

    private func emit(_ output: AVAudioCompressedBuffer) {
        guard let descriptions = output.packetDescriptions, let anchor else { return }
        for i in 0..<Int(output.packetCount) {
            let d = descriptions[i]
            let data = Data(bytes: output.data + Int(d.mStartOffset), count: Int(d.mDataByteSize))
            let pts = anchor + packetsOut * Int64(AAC.samplesPerPacket) * 1_000_000 / 48_000
            packetsOut += 1
            onPacket?(pts, data)
        }
    }
}

// MARK: - Network.framework transport for RTMP / RTMPS

final class NWTransport: ByteTransport, @unchecked Sendable {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "litecap.rtmp.net", qos: .userInitiated)

    func connect(host: String, port: Int, tls: Bool) async throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        let parameters = tls ? NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp) : NWParameters(tls: nil, tcp: tcp)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw RTMPPublisher.Error.badURL }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        self.connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            var resumed = false
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    resumed = true
                    connection.cancel()
                    continuation.resume(throwing: error)
                case .cancelled:
                    resumed = true
                    continuation.resume(throwing: RTMPPublisher.Error.disconnected)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data, completion: @escaping @Sendable (Swift.Error?) -> Void) {
        guard let connection else { completion(RTMPPublisher.Error.disconnected); return }
        connection.send(content: data, completion: .contentProcessed { error in completion(error) })
    }

    func receive() async throws -> Data {
        guard let connection else { throw RTMPPublisher.Error.disconnected }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    _ = isComplete
                    continuation.resume(throwing: RTMPPublisher.Error.disconnected)
                }
            }
        }
    }

    func close() {
        connection?.cancel()
        connection = nil
    }
}
