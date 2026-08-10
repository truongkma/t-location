//
//  AppNotifications.swift
//  TLocation
//
//  Cross-view notifications. `LocationSimulationView` is the single owner of the
//  simulated-location state (pin, resend loop, route playback, background task),
//  so external requests (URL scheme, alerts) are routed to it instead of calling
//  the device FFI directly.
//

import Foundation
import CoreLocation

extension Notification.Name {
    /// Ask the root view to present the pairing-file importer.
    static let showPairingFilePicker = Notification.Name("vn.truongkma.tlocation.showPairingFilePicker")

    /// Ask the map to start simulating a coordinate (see `LocationSimulationRequest`).
    static let simulateLocationRequested = Notification.Name("vn.truongkma.tlocation.simulateLocationRequested")

    /// Ask the map to stop simulating and clear the position on the device.
    static let clearSimulatedLocationRequested = Notification.Name("vn.truongkma.tlocation.clearSimulatedLocationRequested")
}

enum LocationSimulationRequest {
    private static let latitudeKey = "latitude"
    private static let longitudeKey = "longitude"
    /// Marks a notification that reports what the sender has *already* done to
    /// the device rather than asking the map to do it.
    ///
    /// A Shortcuts intent (see `LocationIntents.swift`) has to run whether or not
    /// the app has a UI, so it always drives the FFI itself. When a map happens
    /// to be on screen it still has to be told, or its 4-second resend loop would
    /// push the old coordinate back over the intent's within seconds — but it
    /// must sync its display *without* repeating the FFI call or taking a second
    /// keep-alive activation. Hence the same two notifications, flagged.
    private static let appliedKey = "alreadyApplied"

    static func postSimulate(latitude: Double, longitude: Double) {
        NotificationCenter.default.post(
            name: .simulateLocationRequested,
            object: nil,
            userInfo: [latitudeKey: latitude, longitudeKey: longitude]
        )
    }

    static func postClear() {
        NotificationCenter.default.post(name: .clearSimulatedLocationRequested, object: nil)
    }

    static func postSimulateApplied(latitude: Double, longitude: Double) {
        NotificationCenter.default.post(
            name: .simulateLocationRequested,
            object: nil,
            userInfo: [latitudeKey: latitude, longitudeKey: longitude, appliedKey: true]
        )
    }

    static func postClearApplied() {
        NotificationCenter.default.post(
            name: .clearSimulatedLocationRequested,
            object: nil,
            userInfo: [appliedKey: true]
        )
    }

    static func isAlreadyApplied(_ notification: Notification) -> Bool {
        notification.userInfo?[appliedKey] as? Bool == true
    }

    static func coordinate(from notification: Notification) -> CLLocationCoordinate2D? {
        guard let latitude = notification.userInfo?[latitudeKey] as? Double,
              let longitude = notification.userInfo?[longitudeKey] as? Double else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
