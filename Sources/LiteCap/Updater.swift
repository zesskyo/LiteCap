import Combine
import Foundation
import Sparkle
import SwiftUI

/// Wraps Sparkle. Updates come from the appcast attached to the latest GitHub release
/// and must be signed with the project's EdDSA key (SUPublicEDKey in Info.plist).
@MainActor
final class Updater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController?
    private let gate: UpdateGate

    /// False for builds made without a public key (e.g. before keys were set up).
    var isAvailable: Bool { controller != nil }

    init(isLive: @escaping @MainActor () -> Bool) {
        let gate = UpdateGate()
        gate.isLive = isLive
        self.gate = gate
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? ""
        guard !key.isEmpty else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: gate, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }
}

/// Keeps background update checks (and their pop-ups) away while you're recording or streaming.
final class UpdateGate: NSObject, SPUUpdaterDelegate {
    var isLive: (@MainActor () -> Bool)?

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground else { return }
        let live = MainActor.assumeIsolated { isLive?() ?? false }
        if live {
            throw NSError(domain: "LiteCap", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Skipping update check while live."])
        }
    }
}

/// "Check for Updates…" menu item.
struct CheckForUpdatesButton: View {
    @ObservedObject var updater: Updater

    var body: some View {
        if updater.isAvailable {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}
