//
//  LocationIntents.swift
//  TLocation
//
//  Shortcuts / Siri support.
//
//  These intents run in the app's process, but usually *without* any UI: the
//  system launches TLocation in the background to service them. So nothing here
//  may touch SwiftUI view state, present an alert, or assume `RootView` has ever
//  appeared — in particular it cannot rely on `RootView.onAppear` having started
//  the tunnel or on `MountingProgress` having mounted the DDI. Each intent
//  therefore re-establishes its own prerequisites and reports what is missing in
//  words the user can act on.
//

import AppIntents
import CoreLocation
import Foundation

// MARK: - Errors

/// Every failure an intent can report. `CustomLocalizedStringResourceConvertible`
/// is what makes the message visible in Shortcuts and Siri instead of the generic
/// "The action failed to run"; `LocalizedError` gives the same text to
/// `LogManager` and to anything that catches this as a plain `Error`.
enum LocationIntentError: Swift.Error, CustomLocalizedStringResourceConvertible, LocalizedError {
    case noPairingFile
    case tunnelUnavailable(detail: String)
    case timedOut(step: String)
    case developerDiskImageNotMounted
    case invalidLatitude(Double)
    case invalidLongitude(Double)
    case bookmarkUnavailable
    case simulationFailed(code: Int)
    case clearFailed(code: Int)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noPairingFile:
            return "Import a pairing file in TLocation first."
        case .tunnelUnavailable(let detail):
            return "TLocation could not reach this device. Connect LocalDevVPN and make sure Wi-Fi is joined to a network. (\(detail))"
        case .timedOut(let step):
            return "\(step) timed out. Connect LocalDevVPN and make sure Wi-Fi is joined to a network, then try again."
        case .developerDiskImageNotMounted:
            return "The Developer Disk Image (DDI) is not mounted yet. Open TLocation and wait for setup to finish, then try again."
        case .invalidLatitude(let value):
            return "Latitude \(value) is out of range. It must be between -90 and 90."
        case .invalidLongitude(let value):
            return "Longitude \(value) is out of range. It must be between -180 and 180."
        case .bookmarkUnavailable:
            return "That saved location no longer exists in TLocation."
        case .simulationFailed(let code):
            return "TLocation could not simulate the location (error \(code)). Make sure the device is connected and the Developer Disk Image (DDI) is mounted."
        case .clearFailed(let code):
            return "TLocation could not clear the simulated location (error \(code)). It may already have been cleared."
        }
    }

    var errorDescription: String? {
        String(localized: localizedStringResource)
    }
}

// MARK: - Bookmark entity

/// A saved location, exposed to Shortcuts so an action can offer a picker of the
/// user's own places instead of asking for raw numbers. Backed one-to-one by
/// `LocationBookmark`; nothing here is persisted, so `BookmarkStore`'s on-disk
/// format is untouched.
struct BookmarkEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Saved Location"
    static var defaultQuery = BookmarkEntityQuery()

    var id: UUID
    var name: String
    var latitude: Double
    var longitude: Double

    init(_ bookmark: LocationBookmark) {
        self.id = bookmark.id
        self.name = bookmark.name
        self.latitude = bookmark.latitude
        self.longitude = bookmark.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(LocationIntentFormat.coordinate(latitude: latitude, longitude: longitude))"
        )
    }
}

/// Reads straight from `BookmarkStore`, so the picker always shows what the app
/// shows — including bookmarks added or renamed since the shortcut was built.
/// `EntityStringQuery` (rather than plain `EntityQuery`) is what lets Siri match
/// a spoken bookmark name against the list.
struct BookmarkEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [BookmarkEntity] {
        let wanted = Set(identifiers)
        return BookmarkStore.load()
            .filter { wanted.contains($0.id) }
            .map(BookmarkEntity.init)
    }

    func entities(matching string: String) async throws -> [BookmarkEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await suggestedEntities() }
        // `localizedStandardContains` is case- and diacritic-insensitive, so a
        // spoken "ha noi" still matches a bookmark saved as "Hà Nội".
        return BookmarkStore.load()
            .filter { $0.name.localizedStandardContains(query) }
            .map(BookmarkEntity.init)
    }

    func suggestedEntities() async throws -> [BookmarkEntity] {
        BookmarkStore.load().map(BookmarkEntity.init)
    }
}

// MARK: - Intents

/// Split out from a single "Simulate Location" action deliberately: a saved
/// location and a raw coordinate pair have no fields in common, and two actions
/// keep every field in the Shortcuts editor relevant. See the sibling
/// `SimulateCoordinatesIntent`.
struct SimulateSavedLocationIntent: AppIntent {
    static var title: LocalizedStringResource = "Simulate Saved Location"
    static var description = IntentDescription(
        "Sets this device's simulated GPS position to one of your saved locations in TLocation.",
        categoryName: "Location"
    )
    /// The work happens over the device tunnel; there is nothing to show, so the
    /// intent stays in the background and reports its result as a dialog.
    static var openAppWhenRun: Bool = false

    static var parameterSummary: some ParameterSummary {
        Summary("Simulate \(\.$bookmark)")
    }

    @Parameter(title: "Saved Location")
    var bookmark: BookmarkEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // A shortcut can outlive the bookmark it was built around; re-read it so
        // an entry deleted or moved since then is reported rather than replayed
        // from the stale copy Shortcuts persisted in the action.
        let current = BookmarkStore.load().first { $0.id == bookmark.id }
        guard let current else { throw LocationIntentError.bookmarkUnavailable }

        try await LocationIntentRunner.simulate(
            latitude: current.latitude,
            longitude: current.longitude
        )
        return .result(dialog: "Simulating \(current.name)")
    }
}

/// The explicit-coordinate half of "simulate a location".
struct SimulateCoordinatesIntent: AppIntent {
    static var title: LocalizedStringResource = "Simulate Coordinates"
    static var description = IntentDescription(
        "Sets this device's simulated GPS position to a latitude and longitude.",
        categoryName: "Location"
    )
    static var openAppWhenRun: Bool = false

    static var parameterSummary: some ParameterSummary {
        Summary("Simulate \(\.$latitude), \(\.$longitude)")
    }

    @Parameter(title: "Latitude", inclusiveRange: (-90.0, 90.0))
    var latitude: Double

    @Parameter(title: "Longitude", inclusiveRange: (-180.0, 180.0))
    var longitude: Double

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await LocationIntentRunner.simulate(latitude: latitude, longitude: longitude)
        let formatted = LocationIntentFormat.coordinate(latitude: latitude, longitude: longitude)
        return .result(dialog: "Simulating \(formatted)")
    }
}

/// Clears the simulated position so the device reports its real GPS fix again.
struct StopSimulationIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Simulating Location"
    static var description = IntentDescription(
        "Clears the simulated GPS position so this device reports its real location again.",
        categoryName: "Location"
    )
    static var openAppWhenRun: Bool = false

    static var parameterSummary: some ParameterSummary {
        Summary("Stop simulating location")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await LocationIntentRunner.stop()
        return .result(dialog: "Stopped simulating location")
    }
}

// MARK: - Shortcuts

/// Every phrase must contain `\(.applicationName)` — the system rejects the
/// shortcut otherwise. The phrases themselves are translated in
/// `AppShortcuts.xcstrings`, which Xcode extracts these literals into; every
/// translated phrase must keep the `${applicationName}` token for the same
/// reason.
struct TLocationShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SimulateSavedLocationIntent(),
            phrases: [
                "Simulate a saved location in \(.applicationName)",
                "Simulate \(\.$bookmark) in \(.applicationName)"
            ],
            shortTitle: "Simulate Saved Location",
            systemImageName: "bookmark.circle"
        )
        AppShortcut(
            intent: SimulateCoordinatesIntent(),
            phrases: [
                "Simulate coordinates in \(.applicationName)",
                "Set a simulated location in \(.applicationName)"
            ],
            shortTitle: "Simulate Coordinates",
            systemImageName: "location.circle"
        )
        AppShortcut(
            intent: StopSimulationIntent(),
            phrases: [
                "Stop simulating location in \(.applicationName)",
                "Clear the simulated location in \(.applicationName)"
            ],
            shortTitle: "Stop Simulating",
            systemImageName: "location.slash"
        )
    }
}

// MARK: - Formatting

enum LocationIntentFormat {
    static func coordinate(latitude: Double, longitude: Double) -> String {
        String(format: "%.4f, %.4f", latitude, longitude)
    }
}

// MARK: - Runner

/// The shared body of every intent: check the prerequisites, drive the device
/// FFI, then keep the rest of the app consistent with what just happened.
///
/// Deliberately free of any view or `@Published` state — see the file header.
enum LocationIntentRunner {
    /// Creating the tunnel can sit on a TCP connect when the VPN is up but the
    /// device is not answering. Failing with an explanation beats being killed
    /// by the intent watchdog with a generic error.
    private static let tunnelTimeout: TimeInterval = 25
    private static let commandTimeout: TimeInterval = 20

    /// Mirrors `TunnelManager`, which also creates the tunnel off the main
    /// thread. `JITEnableContext.startTunnel()` serialises callers internally,
    /// so this racing the app's own start is safe.
    private static let tunnelQueue = DispatchQueue(
        label: "vn.truongkma.tlocation.intent-tunnel",
        qos: .userInitiated
    )

    // MARK: Simulate

    static func simulate(latitude: Double, longitude: Double) async throws {
        guard (-90.0...90.0).contains(latitude) else {
            throw LocationIntentError.invalidLatitude(latitude)
        }
        guard (-180.0...180.0).contains(longitude) else {
            throw LocationIntentError.invalidLongitude(longitude)
        }

        let pairingFilePath = try requirePairingFile()
        try await ensureDeviceReady()

        let deviceIP = DeviceConnectionContext.targetIPAddress
        let code = try await run(
            on: LocationSimulationCommandQueue.shared,
            timeout: commandTimeout,
            step: String(localized: "Simulating the location")
        ) {
            simulate_location(deviceIP, latitude, longitude, pairingFilePath)
        }

        guard code == 0 else {
            LogManager.shared.addErrorLog("Shortcut simulate failed with code \(code)")
            throw LocationIntentError.simulationFailed(code: Int(code))
        }

        LogManager.shared.addInfoLog(
            String(format: "Shortcut simulated location: %.6f, %.6f", latitude, longitude)
        )
        await publishSimulation(latitude: latitude, longitude: longitude)
    }

    // MARK: Stop

    static func stop() async throws {
        // Clearing genuinely needs the pairing file now: with no live session
        // `clear_simulated_location` builds one from it before clearing, which is
        // what lets a shortcut stop a simulation that outlived the app. Checking
        // here turns a missing file into a sentence rather than a bare code 2.
        //
        // Note this is a real device round trip even when the app never simulated
        // anything in this launch — which is the entire point, since the device may
        // well still be simulating from a previous one.
        _ = try requirePairingFile()

        let code = try await run(
            on: LocationSimulationCommandQueue.shared,
            timeout: commandTimeout,
            step: String(localized: "Clearing the simulated location")
        ) {
            clear_simulated_location()
        }

        guard code == 0 else {
            LogManager.shared.addErrorLog("Shortcut clear failed with code \(code)")
            throw LocationIntentError.clearFailed(code: Int(code))
        }

        LogManager.shared.addInfoLog("Shortcut cleared the simulated location")
        await publishClear()
    }

    // MARK: Prerequisites

    private static func requirePairingFile() throws -> String {
        let path = PairingFileStore.prepareURL().path
        guard FileManager.default.fileExists(atPath: path) else {
            throw LocationIntentError.noPairingFile
        }
        return path
    }

    /// Brings up the loopback tunnel and confirms the DDI is mounted.
    ///
    /// `simulate_location` builds its own tunnel from the pairing file, so this
    /// is not strictly required to make the call succeed — but it is how a
    /// missing VPN turns into a sentence the user can act on instead of a bare
    /// "error 3", and the DDI (which the location service lives behind) is only
    /// mountable over this tunnel.
    private static func ensureDeviceReady() async throws {
        do {
            try await run(on: tunnelQueue, timeout: tunnelTimeout, step: String(localized: "Connecting to the device")) {
                try JITEnableContext.shared.ensureTunnel()
            }
        } catch let error as LocationIntentError {
            throw error
        } catch {
            LogManager.shared.addErrorLog("Shortcut tunnel failed: \(error.localizedDescription)")
            throw LocationIntentError.tunnelUnavailable(detail: error.localizedDescription)
        }

        // Advisory only. A definitive "nothing is mounted" is worth reporting up
        // front; anything else (the query itself failing) is left to
        // `simulate_location` to report, so a flaky probe can never block a
        // simulation that would have worked.
        let mountedCount = try? await run(
            on: tunnelQueue,
            timeout: commandTimeout,
            step: String(localized: "Checking the Developer Disk Image")
        ) {
            try JITEnableContext.shared.getMountedDeviceCount()
        }

        if mountedCount == 0 {
            throw LocationIntentError.developerDiskImageNotMounted
        }
    }

    // MARK: Keeping the rest of the app in step

    /// `BackgroundLocationManager` owns a `CLLocationManager`, which expects to
    /// be driven from the main thread; the app's own UI paths always call it
    /// from there, and so does this. The notification is posted from the same
    /// hop because `MapSelectionView` observes it with `onReceive`, which
    /// delivers on whatever thread posted.
    /// The persisted record is written before the notification, so a map that is on
    /// screen sees the new value the moment it is told to sync, and a map that is
    /// not reads it on its next launch. Intents are the one path that can change
    /// the device's simulation with no UI in the process at all, which is exactly
    /// why the record has to be updated here rather than in a view.
    private static func publishSimulation(latitude: Double, longitude: Double) async {
        await MainActor.run {
            ActiveSimulationStore.markStarted(latitude: latitude, longitude: longitude)
            BackgroundLocationManager.shared.requestStart()
            LocationSimulationRequest.postSimulateApplied(latitude: latitude, longitude: longitude)
        }
    }

    private static func publishClear() async {
        await MainActor.run {
            ActiveSimulationStore.markCleared()
            BackgroundLocationManager.shared.requestStop()
            LocationSimulationRequest.postClearApplied()
        }
    }

    // MARK: Blocking-work bridge

    /// Runs blocking FFI work on `queue` and gives up after `timeout`.
    ///
    /// The work itself cannot be cancelled — the idevice FFI is synchronous — so
    /// a timed-out call is left to finish on its own; the guard below makes sure
    /// whichever of the two finishes first is the only one to resume the
    /// continuation, so a late completion can never resume it twice and trap.
    private static func run<T: Sendable>(
        on queue: DispatchQueue,
        timeout: TimeInterval,
        step: String,
        work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let resume = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let value = try work()
                    if resume.claim() { continuation.resume(returning: value) }
                } catch {
                    if resume.claim() { continuation.resume(throwing: error) }
                }
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                if resume.claim() {
                    continuation.resume(throwing: LocationIntentError.timedOut(step: step))
                }
            }
        }
    }

    /// One-shot ticket: exactly one caller of `claim()` ever gets `true`.
    private final class ResumeOnce: @unchecked Sendable {
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
}
