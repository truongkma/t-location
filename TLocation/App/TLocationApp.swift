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

    /// Rebuilds `JITEnableContext`'s tunnel once per background → foreground
    /// round trip, so a tunnel that broke while the app was away (VPN dropped,
    /// device slept, Wi-Fi roamed) is repaired on return.
    ///
    /// It stands down while a location-simulation session is open. That session
    /// carries its own tunnel — `simulate_location` calls
    /// `tunnel_create_rppairing` into `LocationSimulationState`, entirely
    /// separate from the one this rebuilds — so reconnecting here does nothing
    /// for the simulation but does start a *second*, concurrent RemotePairing
    /// handshake against the same `<targetIP>:49152` endpoint. That endpoint is
    /// documented in this app's own recovery text as single-occupancy
    /// (`tunnelConnectionAlertMessage(for:)` in `TunnelManager.swift`, errno 48
    /// "address already in use"), and the moment this fires — the first seconds
    /// back in the
    /// foreground — is exactly when the resend loop may be rebuilding the
    /// simulation's session after a suspension. Two handshakes racing for one
    /// endpoint is a risk taken for no benefit, so it is not taken.
    ///
    /// Nothing is lost by waiting. `shouldAttemptTunnelReconnect` is deliberately
    /// left set, so the reconnect happens on the next foreground return once the
    /// simulation has ended. Nothing the simulation itself needs depends on
    /// `JITEnableContext`'s tunnel — `simulate_location` and
    /// `clear_simulated_location` build and tear down their own — and every
    /// explicit recovery route is untouched: the readiness card's Retry
    /// (`RootView.retryConnection()`), Open LocalDevVPN, importing a pairing
    /// file, and Settings' import all call `startTunnelInBackground()` directly
    /// and are not gated on this.
    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            shouldAttemptTunnelReconnect = true
        case .active:
            guard shouldAttemptTunnelReconnect else { return }
            guard !LocationSimulationSession.isOpen else {
                LogManager.shared.addInfoLog(
                    "Foreground tunnel reconnect skipped: a location-simulation session is open. It will run on the next return to the foreground after the simulation ends."
                )
                return
            }
            shouldAttemptTunnelReconnect = false
            startTunnelInBackground(showErrorUI: false)
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
