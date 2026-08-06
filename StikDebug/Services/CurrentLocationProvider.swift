//
//  CurrentLocationProvider.swift
//  TLocation
//
//  One-shot real-GPS lookup for the "locate me" button. Separate from
//  BackgroundLocationManager, which only keeps the app alive in background.
//

import CoreLocation

final class CurrentLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum LocateError: Error {
        case denied
        case unavailable
    }

    @Published private(set) var isLocating = false

    private let manager = CLLocationManager()
    private var completion: ((Result<CLLocationCoordinate2D, LocateError>) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func locate(_ completion: @escaping (Result<CLLocationCoordinate2D, LocateError>) -> Void) {
        guard !isLocating else { return }
        self.completion = completion
        isLocating = true

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finish(.failure(.denied))
        default:
            manager.requestLocation()
        }
    }

    private func finish(_ result: Result<CLLocationCoordinate2D, LocateError>) {
        DispatchQueue.main.async {
            self.isLocating = false
            self.completion?(result)
            self.completion = nil
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isLocating else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(.denied))
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else {
            finish(.failure(.unavailable))
            return
        }
        finish(.success(coordinate))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(.unavailable))
    }
}
