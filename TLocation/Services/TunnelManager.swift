//
//  TunnelManager.swift
//  TLocation
//

import Foundation

final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published private(set) var isConnected = false

    private var isStarting = false

    private init() {}

    func markDisconnected() {
        runOnMain {
            self.isConnected = false
        }
    }

    func start(showErrorUI: Bool = true) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.start(showErrorUI: showErrorUI)
            }
            return
        }

        let pairingFileURL = PairingFileStore.prepareURL()
        guard FileManager.default.fileExists(atPath: pairingFileURL.path) else {
            isConnected = false
            return
        }

        guard !isStarting else {
            return
        }

        isStarting = true

        DispatchQueue.global(qos: .userInteractive).async { [showErrorUI] in
            let result: Result<Void, NSError>
            do {
                try JITEnableContext.shared.startTunnel()
                result = .success(())
            } catch {
                result = .failure(error as NSError)
            }

            DispatchQueue.main.async {
                self.finishStart(result, showErrorUI: showErrorUI)
            }
        }
    }

    private func finishStart(_ result: Result<Void, NSError>, showErrorUI: Bool) {
        isStarting = false

        switch result {
        case .success:
            isConnected = true
            LogManager.shared.addInfoLog("Tunnel connected successfully")
            mountDeveloperDiskImageIfNeeded()
        case .failure(let error):
            isConnected = false
            handleStartFailure(error, showErrorUI: showErrorUI)
        }
    }

    private func mountDeveloperDiskImageIfNeeded() {
        let trustcachePath = URL.documentsDirectory.appendingPathComponent("DDI/Image.dmg.trustcache").path
        guard FileManager.default.fileExists(atPath: trustcachePath),
              !MountingProgress.shared.coolisMounted,
              MountingProgress.shared.mountingThread == nil else {
            return
        }
        MountingProgress.shared.pubMount()
    }

    private func handleStartFailure(_ error: NSError, showErrorUI: Bool) {
        LogManager.shared.addErrorLog(tunnelConnectionLogMessage(for: error))
        guard showErrorUI else {
            return
        }

        if error.code == -9 {
            handleInvalidPairingFile()
            return
        }

        showAlert(
            title: String(localized: "Connection Error"),
            message: tunnelConnectionAlertMessage(for: error),
            showOk: false,
            showTryAgain: true
        ) { shouldTryAgain in
            if shouldTryAgain {
                startTunnelInBackground()
            }
        }
    }

    private func handleInvalidPairingFile() {
        LogManager.shared.addInfoLog("Pairing file reported invalid; keeping existing file")

        showAlert(
            title: String(localized: "Invalid Pairing File"),
            message: String(localized: "The pairing file may be invalid or expired. You can import a new pairing file to replace it."),
            showOk: true,
            showTryAgain: false,
            primaryButtonText: String(localized: "Select New File")
        ) { _ in
            NotificationCenter.default.post(name: .showPairingFilePicker, object: nil)
        }
    }

    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

func startTunnelInBackground(showErrorUI: Bool = true) {
    TunnelManager.shared.start(showErrorUI: showErrorUI)
}

func markTunnelDisconnected() {
    TunnelManager.shared.markDisconnected()
}

private func tunnelConnectionLogMessage(for error: NSError) -> String {
    let target = "\(DeviceConnectionContext.targetIPAddress):49152"
    return "Tunnel connection failed for \(target): \(error.localizedDescription) (Domain: \(error.domain), Code: \(error.code), Raw: \(String(describing: error)))"
}

private func tunnelConnectionAlertMessage(for error: NSError) -> String {
    let targetIP = DeviceConnectionContext.targetIPAddress
    let rawMessage = error.localizedDescription
    let lowercasedMessage = rawMessage.lowercased()

    let likelyCause: String
    let recoverySteps: [String]

    let defaultIP = DeviceConnectionContext.defaultTargetIPAddress

    if error.code == 48 || lowercasedMessage.contains("address already in use") || lowercasedMessage.contains("port already in use") {
        likelyCause = String(localized: "A port needed for the connection to this device is already in use.")
        recoverySteps = [
            String(localized: "Close other JIT, debugging, proxy, or VPN apps that may be using the connection."),
            String(localized: "Disconnect and reconnect LocalDevVPN."),
            String(localized: "Restart TLocation, then try again."),
            String(localized: "If it keeps happening, reboot the device to clear the stuck port.")
        ]
    } else if error.code == 54 || lowercasedMessage.contains("connection reset") {
        likelyCause = String(localized: "The device or VPN closed the connection before setup finished.")
        recoverySteps = [
            String(localized: "Open LocalDevVPN and confirm the VPN is connected."),
            String(localized: "Make sure LocalDevVPN is using the default \(defaultIP) address."),
            String(localized: "Reconnect Wi-Fi and LocalDevVPN, then try again."),
            String(localized: "If this keeps happening, select a fresh pairing file.")
        ]
    } else if error.code == -18 || lowercasedMessage.contains("parse target ip") {
        likelyCause = String(localized: "The configured target IP address is not valid.")
        recoverySteps = [
            String(localized: "Open Settings and check the target IP address."),
            String(localized: "Use the default \(defaultIP).")
        ]
    } else if lowercasedMessage.contains("timed out") || lowercasedMessage.contains("timeout") {
        likelyCause = String(localized: "The app could not reach the device before the connection timed out.")
        recoverySteps = [
            String(localized: "Confirm Wi-Fi and LocalDevVPN are both connected."),
            String(localized: "Wake and unlock the target device."),
            String(localized: "Confirm LocalDevVPN is exposing the device at \(targetIP).")
        ]
    } else if lowercasedMessage.contains("network is unreachable") || lowercasedMessage.contains("no route") {
        likelyCause = String(localized: "The VPN route to the device is not available.")
        recoverySteps = [
            String(localized: "Disconnect and reconnect LocalDevVPN."),
            String(localized: "Confirm iOS shows the VPN indicator."),
            String(localized: "Try switching Wi-Fi off and on.")
        ]
    } else {
        likelyCause = String(localized: "The connection to this device could not be created.")
        recoverySteps = [
            String(localized: "Confirm Wi-Fi and LocalDevVPN are connected."),
            String(localized: "Wake and unlock the target device."),
            String(localized: "Reconnect LocalDevVPN, then try again.")
        ]
    }

    // A numbered list, not a sentence: each step is already a whole translated
    // string, and only the "1. " prefix is assembled here.
    let steps = recoverySteps.enumerated()
        .map { "\($0.offset + 1). \($0.element)" }
        .joined(separator: "\n")

    // The raw FFI message is deliberately left untranslated — it is diagnostic
    // detail for a bug report, not prose for the user.
    return String(
        localized: """
        \(likelyCause)

        Target: \(targetIP):49152
        Expected LocalDevVPN IP: \(defaultIP)

        Try this:
        \(steps)

        Technical details:
        Code \(error.code): \(rawMessage)
        """
    )
}
