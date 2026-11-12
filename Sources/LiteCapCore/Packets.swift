import Foundation

/// One encoded frame (video) or AAC packet (audio), ready to mux or send.
public struct EncodedPacket: Sendable {
    public enum Kind: Sendable, Equatable {
        case video
        /// `index` is the position in the output's list of audio tracks (0 = first).
        case audio(index: Int)
    }

    public var kind: Kind
    /// Presentation time in microseconds on the host clock.
    public var pts: Int64
    public var isKeyframe: Bool
    /// Video: length-prefixed NAL units (AVCC/HVCC). Audio: one raw AAC frame.
    public var data: Data

    public init(kind: Kind, pts: Int64, isKeyframe: Bool, data: Data) {
        self.kind = kind
        self.pts = pts
        self.isKeyframe = isKeyframe
        self.data = data
    }
}

public enum VideoCodecKind: String, Codable, Sendable, CaseIterable {
    case h264, hevc
}

public struct VideoTrackInfo: Sendable {
    public var codec: VideoCodecKind
    public var width: Int
    public var height: Int
    public var fps: Double
    /// avcC / hvcC decoder configuration record.
    public var codecPrivate: Data

    public init(codec: VideoCodecKind, width: Int, height: Int, fps: Double, codecPrivate: Data) {
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.codecPrivate = codecPrivate
    }
}

public struct AudioTrackInfo: Sendable {
    public var name: String
    public var sampleRate: Double
    public var channels: Int
    /// AudioSpecificConfig.
    public var codecPrivate: Data

    public init(name: String, sampleRate: Double = 48_000, channels: Int = 2, codecPrivate: Data = AAC.audioSpecificConfig()) {
        self.name = name
        self.sampleRate = sampleRate
        self.channels = channels
        self.codecPrivate = codecPrivate
    }
}

public enum AAC {
    /// AAC-LC AudioSpecificConfig (2 bytes).
    public static func audioSpecificConfig(sampleRate: Double = 48_000, channels: Int = 2) -> Data {
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let index = UInt16(rates.firstIndex(of: sampleRate) ?? 3)
        let value: UInt16 = (2 << 11) | (index << 7) | (UInt16(channels & 0xF) << 3)
        return Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }
    public static let samplesPerPacket = 1024
}
