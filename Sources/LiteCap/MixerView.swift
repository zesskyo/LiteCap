import SwiftUI

struct MixerPanel: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Audio Mixer") {
                Picker("Listen", selection: $studio.project.listenTrack) {
                    Text("Listen: Off").tag(0)
                    ForEach(1...Project.trackCount, id: \.self) { t in
                        Text("Listen: \(studio.project.trackNames[t - 1])").tag(t)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Hear a track's full mix on your headphones (use headphones to avoid echo)")
                AddAudioMenu()
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(studio.project.audioSources) { source in
                        ChannelStrip(sourceID: source.id)
                    }
                    if studio.project.audioSources.isEmpty {
                        Text("No audio sources. Click + to add one.").foregroundStyle(.secondary).padding()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
    }
}

private struct AddAudioMenu: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        Menu {
            Button("Desktop Audio") { studio.addAudioSource(.desktop, name: "Desktop Audio") }
            Menu("Application Audio") {
                ForEach(studio.apps) { app in
                    Button(app.title) { studio.addAudioSource(.app(bundleID: app.id, name: app.title), name: app.title) }
                }
            }
            Menu("Microphone / Input") {
                Button("Default Input") { studio.addAudioSource(.input(deviceID: ""), name: "Mic") }
                ForEach(studio.audioInputs) { input in
                    Button(input.title) { studio.addAudioSource(.input(deviceID: input.id), name: input.title) }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onAppear { Task { await studio.refreshPickers() } }
    }
}

private struct ChannelStrip: View {
    @EnvironmentObject var studio: Studio
    let sourceID: UUID
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        if let source = studio.project.audioSources.first(where: { $0.id == sourceID }) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: source.kind.symbol).foregroundStyle(.secondary)
                    Text(source.name).font(.callout).lineLimit(1)
                    if !source.filters.isEmpty {
                        Text("\(source.filters.count) filter\(source.filters.count == 1 ? "" : "s")")
                            .font(.caption2).padding(.horizontal, 4).background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    Text(Self.dB(source.volume)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Meter(sourceID: sourceID, meters: studio.meters, muted: source.muted)
                HStack(spacing: 6) {
                    Slider(value: Binding(
                        get: { Self.sliderValue(source.volume) },
                        set: { v in studio.updateAudioSource(sourceID) { $0.volume = Self.gain(v) } }
                    ), in: 0...1)
                    .controlSize(.small)
                    Button { studio.updateAudioSource(sourceID) { $0.muted.toggle() } } label: {
                        Image(systemName: source.muted ? "speaker.slash.fill" : "speaker.wave.2")
                            .foregroundStyle(source.muted ? Color.red : Color.primary)
                    }
                    .buttonStyle(.borderless).help(source.muted ? "Unmute" : "Mute")
                    Button { studio.updateAudioSource(sourceID) { $0.monitor.toggle() } } label: {
                        Image(systemName: source.monitor ? "headphones.circle.fill" : "headphones")
                            .foregroundStyle(source.monitor ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.borderless).help("Monitor: hear this source on your output device")
                    Button { studio.filtersSourceID = sourceID } label: { Image(systemName: "slider.vertical.3") }
                        .buttonStyle(.borderless).help("Filters (Audio Unit plugins)")
                    Menu {
                        Section("Tracks") {
                            ForEach(1...Project.trackCount, id: \.self) { t in
                                Toggle(studio.project.trackNames[t - 1], isOn: Binding(
                                    get: { source.tracks.contains(t) },
                                    set: { on in studio.updateAudioSource(sourceID) {
                                        if on { $0.tracks.insert(t) } else { $0.tracks.remove(t) }
                                    } }
                                ))
                            }
                        }
                        Button("Filters…") { studio.filtersSourceID = sourceID }
                        Button("Rename…") { newName = source.name; renaming = true }
                        Divider()
                        Button("Remove", role: .destructive) { studio.removeAudioSource(sourceID) }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                TrackDots(tracks: source.tracks)
            }
            .padding(8)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            .alert("Rename Audio Source", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Rename") { if !newName.isEmpty { studio.updateAudioSource(sourceID) { $0.name = newName } } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // Slider position ↔ gain: cubic taper feels natural (like OBS); 0.79 ≈ 0 dB, 1.0 ≈ +6 dB.
    static func gain(_ slider: Double) -> Double { 2 * pow(slider, 3) }
    static func sliderValue(_ gain: Double) -> Double { pow(gain / 2, 1.0 / 3) }

    static func dB(_ gain: Double) -> String {
        guard gain > 0.00001 else { return "-∞ dB" }
        return String(format: "%.1f dB", 20 * log10(gain))
    }
}

private struct TrackDots: View {
    let tracks: Set<Int>
    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...Project.trackCount, id: \.self) { t in
                Text("\(t)")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .frame(width: 14, height: 12)
                    .background(tracks.contains(t) ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(tracks.contains(t) ? Color.white : Color.secondary)
            }
        }
        .help("Tracks this source goes to (change in the ⚙︎ menu)")
    }
}

/// Stereo peak meter, −60…0 dBFS. Observes only the meter store.
private struct Meter: View {
    let sourceID: UUID
    @ObservedObject var meters: MeterStore
    let muted: Bool

    var body: some View {
        let levels = meters.levels[sourceID] ?? AudioEngine.Levels()
        VStack(spacing: 2) {
            bar(levels.left)
            bar(levels.right)
        }
        .frame(height: 9)
        .opacity(muted ? 0.35 : 1)
    }

    private func bar(_ peak: Float) -> some View {
        GeometryReader { geo in
            let db = peak > 0 ? 20 * log10(Double(peak)) : -60
            let fraction = max(0, min(1, (db + 60) / 60))
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.secondary.opacity(0.18))
                Rectangle()
                    .fill(LinearGradient(stops: [
                        .init(color: .green, location: 0),
                        .init(color: .green, location: 0.70),
                        .init(color: .yellow, location: 0.85),
                        .init(color: .red, location: 1)
                    ], startPoint: .leading, endPoint: .trailing))
                    .mask(alignment: .leading) { Rectangle().frame(width: geo.size.width * fraction) }
            }
        }
    }
}
