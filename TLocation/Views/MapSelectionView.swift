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

/// Enlarges a tappable chip's *hit region* vertically toward Apple's ~44pt
/// touch-target minimum, without touching its horizontal footprint: only
/// `.padding(.vertical:)` is applied, so `HStack` layout — and therefore the
/// callout's rendered width — is completely unaffected. The chip's own
/// background/overlay stay at their original `26pt` size; `.contentShape` is
/// what makes the padded, invisible vertical margin respond to taps.
///
/// A prior version of this modifier also padded horizontally to reach a full
/// 44×44 box, but that grew each chip's reported width and forced the
/// callout wider (240 → 276pt) to fit — visibly larger than before, which
/// was rejected. Horizontal hit area is intentionally left alone: the Copy
/// chip sits between the coordinate text and the Save chip with only `8pt`
/// of `HStack` spacing on each side, so any horizontal padding here would
/// either widen the callout (if it grows the reported frame, as `.padding`
/// does) or risk the two chips' hit regions no longer being disjoint.
/// Vertical padding has no such conflict — there is no sibling above or
/// below a chip to collide with — so it is free real estate for tap comfort.
///
/// `26pt` visible chip (`LocationSimulationView.calloutChipSize`) + `9pt`
/// padding per side = `44pt` tall reported frame, `26pt` wide (unchanged).
///
/// Only ever applied to interactive chips (Copy, unsaved Save). The saved
/// badge is not a button and must not pick this up, or it would gain a
/// tappable footprint it should never have.
private struct CalloutTapTarget: ViewModifier {
    static let verticalPadding: CGFloat = 9

    func body(content: Content) -> some View {
        content
            .padding(.vertical, Self.verticalPadding)
            .contentShape(Rectangle())
    }
}

/// Which alert `LocationSimulationView` currently wants on screen.
///
/// SwiftUI only reliably honours one `.alert` per view at the same
/// modifier-chain level. Three stacked `.alert`s made presentation
/// non-deterministic and let a `Bool` binding desync into a stuck `true`: the
/// Save-bookmark chip set `showSaveBookmarkAlert = true` while it was *already*
/// `true` with nothing on screen, which is a no-op, so tapping did nothing at
/// all until the app was relaunched. Routing all three through one piece of
/// optional state and one `.alert` modifier removes the class of bug — exactly
/// the consolidation `PendingImport` in `SettingsView` applies to
/// `.fileImporter`. Adding a fourth alert means a fourth case here, not a
/// second `.alert`.
///
/// The generic message case carries its own title and body, so there is no
/// separate `alertTitle` / `alertMessage` state left over to drift out of step
/// with what is actually being presented.
private enum PendingAlert {
    /// Generic error/information alert with a runtime-supplied, already
    /// localized title and body.
    case message(title: String, body: String)
    case saveBookmark
    case locationPermissionDenied

    /// Verbatim, because the `.message` payload arrives already localized from
    /// `String(localized:)` at the call site; the two fixed cases look their own
    /// titles up here so the rest of the view never has to.
    var title: String {
        switch self {
        case .message(let title, _): return title
        case .saveBookmark: return String(localized: "Save Bookmark")
        case .locationPermissionDenied: return String(localized: "Location Permission Needed")
        }
    }
}

/// Which sheet `LocationSimulationView` currently wants on screen. Same reason
/// as `PendingAlert`: two stacked `.sheet` modifiers carry the same
/// presentation-conflict risk, so Bookmarks and Settings share one piece of
/// state and one `.sheet(item:)` — which nils the item itself on every
/// dismissal, leaving nothing to get stuck.
private enum PendingSheet: Identifiable {
    case bookmarks
    case settings

    var id: Int {
        switch self {
        case .bookmarks: return 0
        case .settings: return 1
        }
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
    /// Drives the single consolidated `.alert` below — see `PendingAlert`.
    /// Nothing else in this view decides whether an alert is on screen.
    @State private var pendingAlert: PendingAlert?

    @State private var searchText = ""
    @StateObject private var searchCompleter = LocationSearchCompleter()
    @FocusState private var isSearchFocused: Bool
    @State private var simulatedCoordinate: CLLocationCoordinate2D?

    // Bookmarks
    @State private var bookmarks: [LocationBookmark] = []
    /// Drives the single consolidated `.sheet` below — see `PendingSheet`.
    @State private var pendingSheet: PendingSheet?
    /// Draft name typed into the "Save Bookmark" alert (`PendingAlert
    /// .saveBookmark`, opened from the callout's unsaved bookmark chip).
    /// `beginSaveBookmark` blanks it every time it opens the alert, so the user
    /// always types into an empty field rather than one pre-filled with the
    /// coordinate default; that default is only ever used as a fallback if Save
    /// is tapped while the field is still empty (see
    /// `saveCurrentPinAsBookmark`). It is cleared again on the way out too — by
    /// `saveCurrentPinAsBookmark` on Save, by `cancelSaveBookmark` on Cancel —
    /// but the clear on the way *in* is what actually guarantees no leftover
    /// text from a previous pin can ever be shown.
    ///
    /// Deliberately not cleared from the alert's `isPresented` setter: SwiftUI
    /// flips that binding as part of dismissing the alert, which can happen
    /// before the tapped button's action runs, and wiping the name there would
    /// make Save silently store the coordinate fallback instead of what was
    /// typed.
    @State private var newBookmarkName = ""

    /// Measured size of the pin callout, used to work out the screen rectangle
    /// the annotation occupies so a tap that lands on it is not also treated as
    /// a map tap. Zero until the callout has been laid out once.
    @State private var calloutSize: CGSize = .zero

    // Current location
    @StateObject private var currentLocationProvider = CurrentLocationProvider()
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

    /// How many resends in a row have come back non-zero. Reset to zero by any
    /// successful resend and by `startResendLoop`/`stopResendLoop`, so it only
    /// ever counts an unbroken run. Main-thread only, like every other piece of
    /// this view's state — see `handleResendResult(_:)`.
    @State private var consecutiveResendFailures = 0

    /// Consecutive failed resends before the app concludes the simulation is no
    /// longer running and says so.
    ///
    /// Three, spanning roughly twelve seconds of the four-second loop. One is far
    /// too eager to act on: every failing tick already contains a complete
    /// recovery attempt of its own — `simulate_location` tears the dead session
    /// down and builds a fresh tunnel, remote server and session at the user's
    /// anchor before it reports failure — so a single non-zero code can be a
    /// transport blip mid-repair (VPN re-establishing after a foreground return,
    /// Wi-Fi roaming) rather than a verdict. Three consecutive failures means
    /// three full rebuild attempts have been made and refused, which is well past
    /// any of those, while still telling the user the truth inside a quarter of a
    /// minute rather than leaving the map lying indefinitely.
    private static let resendFailureLimit = 3

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
                action: { pendingSheet = .bookmarks }
            )

            // Settings stays a first-class button: it is the fallback route to
            // importing a pairing file when the connection banner is dismissed.
            mapControlButton(
                systemImage: "gearshape.fill",
                accessibilityLabel: "Settings",
                isDisabled: false,
                action: { pendingSheet = .settings }
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
            pinControls
        }
        .animation(.default, value: statusMessage)
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    // MARK: - Pin callout

    /// Gap between the callout and the pin glyph below it.
    private static let calloutSpacing: CGFloat = 4
    /// Height of `pinGlyph` (head + stem). Fixed, so the annotation's screen
    /// rectangle can be reconstructed in `isInsidePinAnnotation`.
    private static let pinGlyphHeight: CGFloat = 30
    private static let pinGlyphWidth: CGFloat = 20
    /// Keeps a long bookmark name from stretching the callout across the map.
    /// A `276pt` variant briefly existed to fit chips that had grown wide
    /// enough to need a 44×44 hit box, but that made the callout visibly
    /// larger overall and was reverted — `CalloutTapTarget` now only expands
    /// hit regions vertically, so the chips' reported width (and therefore
    /// this cap) is back to its original value.
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

            // Original `8pt` gap, unchanged. `CalloutTapTarget`'s vertical-only
            // padding never touches horizontal layout, so this spacing is the
            // only thing separating the two chips' hit regions horizontally —
            // and it does, since neither chip's tap target extends sideways.
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
                    .modifier(CalloutTapTarget())
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
    /// that opens the "Save Bookmark" name prompt (`beginSaveBookmark`).
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
                beginSaveBookmark()
            } label: {
                calloutChip(
                    systemImage: "bookmark",
                    glyphColor: Self.bookmarkUnsavedTint,
                    fill: Self.bookmarkUnsavedTint.opacity(0.20),
                    stroke: Self.bookmarkUnsavedTint.opacity(0.70)
                )
                .modifier(CalloutTapTarget())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save Bookmark")
        }
    }

    /// Visible diameter of a callout chip. Briefly grew to `30pt` alongside a
    /// horizontally-padded `CalloutTapTarget`, but that made the callout
    /// visibly larger overall and was reverted back to its original size.
    private static let calloutChipSize: CGFloat = 26

    private func calloutChip(
        systemImage: String,
        glyphColor: Color,
        fill: Color,
        stroke: Color
    ) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(glyphColor)
            .frame(width: Self.calloutChipSize, height: Self.calloutChipSize)
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
    ///
    /// `calloutSize` is measured off the live view hierarchy (see the
    /// `GeometryReader` in `pinCallout`), so this guard automatically follows
    /// whatever the callout actually renders at — including the slightly
    /// taller footprint `CalloutTapTarget`'s vertical hit padding produces —
    /// with no separate constant to keep in sync by hand.
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

    /// The coordinate-derived name used as the fallback when the user leaves
    /// the field empty (or whitespace-only) and hits Save anyway — the same
    /// default the rest of the app already falls back to (see
    /// `BookmarksView.commitRename`), so a bookmark always ends up with a name.
    private static func defaultBookmarkName(for coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
    }

    /// Opens the "Save Bookmark" name prompt with an empty field — the user
    /// types a name from scratch; the "Name" placeholder keeps the field from
    /// reading as a blank box. The coordinate-derived default only appears if
    /// Save is tapped while still empty (see `saveCurrentPinAsBookmark`).
    /// Mirrors the duplicate guard in `saveCurrentPinAsBookmark` so the chip
    /// can never be re-tapped into opening the prompt for an already-saved pin.
    private func beginSaveBookmark() {
        guard let coord = coordinate,
              BookmarkStore.bookmark(nearest: coord, in: bookmarks) == nil else { return }
        newBookmarkName = ""
        // Assignment, not a flag flip: `pendingAlert` is nil whenever no alert
        // is on screen (the `.alert` binding's setter guarantees it), so this
        // can never be the "set true while already true" no-op that used to
        // leave the chip dead until the app was relaunched.
        pendingAlert = .saveBookmark
    }

    /// Cancels the "Save Bookmark" prompt without saving anything, clearing the
    /// draft name so nothing is left behind. Dismissing the alert itself is the
    /// `.alert` binding's job, not this function's.
    private func cancelSaveBookmark() {
        newBookmarkName = ""
    }

    /// Commits the "Save Bookmark" prompt: trims the typed name and, if that
    /// leaves nothing (the field started empty and the user saved without
    /// typing, or typed only whitespace), falls back to the coordinate-derived
    /// default — the same behaviour `BookmarksView.commitRename` already uses
    /// for an emptied rename — so a bookmark always ends up with a name.
    ///
    /// Always stores `coordinate`, the exact anchor the user chose; natural GPS
    /// drift never touches it (see `savedBookmarkAtPin`). The duplicate guard
    /// repeats the callout's own check, so even if the badge were somehow tapped
    /// while showing "saved" no second bookmark could be created.
    private func saveCurrentPinAsBookmark() {
        defer { newBookmarkName = "" }
        guard let coord = coordinate,
              BookmarkStore.bookmark(nearest: coord, in: bookmarks) == nil else { return }
        let trimmed = newBookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? Self.defaultBookmarkName(for: coord) : trimmed
        bookmarks.append(
            LocationBookmark(
                name: name,
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
        // The one and only alert on this view — the generic error/message
        // alert, the "Save Bookmark" name prompt and the location-permission
        // alert all come out of `pendingAlert`. See `PendingAlert` for why
        // three stacked `.alert`s had to go.
        //
        // `isPresented` is derived from `pendingAlert` and its setter nils it
        // on *every* dismissal — Save, Cancel, and SwiftUI dismissing the alert
        // on its own — so no call site has to remember to tidy up and a stale
        // "already presenting" state cannot survive to block the next request.
        .alert(
            pendingAlert?.title ?? "",
            isPresented: Binding(
                get: { pendingAlert != nil },
                set: { isPresented in if !isPresented { pendingAlert = nil } }
            ),
            presenting: pendingAlert
        ) { alert in
            switch alert {
            case .message:
                Button("OK", role: .cancel) { }

            // Restores the name prompt the callout's one-tap save temporarily
            // replaced. Wording and structure match the pre-callout "Save
            // Bookmark" alert (see git history on this file) so it still looks
            // consistent with the rest of the app, notably `BookmarksView`'s
            // own "Rename Bookmark" alert below. The field opens empty — see
            // `beginSaveBookmark` — with only the "Name" placeholder as a hint.
            case .saveBookmark:
                TextField("Name", text: $newBookmarkName)
                // No role, plus `.defaultAction`: renders as the bold, primary
                // button (not `.destructive`, which would render red and
                // wrongly read as dangerous for a save) and lets Return submit
                // while typing. Alert button roles/style come from `role` and
                // `.keyboardShortcut`, not `.foregroundColor`, which `.alert`
                // ignores.
                Button("Save") { saveCurrentPinAsBookmark() }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) { cancelSaveBookmark() }

            case .locationPermissionDenied:
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) { }
            }
        } message: { alert in
            switch alert {
            // Verbatim: the body arrives already localized in the payload,
            // matching the old `Text(alertMessage)`, which was also verbatim.
            case .message(_, let body):
                Text(verbatim: body)
            case .saveBookmark:
                Text("Enter a name for this location.")
            case .locationPermissionDenied:
                Text("TLocation needs location access to find your current position. Note: while a simulated location is active, iOS reports the simulated position.")
            }
        }
        // The one and only sheet on this view, for the same reason — see
        // `PendingSheet`. `.sheet(item:)` nils `pendingSheet` itself on every
        // dismissal (swipe-down included), so neither sheet can leave state
        // behind that blocks reopening it.
        //
        // `onDismiss` reloads for *both* cases. Settings can import bookmarks
        // into the store behind this view's `@State` copy, so the copy has to
        // be refreshed the moment it closes; Bookmarks edits that same copy
        // through a `@Binding` and persists each change immediately, so a
        // reload there is a no-op on content but keeps the two definitively in
        // step (and picks up anything a linked sync file changed underneath).
        // `onDismiss` is used rather than relying on `.onAppear` firing again,
        // which is a SwiftUI implementation detail this view should not depend
        // on for correctness.
        .sheet(item: $pendingSheet, onDismiss: loadBookmarks) { sheet in
            switch sheet {
            case .bookmarks:
                BookmarksView(bookmarks: $bookmarks) { bookmark in
                    applySelection(bookmark.coordinate)
                    pendingSheet = nil
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
            case .settings:
                SettingsView()
            }
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
        if hasActiveSimulation {
            BackgroundLocationManager.shared.requestStop()
        }
        coordinate = requested
        recenterCamera(on: requested)
        beginBackgroundTask()
        startResendLoop(with: requested)
    }

    /// Counterpart of `adoptExternalSimulation`: the intent has already cleared
    /// the device and released its keep-alive activation, so calling `clear()`
    /// here would only re-run `clear_simulated_location()` on an already-torn-down
    /// session — error 12 and a spurious alert.
    ///
    /// This is `clear()`'s success path minus the FFI call and the keep-alive
    /// release, so the map ends up exactly where the Stop button would leave it:
    /// resend loop stopped, background task ended, and the pin still on screen
    /// ready to be re-simulated.
    private func adoptExternalClear() {
        stopResendLoop()
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
                    pendingAlert = .message(title: errorTitle, body: errorMessage(code))
                }
            }
        }
    }

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
            endBackgroundTask()
            BackgroundLocationManager.shared.requestStop()
            // The simulated fix is gone; bounce the tracking session so the
            // real dot arrives as soon as CoreLocation can manage rather than
            // waiting out `distanceFilter`'s cache. Covers both the Stop
            // button and Return to Real Location, which both funnel through
            // this closure. No-op if tracking is not running (map off screen
            // or no authorization yet) — see `refreshTracking()`.
            currentLocationProvider.refreshTracking()
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
        consecutiveResendFailures = 0
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
                let code = locationUpdateCode(for: sendCoordinate)
                // The result used to be discarded here. A session that had died
                // then failed on every tick in complete silence — no log line
                // from this loop, no alert, and a map that went on showing an
                // active simulation the device had already stopped honouring.
                DispatchQueue.main.async { handleResendResult(code) }
            }
        }
    }

    /// Reacts to one resend's return code, on the main thread.
    ///
    /// Success is deliberately silent: at one tick every four seconds, logging
    /// those would bury everything else in the log within minutes. Failures are
    /// logged individually with their code — `simulate_location` has already
    /// written the line explaining what that code means and which call produced
    /// it, so this one only has to say that a *resend* was what hit it and how
    /// close the run is to the limit.
    private func handleResendResult(_ code: Int32) {
        // The loop has been stopped (Stop, Return to Real Location, a Shortcut's
        // clear, or the map going off screen) since this resend was dispatched.
        // Its result is about a simulation that is already over, so it must not
        // count toward the failure run or raise anything.
        guard simulatedCoordinate != nil else { return }

        guard code != 0 else {
            consecutiveResendFailures = 0
            return
        }

        consecutiveResendFailures += 1
        LogManager.shared.addWarningLog(
            "Location resend failed (code \(code)) — consecutive failure \(consecutiveResendFailures) of \(Self.resendFailureLimit); see the simulate_location line above for what this code means"
        )

        guard consecutiveResendFailures >= Self.resendFailureLimit else { return }
        concludeSimulationHasStopped()
    }

    /// Stops claiming a simulation the app can no longer sustain, and tells the
    /// user why.
    ///
    /// **State correction only — nothing is sent to the device in either
    /// direction.** No re-simulate: `simulate_location` has already retried the
    /// user's exact anchor on every one of the failing ticks that got us here
    /// (it rebuilds tunnel, remote server and session before reporting failure,
    /// and logs both the rebuild and its outcome), so an extra attempt from here
    /// would repeat work that has just been refused three times, and any attempt
    /// this function *could* make would have to invent its own coordinate at some
    /// point in the future — the shape of change this project has already had to
    /// revert once. And no clear: `clear_simulated_location()` stays reachable
    /// only from a deliberate user action.
    ///
    /// The pin is left on the map, so "Simulate Location" is right there to try
    /// again with the same point if the user wants to.
    private func concludeSimulationHasStopped() {
        LogManager.shared.addErrorLog(
            "Location resends failed \(Self.resendFailureLimit) times in a row; TLocation is no longer treating the simulation as running. No command was sent to the device."
        )
        stopResendLoop()
        endBackgroundTask()
        BackgroundLocationManager.shared.requestStop()
        // Same reasoning as `clear()`'s success path: whatever the device is
        // reporting now, this app should stop sitting on a cached simulated fix.
        currentLocationProvider.refreshTracking()
        pendingAlert = .message(
            title: String(localized: "Simulation Stopped"),
            body: String(localized: "TLocation lost the location-simulation session on this device and could not rebuild it, so the position is no longer being kept up to date — the device has most likely returned to its real location. Nothing was sent to the device. Tap Simulate Location to start again.")
        )
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
        consecutiveResendFailures = 0
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
            showStatusMessage(String(localized: "Simulation stopped — map is waiting for your real location (slower indoors)"))
        }
    }

    private func performLocate() {
        currentLocationProvider.locate { result in
            switch result {
            case .success(let coordinate):
                applySelection(coordinate)
                Haptics.medium()
            case .failure(.denied):
                pendingAlert = .locationPermissionDenied
            case .failure(.unavailable):
                pendingAlert = .message(
                    title: String(localized: "Could Not Determine Location"),
                    body: String(localized: "No GPS fix was available. Try again, ideally with a clear view of the sky.")
                )
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
            // Same treatment as the callout's "Save Bookmark" alert: no role
            // (not `.destructive`, which would render red) plus
            // `.defaultAction` for the bold primary-button style and
            // Return-to-submit.
            Button("Save") { commitRename() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                renamingBookmarkID = nil
                renameText = ""
            }
        } message: {
            Text("Enter a new name for this location.")
        }
    }
}
