import AppKit
import AVFoundation
import CoreAudio
import LiteCapCore

/// Desktop or app audio through Core Audio process taps (macOS 14.2+).
///
/// Unlike ScreenCaptureKit this is audio-only: macOS asks for "System Audio Recording"
/// permission and doesn't show the purple screen-sharing pill for it.
final class AudioTapCapture: AudioCapture, @unchecked Sendable {
    /// nil = all desktop audio (minus LiteCap); otherwise one app, by bundle ID or (if empty) by name.
    private let app: (bundleID: String, name: String)?
    private let ring: AudioRing
    /// Setup/teardown. The audio callback runs on its own queue, so stopping can't deadlock.
    private let queue = DispatchQueue(label: "litecap.audio.tap", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "litecap.audio.tap.io", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var running = false
    private var retry: DispatchWorkItem?
    private(set) var status = ""

    init(app: (bundleID: String, name: String)?, ring: AudioRing) {
        self.app = app
        self.ring = ring
    }

    func start() {
        queue.async { [self] in
            running = true
            open()
        }
    }

    func stop() {
        queue.sync {
            running = false
            retry?.cancel()
            retry = nil
            close()
        }
    }

    // MARK: Setup (on `queue`)

    private func open() {
        guard running, tapID == kAudioObjectUnknown else { return }
        let description: CATapDescription
        if let app {
            let processes = Self.processObjects(matching: app)
            guard !processes.isEmpty else {
                status = "\(app.name) isn't playing audio yet"
                scheduleRetry()
                return
            }
            description = CATapDescription(stereoMixdownOfProcesses: processes)
        } else {
            // Everything except LiteCap itself (so monitoring doesn't feed back).
            let me = Self.processObject(pid: ProcessInfo.processInfo.processIdentifier)
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: me.map { [$0] } ?? [])
        }
        description.uuid = UUID()
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &tap)
        guard err == noErr else {
            status = "System audio permission needed (System Settings → Privacy & Security → Screen & System Audio Recording)"
            scheduleRetry()
            return
        }
        tapID = tap

        guard let outputUID = Self.defaultOutputUID() else {
            status = "No audio output device"
            close()
            return
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LiteCap Audio Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString
            ]]
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard err == noErr else {
            status = "Couldn't start audio capture (\(err))"
            close()
            return
        }
        aggregateID = device

        guard var asbd = Self.tapFormat(tap), let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
            status = "Couldn't read the audio format"
            close()
            return
        }

        // Everything the callback needs is captured here, so it never touches shared state.
        let converter = PCMConverter()
        let ring = self.ring
        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, device, ioQueue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: input, deallocator: nil),
                  let converted = converter.convert(buffer) else { return }
            ring.write(converted)
        }
        guard err == noErr, let proc else {
            status = "Couldn't start audio capture (\(err))"
            close()
            return
        }
        procID = proc
        err = AudioDeviceStart(device, proc)
        guard err == noErr else {
            status = "Couldn't start audio capture (\(err))"
            close()
            return
        }
        status = ""
    }

    private func close() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// The app may not be running or playing yet: try again shortly.
    private func scheduleRetry() {
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.open() }
        retry = work
        queue.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: Core Audio helpers

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                             UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return err == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// The app's own audio process plus its helpers (e.g. com.google.Chrome.helper).
    private static func processObjects(matching app: (bundleID: String, name: String)) -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr
        else { return [] }

        // Apps without a bundle ID (Java games, …) are matched through their process IDs.
        let namedPIDs: Set<pid_t> = app.bundleID.isEmpty
            ? Set(NSWorkspace.shared.runningApplications.filter { $0.localizedName == app.name }.map(\.processIdentifier))
            : []
        return objects.filter { object in
            if !app.bundleID.isEmpty {
                let bundle = bundleID(of: object)
                return bundle == app.bundleID || bundle.hasPrefix(app.bundleID + ".")
            }
            return namedPIDs.contains(pid(of: object))
        }
    }

    private static func bundleID(of object: AudioObjectID) -> String {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }

    private static func pid(of object: AudioObjectID) -> pid_t {
        var address = address(kAudioProcessPropertyPID)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid)
        return pid
    }

    private static func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd) == noErr ? asbd : nil
    }

    private static func defaultOutputUID() -> String? {
        var address = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        var uidAddress = Self.address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
