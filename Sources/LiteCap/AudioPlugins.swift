import AppKit
import AudioToolbox
import CoreAudioKit
import AVFoundation
import SwiftUI

/// Audio Unit plugins (AUv2 and AUv3): everything in /Library/Audio/Plug-Ins/Components,
/// ~/Library/Audio/Plug-Ins/Components, app-extension AUs, and Apple's built-ins.
enum AudioPlugins {
    static func available() -> [AVAudioUnitComponent] {
        let manager = AVAudioUnitComponentManager.shared()
        let types = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect]
        return types
            .flatMap { type in
                manager.components(matching: AudioComponentDescription(
                    componentType: type, componentSubType: 0, componentManufacturer: 0,
                    componentFlags: 0, componentFlagsMask: 0
                ))
            }
            .sorted { ($0.manufacturerName, $0.name) < ($1.manufacturerName, $1.name) }
    }

    static func config(for component: AVAudioUnitComponent) -> AudioFilterConfig {
        let d = component.audioComponentDescription
        return AudioFilterConfig(name: component.name, type: d.componentType, subType: d.componentSubType,
                                 manufacturer: d.componentManufacturer)
    }

    static func instantiate(_ filter: AudioFilterConfig) async throws -> AVAudioUnit {
        let description = AudioComponentDescription(
            componentType: filter.type, componentSubType: filter.subType, componentManufacturer: filter.manufacturer,
            componentFlags: 0, componentFlagsMask: 0
        )
        let unit = try await AVAudioUnit.instantiate(with: description, options: [])
        if let data = filter.state,
           let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            unit.auAudioUnit.fullState = state
        }
        return unit
    }
}

/// Opens a plugin's own editor window (or a generic slider panel if it has none).
@MainActor
enum PluginWindows {
    private static var windows: [UUID: NSWindow] = [:]
    private static var observers: [UUID: NSObjectProtocol] = [:]

    static func show(_ unit: AVAudioUnit, id: UUID, title: String) {
        if let window = windows[id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        unit.auAudioUnit.requestViewController { @Sendable controller in
            Task { @MainActor in
                let content: NSViewController = controller
                    ?? NSHostingController(rootView: GenericPluginView(unit: unit.auAudioUnit))
                let window = NSWindow(contentViewController: content)
                window.title = title
                window.styleMask.insert([.titled, .closable])
                window.isReleasedWhenClosed = false
                let preferred = content.preferredContentSize
                if preferred.width > 50 && preferred.height > 50 { window.setContentSize(preferred) }
                window.center()
                window.makeKeyAndOrderFront(nil)
                windows[id] = window
                observers[id] = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { _ in
                    MainActor.assumeIsolated {
                        windows[id] = nil
                        if let o = observers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(o) }
                    }
                }
            }
        }
    }

    static func close(_ id: UUID) { windows[id]?.close() }
}

/// Fallback editor: one slider per parameter.
struct GenericPluginView: View {
    let unit: AUAudioUnit

    var body: some View {
        let parameters = unit.parameterTree?.allParameters ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if parameters.isEmpty {
                    Text("This plugin has no adjustable parameters.").foregroundStyle(.secondary)
                }
                ForEach(parameters, id: \.address) { ParameterRow(parameter: $0) }
            }
            .padding(16)
        }
        .frame(minWidth: 460, minHeight: 240)
    }
}

private struct ParameterRow: View {
    let parameter: AUParameter
    @State private var value: Float = 0

    var body: some View {
        HStack {
            Text(parameter.displayName).frame(width: 160, alignment: .leading).lineLimit(1)
            if parameter.maxValue > parameter.minValue {
                Slider(value: $value, in: parameter.minValue...parameter.maxValue)
                    .onChange(of: value) { _, newValue in parameter.value = newValue }
            }
            Text(String(format: "%.2f %@", value, parameter.unitName ?? ""))
                .font(.caption.monospacedDigit()).frame(width: 80, alignment: .trailing)
        }
        .onAppear { value = parameter.value }
    }
}
