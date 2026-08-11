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
                // The other half of the deferral below: the moment a simulation
                // stops standing in the way, the pending rebuild runs, instead
                // of waiting for another background → foreground round trip that
                // may never come.
                .onReceive(NotificationCenter.default.publisher(for: .locationSimulationSessionEnded)) { _ in
                    attemptDeferredTunnelReconnect(
                        isActive: scenePhase == .active,
                        trigger: "the location simulation ending"
                    )
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
    /// left set, and the wait is bounded by the simulation rather than by the
    /// process: `LocationSimulationSession` posts
    /// `.locationSimulationSessionEnded` the moment either half of that state
    /// retracts, and this scene observes it, so a deferred rebuild runs as soon
    /// as the simulation is over — no second background → foreground round trip
    /// required. Nothing the simulation itself needs depends on
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
            // `scenePhase` itself is not read here: `onChange` hands us the new
            // phase, and the environment value it mirrors may not have been
            // republished yet at this point in the update.
            attemptDeferredTunnelReconnect(isActive: true, trigger: "a return to the foreground")
        default:
            break
        }
    }

    /// Runs the pending tunnel rebuild if one is owed and nothing is in its way.
    ///
    /// Both the "in the way" checks matter, and neither is redundant:
    /// `isOpen` covers a live session (including one a Shortcut opened while no
    /// map was on screen), `isMaintained` covers a resend loop whose last
    /// rebuild failed — session already gone, another rebuild due within
    /// seconds. Reconnecting into either is the second concurrent RemotePairing
    /// handshake against single-occupancy `<targetIP>:49152` that this deferral
    /// exists to avoid.
    ///
    /// The hop through `LocationSimulationCommandQueue` is what makes the checks
    /// mean anything when the trigger is a session *closing*: that close is
    /// posted from inside `LocationSimulationState.cleanup()`, which
    /// `simulate_location` also calls halfway through rebuilding a session it
    /// found dead. Read straight off the notification, the flags say "nothing
    /// open, nothing maintained" while a tunnel is being built on that very
    /// queue. Because the queue is serial, a block appended to it cannot start
    /// until that call has returned — so the re-check on the far side sees the
    /// settled state, and a rebuild that succeeded has already set `isOpen`
    /// again.
    private func attemptDeferredTunnelReconnect(isActive: Bool, trigger: String) {
        guard shouldAttemptTunnelReconnect, isActive else { return }

        guard !LocationSimulationSession.isOpen, !LocationSimulationSession.isMaintained else {
            LogManager.shared.addInfoLog(
                "Tunnel reconnect after \(trigger) skipped: a location simulation is still in progress. It will run as soon as the simulation ends."
            )
            return
        }

        LocationSimulationCommandQueue.shared.async {
            DispatchQueue.main.async {
                guard shouldAttemptTunnelReconnect,
                      !LocationSimulationSession.isOpen,
                      !LocationSimulationSession.isMaintained else { return }
                shouldAttemptTunnelReconnect = false
                LogManager.shared.addInfoLog("Rebuilding the app's tunnel after \(trigger).")
                startTunnelInBackground(showErrorUI: false)
            }
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
