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
        .overlay { dialog }
    }

    /// Dialogs are square panels inside the window (macOS sheets have rounded corners).
    @ViewBuilder private var dialog: some View {
        if let id = studio.editingSourceID {
            ModalPanel { SourcePropertiesSheet(sourceID: id).id(id) }
        } else if let id = studio.filtersSourceID {
            ModalPanel { FiltersSheet(sourceID: id).id(id) }
        } else if studio.showingTracks {
            ModalPanel { TracksSheet() }
        }
    }
}

/// Dims the window and shows a square panel on top.
struct ModalPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).contentShape(Rectangle()).onTapGesture {}
            content
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(Rectangle().stroke(Color.gray.opacity(0.4), lineWidth: 1))
                .shadow(radius: 12)
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

/// Click to select, drag to move, drag a handle to resize.
///   ⇧ while dragging a handle = crop that side instead (content isn't stretched).
///   ⌥ on a corner = free aspect ratio.  ⌘ = no snapping.
/// While dragging only the video layer updates; the project is written once on release.
private struct EditOverlay: View {
    @EnvironmentObject var studio: Studio
    @State private var mode: DragMode = .inactive

    private enum DragMode {
        case inactive
        case idle
        case move(UUID, CanvasRect, Crop)
        case resize(UUID, CanvasRect, Crop, handle: Handle)
        case crop(UUID, CanvasRect, Crop, handle: Handle, source: CGSize)
    }

    /// Corners and edge midpoints.
    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
        var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
        var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
        var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
        var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }

        func point(in r: CGRect) -> CGPoint {
            CGPoint(x: movesLeft ? r.minX : (movesRight ? r.maxX : r.midX),
                    y: movesTop ? r.minY : (movesBottom ? r.maxY : r.midY))
        }
    }

    private struct Guide: Hashable {
        let vertical: Bool
        let position: Double
    }

    var body: some View {
        // The box, handles and guides are drawn by the Metal preview (in step with the video);
        // this layer only handles the mouse.
        GeometryReader { geo in
            let scale = geo.size.width / CGFloat(max(1, studio.project.video.width))
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in drag(value, scale: scale) }
                        .onEnded { _ in finish() }
                )
                .contextMenu { ItemMenu(itemID: studio.selectedItemID) }
        }
    }

    /// Snap lines: canvas edges and center, plus the edges of other visible sources.
    private func targets(excluding id: UUID) -> (x: [Double], y: [Double]) {
        let W = Double(studio.project.video.width), H = Double(studio.project.video.height)
        var xs = [0, W / 2, W], ys = [0, H / 2, H]
        for item in studio.project.currentScene?.items ?? [] where item.id != id && item.visible {
            guard let f = item.frame else { continue }
            xs += [f.x, f.x + f.w]
            ys += [f.y, f.y + f.h]
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

    private func finish() {
        studio.endDrag()
        mode = .inactive
    }

    private func show(_ id: UUID, _ frame: CanvasRect, _ crop: Crop) {
        studio.previewDrag(id, frame: frame, crop: crop)
    }

    private func drag(_ value: DragGesture.Value, scale: CGFloat) {
        if case .inactive = mode { begin(value, scale: scale) }
        let dx = Double(value.translation.width / scale), dy = Double(value.translation.height / scale)
        let threshold = 6 / Double(scale) // 6 screen points, whatever the preview size
        let flags = NSEvent.modifierFlags
        let snapping = !flags.contains(.command)
        var newGuides: [Guide] = []
        switch mode {
        case .move(let id, let start, let crop):
            var f = start
            f.x += dx
            f.y += dy
            if snapping {
                let t = targets(excluding: id)
                let W = Double(studio.project.video.width), H = Double(studio.project.video.height)
                // Edges snap to everything; the center only to the canvas center.
                let sx = [Self.snap([f.x, f.x + f.w], to: t.x, threshold: threshold),
                          Self.snap([f.x + f.w / 2], to: [W / 2], threshold: threshold)]
                    .compactMap { $0 }.min { abs($0.delta) < abs($1.delta) }
                let sy = [Self.snap([f.y, f.y + f.h], to: t.y, threshold: threshold),
                          Self.snap([f.y + f.h / 2], to: [H / 2], threshold: threshold)]
                    .compactMap { $0 }.min { abs($0.delta) < abs($1.delta) }
                if let s = sx {
                    f.x += s.delta
                    newGuides.append(Guide(vertical: true, position: s.line))
                }
                if let s = sy {
                    f.y += s.delta
                    newGuides.append(Guide(vertical: false, position: s.line))
                }
            }
            show(id, f, crop)

        case .resize(let id, let start, let crop, let handle):
            var left = start.x, right = start.x + start.w, top = start.y, bottom = start.y + start.h
            if handle.movesLeft { left = min(right - 16, left + dx) }
            if handle.movesRight { right = max(left + 16, right + dx) }
            if handle.movesTop { top = min(bottom - 16, top + dy) }
            if handle.movesBottom { bottom = max(top + 16, bottom + dy) }
            if snapping {
                let t = targets(excluding: id)
                if handle.movesLeft, let s = Self.snap([left], to: t.x, threshold: threshold) { left += s.delta; newGuides.append(Guide(vertical: true, position: s.line)) }
                if handle.movesRight, let s = Self.snap([right], to: t.x, threshold: threshold) { right += s.delta; newGuides.append(Guide(vertical: true, position: s.line)) }
                if handle.movesTop, let s = Self.snap([top], to: t.y, threshold: threshold) { top += s.delta; newGuides.append(Guide(vertical: false, position: s.line)) }
                if handle.movesBottom, let s = Self.snap([bottom], to: t.y, threshold: threshold) { bottom += s.delta; newGuides.append(Guide(vertical: false, position: s.line)) }
            }
            // Corners keep the aspect ratio (unless ⌥): follow the axis that moved most.
            if handle.isCorner && !flags.contains(.option) {
                let aspect = start.w / max(1, start.h)
                let w = right - left, h = bottom - top
                if abs(w - start.w) / start.w >= abs(h - start.h) / start.h {
                    let newH = w / aspect
                    if handle.movesTop { top = bottom - newH } else { bottom = top + newH }
                } else {
                    let newW = h * aspect
                    if handle.movesLeft { left = right - newW } else { right = left + newW }
                }
            }
            show(id, CanvasRect(x: left, y: top, w: max(16, right - left), h: max(16, bottom - top)), crop)

        case .crop(let id, let start, let startCrop, let handle, let size):
            // Canvas pixels per source pixel; the frame edge follows the mouse, the rest stays put.
            let sx = start.w / max(1, Double(size.width) - startCrop.left - startCrop.right)
            let sy = start.h / max(1, Double(size.height) - startCrop.top - startCrop.bottom)
            var edgeX = handle.movesLeft ? start.x + dx : start.x + start.w + dx
            var edgeY = handle.movesTop ? start.y + dy : start.y + start.h + dy
            if snapping {
                let t = targets(excluding: id)
                if handle.movesLeft || handle.movesRight, let s = Self.snap([edgeX], to: t.x, threshold: threshold) {
                    edgeX += s.delta
                    newGuides.append(Guide(vertical: true, position: s.line))
                }
                if handle.movesTop || handle.movesBottom, let s = Self.snap([edgeY], to: t.y, threshold: threshold) {
                    edgeY += s.delta
                    newGuides.append(Guide(vertical: false, position: s.line))
                }
            }
            var crop = startCrop
            if handle.movesLeft { crop.left = startCrop.left + (edgeX - start.x) / sx }
            if handle.movesRight { crop.right = startCrop.right - (edgeX - (start.x + start.w)) / sx }
            if handle.movesTop { crop.top = startCrop.top + (edgeY - start.y) / sy }
            if handle.movesBottom { crop.bottom = startCrop.bottom - (edgeY - (start.y + start.h)) / sy }
            var item = SceneItem(sourceID: id, frame: start, crop: startCrop)
            item = Studio.applyCrop(item, crop, size: size)
            if let f = item.frame { show(id, f, item.crop) }

        default:
            break
        }
        studio.setGuides(newGuides.map { ($0.vertical, $0.position) })
    }

    private func begin(_ value: DragGesture.Value, scale: CGFloat) {
        mode = .idle
        let p = value.startLocation
        if let item = studio.item(studio.selectedItemID), let f = item.frame, !item.locked, item.visible {
            let rect = CGRect(x: f.x * scale, y: f.y * scale, width: f.w * scale, height: f.h * scale)
            for handle in Handle.allCases {
                let c = handle.point(in: rect)
                guard abs(c.x - p.x) <= 8 && abs(c.y - p.y) <= 8 else { continue }
                if NSEvent.modifierFlags.contains(.shift), let size = studio.sourcePixelSize(item.sourceID) {
                    mode = .crop(item.id, f, item.crop, handle: handle, source: size)
                } else {
                    mode = .resize(item.id, f, item.crop, handle: handle)
                }
                return
            }
        }
        let cx = Double(p.x / scale), cy = Double(p.y / scale)
        let hit = studio.project.currentScene?.items.reversed().first { item in
            item.visible && (item.frame?.contains(cx, cy) ?? false)
        }
        studio.selectedItemID = hit?.id
        if let hit, !hit.locked, let f = hit.frame { mode = .move(hit.id, f, hit.crop) }
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
                        // Select on the first click right away; a second click opens Properties.
                        .onTapGesture(count: 2) { studio.editingSourceID = item.sourceID }
                        .simultaneousGesture(TapGesture().onEnded { studio.selectedItemID = item.id })
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
            Button("Settings") { AppWindows.showSettings() }
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
