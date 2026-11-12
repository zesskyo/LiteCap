import SwiftUI

struct MixerPanel: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Mixer") {
                Button { studio.showingTracks = true } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(IconButtonStyle()).help("Tracks")
                AddAudioMenu()
            }
            if studio.project.audioSources.isEmpty {
                Text("No audio sources").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 1) {
                        ForEach(studio.project.audioSources) { source in ChannelStrip(sourceID: source.id) }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
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
            Menu("Input") {
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
        .frame(width: 22)
        .onAppear { Task { await studio.refreshPickers() } }
    }
}

/// One vertical channel: dB, meters + fader, buttons, name.
private struct ChannelStrip: View {
    @EnvironmentObject var studio: Studio
    let sourceID: UUID
    @State private var renaming = false
    @State private var newName = ""
    @State private var dropTargeted = false

    var body: some View {
        if let source = studio.project.audioSources.first(where: { $0.id == sourceID }) {
            VStack(spacing: 5) {
                Text(Self.dB(source.volume)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Meter(sourceID: sourceID, meters: studio.meters, muted: source.muted)
                    VerticalFader(value: Binding(
                        get: { Self.sliderValue(source.volume) },
                        set: { v in studio.updateAudioSource(sourceID) { $0.volume = Self.gain(v) } }
                    ), resetValue: Self.sliderValue(1))
                }
                .frame(maxHeight: .infinity)
                HStack(spacing: 2) {
                    Button { studio.updateAudioSource(sourceID) { $0.muted.toggle() } } label: {
                        Image(systemName: source.muted ? "speaker.slash.fill" : "speaker.wave.2")
                    }
                    .buttonStyle(IconButtonStyle(on: source.muted)).help("Mute")
                    Button { studio.updateAudioSource(sourceID) { $0.monitor.toggle() } } label: {
                        Image(systemName: "headphones")
                    }
                    .buttonStyle(IconButtonStyle(on: source.monitor)).help("Monitor")
                    Menu {
                        Button("Filters…") { studio.filtersSourceID = sourceID }
                        Button("Tracks…") { studio.showingTracks = true }
                        Button("Rename…") { newName = source.name; renaming = true }
                        Divider()
                        Button("Move Left") { studio.moveAudioSource(sourceID, by: -1) }
                        Button("Move Right") { studio.moveAudioSource(sourceID, by: 1) }
                        Divider()
                        Button("Remove", role: .destructive) { studio.removeAudioSource(sourceID) }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
                }
                Text(source.name).font(.caption).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(source.filters.isEmpty ? Color.primary : Theme.active)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .help("Drag the name to reorder")
                    .draggable(sourceID.uuidString)
            }
            .frame(width: 84)
            .padding(.vertical, 6)
            .background(dropTargeted ? Theme.selection : Theme.panel)
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, let dragged = UUID(uuidString: raw), dragged != sourceID,
                      let target = studio.project.audioSources.firstIndex(where: { $0.id == sourceID }) else { return false }
                studio.moveAudioSource(dragged, to: target)
                return true
            } isTargeted: { dropTargeted = $0 }
            .alert("Rename Audio Source", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Rename") { if !newName.isEmpty { studio.updateAudioSource(sourceID) { $0.name = newName } } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // Fader position ↔ gain: cubic taper (like OBS); 0.79 ≈ 0 dB, 1.0 ≈ +6 dB.
    static func gain(_ slider: Double) -> Double { 2 * pow(slider, 3) }
    static func sliderValue(_ gain: Double) -> Double { pow(gain / 2, 1.0 / 3) }

    static func dB(_ gain: Double) -> String {
        guard gain > 0.00001 else { return "-inf dB" }
        return String(format: "%.1f dB", 20 * log10(gain))
    }
}

/// Square vertical fader. Drag to set; double-click for 0 dB.
private struct VerticalFader: View {
    @Binding var value: Double
    let resetValue: Double

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height, thumb: CGFloat = 8
            let y = (1 - CGFloat(value)) * (h - thumb)
            ZStack(alignment: .top) {
                Rectangle().fill(Color.gray.opacity(0.35)).frame(width: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Color.primary.opacity(0.85)).frame(width: 18, height: thumb).offset(y: y)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                value = Double(min(1, max(0, 1 - (g.location.y - thumb / 2) / max(1, h - thumb))))
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = resetValue })
        }
        .frame(width: 22)
    }
}

/// Stereo peak meter, −60…0 dBFS, bottom-up. Observes only the meter store.
private struct Meter: View {
    let sourceID: UUID
    @ObservedObject var meters: MeterStore
    let muted: Bool

    var body: some View {
        let levels = meters.levels[sourceID] ?? AudioEngine.Levels()
        HStack(spacing: 2) {
            bar(levels.left)
            bar(levels.right)
        }
        .frame(width: 14)
        .opacity(muted ? 0.35 : 1)
    }

    private func bar(_ peak: Float) -> some View {
        GeometryReader { geo in
            let db = peak > 0 ? 20 * log10(Double(peak)) : -60
            let fraction = max(0, min(1, (db + 60) / 60))
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color.gray.opacity(0.2))
                Rectangle()
                    .fill(LinearGradient(stops: [
                        .init(color: .green, location: 0),
                        .init(color: .green, location: 0.70),
                        .init(color: .yellow, location: 0.85),
                        .init(color: .red, location: 1)
                    ], startPoint: .bottom, endPoint: .top))
                    .mask(alignment: .bottom) { Rectangle().frame(height: geo.size.height * fraction) }
            }
        }
    }
}

/// Which of the 6 tracks each source goes to (like OBS's Advanced Audio Properties).
struct TracksSheet: View {
    @EnvironmentObject var studio: Studio
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Source").font(.headline)
                    Text("Monitor").font(.headline)
                    ForEach(1...Project.trackCount, id: \.self) { t in Text("\(t)").font(.headline).gridColumnAlignment(.center) }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(studio.project.audioSources) { source in
                    GridRow {
                        Text(source.name).lineLimit(1).frame(minWidth: 160, alignment: .leading)
                        Toggle("", isOn: Binding(
                            get: { source.monitor },
                            set: { on in studio.updateAudioSource(source.id) { $0.monitor = on } }
                        )).labelsHidden().toggleStyle(.checkbox)
                        ForEach(1...Project.trackCount, id: \.self) { t in
                            Toggle("", isOn: Binding(
                                get: { source.tracks.contains(t) },
                                set: { on in studio.updateAudioSource(source.id) {
                                    if on { $0.tracks.insert(t) } else { $0.tracks.remove(t) }
                                } }
                            )).labelsHidden().toggleStyle(.checkbox)
                        }
                    }
                }
            }
            .padding(16)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(FlatButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 520)
    }
}
