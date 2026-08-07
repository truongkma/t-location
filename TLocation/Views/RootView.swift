//
//  RootView.swift
//  TLocation
//

import SwiftUI

private enum ExternalLocationAction: Identifiable {
    case simulate(URL, Double, Double)
    case clear

    var id: String {
        switch self {
        case .simulate(let url, _, _): return "simulate-\(url.absoluteString)"
        case .clear: return "clear-location"
        }
    }

    var title: String {
        switch self {
        case .simulate: return "Simulate Location?"
        case .clear: return "Clear Location?"
        }
    }

    var message: String {
        switch self {
        case .simulate(_, let latitude, let longitude):
            return String(format: "An external link wants to set the simulated location to %.6f, %.6f.", latitude, longitude)
        case .clear:
            return "An external link wants to clear the simulated location."
        }
    }

    var confirmationTitle: String {
        switch self {
        case .simulate: return "Set Location"
        case .clear: return "Clear Location"
        }
    }
}

struct RootView: View {
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var mounting = MountingProgress.shared

    @State private var isShowingPairingFilePicker = false
    @State private var pendingLocationAction: ExternalLocationAction?
    @State private var pairingExists = FileManager.default.fileExists(
        atPath: PairingFileStore.prepareURL().path
    )

    private let statusTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isReady: Bool {
        pairingExists && tunnel.isConnected && mounting.coolisMounted
    }

    var body: some View {
        NavigationStack {
            LocationSimulationView()
                .safeAreaInset(edge: .top) {
                    if !isReady {
                        connectionBanner
                    }
                }
        }
        .fileImporter(
            isPresented: $isShowingPairingFilePicker,
            allowedContentTypes: PairingFileStore.supportedContentTypes
        ) { result in
            importPairingFile(result)
        }
        .onAppear {
            startTunnelInBackground()
            MountingProgress.shared.checkforMounted()
        }
        .onReceive(statusTimer) { _ in
            // Cheap existence check only. `prepareURL()` does directory creation and a
            // full byte-compare, which must not run on the main thread once per second.
            pairingExists = FileManager.default.fileExists(atPath: PairingFileStore.url.path)
            if mounting.mountingThread == nil, !mounting.coolisMounted {
                MountingProgress.shared.checkforMounted()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPairingFilePicker)) { _ in
            isShowingPairingFilePicker = true
        }
        .onOpenURL { url in
            handleURL(url)
        }
        .confirmationDialog(
            pendingLocationAction?.title ?? "External Location Request",
            isPresented: Binding(
                get: { pendingLocationAction != nil },
                set: { if !$0 { pendingLocationAction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingLocationAction
        ) { action in
            Button(action.confirmationTitle, role: .destructive) {
                performLocationAction(action)
                pendingLocationAction = nil
            }
            Button("Cancel", role: .cancel) { pendingLocationAction = nil }
        } message: { action in
            Text(action.message)
        }
    }

    private var connectionBanner: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                statusChip("Pairing", ok: pairingExists)
                statusChip("Tunnel", ok: tunnel.isConnected)
                statusChip("DDI", ok: mounting.coolisMounted)
            }
            if !pairingExists {
                Button("Import Pairing File") {
                    isShowingPairingFilePicker = true
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private func statusChip(_ label: String, ok: Bool) -> some View {
        Label(label, systemImage: ok ? "checkmark.circle.fill" : "circle.dashed")
            .font(.caption.weight(.medium))
            .foregroundStyle(ok ? .green : .secondary)
    }

    private func importPairingFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                try PairingFileStore.importFromPicker(url)
                pairingExists = true
                markTunnelDisconnected()
                startTunnelInBackground()
                AlertPresenter.dismissPresentedAlert()
            } catch {
                LogManager.shared.addErrorLog("Failed to import pairing file: \(error.localizedDescription)")
                showAlert(title: "Import Failed", message: error.localizedDescription, showOk: true)
            }
        case .failure(let error):
            LogManager.shared.addErrorLog("Pairing file picker failed: \(error.localizedDescription)")
        }
    }

    // MARK: - URL scheme (tlocation://)

    private func handleURL(_ url: URL) {
        guard let host = url.host()?.lowercased() else { return }
        switch host {
        case "simulate-location", "set-location", "location", "location-simulation":
            confirmSimulatedLocation(from: url)
        case "clear-location", "stop-location":
            pendingLocationAction = .clear
        default:
            break
        }
    }

    private func confirmSimulatedLocation(from url: URL) {
        guard let coordinate = coordinate(from: url) else {
            showAlert(
                title: "Invalid Location URL",
                message: "Use tlocation://simulate-location?lat=37.3349&lon=-122.0090",
                showOk: true
            )
            return
        }
        guard coordinateIsValid(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            showAlert(
                title: "Invalid Coordinates",
                message: "Latitude must be between -90 and 90. Longitude must be between -180 and 180.",
                showOk: true
            )
            return
        }
        pendingLocationAction = .simulate(url, coordinate.latitude, coordinate.longitude)
    }

    private func performLocationAction(_ action: ExternalLocationAction) {
        switch action {
        case .simulate(let url, _, _):
            requestSimulatedLocation(from: url)
        case .clear:
            requestClearSimulatedLocation()
        }
    }

    /// Hands the request to `LocationSimulationView`, which is the single owner of the
    /// simulation state (map pin, 4s resend loop, route playback, background task).
    /// Calling the FFI here instead would leave that state out of sync: the resend loop
    /// would revive a cleared position, and a URL-started simulation could not be stopped
    /// from the map.
    private func requestSimulatedLocation(from url: URL) {
        guard let coordinate = coordinate(from: url),
              coordinateIsValid(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            return
        }
        guard requirePairingFile(
            message: "Import a pairing file before simulating location from a URL."
        ) else { return }

        LogManager.shared.addInfoLog(
            String(format: "Requested simulated location from URL: %.6f, %.6f", coordinate.latitude, coordinate.longitude)
        )
        LocationSimulationRequest.postSimulate(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    private func requestClearSimulatedLocation() {
        guard requirePairingFile(
            message: "Import a pairing file before clearing the simulated location from a URL."
        ) else { return }

        LogManager.shared.addInfoLog("Requested clear of simulated location from URL")
        LocationSimulationRequest.postClear()
    }

    private func requirePairingFile(message: String) -> Bool {
        guard FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path) else {
            showAlert(title: "Pairing File Required", message: message, showOk: true)
            return false
        }
        return true
    }

    private func coordinate(from url: URL) -> (latitude: Double, longitude: Double)? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        func queryValue(_ names: [String]) -> String? {
            for name in names {
                if let value = queryItems.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value {
                    return value
                }
            }
            return nil
        }

        if let latitudeText = queryValue(["lat", "latitude"]),
           let longitudeText = queryValue(["lon", "lng", "long", "longitude"]),
           let latitude = Double(latitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
           let longitude = Double(longitudeText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return (latitude, longitude)
        }

        let coordinateText = queryValue(["coordinate", "coordinates", "coords", "q", "ll"])
            ?? components?.path
            ?? ""
        let values = numbers(in: coordinateText)
        guard values.count >= 2 else { return nil }
        return (values[0], values[1])
    }

    private func coordinateIsValid(latitude: Double, longitude: Double) -> Bool {
        (-90.0...90.0).contains(latitude) && (-180.0...180.0).contains(longitude)
    }

    private func numbers(in text: String) -> [Double] {
        let pattern = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return Double(text[matchRange])
        }
    }
}
