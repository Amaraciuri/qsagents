import Foundation
import Sparkle
import SwiftUI

/// Long-lived Sparkle controller (must outlive menus / Support UI).
@MainActor
final class SparkleUpdater: ObservableObject {
    let controller: SPUStandardUpdaterController

    init() {
        // Starts updater so Info.plist SUEnableAutomaticChecks / SUScheduledCheckInterval apply.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var updater: SPUUpdater { controller.updater }

    /// Manual check (Support / app menu). Shows Sparkle UI including “up to date”.
    func checkForUpdates() {
        updater.checkForUpdates()
    }

    /// Launch path: native Sparkle alert only when an update exists (silent if none).
    /// Scheduled background checks continue via Sparkle’s own timer when automatic checks are on.
    func checkForUpdatesInBackgroundAfterLaunch() {
        #if DEBUG
        // Unsigned / mismatched Debug builds often fail feed verification — stay silent.
        AppLogger.info("Sparkle: skipping launch background check in DEBUG")
        return
        #else
        guard updater.automaticallyChecksForUpdates else { return }
        updater.checkForUpdatesInBackground()
        #endif
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject var sparkle: SparkleUpdater

    var body: some View {
        Button(L("Cerca aggiornamenti…")) {
            sparkle.checkForUpdates()
        }
        .disabled(!sparkle.updater.canCheckForUpdates)
    }
}
