import AppKit
import AVFoundation
import SwiftUI

// MARK: - Source properties

/// Label on the left (fixed width, right-aligned), control on the right.
private struct Row<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 84, alignment: .trailing)
            content
            Spacer(minLength: 0)
        }
    }
}

struct SourcePropertiesSheet: View {
    @EnvironmentObject var studio: Studio
    let sourceID: UUID
    @State private var draft: VideoSourceConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let binding = Binding($draft) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(binding.wrappedValue.kind.typeName).font(.headline).padding(.bottom, 2)
                    Row(label: "Name") { TextField("", text: binding.name).frame(width: 300) }
                    KindEditor(config: binding)
                    if let itemID {
                        Divider().padding(.vertical, 4)
                        TransformEditor(itemID: itemID)
                    }
                }
                .padding(18)
            } else {
                ProgressView().padding(40)
            }
            Divider()
            HStack {
                if case .browser = draft?.kind {
                    Button("Interact…") { studio.browserSource(sourceID)?.interact() }
                    Button("Reload") { studio.browserSource(sourceID)?.reload() }
                }
                Spacer()
                Button("Cancel") { studio.editingSourceID = nil }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                Button("Done") { apply(); studio.editingSourceID = nil }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480)
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
        studio.updateVideoSource(sourceID) { config in
            let linkedAudio = config.audioSourceID // managed by Studio; the draft's copy may be stale
            config = draft
            config.audioSourceID = linkedAudio
        }
    }
}

private struct KindEditor: View {
    @EnvironmentObject var studio: Studio
    @Binding var config: VideoSourceConfig

    var body: some View {
        switch config.kind {
        case .display(let id):
            Row(label: "Display") {
                Picker("", selection: Binding(get: { String(id) }, set: { config.kind = .display(id: UInt32($0) ?? 0) })) {
                    if !studio.displays.contains(where: { $0.id == String(id) }) { Text("Main display").tag(String(id)) }
                    ForEach(studio.displays) { Text($0.title).tag($0.id) }
                }
                .labelsHidden().frame(width: 300)
            }
            Row(label: "") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Capture cursor", isOn: $config.showCursor)
                    Toggle("Hide Dock and menu bar", isOn: Binding(
                        get: { config.hideSystemUI == true }, set: { config.hideSystemUI = $0 }
                    ))
                }
            }
        case .window(let id, _, let title):
            Row(label: "Window") {
                Picker("", selection: Binding(get: { id }, set: { newID in
                    if let w = studio.windows.first(where: { $0.id == newID }) {
                        config.kind = .window(id: w.id, bundleID: w.bundleID, title: w.windowTitle)
                        config.appName = w.appName
                    }
                })) {
                    if !studio.windows.contains(where: { $0.id == id }) {
                        Text(title.isEmpty ? "Choose a window" : "\(title) (not open)").tag(id)
                    }
                    ForEach(studio.windows) { Text($0.title).tag($0.id) }
                }
                .labelsHidden().frame(width: 260)
                Button { Task { await studio.refreshPickers() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh window list")
            }
            Row(label: "") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Capture cursor", isOn: $config.showCursor)
                    Toggle("Capture audio", isOn: Binding(
                        get: { config.captureAudio == true }, set: { config.captureAudio = $0 }
                    ))
                }
            }
        case .browser(let url, let width, let height, let css, let fps):
            Row(label: "URL") {
                TextField("", text: Binding(get: { url }, set: { config.kind = .browser(url: $0, width: width, height: height, css: css, fps: fps) }))
                    .frame(width: 300)
            }
            Row(label: "Size") {
                TextField("", value: Binding(get: { width }, set: { config.kind = .browser(url: url, width: max(16, min($0, 7680)), height: height, css: css, fps: fps) }), format: plainNumber)
                    .frame(width: 70)
                Text("×").foregroundStyle(.secondary)
                TextField("", value: Binding(get: { height }, set: { config.kind = .browser(url: url, width: width, height: max(16, min($0, 4320)), css: css, fps: fps) }), format: plainNumber)
                    .frame(width: 70)
            }
            Row(label: "Frame rate") {
                TextField("", value: Binding(get: { fps }, set: { config.kind = .browser(url: url, width: width, height: height, css: css, fps: max(1, min($0, 60))) }), format: plainNumber)
                    .frame(width: 70)
                Text("fps").foregroundStyle(.secondary)
            }
            Row(label: "CSS") {
                TextEditor(text: Binding(get: { css }, set: { config.kind = .browser(url: url, width: width, height: height, css: $0, fps: fps) }))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 300, height: 60)
                    .overlay(Rectangle().stroke(Color.gray.opacity(0.4)))
            }
        case .image(let path):
            Row(label: "File") {
                Text((path as NSString).lastPathComponent).lineLimit(1).frame(maxWidth: 220, alignment: .leading)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image]
                    if panel.runModal() == .OK, let url = panel.url { config.kind = .image(path: url.path) }
                }
            }
        case .camera(let deviceID):
            Row(label: "Device") {
                Picker("", selection: Binding(get: { deviceID }, set: { config.kind = .camera(deviceID: $0) })) {
                    if !studio.cameras.contains(where: { $0.id == deviceID }) { Text("Default camera").tag(deviceID) }
                    ForEach(studio.cameras) { Text($0.title).tag($0.id) }
                }
                .labelsHidden().frame(width: 300)
            }
        }
    }
}

/// Live position/size/crop editing (applies immediately; crop never stretches).
private struct TransformEditor: View {
    @EnvironmentObject var studio: Studio
    let itemID: UUID

    var body: some View {
        if let item = studio.item(itemID) {
            let f = item.frame ?? CanvasRect(x: 0, y: 0, w: 0, h: 0)
            VStack(alignment: .leading, spacing: 9) {
                Row(label: "Position") {
                    number("X", f.x) { v in studio.updateItem(itemID) { $0.frame?.x = v } }
                    number("Y", f.y) { v in studio.updateItem(itemID) { $0.frame?.y = v } }
                }
                Row(label: "Size") {
                    number("W", f.w) { v in studio.updateItem(itemID) { $0.frame?.w = max(1, v) } }
                    number("H", f.h) { v in studio.updateItem(itemID) { $0.frame?.h = max(1, v) } }
                }
                Row(label: "") {
                    Button("Fit") { studio.transform(itemID, .fit) }
                    Button("Stretch") { studio.transform(itemID, .stretch) }
                    Button("Center") { studio.transform(itemID, .center) }
                    Button("Reset") { studio.transform(itemID, .reset) }
                }
                Row(label: "Crop") {
                    number("L", item.crop.left) { v in var c = item.crop; c.left = v; studio.setCrop(itemID, c) }
                    number("R", item.crop.right) { v in var c = item.crop; c.right = v; studio.setCrop(itemID, c) }
                }
                Row(label: "") {
                    number("T", item.crop.top) { v in var c = item.crop; c.top = v; studio.setCrop(itemID, c) }
                    number("B", item.crop.bottom) { v in var c = item.crop; c.bottom = v; studio.setCrop(itemID, c) }
                }
            }
        }
    }

    private func number(_ label: String, _ value: Double, _ set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary).frame(width: 14, alignment: .trailing)
            // `+ 0` turns -0 into 0.
            TextField("", value: Binding(get: { value.rounded() + 0 }, set: set), format: plainDecimal)
                .frame(width: 80)
        }
    }
}

// MARK: - Audio filters

struct FiltersSheet: View {
    @EnvironmentObject var studio: Studio
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
                Button("Done") { studio.filtersSourceID = nil }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 420)
        .buttonStyle(FlatButtonStyle())
        .onAppear { plugins = AudioPlugins.available() }
    }
}
