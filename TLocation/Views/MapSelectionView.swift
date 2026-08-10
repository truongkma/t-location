//
//  MapSelectionView.swift
//  TLocation
//
//  Created by Stephen on 11/3/25.
//

import SwiftUI
import MapKit
import UIKit
import Foundation

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

/// Rounded glass/material backing for the pin callout. Same iOS 26 Liquid Glass
/// / `.ultraThinMaterial` split as `FloatingCircleBackground`, so the callout
/// stays legible over both light map tiles and dark satellite imagery.
private struct CalloutBackground: ViewModifier {
    private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(in: .rect(cornerRadius: 14))
        } else {
            content
                .background(.ultraThinMaterial, in: Self.shape)
                .overlay(Self.shape.strokeBorder(Color.primary.opacity(0.10)))
                .shadow(color: .black.opacity(0.20), radius: 6, y: 3)
        }
    }
}

/// One-shot ticket shared by a device command and the deadline watching it:
/// exactly one caller of `claim()` ever gets `true`.
///
/// The idevice FFI is synchronous and cannot be aborted, so a command that
/// overruns its budget is left to finish on `LocationSimulationCommandQueue`.
/// This is what stops that abandoned call from walking back into the UI
/// afterwards and firing success handlers behind a failure the user has already
/// been shown.
private final class LocationCommandOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

struct LocationSimulationView: View {
    /// Opt-in "natural GPS drift": when enabled, periodic resends of an active
    /// simulation wobble a few metres around the chosen point instead of
    /// resending the exact same fix every time. Off by default; see
    /// `jitteredCoordinate(around:)` and `startResendLoop(with:)`.
    @AppStorage("naturalGPSDrift") private var naturalGPSDrift = false

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
    @State private var showSettings = false

    /// Measured size of the pin callout, used to work out the screen rectangle
    /// the annotation occupies so a tap that lands on it is not also treated as
    /// a map tap. Zero until the callout has been laid out once.
    @State private var calloutSize: CGSize = .zero

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
    /// Drives the confirmation shown before "Return to Real Location" undoes a
    /// live simulation. Only ever set by a tap on that button; see
    /// `returnToRealLocation()`.
    @State private var isConfirmingReturnToRealLocation = false

    /// Mirrors `ActiveSimulationStore.isActive` — "the device is simulating a
    /// position, as far as this app knows" — as view state, so SwiftUI redraws the
    /// Stop button when it changes instead of the value being read out of
    /// `UserDefaults` inside `body`. Unlike `simulatedCoordinate` this survives the
    /// process, which is the point: see `restorePersistedSimulationIfNeeded()`.
    /// Every write goes through `setSimulationActive(_:)` so the mirror and the
    /// stored record cannot drift apart.
    @State private var hasPersistedSimulation = false
    /// Guards the one-shot restore below, same reasoning as `hasCenteredOnLaunch`.
    @State private var hasRestoredPersistedSimulation = false

    /// Brief, non-modal confirmation shown in the bottom control area (e.g.
    /// after "Return to Real Location"). Auto-clears itself a few seconds
    /// after being set; see `showStatusMessage`.
    @State private var statusMessage: String?
    @State private var statusMessageWorkItem: DispatchWorkItem?
    private static let statusMessageDuration: TimeInterval = 3.0

    /// A statement about what the *device* is doing that the user has not acted on
    /// yet — currently only a simulation carried over from a previous launch.
    ///
    /// Deliberately not a `statusMessage`: that one clears itself after three
    /// seconds, and at launch the readiness overlay is normally still covering the
    /// map long after those three seconds are up, so the one notice the user most
    /// needs was the one they never saw. This stays until they dismiss it or the
    /// simulation it describes ends. It is text only — nothing here, and nothing
    /// that sets it, touches the device.
    @State private var carriedOverSimulationNotice: String?

    /// How long the UI waits for a device command before handing the controls
    /// back. Comparable to what a Shortcuts intent budgets for the same work (see
    /// `LocationIntentRunner`: a connection allowance plus a command allowance),
    /// because it *is* the same work — with no live session the FFI builds a
    /// tunnel from the pairing file before it can do anything else.
    private static let commandTimeout: TimeInterval = 45

    private var pairingFilePath: String {
        PairingFileStore.prepareURL().path
    }

    private var pairingExists: Bool {
        FileManager.default.fileExists(atPath: pairingFilePath)
    }

    private var deviceIP: String {
        DeviceConnectionContext.targetIPAddress
    }

    /// Whether the device is holding a simulated position.
    ///
    /// Two independent sources, because the position outlives this view and even
    /// this process: `simulatedCoordinate` is the anchor of a resend loop *this*
    /// view is running, while `hasPersistedSimulation` covers a simulation started
    /// before a force-quit — the DDI service is still reporting it even though
    /// nothing is left in memory to describe it.
    ///
    /// Read by Stop's enabled state and by "Return to Real Location", which uses it
    /// to decide whether tapping needs a confirmation (something to undo) or can
    /// act straight away.
    private var hasActiveSimulation: Bool {
        simulatedCoordinate != nil || hasPersistedSimulation
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
                // Deliberately not gated on `hasActiveSimulation`. Clearing with
                // nothing simulated is now an idempotent no-op that reports
                // success, so there is nothing to protect the user from — and an
                // always-live control is the dependable way out if the persisted
                // flag is ever wrong about what the device is doing. The remaining
                // guards are the ones that still mean something: no pairing file,
                // no FFI at all; and no overlapping commands.
                isDisabled: isBusy || currentLocationProvider.isLocating || isReturningToRealLocation || !pairingExists,
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
        accessibilityLabel: LocalizedStringKey,
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

    /// Bottom cluster (Stop / Simulate Location, plus any transient status
    /// message). Given a material backing so it stays legible on a map.
    private var bottomControlCluster: some View {
        VStack(spacing: 12) {
            carriedOverSimulationBanner
            pinControls
        }
        .animation(.default, value: statusMessage)
        .animation(.default, value: carriedOverSimulationNotice)
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    /// The persistent counterpart of `statusMessage`, drawn in the same bottom
    /// cluster and above it. Carries a dismiss control rather than a timer, and
    /// no action button: the only thing to do about it is "Return to Real
    /// Location", which is already on screen and always enabled.
    @ViewBuilder
    private var carriedOverSimulationBanner: some View {
        if let carriedOverSimulationNotice {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)

                Text(carriedOverSimulationNotice)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    self.carriedOverSimulationNotice = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .transition(.opacity)
        }
    }

    // MARK: - Pin callout

    /// Gap between the callout and the pin glyph below it.
    private static let calloutSpacing: CGFloat = 4
    /// Height of `pinGlyph` (head + stem). Fixed, so the annotation's screen
    /// rectangle can be reconstructed in `isInsidePinAnnotation`.
    private static let pinGlyphHeight: CGFloat = 30
    private static let pinGlyphWidth: CGFloat = 20
    /// Keeps a long bookmark name from stretching the callout across the map.
    private static let calloutMaxWidth: CGFloat = 240

    /// Saved state: a solid, saturated blue chip with a white glyph.
    private static let bookmarkSavedTint = Color(red: 0.04, green: 0.28, blue: 0.78)
    /// Unsaved state: a pale, muted blue outline. The difference between the two
    /// is a filled dark chip vs. an empty light one, which reads at a glance
    /// without relying on hue alone.
    private static let bookmarkUnsavedTint = Color(red: 0.42, green: 0.64, blue: 0.92)

    private static func formattedCoordinate(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
    }

    /// The bookmark already saved at the dropped pin, if any.
    ///
    /// `coordinate` always holds the exact point the user chose — a map tap, a
    /// search result, a bookmark, or a `Locate Me` fix. The natural-GPS-drift
    /// offset from `jitteredCoordinate(around:)` is applied only to the value
    /// handed to the FFI inside `startResendLoop(with:)` and is never written
    /// back into `coordinate` or `simulatedCoordinate`, so nothing read here is
    /// ever a jittered value.
    private var savedBookmarkAtPin: LocationBookmark? {
        guard let coordinate else { return nil }
        return BookmarkStore.bookmark(nearest: coordinate, in: bookmarks)
    }

    /// Compact information callout drawn above the pin: the bookmark name when
    /// this place is already saved, the coordinates, a copy button, and the
    /// bookmark state/action chip.
    private func pinCallout(for coordinate: CLLocationCoordinate2D) -> some View {
        let saved = savedBookmarkAtPin

        return VStack(alignment: .leading, spacing: 3) {
            if let saved {
                Text(saved.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            HStack(spacing: 8) {
                Text(Self.formattedCoordinate(coordinate))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Button {
                    copyCoordinates(coordinate)
                } label: {
                    calloutChip(
                        systemImage: "doc.on.doc",
                        glyphColor: .secondary,
                        fill: Color.primary.opacity(0.10),
                        stroke: Color.primary.opacity(0.12)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy Coordinates")

                bookmarkChip(saved: saved != nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: Self.calloutMaxWidth, alignment: .leading)
        .modifier(CalloutBackground())
        // Measured rather than assumed: the height depends on whether the name
        // line is present and on the user's Dynamic Type size.
        .background {
            GeometryReader { geometry in
                Color.clear
                    // `.task(id:)` rather than a direct assignment, so the state
                    // write happens after layout instead of during it.
                    .task(id: geometry.size) { calloutSize = geometry.size }
            }
        }
    }

    /// Saved → an inert badge (no button, so it cannot possibly add a second
    /// bookmark for a place the callout is already naming). Unsaved → a button
    /// that saves immediately.
    @ViewBuilder
    private func bookmarkChip(saved: Bool) -> some View {
        if saved {
            calloutChip(
                systemImage: "bookmark.fill",
                glyphColor: .white,
                fill: Self.bookmarkSavedTint,
                stroke: Color.white.opacity(0.65)
            )
            .accessibilityLabel("Saved to Bookmarks")
        } else {
            Button {
                saveCurrentPinAsBookmark()
            } label: {
                calloutChip(
                    systemImage: "bookmark",
                    glyphColor: Self.bookmarkUnsavedTint,
                    fill: Self.bookmarkUnsavedTint.opacity(0.20),
                    stroke: Self.bookmarkUnsavedTint.opacity(0.70)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save Bookmark")
        }
    }

    private func calloutChip(
        systemImage: String,
        glyphColor: Color,
        fill: Color,
        stroke: Color
    ) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(glyphColor)
            .frame(width: 26, height: 26)
            .background(Circle().fill(fill))
            .overlay(Circle().strokeBorder(stroke, lineWidth: 1))
            .contentShape(Circle())
    }

    /// Classic pin: a red head with a white ring over a short stem whose tip is
    /// the annotation's anchor point. Kept simple and high-contrast so it stays
    /// readable on satellite imagery.
    private var pinGlyph: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(Color.red)
                Circle().strokeBorder(.white, lineWidth: 2)
            }
            .frame(width: Self.pinGlyphWidth, height: Self.pinGlyphWidth)

            Rectangle()
                .fill(Color.red)
                .frame(width: 3, height: Self.pinGlyphHeight - Self.pinGlyphWidth)
        }
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        .accessibilityHidden(true)
    }

    /// Whether `point` (map-local coordinates) falls inside the annotation —
    /// callout plus pin — currently drawn for `coordinate`.
    private func isInsidePinAnnotation(_ point: CGPoint, proxy: MapProxy) -> Bool {
        guard let coordinate,
              calloutSize != .zero,
              let anchor = proxy.convert(coordinate, to: .local) else { return false }
        let width = max(calloutSize.width, Self.pinGlyphWidth)
        let height = calloutSize.height + Self.calloutSpacing + Self.pinGlyphHeight
        // `.bottom` anchoring puts the content's bottom edge on the coordinate.
        let frame = CGRect(x: anchor.x - width / 2, y: anchor.y - height, width: width, height: height)
        return frame.insetBy(dx: -4, dy: -4).contains(point)
    }

    private func copyCoordinates(_ coordinate: CLLocationCoordinate2D) {
        UIPasteboard.general.string = Self.formattedCoordinate(coordinate)
        Haptics.light()
        showStatusMessage(String(localized: "Coordinates copied"))
    }

    /// Saves the pin with a coordinate-derived name and no prompt — the callout
    /// icon is a one-tap action, and the bookmarks sheet already has Rename for
    /// giving it a better name afterwards.
    ///
    /// Always stores `coordinate`, the exact anchor the user chose; natural GPS
    /// drift never touches it (see `savedBookmarkAtPin`). The duplicate guard
    /// repeats the callout's own check, so even if the badge were somehow tapped
    /// while showing "saved" no second bookmark could be created.
    private func saveCurrentPinAsBookmark() {
        guard let coord = coordinate,
              BookmarkStore.bookmark(nearest: coord, in: bookmarks) == nil else { return }
        bookmarks.append(
            LocationBookmark(
                name: String(format: "%.4f, %.4f", coord.latitude, coord.longitude),
                latitude: coord.latitude,
                longitude: coord.longitude
            )
        )
        saveBookmarks()
        Haptics.light()
        showStatusMessage(String(localized: "Saved to Bookmarks"))
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
                        // `Annotation` rather than `Marker` so the information
                        // callout is anchored to the coordinate and pans and
                        // zooms with the map. `.bottom` puts the bottom of the
                        // content — the tip of the pin stem — on the exact
                        // point, leaving the callout above it.
                        Annotation("Pin", coordinate: coordinate, anchor: .bottom) {
                            VStack(spacing: Self.calloutSpacing) {
                                pinCallout(for: coordinate)
                                pinGlyph
                            }
                        }
                        .annotationTitles(.hidden)
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
                    // A tap on the callout or the pin itself is the annotation's
                    // business. The map's tap recogniser still sees those touches
                    // (the annotation is hosted inside the map), so without this
                    // guard tapping Copy or Save would also re-drop the pin a few
                    // metres north of where it is.
                    if isInsidePinAnnotation(point, proxy: proxy) {
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
        // Same `.confirmationDialog` + destructive-role shape `RootView` uses for
        // the external location requests, so the one destructive confirmation on
        // the map looks like the rest of the app. Cancelling does nothing at all:
        // the FFI is only reached from the confirm button's action, so no pin, no
        // camera and no flag is touched, and `isReturningToRealLocation` is never
        // set — the next tap behaves exactly like the first.
        .confirmationDialog(
            "Return to Real Location?",
            isPresented: $isConfirmingReturnToRealLocation,
            titleVisibility: .visible
        ) {
            Button("Stop Simulating", role: .destructive) {
                performReturnToRealLocation()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This stops the simulated location and returns this device to its real position.")
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
            if LocationSimulationRequest.isAlreadyApplied(notification) {
                adoptExternalSimulation(at: requested)
            } else {
                startExternalSimulation(at: requested)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearSimulatedLocationRequested)) { notification in
            if LocationSimulationRequest.isAlreadyApplied(notification) {
                adoptExternalClear()
            } else {
                clear()
            }
        }
        .onAppear {
            loadBookmarks()
            // Before the launch centring below, which stands down whenever a
            // simulation is active and needs to know about a restored one.
            restorePersistedSimulationIfNeeded()
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

    /// The coordinate readout and the bookmark button moved into the pin
    /// callout, which is attached to the pin itself; what stays here is the two
    /// actions that are about the *simulation* rather than about the pin.
    @ViewBuilder
    private var pinControls: some View {
        if let statusMessage {
            Text(statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .transition(.opacity)
        }

        // Stop stays tied to a pin on purpose: it means "pause the simulation for
        // this pin", ready to resume on the same spot. Recovering a simulation that
        // outlived the process — where there is no pin — is "Return to Real
        // Location"'s job, and that button is always enabled, so nothing is
        // unreachable without widening this condition.
        if coordinate != nil {
            HStack(spacing: 12) {
                Button("Stop") { clear() }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(!pairingExists || isBusy || !hasActiveSimulation)

                Button("Simulate Location", action: simulate)
                    .buttonStyle(.borderedProminent)
                    .disabled(!pairingExists || isBusy)
            }
        } else if statusMessage == nil {
            Text("Tap map to drop pin")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// Shows a transient, non-modal message in the bottom control area (above
    /// the Stop / Simulate buttons, or in place of the "Tap map to drop pin"
    /// hint when there is no pin) and clears it automatically after
    /// `statusMessageDuration`. Re-entrant: a new call
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

    /// Adopts a simulation a Shortcuts intent has *already* applied to the
    /// device. The FFI is deliberately not called again — the position is
    /// already set — but the pin, the camera, the background task and above all
    /// the 4-second resend loop have to move onto the new coordinate, or the
    /// loop would resend the map's older position and silently undo the
    /// shortcut.
    private func adoptExternalSimulation(at requested: CLLocationCoordinate2D) {
        // Exactly one keep-alive activation should be outstanding while a
        // simulation is running. The intent took one of its own before posting;
        // if this view was already holding one, release it so the two do not
        // stack and leave background location running after the next stop.
        //
        // The test is `simulatedCoordinate`, not `hasActiveSimulation`: an
        // activation belongs to a resend loop this view started, and a simulation
        // restored from the persisted record has none (see
        // `restorePersistedSimulationIfNeeded()`). Releasing on that would cancel
        // the intent's own activation and stop background location outright.
        if simulatedCoordinate != nil {
            BackgroundLocationManager.shared.requestStop()
        }
        refreshPersistedSimulation()
        coordinate = requested
        recenterCamera(on: requested)
        beginBackgroundTask()
        startResendLoop(with: requested)
    }

    /// Counterpart of `adoptExternalSimulation`: the intent has already cleared the
    /// device and released its keep-alive activation, so the FFI is deliberately
    /// not called again — the position is already gone and a second clear would be
    /// redundant work over a tunnel that has to be rebuilt to perform it.
    ///
    /// (`clear_simulated_location()` would now *succeed* on a torn-down session
    /// rather than returning error 12 as it once did, so this is no longer about
    /// avoiding a spurious alert. It is simply that there is nothing left to do.)
    ///
    /// This is `clear()`'s success path minus the FFI call and the keep-alive
    /// release, so the map ends up exactly where the Stop button would leave it:
    /// resend loop stopped, background task ended, and the pin still on screen
    /// ready to be re-simulated. The intent already dropped the persisted record;
    /// this just picks that up.
    private func adoptExternalClear() {
        stopResendLoop()
        refreshPersistedSimulation()
        endBackgroundTask()
    }

    private func simulate(at target: CLLocationCoordinate2D?) {
        guard pairingExists, let coord = target, !isBusy else { return }
        coordinate = coord
        runLocationCommand(
            errorTitle: String(localized: "Simulation Failed"),
            errorMessage: { code in
                String(localized: "Could not simulate location (error \(code)). Make sure the device is connected and the Developer Disk Image (DDI) is mounted.")
            },
            operation: { locationUpdateCode(for: coord) }
        ) {
            setSimulationActive(coord)
            beginBackgroundTask()
            startResendLoop(with: coord)
            BackgroundLocationManager.shared.requestStart()
        }
    }

    /// Single writer for "the device is simulating", keeping the persisted record
    /// and the `hasPersistedSimulation` mirror it feeds in lockstep. Pass the
    /// coordinate the device accepted, or `nil` once it has accepted a clear.
    ///
    /// Only ever called after the FFI has reported success, so the record can
    /// never claim more than actually reached the device.
    private func setSimulationActive(_ coordinate: CLLocationCoordinate2D?) {
        if let coordinate {
            ActiveSimulationStore.markStarted(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        } else {
            ActiveSimulationStore.markCleared()
        }
        hasPersistedSimulation = coordinate != nil
        // Whichever way this went, the notice has been overtaken: the previous
        // session's simulation has either been ended or replaced by this one.
        carriedOverSimulationNotice = nil
    }

    /// Re-reads the persisted record after something *else* in the process changed
    /// it — currently only a Shortcuts intent, which drives the device itself and
    /// writes the record from `LocationIntentRunner` before telling the map.
    private func refreshPersistedSimulation() {
        hasPersistedSimulation = ActiveSimulationStore.isActive
        // Same reasoning as `setSimulationActive`: an intent has just changed what
        // the device is doing, so a notice about an older session is stale.
        carriedOverSimulationNotice = nil
    }

    /// Runs one device command on `LocationSimulationCommandQueue` and gives the
    /// controls back either when it answers or when `commandTimeout` expires,
    /// whichever comes first.
    ///
    /// The deadline exists because "Return to Real Location" is enabled with no
    /// live session at all: the FFI then has to build a tunnel from the pairing
    /// file, and with the VPN up but the device not answering that sits on a TCP
    /// connect for tens of seconds. Without a bound, `isBusy` stayed true for the
    /// whole of it and every control on the map — Simulate, Stop, Locate Me,
    /// Return to Real — was dead with no way to cancel.
    ///
    /// Nothing here reaches into `LocationSimulationState`: the FFI call itself is
    /// still the only thing that touches it and it still runs on
    /// `LocationSimulationCommandQueue`, alone. Expiring the deadline does not
    /// abort the call — it cannot be aborted — it only stops the UI waiting on it.
    /// A command started afterwards queues behind the abandoned one on that same
    /// serial queue, so the handles are never contended.
    private func runLocationCommand(
        errorTitle: String,
        errorMessage: @escaping (Int32) -> String,
        operation: @escaping () -> Int32,
        onFailure: (() -> Void)? = nil,
        onSuccess: @escaping () -> Void
    ) {
        isBusy = true
        let outcome = LocationCommandOutcome()

        LocationSimulationCommandQueue.shared.async {
            let code = operation()
            DispatchQueue.main.async {
                guard outcome.claim() else {
                    // The deadline already fired and the user has been told this
                    // did not work. Whatever the device eventually answered is
                    // logged and goes no further: running the handlers now would
                    // re-arm the resend loop, or flip the persisted flag, behind a
                    // message that says the command failed.
                    LogManager.shared.addInfoLog(
                        "Location command finished after the UI stopped waiting (code \(code))"
                    )
                    return
                }
                isBusy = false
                if code == 0 {
                    onSuccess()
                } else {
                    onFailure?()
                    presentAlert(title: errorTitle, message: errorMessage(code))
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commandTimeout) {
            guard outcome.claim() else { return }
            isBusy = false
            onFailure?()
            LogManager.shared.addErrorLog(
                "Location command timed out after \(Int(Self.commandTimeout))s waiting for the device"
            )
            presentAlert(
                title: String(localized: "Device Not Responding"),
                message: String(localized: "TLocation could not reach this device in time. Connect LocalDevVPN and make sure Wi-Fi is joined to a network, then try again. If the command does reach the device it may still take effect; Return to Real Location ends any simulation.")
            )
        }
    }

    private func presentAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }

    /// Ends the simulation on the device. Reached only from the Stop button, from
    /// "Return to Real Location", and from a `tlocation://clear-location` URL the
    /// user has confirmed in a dialog — never automatically. Someone relying on a
    /// simulated position must not be dropped back to their real one without
    /// asking.
    ///
    /// Leaves the pin and the camera alone by itself: "stop, then re-simulate this
    /// same spot in a minute" is a real workflow, which is what the bare Stop
    /// button gives. Moving the map is `returnToRealLocation()`'s business, and it
    /// does that in the `onCleared` hook rather than here.
    ///
    /// The persisted record is dropped only on success — a failed clear leaves the
    /// device still simulating, so the flag (and with it an enabled Stop button)
    /// has to stay, or a retry would be impossible.
    private func clear(onFailure: (() -> Void)? = nil, onCleared: (() -> Void)? = nil) {
        guard pairingExists, !isBusy else { return }
        stopResendLoop()
        runLocationCommand(
            errorTitle: String(localized: "Clear Failed"),
            errorMessage: { code in
                String(localized: "Could not clear simulated location (error \(code)).")
            },
            operation: clear_simulated_location,
            onFailure: onFailure
        ) {
            setSimulationActive(nil)
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
            // `simulatedCoordinate` is the fixed anchor set above (or in
            // `adoptExternalSimulation`) and is never overwritten by a
            // jittered value, so every tick wobbles around the same point
            // instead of drifting further away over time. Read live so
            // flipping the setting mid-simulation takes effect on the very
            // next resend.
            let sendCoordinate = naturalGPSDrift
                ? jitteredCoordinate(around: simulatedCoordinate)
                : simulatedCoordinate
            LocationSimulationCommandQueue.shared.async {
                _ = locationUpdateCode(for: sendCoordinate)
            }
        }
    }

    /// Returns `anchor` offset by a small, realistic amount of consumer-GPS
    /// noise (a uniformly random radius of 3–5 m in a uniformly random
    /// direction, so the offset varies every call and never exceeds ~5 m).
    /// Only ever used for the bytes sent to the device on a resend — never
    /// for the pin, the anchor itself, or anything shown in the UI.
    ///
    /// Metres are converted to degrees using ~111,320 m per degree of
    /// latitude; longitude is additionally scaled by `cos(latitude)` since a
    /// degree of longitude shrinks toward the poles (e.g. ~7% shorter at
    /// Hanoi's ~21°N, ~2x shorter at 60°N) — skipping that scaling would make
    /// the east/west component of the wobble increasingly wrong away from
    /// the equator.
    private func jitteredCoordinate(around anchor: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let metersPerDegreeLatitude = 111_320.0
        let radiusMeters = Double.random(in: 3...5)
        let angle = Double.random(in: 0..<(2 * .pi))
        let eastMeters = radiusMeters * cos(angle)
        let northMeters = radiusMeters * sin(angle)

        let deltaLatitude = northMeters / metersPerDegreeLatitude
        let metersPerDegreeLongitude = metersPerDegreeLatitude * cos(anchor.latitude * .pi / 180)
        let deltaLongitude = metersPerDegreeLongitude != 0 ? eastMeters / metersPerDegreeLongitude : 0

        return CLLocationCoordinate2D(
            latitude: anchor.latitude + deltaLatitude,
            longitude: anchor.longitude + deltaLongitude
        )
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

    /// Recentres on `target` while preserving the current zoom span.
    ///
    /// - Parameter fallbackSpanMeters: framing to use when the camera has not
    ///   reported a region yet. Defaults to the historical 1000 m × 1000 m for
    ///   every mid-session caller; the launch-time restore passes
    ///   `defaultSpanMeters` instead, since it is the one caller that always runs
    ///   before the map has reported anything and should match the launch centring.
    private func recenterCamera(
        on target: CLLocationCoordinate2D,
        fallbackSpanMeters: CLLocationDistance = 1000
    ) {
        if let cameraSpan {
            position = .region(MKCoordinateRegion(center: target, span: cameraSpan))
        } else {
            position = .region(
                MKCoordinateRegion(
                    center: target,
                    latitudinalMeters: fallbackSpanMeters,
                    longitudinalMeters: fallbackSpanMeters
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
    ///
    /// Like Stop, this only ever runs from a direct tap on its own button.
    ///
    /// Confirmation is asked for only when there is a simulation to undo — which
    /// includes one restored from the persisted record, the case where the user is
    /// least likely to remember it is running. With nothing simulated the button is
    /// just "put the camera back on me" plus a harmless idempotent clear, and a
    /// dialog in front of that would be friction with nothing behind it.
    private func returnToRealLocation() {
        // Mirrors `clear()`'s own guard, so a tap it would drop on the floor cannot
        // raise a dialog whose confirm button then does nothing.
        guard pairingExists, !isBusy else { return }
        guard hasActiveSimulation else {
            performReturnToRealLocation()
            return
        }
        isConfirmingReturnToRealLocation = true
    }

    /// The action itself, reached either straight from `returnToRealLocation()` or
    /// from the confirm button of the dialog it raises.
    private func performReturnToRealLocation() {
        // Re-checked rather than assumed: an arbitrary amount of time can pass
        // while the dialog is on screen, so the spinner flag below can never be
        // left set by a call that `clear()` drops on the floor.
        guard pairingExists, !isBusy else { return }
        // Clear the pin immediately so no stale marker can mislead the user
        // while the simulation is torn down.
        coordinate = nil
        isReturningToRealLocation = true
        clear {
            isReturningToRealLocation = false
        } onCleared: {
            isReturningToRealLocation = false
            position = .userLocation(fallback: .automatic)
            showStatusMessage(String(localized: "Simulation stopped — following your real location"))
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
                alertTitle = String(localized: "Could Not Determine Location")
                alertMessage = String(localized: "No GPS fix was available. Try again, ideally with a clear view of the sky.")
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

    /// Reflects a simulation that outlived the process.
    ///
    /// A simulation runs in the device's DDI location-simulation service, so
    /// force-quitting TLocation does not end it: iOS carries on reporting the
    /// simulated position while every in-memory trace of it is gone.
    /// `ActiveSimulationStore` is the only record that survives, so the first time
    /// the map appears it is read back into `hasPersistedSimulation` — which is what
    /// makes "Return to Real Location" confirm before acting, and re-enables Stop
    /// once the restored pin is back on screen.
    ///
    /// Display only, and deliberately so. Nothing is sent to the device here in
    /// either direction: no re-simulate, and above all no clear. Ending someone's
    /// simulation is their decision, never a side effect of launching the app.
    ///
    /// No resend loop and no keep-alive activation are started either. Neither
    /// survived the process, and the loop only refreshes a position the device is
    /// already holding, so leaving it off changes nothing until the user acts.
    private func restorePersistedSimulationIfNeeded() {
        guard !hasRestoredPersistedSimulation else { return }
        hasRestoredPersistedSimulation = true
        guard ActiveSimulationStore.isActive else { return }

        hasPersistedSimulation = true

        // Claimed for the whole restore, not just the branch that moves the camera.
        // `centerOnLaunchLocationIfNeeded()` stands down while a simulation is
        // active, so leaving the one-shot unclaimed here used to arm a delayed
        // surprise: the moment the user cleared, the next `.onAppear` — the
        // Settings sheet closing is enough — would find no active simulation and
        // yank the camera to the real location. Either way this launch has decided
        // where the map starts.
        hasCenteredOnLaunch = true

        if let restored = ActiveSimulationStore.coordinate {
            coordinate = restored
            // Framed at the same street-level zoom the launch centring uses.
            // `cameraSpan` is always nil this early — the map has not reported a
            // region yet — so without naming the default explicitly this fell
            // through to `recenterCamera`'s wider 1000 m fallback.
            recenterCamera(on: restored, fallbackSpanMeters: Self.defaultSpanMeters)
        }
        // Without a stored coordinate there is nothing to frame, so the map is
        // simply left where it is; the notice below is then the only signal, which
        // is exactly why it has to be one the user will actually see.

        // Stated as fact, not as a hedge: a simulation held by the DDI service does
        // not expire and the device never reverts on its own (confirmed on
        // hardware), so it is still running until the user stops it. It names the
        // control that actually works here — with no pin there is no Stop button,
        // but "Return to Real Location" is always enabled.
        //
        // Persistent rather than transient: this runs at launch, when the readiness
        // overlay is usually still covering the map, and a three-second message
        // would be long gone by the time the overlay lifts. `RootView`'s readiness
        // card carries the same fact for the window where the map is not visible at
        // all.
        carriedOverSimulationNotice = String(localized: "A simulated location from a previous session is still active on this device. Use Return to Real Location to end it.")
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
