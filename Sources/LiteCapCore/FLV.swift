import Foundation

/// Builds RTMP/FLV audio & video message bodies.
public enum FLV {
    // MARK: Video (legacy AVC, what every RTMP server accepts)

    public static func avcSequenceHeader(_ avcC: Data) -> Data {
        var w = ByteWriter()
        w.bytes([0x17, 0x00, 0x00, 0x00, 0x00])
        w.bytes(avcC)
        return w.data
    }

    public static func avcFrame(_ avcc: Data, keyframe: Bool, compositionTimeMs: Int32 = 0) -> Data {
        var w = ByteWriter(capacity: avcc.count + 5)
        w.u8(keyframe ? 0x17 : 0x27)
        w.u8(0x01)
        w.u24(UInt32(bitPattern: compositionTimeMs) & 0xFFFFFF)
        w.bytes(avcc)
        return w.data
    }

    // MARK: Audio

    /// Main audio track (index 0): legacy AAC tags.
    public static func aacSequenceHeader(_ asc: Data) -> Data { Data([0xAF, 0x00]) + asc }
    public static func aacFrame(_ raw: Data) -> Data { Data([0xAF, 0x01]) + raw }

    /// Extra audio tracks (e.g. the Twitch VOD track) use Enhanced-RTMP multitrack
    /// audio, the same layout OBS sends: [0x95][packetType]['mp4a'][trackId] payload.
    public static func multitrackAAC(_ payload: Data, trackID: UInt8, isSequenceHeader: Bool) -> Data {
        var w = ByteWriter(capacity: payload.count + 7)
        let soundFormatExHeader: UInt8 = 9 << 4
        let audioPacketTypeMultitrack: UInt8 = 5
        w.u8(soundFormatExHeader | audioPacketTypeMultitrack)
        let oneTrack: UInt8 = 0x00
        let packetType: UInt8 = isSequenceHeader ? 0 : 1 // SequenceStart / CodedFrames
        w.u8(oneTrack | packetType)
        w.ascii("mp4a")
        w.u8(trackID)
        w.bytes(payload)
        return w.data
    }

    // MARK: Metadata

    public static func metadata(width: Int, height: Int, fps: Double, videoKbps: Int, audioKbps: Int) -> Data {
        let pairs: [(String, AMF0)] = [
            ("duration", .number(0)),
            ("width", .number(Double(width))),
            ("height", .number(Double(height))),
            ("videodatarate", .number(Double(videoKbps))),
            ("framerate", .number(fps)),
            ("videocodecid", .number(7)),
            ("audiodatarate", .number(Double(audioKbps))),
            ("audiosamplerate", .number(48_000)),
            ("audiosamplesize", .number(16)),
            ("audiochannels", .number(2)),
            ("stereo", .bool(true)),
            ("audiocodecid", .number(10)),
            ("encoder", .string("LiteCap"))
        ]
        return AMF0.encode([.string("@setDataFrame"), .string("onMetaData"), .ecmaArray(pairs)])
    }
}
