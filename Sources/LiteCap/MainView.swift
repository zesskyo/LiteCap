import AppKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        VStack(spacing: 0) {
            PreviewPanel()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.85))
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScenesPanel().frame(width: 170)
                Divider()
                SourcesPanel().frame(width: 250)
                Divider()
                MixerPanel().frame(minWidth: 300, maxWidth: .infinity)
                Divider()
                ControlsPanel().frame(width: 190)
            }
            .frame(height: 270)
            Divider()
            StatusBar()
        }
        .frame(minWidth: 1040, minHeight: 720)
        .textFieldStyle(.squareBorder)
        .onAppear { studio.windowAppeared() }
        .onDisappear { studio.windowDisappeared() }
        .sheet(item: Binding(get: { studio.editingSourceID.map(IdentifiedID.init) },
                             set: { studio.editingSourceID = $0?.id })) { wrapped in
            SourcePropertiesSheet(sourceID: wrapped.id)
        }
        .sheet(item: Binding(get: { studio.filtersSourceID.map(IdentifiedID.init) },
                             set: { studio.filtersSourceID = $0?.id })) { wrapped in
            FiltersSheet(sourceID: wrapped.id)
        }
        .sheet(isPresented: $studio.showingTracks) { TracksSheet() }
    }
}

struct IdentifiedID: Identifiable {
    let id: UUID
}

// MARK: - Preview

private struct PreviewPanel: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        if studio.previewHidden {
            VStack(spacing: 8) {
                Text("Preview hidden").foregroundStyle(.secondary)
                Button("Show Preview") { studio.previewHidden = false }.buttonStyle(FlatButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let W = CGFloat(studio.project.video.width), H = CGFloat(studio.project.video.height)
            ZStack {
                PreviewSurface(compositor: studio.compositor)
                EditOverlay()
            }
            .aspectRatio(W / H, contentMode: .fit)
            .padding(6)
            .onAppear { studio.previewAppeared() }
            .onDisappear { studio.previewDisappeared() }
        }
    }
}

/// Click to select, drag to move, drag a corner to resize (⇧ = free aspect).
/// Edges and centers snap to the canvas and to other sources.
private struct EditOverlay: View {
    @EnvironmentObject var studio: Studio
    @State private var mode: DragMode = .inactive
    @State private var guides: [Guide] = []

    private enum DragMode {
        case inactive
        case idle
        case move(UUID, CanvasRect)
        case resize(UUID, CanvasRect, corner: Int)
    }

    private struct Guide: Hashable {
        let vertical: Bool
        let position: Double
    }

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / CGFloat(max(1, studio.project.video.width))
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                ForEach(guides, id: \.self) { guide in
                    if guide.vertical {
                        Rectangle().fill(Color.cyan).frame(width: 1, height: geo.size.height)
                            .offset(x: CGFloat(guide.position) * scale)
                    } else {
                        Rectangle().fill(Color.cyan).frame(width: geo.size.width, height: 1)
                            .offset(y: CGFloat(guide.position) * scale)
                    }
                }
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
                    .onEnded { _ in
                        mode = .inactive
                        guides = []
                    }
            )
            .contextMenu { ItemMenu(itemID: studio.selectedItemID) }
        }
    }

    private static func corner(_ r: CGRect, _ i: Int) -> CGPoint {
        CGPoint(x: i % 2 == 0 ? r.minX : r.maxX, y: i < 2 ? r.minY : r.maxY)
    }

    /// Snap lines: canvas edges and center, plus every other visible source's edges and center.
    private func targets(excluding id: UUID) -> (x: [Double], y: [Double]) {
        let W = Double(studio.project.video.width), H = Double(studio.project.video.height)
        var xs = [0, W / 2, W], ys = [0, H / 2, H]
        for item in studio.project.currentScene?.items ?? [] where item.id != id && item.visible {
            guard let f = item.frame else { continue }
            xs += [f.x, f.x + f.w / 2, f.x + f.w]
            ys += [f.y, f.y + f.h / 2, f.y + f.h]
        }
        return (xs, ys)
    }

    /// Best correction moving any of `edges` onto any target, within `threshold`.
    private static func snap(_ edges: [Double], to targets: [Double], threshold: Double) -> (delta: Double, line: Double)? {
        var best: (delta: Double, line: Double)?
        for edge in edges {
            for target in targets {
                let d = target - edge
                if abs(d) <= threshold, abs(d) < abs(best?.delta ?? .infinity) { best = (d, target) }
            }
        }
        return best
    }

    private func drag(_ value: DragGesture.Value, scale: CGFloat) {
        if case .inactive = mode { begin(value, scale: scale) }
        let dx = Double(value.translation.width / scale), dy = Double(value.translation.height / scale)
        let threshold = 8 / Double(scale) // 8 screen points, whatever the preview size
        let noSnap = NSEvent.modifierFlags.contains(.command) // hold ⌘ to place freely
        switch mode {
        case .move(let id, let start):
            var f = start
            f.x += dx
            f.y += dy
            var newGuides: [Guide] = []
            if !noSnap {
                let t = targets(excluding: id)
                if let s = Self.snap([f.x, f.x + f.w / 2, f.x + f.w], to: t.x, threshold: threshold) {
                    f.x += s.delta
                    newGuides.append(Guide(vertical: true, position: s.line))
                }
                if let s = Self.snap([f.y, f.y + f.h / 2, f.y + f.h], to: t.y, threshold: threshold) {
                    f.y += s.delta
                    newGuides.append(Guide(vertical: false, position: s.line))
                }
            }
            guides = newGuides
            studio.updateItem(id) { $0.frame = f }
        case .resize(let id, let start, let corner):
            let free = NSEvent.modifierFlags.contains(.shift)
            let left = corner % 2 == 0, top = corner < 2
            let anchorX = left ? start.x + start.w : start.x
            let anchorY = top ? start.y + start.h : start.y
            var w = max(16, left ? start.w - dx : start.w + dx)
            var h = max(16, top ? start.h - dy : start.h + dy)
            let aspect = start.w / max(1, start.h)
            let widthLeads = abs(dx) * start.h >= abs(dy) * start.w
            if !free { if widthLeads { h = w / aspect } else { w = h * aspect } }
            var newGuides: [Guide] = []
            if !noSnap {
                let t = targets(excluding: id)
                // Snap the moving edge along whichever axis leads, then keep the aspect ratio.
                if free || widthLeads {
                    let edge = left ? anchorX - w : anchorX + w
                    if let s = Self.snap([edge], to: t.x, threshold: threshold) {
                        w = max(16, w + (left ? -s.delta : s.delta))
                        if !free { h = w / aspect }
                        newGuides.append(Guide(vertical: true, position: s.line))
                    }
                }
                if free || !widthLeads {
                    let edge = top ? anchorY - h : anchorY + h
                    if let s = Self.snap([edge], to: t.y, threshold: threshold) {
                        h = max(16, h + (top ? -s.delta : s.delta))
                        if !free { w = h * aspect }
                        newGuides.append(Guide(vertical: false, position: s.line))
                    }
                }
            }
            guides = newGuides
            let x = left ? anchorX - w : anchorX
            let y = top ? anchorY - h : anchorY
            studio.updateItem(id) { $0.frame = CanvasRect(x: x, y: y, w: w, h: h) }
        default:
            break
        }
    }

    private func begin(_ value: DragGesture.Value, scale: CGFloat) {
        mode = .idle
        let p = value.startLocation
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

/// Right-click menu for a scene item.
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
            Button("Reset Size and Crop") { studio.transform(itemID, .reset) }
            Divider()
            Button(item.visible ? "Hide" : "Show") { studio.updateItem(itemID) { $0.visible.toggle() } }
            Button(item.locked ? "Unlock" : "Lock") { studio.updateItem(itemID) { $0.locked.toggle() } }
            Button("Move Up") { studio.moveItem(itemID, by: 1) }
            Button("Move Down") { studio.moveItem(itemID, by: -1) }
            Divider()
            Button("Remove", role: .destructive) { studio.removeItem(itemID) }
        } else {
            Text("Select a source first")
        }
    }
}

// MARK: - Panels

struct PanelHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 2) {
            Text(title).font(.headline)
            Spacer()
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

private struct ScenesPanel: View {
    @EnvironmentObject var studio: Studio
    @State private var renaming: UUID?
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Scenes") {
                Button { studio.addScene() } label: { Image(systemName: "plus") }.buttonStyle(IconButtonStyle())
                Button { studio.removeScene(studio.project.currentSceneID) } label: { Image(systemName: "minus") }
                    .buttonStyle(IconButtonStyle()).disabled(studio.project.scenes.count < 2)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(studio.project.scenes) { scene in
                        FlatRow(selected: scene.id == studio.project.currentSceneID) {
                            Text(scene.name).lineLimit(1)
                        }
                        .onTapGesture { studio.project.currentSceneID = scene.id }
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
            }
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
                    .buttonStyle(IconButtonStyle()).disabled(studio.selectedItemID == nil)
                Button { if let id = studio.selectedItemID { studio.moveItem(id, by: 1) } } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(IconButtonStyle()).disabled(studio.selectedItemID == nil)
                Button { if let id = studio.selectedItemID { studio.moveItem(id, by: -1) } } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(IconButtonStyle()).disabled(studio.selectedItemID == nil)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        let source = studio.project.videoSource(item.sourceID)
                        FlatRow(selected: item.id == studio.selectedItemID) {
                            Image(systemName: source?.kind.symbol ?? "questionmark").frame(width: 16)
                            Text(source?.name ?? "Missing").lineLimit(1)
                                .foregroundStyle(item.visible ? .primary : .secondary)
                            Spacer()
                            Button { studio.updateItem(item.id) { $0.visible.toggle() } } label: {
                                Image(systemName: item.visible ? "eye" : "eye.slash")
                            }.buttonStyle(IconButtonStyle())
                            Button { studio.updateItem(item.id) { $0.locked.toggle() } } label: {
                                Image(systemName: item.locked ? "lock" : "lock.open")
                            }.buttonStyle(IconButtonStyle())
                        }
                        .onTapGesture(count: 2) { studio.editingSourceID = item.sourceID }
                        .onTapGesture { studio.selectedItemID = item.id }
                        .contextMenu { ItemMenu(itemID: item.id) }
                    }
                }
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
        .frame(width: 22)
        .onAppear { Task { await studio.refreshPickers() } }
    }
}

private struct ControlsPanel: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Controls").font(.headline).padding(.bottom, 2)
            Button(studio.isStreaming ? "Stop Streaming" : "Start Streaming") { studio.toggleStreaming() }
                .buttonStyle(FlatButtonStyle(active: studio.isStreaming, fullWidth: true))
                .disabled(studio.isBusy)
            Button(studio.isRecording ? "Stop Recording" : "Start Recording") { studio.toggleRecording() }
                .buttonStyle(FlatButtonStyle(active: studio.isRecording, fullWidth: true))
            SettingsLink { Text("Settings") }
                .buttonStyle(FlatButtonStyle(fullWidth: true))
            Button("Recordings") { studio.revealRecordings() }
                .buttonStyle(FlatButtonStyle(fullWidth: true))
            Button(studio.previewHidden ? "Show Preview" : "Hide Preview") { studio.previewHidden.toggle() }
                .buttonStyle(FlatButtonStyle(fullWidth: true))
            Spacer()
            LiveTimers()
        }
        .padding(8)
    }
}

private struct LiveTimers: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 2) {
                if let start = studio.streamStarted {
                    Text("LIVE \(elapsed(start, context.date))").foregroundStyle(Theme.active)
                } else if case .reconnecting(let n) = studio.streamState {
                    Text("Reconnecting (\(n))…").foregroundStyle(.orange)
                }
                if let start = studio.recordStarted {
                    Text("REC \(elapsed(start, context.date))").foregroundStyle(Theme.active)
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
                Text(problem).foregroundStyle(.orange).lineLimit(1)
                    .help(stats.sourceProblems.joined(separator: "\n"))
            }
            Text(String(format: "CPU %.1f%%", stats.cpu))
            if let gpu = stats.gpu { Text(String(format: "GPU %.0f%%", gpu)) }
            Text(String(format: "%.1f / %d fps", stats.fps, studio.project.video.fps))
            Text("skipped \(stats.skipped)").foregroundStyle(stats.skipped > 0 ? Color.orange : Color.secondary)
            if studio.isStreaming {
                Text("\(stats.streamKbps) kb/s").foregroundStyle(stats.congested ? Color.orange : Color.primary)
                Text("dropped \(stats.dropped)").foregroundStyle(stats.dropped > 0 ? Color.orange : Color.secondary)
            }
            if studio.isRecording { Text(String(format: "%.0f MB", stats.recordMB)) }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}
