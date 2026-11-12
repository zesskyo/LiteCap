import AVFoundation
import LiteCapCore
import ScreenCaptureKit

/// The mixer's internal format: 48 kHz stereo Float32, non-interleaved.
let mixFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

/// Converts whatever a device delivers (any rate, mono/stereo, int/float) to `mixFormat`.
final class PCMConverter {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    private var sourceDescription: AudioStreamBasicDescription?
    private var sourceFormat: AVAudioFormat?

    func convert(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        // Build the format from the raw stream description with failable initializers:
        // devices can switch formats mid-stream, and an unusable one must be skipped, not crash.
        guard let description = sampleBuffer.formatDescription,
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate >= 8_000, asbd.mSampleRate <= 384_000,
              asbd.mChannelsPerFrame >= 1, asbd.mChannelsPerFrame <= 64 else { return nil }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0, frameCount <= 192_000 else { return nil }
        if sourceDescription.map({ !Self.same($0, asbd) }) ?? true {
            sourceDescription = asbd
            sourceFormat = AVAudioFormat(streamDescription: &asbd)
            if sourceFormat == nil, let layout = AVAudioChannelLayout(
                layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | asbd.mChannelsPerFrame
            ) {
                sourceFormat = AVAudioFormat(streamDescription: &asbd, channelLayout: layout)
            }
        }
        let frames = AVAudioFrameCount(frameCount)
        guard let format = sourceFormat,
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        input.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return convert(input)
    }

    private static func same(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
            && a.mBytesPerPacket == b.mBytesPerPacket && a.mFramesPerPacket == b.mFramesPerPacket
            && a.mBytesPerFrame == b.mBytesPerFrame && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBitsPerChannel == b.mBitsPerChannel
    }

    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = input.format
        if format == mixFormat { return input }
        if inputFormat != format {
            inputFormat = format
            converter = AVAudioConverter(from: format, to: mixFormat)
            // Mono mics: put the signal in both ears instead of only the left.
            if format.channelCount == 1 { converter?.channelMap = [0, 0] }
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * mixFormat.sampleRate / format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        return error == nil ? output : nil
    }
}

/// Something that pushes audio into a mixer channel's ring buffer.
protocol AudioCapture: AnyObject {
    var status: String { get }
    func start()
    func stop()
}

extension AudioRing {
    func write(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let right = buffer.format.channelCount > 1 ? channels[1] : channels[0]
        write(left: channels[0], right: right, frames: Int(buffer.frameLength))
    }
}

// MARK: - Microphone / audio interface / capture card audio

final class InputDeviceCapture: NSObject, AudioCapture, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let deviceID: String
    private let ring: AudioRing
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "litecap.audio.input", qos: .userInteractive)
    private let converter = PCMConverter()
    private(set) var status = ""

    init(deviceID: String, ring: AudioRing) {
        self.deviceID = deviceID
        self.ring = ring
    }

    func start() {
        queue.async { [self] in
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in granted = ok; semaphore.signal() }
            semaphore.wait()
            guard granted else { status = "Microphone permission denied"; return }
            let device = deviceID.isEmpty
                ? AVCaptureDevice.default(for: .audio)
                : (AVCaptureDevice(uniqueID: deviceID) ?? AVCaptureDevice.default(for: .audio))
            guard let device, let input = try? AVCaptureDeviceInput(device: device) else {
                status = "Device not found"
                return
            }
            session.beginConfiguration()
            if session.canAddInput(input) { session.addInput(input) }
            let output = AVCaptureAudioDataOutput()
            // Ask for one fixed format (48 kHz stereo float), so a device changing its own
            // format mid-stream doesn't reach us, and no extra conversion is needed.
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: true,
                AVLinearPCMIsBigEndianKey: false
            ]
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            session.startRunning()
            status = ""
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let pcm = converter.convert(sampleBuffer) { ring.write(pcm) }
    }
}

// MARK: - Desktop audio / one app's audio (ScreenCaptureKit)

final class SystemAudioCapture: NSObject, AudioCapture, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// nil = all desktop audio (minus LiteCap); otherwise only this app
    /// (matched by bundle ID, or by name for apps without one, like Java games).
    private let app: (bundleID: String, name: String)?
    private let ring: AudioRing
    private let queue = DispatchQueue(label: "litecap.audio.system", qos: .userInteractive)
    private let converter = PCMConverter()
    private var stream: SCStream?
    private var running = false
    private(set) var status = ""

    init(app: (bundleID: String, name: String)?, ring: AudioRing) {
        self.app = app
        self.ring = ring
    }

    func start() {
        running = true
        Task { await open() }
    }

    func stop() {
        running = false
        let old = stream
        stream = nil
        if let old { Task { try? await old.stopCapture() } }
    }

    private func open() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { status = "No display"; return }
            let filter: SCContentFilter
            if let wanted = app {
                guard let app = content.applications.first(where: { candidate in
                    wanted.bundleID.isEmpty
                        ? candidate.bundleIdentifier.isEmpty && candidate.applicationName == wanted.name
                        : candidate.bundleIdentifier == wanted.bundleID
                }) else {
                    status = "App isn't running"
                    // Try again in a bit — the app may be launched later.
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if running { await open() }
                    return
                }
                filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            } else {
                let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            }
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            // Audio only: keep the (required) video part as small and slow as possible.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await newStream.startCapture()
            if running { stream = newStream; status = "" } else { try? await newStream.stopCapture() }
        } catch {
            status = "Audio capture failed: \(error.localizedDescription)"
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let pcm = converter.convert(sampleBuffer) else { return }
        ring.write(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard stream === self.stream, running else { return }
        self.stream = nil
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if running { await open() }
        }
    }
}
