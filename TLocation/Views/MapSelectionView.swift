//
//  MapSelectionView.swift
//  TLocation
//
//  Created by Stephen on 11/3/25.
//

import SwiftUI
import MapKit
import UIKit

private struct CoordinateSnapshot: Equatable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Parses coordinates typed or pasted directly into the search field (e.g.
/// "21.012452, 105.847002"). File-based import (GPX/KML/GeoJSON/CSV) has been
/// removed; this inline text path is all that remains and must keep working.
private enum CoordinateImportParser {
    private enum CoordinateOrder {
        case latitudeLongitude
        case longitudeLatitude
    }

    static func parseInline(_ text: String) -> [CLLocationCoordinate2D] {
        sanitized(parseTextCoordinates(from: text))
    }

    private static func sanitized(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        for coordinate in coordinates where CLLocationCoordinate2DIsValid(coordinate) {
            if result.last.map(CoordinateSnapshot.init) == CoordinateSnapshot(coordinate) {
                continue
            }
            result.append(coordinate)
        }
        return result
    }

    private static func coordinate(
        first: Double,
        second: Double,
        order: CoordinateOrder
    ) -> CLLocationCoordinate2D? {
        let preferred: CLLocationCoordinate2D
        let fallback: CLLocationCoordinate2D

        switch order {
        case .latitudeLongitude:
            preferred = CLLocationCoordinate2D(latitude: first, longitude: second)
            fallback = CLLocationCoordinate2D(latitude: second, longitude: first)
        case .longitudeLatitude:
            preferred = CLLocationCoordinate2D(latitude: second, longitude: first)
            fallback = CLLocationCoordinate2D(latitude: first, longitude: second)
        }

        if CLLocationCoordinate2DIsValid(preferred) {
            return preferred
        }
        if CLLocationCoordinate2DIsValid(fallback) {
            return fallback
        }
        return nil
    }

    private static func parseTextCoordinates(from text: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var headerIndices: (latitude: Int, longitude: Int)?

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let fields = splitFields(trimmed)
            if headerIndices == nil,
               let detectedHeader = detectHeader(in: fields) {
                headerIndices = detectedHeader
                continue
            }

            if let headerIndices,
               fields.indices.contains(headerIndices.latitude),
               fields.indices.contains(headerIndices.longitude),
               let latitude = numbers(in: fields[headerIndices.latitude]).first,
               let longitude = numbers(in: fields[headerIndices.longitude]).first,
               let coordinate = coordinate(first: latitude, second: longitude, order: .latitudeLongitude) {
                coordinates.append(coordinate)
                continue
            }

            let values = numbers(in: trimmed)
            if values.count >= 2,
               let coordinate = coordinate(first: values[0], second: values[1], order: .latitudeLongitude) {
                coordinates.append(coordinate)
            }
        }

        return coordinates
    }

    private static func splitFields(_ line: String) -> [String] {
        line
            .split { character in
                character == "," ||
                character == ";" ||
                character == "\t"
            }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func detectHeader(in fields: [String]) -> (latitude: Int, longitude: Int)? {
        let lowered = fields.map { $0.lowercased() }
        guard let latitude = lowered.firstIndex(where: { $0 == "lat" || $0 == "latitude" }),
              let longitude = lowered.firstIndex(where: { $0 == "lon" || $0 == "lng" || $0 == "long" || $0 == "longitude" }) else {
            return nil
        }
        return (latitude, longitude)
    }

    private static func numbers(in text: String) -> [Double] {
        let pattern = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return Double(text[matchRange])
        }
    }
}

// `LocationBookmark` and its persistence now live in Support/BookmarkStore.swift,
// so Settings can export and import the same list this view edits.

// MARK: - Search Completer

@MainActor
final class LocationSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            completer.queryFragment = ""
            return
        }
        completer.queryFragment = query
    }

    /// Biases suggestions toward what is currently on screen, so a common place
    /// name resolves near the visible map instead of the nearest match anywhere.
    func update(region: MKCoordinateRegion) {
        completer.region = region
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.results = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}

/// Circular glass/material backing for the floating map buttons. Uses iOS 26's
/// Liquid Glass when available and falls back to `.ultraThinMaterial` on iOS 17.4+.
private struct FloatingCircleBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(in: .circle)
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        }
    }
}

struct LocationSimulationView: View {
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    /// Last zoom span reported by the map camera, so recentring never rescales.
    /// `nil` until the map has reported a region at least once.
    @State private var cameraSpan: MKCoordinateSpan?

    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @State private var resendTimer: Timer?
    @State private var isBusy = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    @State private var searchText = ""
    @StateObject private var searchCompleter = LocationSearchCompleter()
    @FocusState private var isSearchFocused: Bool
    @State private var simulatedCoordinate: CLLocationCoordinate2D?

    // Bookmarks
    @State private var bookmarks: [LocationBookmark] = []
    @State private var showBookmarks = false
    @State private var showSaveBookmark = false
    @State private var newBookmarkName = ""
    @State private var showSettings = false

    // Current location
    @StateObject private var currentLocationProvider = CurrentLocationProvider()
    @State private var showLocationDeniedAlert = false
    /// Guards the one-shot launch centring below so it runs once per app
    /// launch, not every time this view's `.onAppear` fires (e.g. after the
    /// Settings sheet, presented from this same view, is dismissed).
    @State private var hasCenteredOnLaunch = false
    /// Comfortable street/neighbourhood-level zoom for the initial launch
    /// centring. Tune here if it ever needs to change.
    private static let defaultSpanMeters: CLLocationDistance = 800

    /// True from the moment "Return to Real Location" is tapped until the
    /// `clear()` FFI call finishes, so the button can show a spinner across
    /// that single async hop.
    @State private var isReturningToRealLocation = false

    /// Brief, non-modal confirmation shown in the bottom control area (e.g.
    /// after "Return to Real Location"). Auto-clears itself a few seconds
    /// after being set; see `showStatusMessage`.
    @State private var statusMessage: String?
    @State private var statusMessageWorkItem: DispatchWorkItem?
    private static let statusMessageDuration: TimeInterval = 3.0

    private var pairingFilePath: String {
        PairingFileStore.prepareURL().path
    }

    private var pairingExists: Bool {
        FileManager.default.fileExists(atPath: pairingFilePath)
    }

    private var deviceIP: String {
        DeviceConnectionContext.targetIPAddress
    }

    private var hasActiveSimulation: Bool {
        simulatedCoordinate != nil
    }

    private var searchResultsListBase: some View {
        List(searchCompleter.results.prefix(5), id: \.self) { result in
            Button {
                selectSearchResult(result)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.subheadline)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .frame(maxHeight: 350)
        .scrollDisabled(true)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var searchResultsList: some View {
        if #available(iOS 26, *) {
            searchResultsListBase
                .glassEffect(in: .rect(cornerRadius: 12))
        } else {
            searchResultsListBase
        }
    }

    // MARK: - Floating map controls

    /// Everything that used to live in the navigation bar, drawn as Apple-Maps
    /// style floating overlays: full-width search capsule on top, completion list
    /// under it, and a right-hand column of circular action buttons.
    private var mapOverlayControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                floatingSearchField

                if isSearchFocused || !searchText.isEmpty {
                    Button("Cancel") {
                        dismissSearch()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Cancel Search")
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .animation(.default, value: isSearchFocused || !searchText.isEmpty)

            if !searchCompleter.results.isEmpty {
                searchResultsList
            }

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                floatingControlColumn
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 10)
    }

    /// Clears the search field, drops any pending completions, and resigns
    /// keyboard focus. Used by both the Cancel button and map-tap dismissal.
    private func dismissSearch() {
        searchText = ""
        searchCompleter.results = []
        isSearchFocused = false
    }

    private var floatingSearchFieldBase: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("Search location...", text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($isSearchFocused)
                .onChange(of: searchText) { _, newValue in
                    searchCompleter.update(query: newValue)
                }
                .onSubmit {
                    applyCoordinatesFromSearchText()
                    isSearchFocused = false
                }

            if !searchText.isEmpty {
                Button {
                    // Clears the typed text only; focus is left alone so the
                    // user can keep typing. Cancel (above) is the control that
                    // also drops focus and dismisses the keyboard.
                    searchText = ""
                    searchCompleter.results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    @ViewBuilder
    private var floatingSearchField: some View {
        if #available(iOS 26, *) {
            floatingSearchFieldBase
                .glassEffect(in: .capsule)
        } else {
            floatingSearchFieldBase
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        }
    }

    private var floatingControlColumn: some View {
        VStack(spacing: 10) {
            mapControlButton(
                systemImage: "location.fill",
                accessibilityLabel: "Locate Me",
                isDisabled: isBusy || currentLocationProvider.isLocating || isReturningToRealLocation,
                showsProgress: currentLocationProvider.isLocating && !isReturningToRealLocation,
                action: performLocate
            )

            mapControlButton(
                systemImage: "location.slash.fill",
                accessibilityLabel: "Return to Real Location",
                isDisabled: !hasActiveSimulation || isBusy || currentLocationProvider.isLocating || isReturningToRealLocation || !pairingExists,
                showsProgress: isReturningToRealLocation,
                action: returnToRealLocation
            )

            mapControlButton(
                systemImage: "bookmark.fill",
                accessibilityLabel: "Bookmarks",
                isDisabled: false,
                action: { showBookmarks = true }
            )

            // Settings stays a first-class button: it is the fallback route to
            // importing a pairing file when the connection banner is dismissed.
            mapControlButton(
                systemImage: "gearshape.fill",
                accessibilityLabel: "Settings",
                isDisabled: false,
                action: { showSettings = true }
            )
        }
    }

    private func mapControlButton(
        systemImage: String,
        accessibilityLabel: String,
        isDisabled: Bool,
        showsProgress: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if showsProgress {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .frame(width: 48, height: 48)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .modifier(FloatingCircleBackground())
        .opacity(isDisabled ? 0.4 : 1)
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Bottom cluster (coordinates readout + Stop / Simulate / Bookmark). Given
    /// a material backing so it stays legible on a map.
    private var bottomControlCluster: some View {
        VStack(spacing: 12) {
            pinControls
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MapReader { proxy in
                Map(position: $position) {
                    // Standard blue dot for the device's own position, so the
                    // user can tell themselves apart from the red simulation
                    // pin. Only draws once location permission is granted.
                    UserAnnotation()

                    if let coordinate {
                        Marker("Pin", coordinate: coordinate)
                            .tint(.red)
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .onTapGesture { point in
                    // While the search field is focused, the first tap on the map
                    // just dismisses the keyboard instead of dropping a pin. A
                    // second tap then behaves normally.
                    if isSearchFocused {
                        isSearchFocused = false
                        return
                    }
                    if let loc = proxy.convert(point, from: .local) {
                        // A tapped point is already on screen, so there is nothing
                        // to recentre — moving the camera here would throw away the
                        // zoom level the user just chose.
                        applySelection(loc, recenter: false)
                    }
                }
                .mapControls {
                    MapCompass()
                }
                // Remember whatever zoom the user has settled on so that a later
                // recentre keeps it instead of snapping back to a fixed span, and
                // bias search suggestions toward whatever is currently on screen.
                .onMapCameraChange(frequency: .onEnd) { context in
                    cameraSpan = context.region.span
                    searchCompleter.update(region: context.region)
                }
            }
                .ignoresSafeArea()

            bottomControlCluster
        }
        // The controls live *above* the map inside the same ZStack, so a tap that
        // lands on one of them is consumed there and never reaches the map's
        // `.onTapGesture` (no accidental pin drop). Empty regions of the overlay
        // have no background and stay transparent to hit-testing, so tapping bare
        // map still drops a pin exactly as before.
        .overlay(alignment: .top) {
            mapOverlayControls
        }
        // iOS 26 collapses an overcrowded `.topBarLeading` group into a single "…"
        // control, which hid every button on device. The bar carries nothing now.
        .toolbar(.hidden, for: .navigationBar)
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .alert("Save Bookmark", isPresented: $showSaveBookmark) {
            TextField("Name", text: $newBookmarkName)
            Button("Save") { addBookmark() }
            Button("Cancel", role: .cancel) { newBookmarkName = "" }
        } message: {
            Text("Enter a name for this location.")
        }
        .alert("Location Permission Needed", isPresented: $showLocationDeniedAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("TLocation needs location access to find your current position. Note: while a simulated location is active, iOS reports the simulated position.")
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarksView(bookmarks: $bookmarks) { bookmark in
                applySelection(bookmark.coordinate)
                showBookmarks = false
            } onDelete: { offsets in
                bookmarks.remove(atOffsets: offsets)
                saveBookmarks()
            } onRename: { id, newName in
                // Looked up by `id` here too, so the in-memory list mutated
                // in place and persisted stays correct regardless of the
                // sheet's current search filter.
                guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
                bookmarks[index].name = newName
                saveBookmarks()
            }
        }
        // Settings can import bookmarks into the store behind this view's
        // `@State` copy, so the copy is refreshed the moment the sheet closes.
        // `onDismiss` is used rather than relying on `.onAppear` firing again,
        // which is a SwiftUI implementation detail this view should not depend
        // on for correctness.
        .sheet(isPresented: $showSettings, onDismiss: loadBookmarks) {
            SettingsView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .simulateLocationRequested)) { notification in
            guard let requested = LocationSimulationRequest.coordinate(from: notification) else { return }
            startExternalSimulation(at: requested)
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearSimulatedLocationRequested)) { _ in
            clear()
        }
        .onAppear {
            loadBookmarks()
            // A live foreground location session for as long as the map is
            // visible. Without it the only Core Location session in the app is
            // BackgroundLocationManager's, which `clear()` shuts down — leaving
            // `UserAnnotation` with a stale grey dot and `.userLocation` camera
            // positions with nothing to follow after "Return to Real Location".
            currentLocationProvider.startTracking()
            centerOnLaunchLocationIfNeeded()
        }
        .onDisappear {
            // Balances the `startTracking()` above: no GPS runs while the map
            // is off screen.
            currentLocationProvider.stopTracking()
            stopResendLoop()
            if backgroundTaskID != .invalid {
                BackgroundLocationManager.shared.requestStop()
            }
            endBackgroundTask()
        }
    }

    // MARK: - Bookmarks

    private func loadBookmarks() {
        bookmarks = BookmarkStore.load()
    }

    private func saveBookmarks() {
        BookmarkStore.save(bookmarks)
    }

    private func addBookmark() {
        guard let coord = coordinate else { return }
        let name = newBookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = LocationBookmark(
            name: name.isEmpty ? String(format: "%.4f, %.4f", coord.latitude, coord.longitude) : name,
            latitude: coord.latitude,
            longitude: coord.longitude
        )
        bookmarks.append(bookmark)
        saveBookmarks()
        newBookmarkName = ""
    }

    // MARK: - Location

    private func selectSearchResult(_ result: MKLocalSearchCompletion) {
        searchText = ""
        searchCompleter.results = []

        let request = MKLocalSearch.Request(completion: result)
        MKLocalSearch(request: request).start { response, _ in
            if let item = response?.mapItems.first {
                applySelection(item.placemark.coordinate)
            }
        }
    }

    private func applyCoordinatesFromSearchText() {
        let importedCoordinates = CoordinateImportParser.parseInline(searchText)
        guard let firstCoordinate = importedCoordinates.first else { return }

        searchText = ""
        searchCompleter.results = []
        applySelection(firstCoordinate)
    }

    @ViewBuilder
    private var pinControls: some View {
        if let coord = coordinate {
            Text(String(format: "%.6f, %.6f", coord.latitude, coord.longitude))
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Stop") { clear() }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(!pairingExists || isBusy || !hasActiveSimulation)

                Button("Simulate Location", action: simulate)
                    .buttonStyle(.borderedProminent)
                    .disabled(!pairingExists || isBusy)

                Button {
                    showSaveBookmark = true
                } label: {
                    Image(systemName: "bookmark")
                }
                .buttonStyle(.bordered)
                .tint(.blue)
            }
        } else if let statusMessage {
            Text(statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .transition(.opacity)
                .animation(.default, value: statusMessage)
        } else {
            Text("Tap map to drop pin")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// Shows a transient, non-modal message in the bottom control area (where
    /// the pin readout / "Tap map to drop pin" hint normally lives) and clears
    /// it automatically after `statusMessageDuration`. Re-entrant: a new call
    /// cancels any pending auto-clear from a previous message so they can't
    /// race and wipe each other's text early.
    private func showStatusMessage(_ message: String) {
        statusMessageWorkItem?.cancel()
        statusMessage = message
        let workItem = DispatchWorkItem { statusMessage = nil }
        statusMessageWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.statusMessageDuration, execute: workItem)
    }

    private func simulate() {
        simulate(at: coordinate)
    }

    /// Starts a simulation requested from outside the map (e.g. the `tlocation://`
    /// URL scheme). Routed through `simulate(at:)` so the pin, `simulatedCoordinate`,
    /// the resend loop and the background task all end up in the same state as a
    /// simulation started by tapping "Simulate Location".
    private func startExternalSimulation(at requested: CLLocationCoordinate2D) {
        guard pairingExists, !isBusy else { return }
        coordinate = requested
        recenterCamera(on: requested)
        simulate(at: requested)
    }

    private func simulate(at target: CLLocationCoordinate2D?) {
        guard pairingExists, let coord = target, !isBusy else { return }
        coordinate = coord
        runLocationCommand(
            errorTitle: "Simulation Failed",
            errorMessage: { code in
                "Could not simulate location (error \(code)). Make sure the device is connected and the DDI is mounted."
            },
            operation: { locationUpdateCode(for: coord) }
        ) {
            beginBackgroundTask()
            startResendLoop(with: coord)
            BackgroundLocationManager.shared.requestStart()
        }
    }

    private func runLocationCommand(
        errorTitle: String,
        errorMessage: @escaping (Int32) -> String,
        operation: @escaping () -> Int32,
        onFailure: (() -> Void)? = nil,
        onSuccess: @escaping () -> Void
    ) {
        isBusy = true
        LocationSimulationCommandQueue.shared.async {
            let code = operation()
            DispatchQueue.main.async {
                isBusy = false
                if code == 0 {
                    onSuccess()
                } else {
                    onFailure?()
                    alertTitle = errorTitle
                    alertMessage = errorMessage(code)
                    showAlert = true
                }
            }
        }
    }

    private func clear(onFailure: (() -> Void)? = nil, onCleared: (() -> Void)? = nil) {
        guard pairingExists, !isBusy else { return }
        stopResendLoop()
        runLocationCommand(
            errorTitle: "Clear Failed",
            errorMessage: { code in "Could not clear simulated location (error \(code))." },
            operation: clear_simulated_location,
            onFailure: onFailure
        ) {
            endBackgroundTask()
            BackgroundLocationManager.shared.requestStop()
            onCleared?()
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { endBackgroundTask() }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func startResendLoop(with coordinate: CLLocationCoordinate2D) {
        simulatedCoordinate = coordinate
        resendTimer?.invalidate()
        resendTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            guard let simulatedCoordinate else { return }
            LocationSimulationCommandQueue.shared.async {
                _ = locationUpdateCode(for: simulatedCoordinate)
            }
        }
    }

    private func stopResendLoop() {
        resendTimer?.invalidate()
        resendTimer = nil
        simulatedCoordinate = nil
    }

    /// - Parameter recenter: `true` for programmatic selections (search result,
    ///   bookmark, Locate Me, typed coordinate, URL scheme), which may target a
    ///   point that is off screen. Pass `false` for map taps, where the point is
    ///   already visible and moving the camera would destroy the user's zoom.
    private func applySelection(_ coordinate: CLLocationCoordinate2D, recenter: Bool = true) {
        self.coordinate = coordinate
        if recenter {
            recenterCamera(on: coordinate)
        }
    }

    /// Recentres on `target` while preserving the current zoom span. Falls back to
    /// the historical 1000 m × 1000 m framing only if the camera has not reported a
    /// region yet.
    private func recenterCamera(on target: CLLocationCoordinate2D) {
        if let cameraSpan {
            position = .region(MKCoordinateRegion(center: target, span: cameraSpan))
        } else {
            position = .region(
                MKCoordinateRegion(
                    center: target,
                    latitudinalMeters: 1000,
                    longitudinalMeters: 1000
                )
            )
        }
    }

    /// Stops the simulation and hands the camera back to the user's live
    /// position. No polling and no distance comparison: the map already
    /// renders `UserAnnotation()`, so once iOS actually releases the
    /// simulated fix the blue dot — and now the camera, following it — settle
    /// onto the real position by themselves, however long that takes. This is
    /// self-healing by construction, so there is nothing to retry and nothing
    /// to alert about beyond a genuine FFI failure (handled by `clear()`'s own
    /// alert).
    ///
    /// This relies on `currentLocationProvider`'s tracking session, started in
    /// `.onAppear` and only stopped in `.onDisappear`. It therefore outlives
    /// the `BackgroundLocationManager.requestStop()` that `clear()` performs —
    /// a different `CLLocationManager` entirely — so a live session is
    /// guaranteed to be running at the moment the camera is handed back to
    /// `.userLocation` below.
    private func returnToRealLocation() {
        // Mirrors `clear()`'s own guard, so the spinner flag below can never be
        // left set by a call that clear() drops on the floor.
        guard hasActiveSimulation, pairingExists, !isBusy else { return }
        // Clear the pin immediately so no stale marker can mislead the user
        // while the simulation is torn down.
        coordinate = nil
        isReturningToRealLocation = true
        clear {
            isReturningToRealLocation = false
        } onCleared: {
            isReturningToRealLocation = false
            position = .userLocation(fallback: .automatic)
            showStatusMessage("Simulation stopped — following your real location")
        }
    }

    private func performLocate() {
        currentLocationProvider.locate { result in
            switch result {
            case .success(let coordinate):
                applySelection(coordinate)
                Haptics.medium()
            case .failure(.denied):
                showLocationDeniedAlert = true
            case .failure(.unavailable):
                alertTitle = "Could Not Determine Location"
                alertMessage = "No GPS fix was available. Try again, ideally with a clear view of the sky."
                showAlert = true
            }
        }
    }

    /// One-shot: centres the map on the user's real position at a comfortable
    /// street-level zoom the first time the map appears, instead of leaving
    /// `.userLocation(fallback: .automatic)` to pick an overly wide zoom.
    /// Runs at most once per app launch and never while a simulation is
    /// active, so it can never yank the camera away from what the user is
    /// doing. Silent on any failure (permission denied, restricted, or no
    /// fix) — the permission-denied alert stays reserved for an explicit tap
    /// on Locate Me.
    private func centerOnLaunchLocationIfNeeded() {
        guard !hasCenteredOnLaunch, !hasActiveSimulation else { return }
        hasCenteredOnLaunch = true
        currentLocationProvider.locate { result in
            guard case .success(let coordinate) = result, !hasActiveSimulation else { return }
            let region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: Self.defaultSpanMeters,
                longitudinalMeters: Self.defaultSpanMeters
            )
            position = .region(region)
            cameraSpan = region.span
        }
    }

    private func locationUpdateCode(for coordinate: CLLocationCoordinate2D) -> Int32 {
        simulate_location(deviceIP, coordinate.latitude, coordinate.longitude, pairingFilePath)
    }
}

// MARK: - Bookmarks Sheet

struct BookmarksView: View {
    @Binding var bookmarks: [LocationBookmark]
    let onSelect: (LocationBookmark) -> Void
    let onDelete: (IndexSet) -> Void
    /// Called with the bookmark's stable `id` (never a list index) and the
    /// already-trimmed/fallback-applied new name.
    let onRename: (UUID, String) -> Void

    @State private var searchText = ""
    // The bookmark being renamed is tracked by `id`, not by its position in
    // `filteredBookmarks` — the same trap already fixed for delete. A search
    // can hide earlier entries, so "the first visible row" and "the first
    // bookmark overall" are not the same thing.
    @State private var renamingBookmarkID: UUID?
    @State private var renameText = ""
    @State private var showRenameAlert = false

    /// Bookmarks matching `searchText` by name or formatted coordinate,
    /// preserving `bookmarks`' order. `localizedStandardContains` is
    /// case- *and* diacritic-insensitive, which matters for names like
    /// "Hà Nội" that should still match a plain "ha noi" query.
    private var filteredBookmarks: [LocationBookmark] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return bookmarks }
        return bookmarks.filter { bookmark in
            bookmark.name.localizedStandardContains(query) ||
            formattedCoordinate(bookmark).localizedStandardContains(query)
        }
    }

    private func formattedCoordinate(_ bookmark: LocationBookmark) -> String {
        String(format: "%.6f, %.6f", bookmark.latitude, bookmark.longitude)
    }

    /// `offsets` indexes into the filtered/displayed list, not `bookmarks`
    /// itself, so it is remapped by identity before being handed to
    /// `onDelete` — otherwise, with an active filter hiding earlier entries,
    /// deleting a visible row would remove the wrong bookmark.
    private func deleteFiltered(at offsets: IndexSet) {
        let idsToDelete = Set(offsets.map { filteredBookmarks[$0].id })
        let originalOffsets = IndexSet(bookmarks.indices.filter { idsToDelete.contains(bookmarks[$0].id) })
        onDelete(originalOffsets)
    }

    /// Used by the explicit swipe-action Delete button (as opposed to the
    /// implicit `.onDelete` swipe/edit-mode affordance), which already has
    /// the exact bookmark in hand and can map straight to `bookmarks` by
    /// `id` without going through a filtered-list offset at all.
    private func deleteBookmark(_ bookmark: LocationBookmark) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        onDelete(IndexSet(integer: index))
    }

    /// Called from a swipe action / context menu on a specific row, so
    /// `bookmark` is already the correct one regardless of any active search
    /// filter — it came straight from that row's `ForEach` element, not from
    /// an index into `bookmarks`.
    private func beginRename(_ bookmark: LocationBookmark) {
        renamingBookmarkID = bookmark.id
        renameText = bookmark.name
        showRenameAlert = true
    }

    /// Looks the target back up by `id` (never by position) before applying
    /// the edit, since `filteredBookmarks` may have reordered or hidden
    /// entries relative to `bookmarks` by the time Save is tapped.
    private func commitRename() {
        defer {
            renamingBookmarkID = nil
            renameText = ""
        }
        guard let id = renamingBookmarkID,
              let bookmark = bookmarks.first(where: { $0.id == id }) else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = trimmed.isEmpty
            ? String(format: "%.4f, %.4f", bookmark.latitude, bookmark.longitude)
            : trimmed
        onRename(id, newName)
    }

    var body: some View {
        NavigationStack {
            if bookmarks.isEmpty {
                ContentUnavailableView(
                    "No Bookmarks",
                    systemImage: "bookmark.slash",
                    description: Text("Drop a pin on the map and tap the bookmark icon to save a location.")
                )
                .navigationTitle("Bookmarks")
                .navigationBarTitleDisplayMode(.inline)
            } else {
                Group {
                    if filteredBookmarks.isEmpty {
                        ContentUnavailableView(
                            "No Matches",
                            systemImage: "magnifyingglass",
                            description: Text("No bookmarks match \"\(searchText)\".")
                        )
                    } else {
                        List {
                            ForEach(filteredBookmarks) { bookmark in
                                Button {
                                    // Renaming never touches selection: this
                                    // action only fires from a direct tap on
                                    // the row body, not from the swipe
                                    // action or context menu below.
                                    onSelect(bookmark)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(bookmark.name)
                                            .foregroundStyle(.primary)
                                        Text(formattedCoordinate(bookmark))
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                // Trailing swipe replaces the implicit
                                // onDelete swipe action for this edge, so
                                // Delete is re-added explicitly alongside
                                // Rename to avoid losing swipe-to-delete.
                                // EditButton's edit-mode delete affordance is
                                // unaffected — that comes from `.onDelete`
                                // below, independent of `.swipeActions`.
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        deleteBookmark(bookmark)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        beginRename(bookmark)
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                                .contextMenu {
                                    Button {
                                        beginRename(bookmark)
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                }
                            }
                            .onDelete(perform: deleteFiltered)
                        }
                    }
                }
                .navigationTitle("Bookmarks")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    EditButton()
                }
                .searchable(text: $searchText, prompt: "Search bookmarks")
            }
        }
        .alert("Rename Bookmark", isPresented: $showRenameAlert) {
            TextField("Name", text: $renameText)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) {
                renamingBookmarkID = nil
                renameText = ""
            }
        } message: {
            Text("Enter a new name for this location.")
        }
    }
}
