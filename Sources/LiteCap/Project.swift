import Foundation
import LiteCapCore

// Everything the user sets up, saved as JSON in ~/Library/Application Support/LiteCap.

struct CanvasRect: Codable, Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    func contains(_ px: Double, _ py: Double) -> Bool {
        px >= x && px <= x + w && py >= y && py <= y + h
    }
}

struct Crop: Codable, Equatable {
    var left = 0.0
    var top = 0.0
    var right = 0.0
    var bottom = 0.0
}

enum VideoSourceKind: Codable, Equatable {
    case display(id: UInt32)
    case window(id: UInt32, bundleID: String, title: String)
    case browser(url: String, width: Int, height: Int, css: String, fps: Int)
    case image(path: String)
    case camera(deviceID: String)

    var typeName: String {
        switch self {
        case .display: return "Display Capture"
        case .window: return "Window Capture"
        case .browser: return "Browser"
        case .image: return "Image"
        case .camera: return "Camera / Capture Card"
        }
    }

    var symbol: String {
        switch self {
        case .display: return "display"
        case .window: return "macwindow"
        case .browser: return "globe"
        case .image: return "photo"
        case .camera: return "video"
        }
    }

    static let defaultBrowserCSS = "body { background-color: rgba(0, 0, 0, 0); margin: 0px auto; overflow: hidden; }"
}

struct VideoSourceConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: VideoSourceKind
    var showCursor = true
}

struct SceneItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var sourceID: UUID
    /// Position/size on the canvas in pixels; nil until the source's size is known.
    var frame: CanvasRect?
    var crop = Crop()
    var visible = true
    var locked = false
}

struct StudioScene: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Draw order: first = bottom (the UI lists them top-first, like OBS).
    var items: [SceneItem] = []
}

enum AudioSourceKind: Codable, Equatable {
    case desktop
    case app(bundleID: String, name: String)
    case input(deviceID: String)

    var symbol: String {
        switch self {
        case .desktop: return "speaker.wave.2"
        case .app: return "app"
        case .input: return "mic"
        }
    }
}

struct AudioFilterConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var type: UInt32
    var subType: UInt32
    var manufacturer: UInt32
    var bypass = false
    /// The plugin's saved settings (AU `fullState`, as a property list).
    var state: Data?
}

struct AudioSourceConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: AudioSourceKind
    /// Linear gain, 0…2 (1 = 0 dB).
    var volume: Double = 1
    var muted = false
    /// Hear this source on your headphones/speakers.
    var monitor = false
    /// Which of the 6 output tracks this source is mixed into.
    var tracks: Set<Int> = [1, 2]
    var filters: [AudioFilterConfig] = []
}

enum StreamService: String, Codable, CaseIterable, Identifiable {
    case twitch, youtube, kick, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .twitch: return "Twitch"
        case .youtube: return "YouTube"
        case .kick: return "Kick"
        case .custom: return "Custom RTMP"
        }
    }
    var defaultServer: String {
        switch self {
        case .twitch: return "rtmp://live.twitch.tv/app"
        case .youtube: return "rtmp://a.rtmp.youtube.com/live2"
        case .kick, .custom: return "" // Kick shows your personal server URL in its dashboard
        }
    }
}

struct VideoSettings: Codable, Equatable {
    var width = 1920
    var height = 1080
    var fps = 60
}

struct RecordSettings: Codable, Equatable {
    var folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/LiteCap").path
    var codec: VideoCodecKind = .h264
    var bitrateKbps = 20_000
    var tracks: Set<Int> = [1]
    var audioKbps = 192
}

struct StreamSettings: Codable, Equatable {
    var service: StreamService = .twitch
    var server = StreamService.twitch.defaultServer
    var bitrateKbps = 6_000
    var cbr = true
    var audioKbps = 160
    /// Track sent as the stream's audio.
    var track = 1
    /// Twitch VOD track: a second audio track that only goes to VODs.
    var vodTrackEnabled = false
    var vodTrack = 2
    /// 0 = same as the canvas; otherwise downscale to this height.
    var outputHeight = 0
}

struct Project: Codable, Equatable {
    var scenes: [StudioScene]
    var currentSceneID: UUID
    var videoSources: [VideoSourceConfig] = []
    var audioSources: [AudioSourceConfig] = []
    var trackNames = ["Track 1", "Track 2", "Track 3", "Track 4", "Track 5", "Track 6"]
    var video = VideoSettings()
    var record = RecordSettings()
    var stream = StreamSettings()
    /// 0 = off, 1…6 = hear that track's mix on your output device.
    var listenTrack = 0

    static let trackCount = 6

    static func makeDefault() -> Project {
        let display = VideoSourceConfig(name: "Display", kind: .display(id: 0))
        let scene = StudioScene(name: "Scene", items: [SceneItem(sourceID: display.id)])
        var project = Project(scenes: [scene], currentSceneID: scene.id, videoSources: [display])
        project.audioSources = [
            AudioSourceConfig(name: "Desktop Audio", kind: .desktop, tracks: [1, 2]),
            AudioSourceConfig(name: "Mic", kind: .input(deviceID: ""), tracks: [1, 2])
        ]
        return project
    }

    var currentScene: StudioScene? { scenes.first { $0.id == currentSceneID } }

    func videoSource(_ id: UUID) -> VideoSourceConfig? { videoSources.first { $0.id == id } }

    // MARK: Persistence

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiteCap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("project.json")
    }

    static func load() -> Project {
        guard let data = try? Data(contentsOf: fileURL),
              let project = try? JSONDecoder().decode(Project.self, from: data),
              !project.scenes.isEmpty else { return makeDefault() }
        var p = project
        if p.currentScene == nil { p.currentSceneID = p.scenes[0].id }
        return p
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}
