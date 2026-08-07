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

    static func coordinate(from notification: Notification) -> CLLocationCoordinate2D? {
        guard let latitude = notification.userInfo?[latitudeKey] as? Double,
              let longitude = notification.userInfo?[longitudeKey] as? Double else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
