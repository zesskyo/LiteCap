import AppKit
import LiteCapCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            StreamSettingsTab().tabItem { Label("Stream", systemImage: "dot.radiowaves.left.and.right") }
            RecordingSettingsTab().tabItem { Label("Recording", systemImage: "record.circle") }
            VideoSettingsTab().tabItem { Label("Video", systemImage: "display") }
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 520)
        .textFieldStyle(.squareBorder)
        .buttonStyle(FlatButtonStyle())
    }
}

/// "6000 kbps" style number field.
private struct NumberField: View {
    let title: String
    @Binding var value: Int
    var unit = ""

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: $value, format: plainNumber).frame(width: 80)
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct TrackPicker: View {
    let title: String
    @Binding var selection: Int

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(1...Project.trackCount, id: \.self) { Text("\($0)").tag($0) }
        }
        .pickerStyle(.radioGroup)
        .horizontalRadioGroupLayout()
    }
}

private struct StreamSettingsTab: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        let s = $studio.project.stream
        Form {
            Picker("Service", selection: Binding(get: { s.wrappedValue.service }, set: { service in
                s.wrappedValue.service = service
                if !service.defaultServer.isEmpty { s.wrappedValue.server = service.defaultServer }
            })) {
                ForEach(StreamService.allCases) { Text($0.label).tag($0) }
            }
            TextField("Server", text: s.server, prompt: Text("rtmp://"))
            SecureField("Stream key", text: $studio.streamKey)
            Divider()
            NumberField(title: "Video bitrate", value: s.bitrateKbps, unit: "kbps")
            Toggle("CBR", isOn: s.cbr)
            Picker("Resolution", selection: s.outputHeight) {
                Text("Canvas").tag(0)
                Text("1080p").tag(1080)
                Text("936p").tag(936)
                Text("720p").tag(720)
            }
            Divider()
            NumberField(title: "Audio bitrate", value: s.audioKbps, unit: "kbps")
            TrackPicker(title: "Audio track", selection: s.track)
            Toggle("Twitch VOD track", isOn: s.vodTrackEnabled)
            if s.wrappedValue.vodTrackEnabled {
                TrackPicker(title: "VOD track", selection: s.vodTrack)
            }
        }
        .formStyle(.columns)
        .padding(20)
        .disabled(studio.isStreaming)
    }
}

private struct RecordingSettingsTab: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        let r = $studio.project.record
        Form {
            LabeledContent("Folder") {
                HStack {
                    Text(r.wrappedValue.folder).lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .leading)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { r.wrappedValue.folder = url.path }
                    }
                }
            }
            Picker("Format", selection: Binding(get: { r.wrappedValue.format ?? .mkv }, set: { r.wrappedValue.format = $0 })) {
                ForEach(RecordFormat.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            if (r.wrappedValue.format ?? .mkv) == .mkv {
                Toggle("Remux to MP4 after recording", isOn: Binding(
                    get: { r.wrappedValue.autoRemux == true }, set: { r.wrappedValue.autoRemux = $0 }
                ))
                .disabled(Studio.ffmpegPath == nil)
                .help(Studio.ffmpegPath == nil ? "Needs ffmpeg: brew install ffmpeg" : "Keeps the .mkv and adds an .mp4 copy")
            }
            Divider()
            Picker("Encoder", selection: r.codec) {
                Text("H.264").tag(VideoCodecKind.h264)
                Text("H.265").tag(VideoCodecKind.hevc)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            NumberField(title: "Video bitrate", value: r.bitrateKbps, unit: "kbps")
            Divider()
            LabeledContent("Audio tracks") {
                HStack(spacing: 10) {
                    ForEach(1...Project.trackCount, id: \.self) { t in
                        Toggle("\(t)", isOn: Binding(
                            get: { r.wrappedValue.tracks.contains(t) },
                            set: { on in
                                if on { r.wrappedValue.tracks.insert(t) }
                                else if r.wrappedValue.tracks.count > 1 { r.wrappedValue.tracks.remove(t) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }
            NumberField(title: "Audio bitrate", value: r.audioKbps, unit: "kbps")
        }
        .formStyle(.columns)
        .padding(20)
        .disabled(studio.isRecording)
    }
}

private struct VideoSettingsTab: View {
    @EnvironmentObject var studio: Studio

    private struct Preset: Hashable {
        let name: String
        let width: Int
        let height: Int
        var tag: String { "\(width)x\(height)" }
    }

    private static let presets = [
        Preset(name: "720p", width: 1280, height: 720), Preset(name: "1080p", width: 1920, height: 1080),
        Preset(name: "2K", width: 2560, height: 1440), Preset(name: "4K", width: 3840, height: 2160)
    ]

    var body: some View {
        let v = $studio.project.video
        Form {
            Picker("Canvas", selection: Binding(
                get: { "\(v.wrappedValue.width)x\(v.wrappedValue.height)" },
                set: { value in
                    let parts = value.split(separator: "x").compactMap { Int($0) }
                    if parts.count == 2 { v.wrappedValue.width = parts[0]; v.wrappedValue.height = parts[1] }
                }
            )) {
                ForEach(Self.presets, id: \.self) { preset in Text(preset.name).tag(preset.tag) }
                let current = "\(v.wrappedValue.width)x\(v.wrappedValue.height)"
                if !Self.presets.contains(where: { $0.tag == current }) {
                    Text("Custom").tag(current)
                }
            }
            NumberField(title: "Width", value: v.width)
            NumberField(title: "Height", value: v.height)
            NumberField(title: "Frame rate", value: v.fps, unit: "fps")
        }
        .formStyle(.columns)
        .padding(20)
        .disabled(studio.isLive)
    }
}

private struct GeneralTab: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        Form {
            if updater.isAvailable {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecks },
                    set: { updater.automaticallyChecks = $0 }
                ))
                LabeledContent("") {
                    Button("Check Now") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates)
                }
            }
            LabeledContent("Version") {
                Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
            }
        }
        .formStyle(.columns)
        .padding(20)
    }
}
