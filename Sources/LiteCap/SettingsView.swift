import AppKit
import LiteCapCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            StreamSettingsTab().tabItem { Label("Stream", systemImage: "dot.radiowaves.left.and.right") }
            RecordingSettingsTab().tabItem { Label("Recording", systemImage: "record.circle") }
            VideoSettingsTab().tabItem { Label("Video", systemImage: "display") }
            AudioSettingsTab().tabItem { Label("Audio", systemImage: "waveform") }
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560, height: 480)
    }
}

private struct StreamSettingsTab: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        let s = $studio.project.stream
        Form {
            Section("Service") {
                Picker("Service", selection: Binding(get: { s.wrappedValue.service }, set: { service in
                    s.wrappedValue.service = service
                    if !service.defaultServer.isEmpty { s.wrappedValue.server = service.defaultServer }
                })) {
                    ForEach(StreamService.allCases) { Text($0.label).tag($0) }
                }
                TextField("Server", text: s.server, prompt: Text("rtmp://… or rtmps://…"))
                SecureField("Stream key", text: $studio.streamKey)
                Text("Your key is stored in the macOS Keychain.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Video") {
                LabeledContent("Bitrate") {
                    HStack {
                        TextField("", value: s.bitrateKbps, format: .number).frame(width: 90).multilineTextAlignment(.trailing)
                        Text("kbps")
                    }
                }
                Toggle("Constant bitrate (CBR, recommended for Twitch)", isOn: s.cbr)
                Picker("Output resolution", selection: s.outputHeight) {
                    Text("Same as canvas").tag(0)
                    Text("1080p").tag(1080)
                    Text("936p").tag(936)
                    Text("720p").tag(720)
                }
            }
            Section("Audio") {
                LabeledContent("Bitrate") {
                    HStack {
                        TextField("", value: s.audioKbps, format: .number).frame(width: 90).multilineTextAlignment(.trailing)
                        Text("kbps")
                    }
                }
                TrackPicker(title: "Stream audio track", selection: s.track)
                Toggle("Twitch VOD track", isOn: s.vodTrackEnabled)
                if s.wrappedValue.vodTrackEnabled {
                    TrackPicker(title: "VOD track", selection: s.vodTrack)
                    Text("Viewers hear the stream track live; Twitch saves the VOD track in your VODs instead. Leave copyrighted music off the VOD track to avoid muted VODs. Twitch only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(studio.isStreaming)
    }
}

private struct RecordingSettingsTab: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        let r = $studio.project.record
        Form {
            Section("File") {
                LabeledContent("Folder") {
                    HStack {
                        Text(r.wrappedValue.folder).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url { r.wrappedValue.folder = url.path }
                        }
                    }
                }
                LabeledContent("Format") { Text("MKV (crash-safe)") }
                Text("If LiteCap or your Mac crashes, the .mkv stays playable up to about a second before. Use “Remux Last to MP4” for editors that don't open MKV.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Video") {
                Picker("Encoder", selection: r.codec) {
                    Text("H.264 (hardware)").tag(VideoCodecKind.h264)
                    Text("HEVC / H.265 (hardware, smaller files)").tag(VideoCodecKind.hevc)
                }
                LabeledContent("Bitrate") {
                    HStack {
                        TextField("", value: r.bitrateKbps, format: .number).frame(width: 90).multilineTextAlignment(.trailing)
                        Text("kbps")
                    }
                }
            }
            Section("Audio tracks to record") {
                HStack {
                    ForEach(1...Project.trackCount, id: \.self) { t in
                        Toggle(studio.project.trackNames[t - 1], isOn: Binding(
                            get: { r.wrappedValue.tracks.contains(t) },
                            set: { on in if on { r.wrappedValue.tracks.insert(t) } else if r.wrappedValue.tracks.count > 1 { r.wrappedValue.tracks.remove(t) } }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
                LabeledContent("Bitrate per track") {
                    HStack {
                        TextField("", value: r.audioKbps, format: .number).frame(width: 90).multilineTextAlignment(.trailing)
                        Text("kbps")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(studio.isRecording)
    }
}

private struct VideoSettingsTab: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        let v = $studio.project.video
        Form {
            Section("Canvas") {
                Picker("Preset", selection: Binding(
                    get: { "\(v.wrappedValue.width)x\(v.wrappedValue.height)" },
                    set: { value in
                        let parts = value.split(separator: "x").compactMap { Int($0) }
                        if parts.count == 2 { v.wrappedValue.width = parts[0]; v.wrappedValue.height = parts[1] }
                    }
                )) {
                    Text("1280×720").tag("1280x720")
                    Text("1920×1080").tag("1920x1080")
                    Text("2560×1440").tag("2560x1440")
                    Text("3840×2160").tag("3840x2160")
                    Text("1080×1920 (vertical)").tag("1080x1920")
                    let custom = "\(v.wrappedValue.width)x\(v.wrappedValue.height)"
                    if !["1280x720", "1920x1080", "2560x1440", "3840x2160", "1080x1920"].contains(custom) {
                        Text("Custom").tag(custom)
                    }
                }
                HStack {
                    TextField("Width", value: v.width, format: .number)
                    TextField("Height", value: v.height, format: .number)
                }
                Picker("Frame rate", selection: v.fps) {
                    ForEach([24, 25, 30, 48, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
            }
            Text("Changing the canvas doesn't move your sources; use Fit to Screen on each one afterwards.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .disabled(studio.isLive)
    }
}

private struct AudioSettingsTab: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        Form {
            Section("Track names") {
                ForEach(0..<Project.trackCount, id: \.self) { i in
                    TextField("Track \(i + 1)", text: $studio.project.trackNames[i])
                }
            }
            Section("Monitoring") {
                Text("Monitoring plays through your Mac's current output device (System Settings → Sound). Use headphones so your mic doesn't pick it up.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralTab: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        Form {
            Section("Updates") {
                if updater.isAvailable {
                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { updater.automaticallyChecks },
                        set: { updater.automaticallyChecks = $0 }
                    ))
                    HStack {
                        Button("Check Now") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates)
                        if let last = updater.lastCheck {
                            Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Updates are never installed while you're recording or streaming.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("This build was made without an update key, so it can't update itself. Download releases from GitHub instead.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Version") {
                    Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                }
            }
            Section("Hotkeys") {
                LabeledContent("Start / stop recording") { Text("⌃⌥⌘R") }
                LabeledContent("Go live / end stream") { Text("⌃⌥⌘S") }
                Text("These work from any app, including fullscreen games.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TrackPicker: View {
    @EnvironmentObject var studio: Studio
    let title: String
    @Binding var selection: Int

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(1...Project.trackCount, id: \.self) { t in Text(studio.project.trackNames[t - 1]).tag(t) }
        }
    }
}
