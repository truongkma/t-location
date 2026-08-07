//
//  RootView.swift
//  TLocation
//

import SwiftUI
import UIKit

private enum RootViewLinks {
    static let localDevVPNAppStore = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
}

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
    @State private var isShowingSettings = false
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
            // Until pairing + tunnel + DDI are all up, every control on the map is
            // disabled anyway. Rather than leave a normal-looking but silently dead
            // map, cover it with a blocking readiness overlay that says exactly what
            // is missing. The overlay is the last child of the ZStack (drawn on top)
            // and the map explicitly stops hit-testing beneath it, so nothing can be
            // tapped through — no accidental pin drops. A safe-area inset banner was
            // used here before and did not render on device, because the map below
            // discards the safe area.
            ZStack {
                LocationSimulationView()
                    .allowsHitTesting(isReady)

                if !isReady {
                    readinessOverlay
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isReady)
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
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

    // MARK: - Readiness overlay

    /// Full-screen blocking overlay shown until pairing, tunnel and DDI are all up.
    /// The scrim is an opaque-to-touches material layer, so it swallows every tap
    /// that misses the card; the map underneath additionally has hit-testing off.
    private var readinessOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            readinessCard
                .padding(.horizontal, 24)
        }
        .transition(.opacity)
    }

    private var readinessCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Device Not Connected", systemImage: "bolt.horizontal.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("TLocation needs a connection to this device before it can simulate a location.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                readinessRow(
                    title: "Pairing file imported",
                    isDone: pairingExists,
                    guidance: "Import your pairing file."
                )
                readinessRow(
                    title: "Device tunnel connected",
                    isDone: tunnel.isConnected,
                    guidance: "Open LocalDevVPN and connect the VPN, and make sure Wi-Fi is joined to a network."
                )
                readinessRow(
                    title: "Developer Disk Image mounted",
                    isDone: mounting.coolisMounted,
                    guidance: "Waiting for the Developer Disk Image to download and mount.",
                    showsProgress: mounting.mountingThread != nil
                )
            }

            VStack(spacing: 10) {
                Button {
                    isShowingPairingFilePicker = true
                } label: {
                    Label("Import Pairing File", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                // Only useful while the tunnel is down — that is the one failure
                // this button can actually fix.
                if !tunnel.isConnected {
                    Button {
                        openLocalDevVPN()
                    } label: {
                        Label("Open LocalDevVPN", systemImage: "network")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 10) {
                    Button {
                        retryConnection()
                    } label: {
                        // "Retry Connection" wrapped onto two lines in this
                        // half-width slot on a narrow device.
                        Label("Retry", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    // Settings must stay reachable from here: it holds the target IP
                    // field and "Redownload DDI", the recovery tools for this screen.
                    Button {
                        isShowingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .font(.subheadline.weight(.medium))
        }
        .padding(22)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
    }

    private func readinessRow(
        title: String,
        isDone: Bool,
        guidance: String,
        showsProgress: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if showsProgress {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle.dashed")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.body)
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isDone ? .secondary : .primary)
                if !isDone {
                    Text(guidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(isDone ? "done" : "pending")")
    }

    /// Deliberately declaration-free: no `LSApplicationQueriesSchemes` entry and
    /// no installed-check. If the scheme does not resolve — app missing, or the
    /// scheme renamed since LocalDevVPN was StosVPN — `open` reports failure and
    /// the App Store page takes over, so a wrong guess costs nothing.
    private func openLocalDevVPN() {
        guard let schemeURL = URL(string: "stosvpn://") else { return }
        UIApplication.shared.open(schemeURL) { success in
            guard !success else { return }
            UIApplication.shared.open(RootViewLinks.localDevVPNAppStore)
        }
    }

    private func retryConnection() {
        markTunnelDisconnected()
        startTunnelInBackground()
        MountingProgress.shared.checkforMounted()
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
