import AppKit
import AVFoundation
import SwiftUI

// MARK: - Source properties

struct SourcePropertiesSheet: View {
    @EnvironmentObject var studio: Studio
    @Environment(\.dismiss) private var dismiss
    let sourceID: UUID
    @State private var draft: VideoSourceConfig?

    var body: some View {
        VStack(spacing: 0) {
            if let binding = Binding($draft) {
                Form {
                    Section("Source") {
                        TextField("Name", text: binding.name)
                        KindEditor(config: binding)
                    }
                    if let itemID = itemID {
                        TransformEditor(itemID: itemID)
                    }
                }
                .formStyle(.columns)
                .padding(20)
            } else {
                ProgressView().padding(40)
            }
            Divider()
            HStack {
                if case .browser = draft?.kind {
                    Button("Interact…") { studio.browserSource(sourceID)?.interact() }
                        .help("Open the page in a window to log in or click things")
                    Button("Reload") { studio.browserSource(sourceID)?.reload() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                Button("Done") { apply(); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 600)
        .buttonStyle(FlatButtonStyle())
        .textFieldStyle(.squareBorder)
        .onAppear {
            draft = studio.project.videoSource(sourceID)
            Task { await studio.refreshPickers() }
        }
    }

    private var itemID: UUID? {
        if let selected = studio.item(studio.selectedItemID), selected.sourceID == sourceID { return selected.id }
        return studio.project.currentScene?.items.first { $0.sourceID == sourceID }?.id
    }

    private func apply() {
        guard let draft else { return }
        studio.updateVideoSource(sourceID) { $0 = draft }
    }
}

private struct KindEditor: View {
    @EnvironmentObject var studio: Studio
    @Binding var config: VideoSourceConfig

    var body: some View {
        switch config.kind {
        case .display(let id):
            Picker("Display", selection: Binding(get: { String(id) }, set: { config.kind = .display(id: UInt32($0) ?? 0) })) {
                if !studio.displays.contains(where: { $0.id == String(id) }) { Text("Main display").tag(String(id)) }
                ForEach(studio.displays) { Text($0.title).tag($0.id) }
            }
            Toggle("Capture cursor", isOn: $config.showCursor)
        case .window(let id, _, let title):
            Picker("Window", selection: Binding(get: { id }, set: { newID in
                if let w = studio.windows.first(where: { $0.id == newID }) {
                    config.kind = .window(id: w.id, bundleID: w.bundleID, title: w.windowTitle)
                }
            })) {
                if !studio.windows.contains(where: { $0.id == id }) {
                    Text(title.isEmpty ? "Choose a window" : "\(title) (not open)").tag(id)
                }
                ForEach(studio.windows) { Text($0.title).tag($0.id) }
            }
            Button("Refresh Window List") { Task { await studio.refreshPickers() } }
            Toggle("Capture cursor", isOn: $config.showCursor)
            Text("Window capture keeps working when the window is covered, but freezes while it's minimized.")
                .font(.caption).foregroundStyle(.secondary)
        case .browser(let url, let width, let height, let css, let fps):
            TextField("URL", text: Binding(get: { url }, set: { config.kind = .browser(url: $0, width: width, height: height, css: css, fps: fps) }))
            TextField("Width", value: Binding(get: { width }, set: { config.kind = .browser(url: url, width: max(16, min($0, 7680)), height: height, css: css, fps: fps) }), format: .number)
            TextField("Height", value: Binding(get: { height }, set: { config.kind = .browser(url: url, width: width, height: max(16, min($0, 4320)), css: css, fps: fps) }), format: .number)
            Picker("Frame rate", selection: Binding(get: { fps }, set: { config.kind = .browser(url: url, width: width, height: height, css: css, fps: $0) })) {
                ForEach([10, 15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
            }
            VStack(alignment: .leading) {
                Text("Custom CSS")
                TextEditor(text: Binding(get: { css }, set: { config.kind = .browser(url: url, width: width, height: height, css: $0, fps: fps) }))
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 70)
            }
            Text("Page audio plays through your Mac, so it's picked up by Desktop Audio. Lower fps = less CPU.")
                .font(.caption).foregroundStyle(.secondary)
        case .image(let path):
            LabeledContent("File") { Text((path as NSString).lastPathComponent).lineLimit(1) }
            Button("Choose Image…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.image]
                if panel.runModal() == .OK, let url = panel.url { config.kind = .image(path: url.path) }
            }
        case .camera(let deviceID):
            Picker("Device", selection: Binding(get: { deviceID }, set: { config.kind = .camera(deviceID: $0) })) {
                if !studio.cameras.contains(where: { $0.id == deviceID }) { Text("Default camera").tag(deviceID) }
                ForEach(studio.cameras) { Text($0.title).tag($0.id) }
            }
            Text("Capture cards show up here. Add their audio in the mixer under Microphone / Input.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Live position/size/crop editing (applies immediately).
private struct TransformEditor: View {
    @EnvironmentObject var studio: Studio
    let itemID: UUID

    var body: some View {
        if let item = studio.item(itemID) {
            Section("Transform (canvas pixels)") {
                let f = item.frame ?? CanvasRect(x: 0, y: 0, w: 0, h: 0)
                HStack {
                    number("X", f.x) { v in studio.updateItem(itemID) { $0.frame?.x = v } }
                    number("Y", f.y) { v in studio.updateItem(itemID) { $0.frame?.y = v } }
                }
                HStack {
                    number("Width", f.w) { v in studio.updateItem(itemID) { $0.frame?.w = max(1, v) } }
                    number("Height", f.h) { v in studio.updateItem(itemID) { $0.frame?.h = max(1, v) } }
                }
                HStack {
                    Button("Fit") { studio.transform(itemID, .fit) }
                    Button("Stretch") { studio.transform(itemID, .stretch) }
                    Button("Center") { studio.transform(itemID, .center) }
                    Button("Reset") { studio.transform(itemID, .reset) }
                }
            }
            Section("Crop (source pixels)") {
                HStack {
                    number("Left", item.crop.left) { v in studio.updateItem(itemID) { $0.crop.left = max(0, v) } }
                    number("Right", item.crop.right) { v in studio.updateItem(itemID) { $0.crop.right = max(0, v) } }
                }
                HStack {
                    number("Top", item.crop.top) { v in studio.updateItem(itemID) { $0.crop.top = max(0, v) } }
                    number("Bottom", item.crop.bottom) { v in studio.updateItem(itemID) { $0.crop.bottom = max(0, v) } }
                }
            }
        }
    }

    private func number(_ label: String, _ value: Double, _ set: @escaping (Double) -> Void) -> some View {
        TextField(label, value: Binding(get: { value.rounded() }, set: set), format: .number)
    }
}

// MARK: - Audio filters

struct FiltersSheet: View {
    @EnvironmentObject var studio: Studio
    @Environment(\.dismiss) private var dismiss
    let sourceID: UUID
    @State private var plugins: [AVAudioUnitComponent] = []

    var body: some View {
        let source = studio.project.audioSources.first { $0.id == sourceID }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Filters — \(source?.name ?? "")").font(.headline)
                Spacer()
                Menu("Add Filter") {
                    let byMaker = Dictionary(grouping: plugins, by: \.manufacturerName)
                    ForEach(byMaker.keys.sorted(), id: \.self) { maker in
                        Menu(maker) {
                            ForEach(byMaker[maker] ?? [], id: \.self) { component in
                                Button(component.name) { studio.addFilter(component, to: sourceID) }
                            }
                        }
                    }
                }
                .fixedSize()
            }
            .padding(12)
            Divider()
            List {
                ForEach(source?.filters ?? []) { filter in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { !filter.bypass },
                            set: { on in studio.updateAudioSource(sourceID) { s in
                                if let i = s.filters.firstIndex(where: { $0.id == filter.id }) { s.filters[i].bypass = !on }
                            } }
                        ))
                        .labelsHidden()
                        .help("Enable / bypass")
                        Text(filter.name).foregroundStyle(filter.bypass ? .secondary : .primary)
                        Spacer()
                        Button("Edit…") { studio.openFilterUI(sourceID: sourceID, filterID: filter.id) }
                        Button { studio.moveFilter(filter.id, in: sourceID, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless)
                        Button { studio.moveFilter(filter.id, in: sourceID, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                        Button { studio.removeFilter(filter.id, from: sourceID) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                if (source?.filters ?? []).isEmpty {
                    Text("No filters yet. Try Apple ▸ AUDynamicsProcessor (compressor/gate), AUNBandEQ, or AUPeakLimiter — or any Audio Unit plugin you've installed.")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            Divider()
            HStack {
                Text("Filters run top to bottom. Turn on 🎧 in the mixer to hear the result.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 420)
        .buttonStyle(FlatButtonStyle())
        .onAppear { plugins = AudioPlugins.available() }
    }
}
