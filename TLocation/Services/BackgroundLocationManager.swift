//
//  BackgroundLocationManager.swift
//  TLocation
//

import Combine
import CoreLocation

final class BackgroundLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = BackgroundLocationManager()

    /// The app's Core Location authorization, republished for the UI.
    ///
    /// This manager is the one place that depends on the *level* of that
    /// authorization rather than merely having some: background location
    /// updates only keep a backgrounded app alive under `.authorizedAlways`.
    /// With "While Using the App" iOS suspends the app shortly after it is
    /// backgrounded, the resend loop stops, and the simulated location
    /// silently reverts to the real one — so Settings shows a warning when
    /// this is anything other than `.authorizedAlways`.
    ///
    /// Published from the delegate callback below rather than sampled by the
    /// UI, because the user changes this in system Settings — outside the app
    /// entirely — and any value read once would be stale by the time they came
    /// back.
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let locationManager = CLLocationManager()
    private var isRunning = false
    private var activityCount = 0

    private override init() {
        super.init()
        locationManager.delegate = self
        authorizationStatus = locationManager.authorizationStatus
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager.distanceFilter = CLLocationDistanceMax
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        isRunning = true
        switch locationManager.authorizationStatus {
        case .authorizedAlways:
            locationManager.startUpdatingLocation()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        case .notDetermined:
            locationManager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    func stop() {
        isRunning = false
        locationManager.stopUpdatingLocation()
    }

    func requestStart() {
        activityCount += 1
        if activityCount == 1, UserDefaults.standard.bool(forKey: "keepAliveLocation") {
            start()
        }
    }

    func requestStop() {
        activityCount = max(activityCount - 1, 0)
        if activityCount == 0 {
            stop()
        }
    }

    /// Re-reads the current authorization. Only a safety net for the case where
    /// the delegate callback below is somehow missed; it is not the mechanism
    /// the UI relies on.
    func refreshAuthorizationStatus() {
        publish(locationManager.authorizationStatus)
    }

    private func publish(_ status: CLAuthorizationStatus) {
        guard status != authorizationStatus else { return }
        if Thread.isMainThread {
            authorizationStatus = status
        } else {
            DispatchQueue.main.async { self.authorizationStatus = status }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Before the `isRunning` guard: the warning in Settings has to be
        // correct whether or not a simulation happens to be running, and this
        // callback also fires for changes made in system Settings while the
        // app was backgrounded.
        publish(manager.authorizationStatus)

        guard isRunning else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Location fixes may fail (e.g. no GPS indoors) — that's fine.
        // The manager just needs to be running, not actually fix a location.
    }
}
