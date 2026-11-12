import AppKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        VStack(spacing: 0) {
            PreviewPanel()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScenesPanel().frame(width: 180)
                Divider()
                SourcesPanel().frame(width: 260)
                Divider()
                MixerPanel().frame(minWidth: 320, maxWidth: .infinity)
                Divider()
                ControlsPanel().frame(width: 210)
            }
            .frame(height: 260)
            Divider()
            StatusBar()
        }
        .frame(minWidth: 1040, minHeight: 720)
        .sheet(item: Binding(get: { studio.editingSourceID.map(IdentifiedID.init) },
                             set: { studio.editingSourceID = $0?.id })) { wrapped in
            SourcePropertiesSheet(sourceID: wrapped.id)
        }
        .sheet(item: Binding(get: { studio.filtersSourceID.map(IdentifiedID.init) },
                             set: { studio.filtersSourceID = $0?.id })) { wrapped in
            FiltersSheet(sourceID: wrapped.id)
        }
    }
}

struct IdentifiedID: Identifiable {
    let id: UUID
}

// MARK: - Preview

private struct PreviewPanel: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        let W = CGFloat(studio.project.video.width), H = CGFloat(studio.project.video.height)
        ZStack {
            PreviewSurface(compositor: studio.compositor)
            EditOverlay()
        }
        .aspectRatio(W / H, contentMode: .fit)
        .padding(8)
        .onAppear { studio.previewAppeared() }
        .onDisappear { studio.previewDisappeared() }
    }
}

/// Click to select, drag to move, drag a corner to resize (hold ⇧ to ignore aspect ratio).
private struct EditOverlay: View {
    @EnvironmentObject var studio: Studio
    @State private var mode: DragMode = .inactive

    private enum DragMode {
        case inactive
        case idle
        case move(UUID, CanvasRect)
        case resize(UUID, CanvasRect, corner: Int)
    }

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / CGFloat(max(1, studio.project.video.width))
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                if let item = studio.item(studio.selectedItemID), let f = item.frame, item.visible {
                    let rect = CGRect(x: f.x * scale, y: f.y * scale, width: f.w * scale, height: f.h * scale)
                    Rectangle()
                        .stroke(item.locked ? Color.orange : Color.red, lineWidth: 1.5)
                        .frame(width: max(1, rect.width), height: max(1, rect.height))
                        .offset(x: rect.minX, y: rect.minY)
                    if !item.locked {
                        ForEach(0..<4, id: \.self) { corner in
                            let p = Self.corner(rect, corner)
                            Rectangle().fill(Color.red).frame(width: 9, height: 9).offset(x: p.x - 4.5, y: p.y - 4.5)
                        }
                    }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in drag(value, scale: scale) }
                    .onEnded { _ in mode = .inactive }
            )
            .contextMenu { ItemMenu(itemID: studio.selectedItemID) }
        }
    }

    private static func corner(_ r: CGRect, _ i: Int) -> CGPoint {
        CGPoint(x: i % 2 == 0 ? r.minX : r.maxX, y: i < 2 ? r.minY : r.maxY)
    }

    private func drag(_ value: DragGesture.Value, scale: CGFloat) {
        if case .inactive = mode { begin(value, scale: scale) }
        let dx = Double(value.translation.width / scale), dy = Double(value.translation.height / scale)
        let W = Double(studio.project.video.width), H = Double(studio.project.video.height)
        let snap = 12.0
        switch mode {
        case .move(let id, let start):
            var f = start
            f.x += dx
            f.y += dy
            if abs(f.x) < snap { f.x = 0 }
            if abs(f.y) < snap { f.y = 0 }
            if abs(f.x + f.w - W) < snap { f.x = W - f.w }
            if abs(f.y + f.h - H) < snap { f.y = H - f.h }
            studio.updateItem(id) { $0.frame = f }
        case .resize(let id, let start, let corner):
            let free = NSEvent.modifierFlags.contains(.shift)
            let anchorX = corner % 2 == 0 ? start.x + start.w : start.x
            let anchorY = corner < 2 ? start.y + start.h : start.y
            var w = max(16, corner % 2 == 0 ? start.w - dx : start.w + dx)
            var h = max(16, corner < 2 ? start.h - dy : start.h + dy)
            if !free {
                let aspect = start.w / max(1, start.h)
                if abs(dx) * start.h > abs(dy) * start.w { h = w / aspect } else { w = h * aspect }
            }
            let x = corner % 2 == 0 ? anchorX - w : anchorX
            let y = corner < 2 ? anchorY - h : anchorY
            studio.updateItem(id) { $0.frame = CanvasRect(x: x, y: y, w: w, h: h) }
        default:
            break
        }
    }

    private func begin(_ value: DragGesture.Value, scale: CGFloat) {
        mode = .idle
        let p = value.startLocation
        // Handles of the selected item first.
        if let item = studio.item(studio.selectedItemID), let f = item.frame, !item.locked, item.visible {
            let rect = CGRect(x: f.x * scale, y: f.y * scale, width: f.w * scale, height: f.h * scale)
            for corner in 0..<4 {
                let c = Self.corner(rect, corner)
                if abs(c.x - p.x) <= 9 && abs(c.y - p.y) <= 9 {
                    mode = .resize(item.id, f, corner: corner)
                    return
                }
            }
        }
        let cx = Double(p.x / scale), cy = Double(p.y / scale)
        let hit = studio.project.currentScene?.items.reversed().first { item in
            item.visible && (item.frame?.contains(cx, cy) ?? false)
        }
        studio.selectedItemID = hit?.id
        if let hit, !hit.locked, let f = hit.frame { mode = .move(hit.id, f) }
    }
}

/// Shared right-click menu for a scene item.
struct ItemMenu: View {
    @EnvironmentObject var studio: Studio
    let itemID: UUID?

    var body: some View {
        if let itemID, let item = studio.item(itemID) {
            Button("Properties…") { studio.editingSourceID = item.sourceID }
            Divider()
            Button("Fit to Screen") { studio.transform(itemID, .fit) }
            Button("Stretch to Screen") { studio.transform(itemID, .stretch) }
            Button("Center") { studio.transform(itemID, .center) }
            Button("Reset Size & Crop") { studio.transform(itemID, .reset) }
            Divider()
            Button(item.visible ? "Hide" : "Show") { studio.updateItem(itemID) { $0.visible.toggle() } }
            Button(item.locked ? "Unlock" : "Lock") { studio.updateItem(itemID) { $0.locked.toggle() } }
            Button("Move Up") { studio.moveItem(itemID, by: 1) }
            Button("Move Down") { studio.moveItem(itemID, by: -1) }
            Divider()
            Button("Remove", role: .destructive) { studio.removeItem(itemID) }
        } else {
            Text("Click a source in the preview to select it")
        }
    }
}

// MARK: - Panels

struct PanelHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.headline)
            Spacer()
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct ScenesPanel: View {
    @EnvironmentObject var studio: Studio
    @State private var renaming: UUID?
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Scenes") {
                Button { studio.addScene() } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
                Button { studio.removeScene(studio.project.currentSceneID) } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless).disabled(studio.project.scenes.count < 2)
            }
            List(selection: Binding(get: { studio.project.currentSceneID },
                                    set: { if let id = $0 { studio.project.currentSceneID = id } })) {
                ForEach(studio.project.scenes) { scene in
                    Text(scene.name).tag(scene.id)
                        .contextMenu {
                            Button("Rename…") { newName = scene.name; renaming = scene.id }
                            Button("Duplicate") { studio.duplicateScene(scene.id) }
                            Button("Move Up") { studio.moveScene(scene.id, by: -1) }
                            Button("Move Down") { studio.moveScene(scene.id, by: 1) }
                            Divider()
                            Button("Remove", role: .destructive) { studio.removeScene(scene.id) }
                                .disabled(studio.project.scenes.count < 2)
                        }
                }
            }
            .listStyle(.inset)
        }
        .alert("Rename Scene", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let id = renaming, let i = studio.project.scenes.firstIndex(where: { $0.id == id }), !newName.isEmpty {
                    studio.project.scenes[i].name = newName
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

private struct SourcesPanel: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        let items = Array((studio.project.currentScene?.items ?? []).reversed())
        VStack(spacing: 0) {
            PanelHeader(title: "Sources") {
                AddSourceMenu()
                Button { if let id = studio.selectedItemID { studio.removeItem(id) } } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless).disabled(studio.selectedItemID == nil)
                Button { if let id = studio.selectedItemID { studio.moveItem(id, by: 1) } } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(studio.selectedItemID == nil)
                Button { if let id = studio.selectedItemID { studio.moveItem(id, by: -1) } } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(studio.selectedItemID == nil)
            }
            List(selection: $studio.selectedItemID) {
                ForEach(items) { item in
                    let source = studio.project.videoSource(item.sourceID)
                    HStack(spacing: 6) {
                        Image(systemName: source?.kind.symbol ?? "questionmark").frame(width: 16)
                        Text(source?.name ?? "Missing").lineLimit(1)
                            .foregroundStyle(item.visible ? .primary : .secondary)
                        Spacer()
                        Button { studio.updateItem(item.id) { $0.visible.toggle() } } label: {
                            Image(systemName: item.visible ? "eye" : "eye.slash")
                        }.buttonStyle(.borderless)
                        Button { studio.updateItem(item.id) { $0.locked.toggle() } } label: {
                            Image(systemName: item.locked ? "lock" : "lock.open")
                        }.buttonStyle(.borderless)
                    }
                    .tag(item.id)
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: UUID.self) { ids in
                ItemMenu(itemID: ids.first)
            } primaryAction: { ids in
                // Double-click opens properties.
                if let id = ids.first, let item = studio.item(id) { studio.editingSourceID = item.sourceID }
            }
        }
    }
}

private struct AddSourceMenu: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        Menu {
            Button("Display Capture") {
                studio.addVideoSource(.display(id: UInt32(studio.displays.first?.id ?? "") ?? 0))
            }
            Button("Window Capture") {
                if let w = studio.windows.first {
                    studio.addVideoSource(.window(id: w.id, bundleID: w.bundleID, title: w.windowTitle))
                } else {
                    studio.addVideoSource(.window(id: 0, bundleID: "", title: ""))
                }
            }
            Button("Browser") {
                studio.addVideoSource(.browser(url: "https://", width: 800, height: 600,
                                               css: VideoSourceKind.defaultBrowserCSS, fps: 30))
            }
            Button("Image…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.image]
                if panel.runModal() == .OK, let url = panel.url {
                    studio.addVideoSource(.image(path: url.path), name: url.deletingPathExtension().lastPathComponent)
                }
            }
            Button("Camera / Capture Card") {
                studio.addVideoSource(.camera(deviceID: studio.cameras.first?.id ?? ""))
            }
            let inScene = Set(studio.project.currentScene?.items.map(\.sourceID) ?? [])
            let others = studio.project.videoSources.filter { !inScene.contains($0.id) }
            if !others.isEmpty {
                Divider()
                Menu("Add Existing") {
                    ForEach(others) { source in Button(source.name) { studio.addExistingSource(source.id) } }
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

private struct ControlsPanel: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Controls").font(.headline)
            Button { studio.toggleStreaming() } label: {
                Label(studio.isStreaming ? "End Stream" : "Go Live",
                      systemImage: studio.isStreaming ? "stop.fill" : "dot.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(studio.isStreaming ? Color.purple : Color.accentColor)
            .disabled(studio.isBusy)

            Button { studio.toggleRecording() } label: {
                Label(studio.isRecording ? "Stop Recording" : "Start Recording",
                      systemImage: studio.isRecording ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(studio.isRecording ? Color.red : Color.accentColor)

            SettingsLink {
                Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity)
            }
            Button { studio.revealRecordings() } label: {
                Label("Recordings", systemImage: "folder").frame(maxWidth: .infinity)
            }
            if let last = studio.lastRecording {
                Button { studio.remuxToMP4(last) } label: {
                    Label("Remux Last to MP4", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
                }
                .help("Copies the .mkv into an .mp4 (no quality loss). Needs ffmpeg: brew install ffmpeg")
            }
            Spacer()
            LiveTimers()
        }
        .padding(10)
    }
}

private struct LiveTimers: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 2) {
                if let start = studio.streamStarted {
                    Label("LIVE \(elapsed(start, context.date))", systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.purple)
                } else if case .reconnecting(let n) = studio.streamState {
                    Label("Reconnecting (\(n))…", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let start = studio.recordStarted {
                    Label("REC \(elapsed(start, context.date))", systemImage: "record.circle.fill").foregroundStyle(.red)
                }
            }
            .font(.callout.monospacedDigit())
        }
    }

    private func elapsed(_ start: Date, _ now: Date) -> String {
        let t = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }
}

private struct StatusBar: View {
    @EnvironmentObject var studio: Studio
    var body: some View { StatusBarContent(stats: studio.stats) }
}

private struct StatusBarContent: View {
    @EnvironmentObject var studio: Studio
    @ObservedObject var stats: LiveStats

    var body: some View {
        HStack(spacing: 14) {
            Text(studio.message).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
            Spacer()
            if let problem = stats.sourceProblems.first {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(1)
                    .help(stats.sourceProblems.joined(separator: "\n"))
            }
            if studio.isStreaming {
                Text("\(stats.streamKbps) kbps").foregroundStyle(stats.congested ? Color.orange : Color.secondary)
                if stats.dropped > 0 { Text("\(stats.dropped) dropped").foregroundStyle(.orange) }
            }
            if studio.isRecording { Text(String(format: "%.0f MB", stats.recordMB)) }
            Text("\(Int(stats.fps.rounded())) / \(studio.project.video.fps) fps")
            Text("\(studio.project.video.width)×\(studio.project.video.height)")
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}
