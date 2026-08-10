//
//  TLocationApp.swift
//  TLocation
//
//  Created by Stephen on 3/26/25.
//

import SwiftUI

@main
struct TLocationApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var shouldAttemptTunnelReconnect = false

    init() {
        AppBootstrapper.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .task {
                    await downloadMissingDeveloperDiskImageFiles()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    handleScenePhaseChange(newPhase)
                }
        }
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            shouldAttemptTunnelReconnect = true
        case .active:
            if shouldAttemptTunnelReconnect {
                shouldAttemptTunnelReconnect = false
                startTunnelInBackground(showErrorUI: false)
            }
        default:
            break
        }
    }

    private func downloadMissingDeveloperDiskImageFiles() async {
        do {
            try await DeveloperDiskImageService.shared.downloadMissingFiles()
            MountingProgress.shared.pubMount()
        } catch {
            LogManager.shared.addErrorLog("DDI download failed: \(error.localizedDescription)")
            await MainActor.run {
                let detail = error.localizedDescription
                showAlert(
                    title: String(localized: "An Error has Occurred"),
                    message: String(localized: "Could not download the Developer Disk Image (DDI): \(detail)"),
                    showOk: true
                )
            }
        }
    }
}
