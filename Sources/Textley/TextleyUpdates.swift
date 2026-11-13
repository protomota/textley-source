#if TEXTLEY_SPARKLE
import Foundation
import Observation
import Sparkle

/// Sparkle updates for the Developer ID build. Debug and source builds compile without it.
@MainActor
@Observable
final class TextleyUpdates: NSObject {
    static let shared = TextleyUpdates()

    private(set) var canCheck = false
    private(set) var automaticUpdates = false
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    func start() {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        self.controller = controller
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            },
            controller.updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
        ]
        controller.startUpdater()
        refresh()
    }

    @objc func check(_ sender: Any? = nil) {
        guard let updater = controller?.updater, updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    func setAutomaticUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
        refresh()
    }

    private func refresh() {
        canCheck = controller?.updater.canCheckForUpdates ?? false
        automaticUpdates = controller?.updater.automaticallyDownloadsUpdates ?? false
    }
}
#endif
