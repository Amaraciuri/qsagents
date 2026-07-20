import Foundation
import Sparkle
import SwiftUI

/// Long-lived Sparkle controller (must outlive menus / Support UI).
@MainActor
final class SparkleUpdater: ObservableObject {
    let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var updater: SPUUpdater { controller.updater }

    func checkForUpdates() {
        updater.checkForUpdates()
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
