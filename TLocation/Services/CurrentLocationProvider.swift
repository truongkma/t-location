//
//  CurrentLocationProvider.swift
//  TLocation
//
//  Owns the app's *foreground* Core Location work: the one-shot real-GPS lookup
//  behind the "locate me" button, and a continuous tracking session that runs
//  only while the map is on screen so the blue user-location dot stays live.
//
//  Separate from BackgroundLocationManager, which only keeps the app alive in
//  the background (3 km accuracy, background updates) and must not be used to
//  drive the map — it is started/stopped around simulate/clear, so leaning on
//  it for the dot leaves the map with no location session the moment a
//  simulation is cleared.
//
//  Two CLLocationManager instances are used on purpose, one per job. That is
//  what keeps the two paths from interfering: `stopTracking()` can never cancel
//  an in-flight `locate()` (documented behaviour of `stopUpdatingLocation()` on
//  the *same* manager), and continuous fixes from the tracking session can
//  never be mistaken for — or duplicate — the one-shot completion.
//

import CoreLocation

final class CurrentLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum LocateError: Error {
        case denied
        case unavailable
    }

    /// Desired accuracy for the continuous tracking session only. There is no
    /// standard `kCLLocationAccuracy*` constant at this level, so it is spelled
    /// out and named here rather than left as a bare literal.
    ///
    /// Chosen over `kCLLocationAccuracyNearestTenMeters` because that tighter
    /// target makes iOS hold back any fix until it can back it with GPS, which
    /// indoors can take a long time — exactly the case right after a
    /// simulation is cleared, when the map should recenter on the real
    /// position quickly. 50 m is loose enough that a WiFi/cell-derived fix
    /// usually satisfies it immediately, while still being tight enough to
    /// place the dot on the correct street for a map view. The one-shot
    /// `locate(_:)` manager is unaffected and keeps the tighter accuracy.
    private static let trackingDesiredAccuracy: CLLocationDistance = 50

    @Published private(set) var isLocating = false

    /// Latest fix from the tracking session, or `nil` while it is not running
    /// (or has not produced a fix yet).
    @Published private(set) var currentCoordinate: CLLocationCoordinate2D?

    /// One-shot manager for `locate(_:)`. Untouched by the tracking session.
    private let manager = CLLocationManager()

    /// Continuous manager for `startTracking()` / `stopTracking()`.
    private let trackingManager = CLLocationManager()

    private var completion: ((Result<CLLocationCoordinate2D, LocateError>) -> Void)?

    /// Whether tracking is *wanted* (map on screen), as opposed to actually
    /// running. The two differ only while authorization is still undecided:
    /// `startTracking()` never prompts, so if permission is granted later —
    /// by the explicit Locate Me flow — the authorization callback starts the
    /// session then.
    private var wantsTracking = false
    private var isTrackingActive = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters

        trackingManager.delegate = self
        // See `trackingDesiredAccuracy` above for why this is 50 m rather than
        // `kCLLocationAccuracyNearestTenMeters` (used by the one-shot manager
        // below) or `Best`, which would burn battery for precision nothing
        // here consumes.
        trackingManager.desiredAccuracy = Self.trackingDesiredAccuracy
        // No distance filter: at 10 m accuracy, a 5 m filter meaningfully
        // distinguished real movement from fix-to-fix noise. At the coarser
        // 50 m accuracy used here, each fix already carries an error radius
        // well past 5 m, so CoreLocation can only confirm a 5 m displacement
        // by waiting for a materially better fix — reintroducing the very
        // delay this change exists to remove. `desiredAccuracy` is already
        // the resolution floor for this session, so a separate distance gate
        // on top of it is redundant; let every fix CoreLocation is willing to
        // deliver through instead.
        trackingManager.distanceFilter = kCLDistanceFilterNone
        // Auto-pause would silently kill the session while the user stands
        // still and would need an explicit restart to recover — exactly the
        // stale/grey dot this session exists to prevent.
        trackingManager.pausesLocationUpdatesAutomatically = false
        // Deliberately left at the default `false`: background keep-alive is
        // BackgroundLocationManager's job, and iOS suspends this session on its
        // own as soon as the app leaves the foreground.
    }

    deinit {
        trackingManager.stopUpdatingLocation()
    }

    // MARK: - Continuous tracking (map on screen)

    /// Starts a foreground location session so `UserAnnotation` renders a live
    /// blue dot and `.userLocation` camera positions have something to follow.
    ///
    /// Never prompts: if authorization is `.notDetermined`, `.denied` or
    /// `.restricted` this is a silent no-op. Permission is only ever requested
    /// by the explicit Locate Me flow.
    func startTracking() {
        wantsTracking = true
        startTrackingIfAuthorized()
    }

    /// Stops the foreground session. Only touches `trackingManager`, so an
    /// in-flight `locate(_:)` on the one-shot manager keeps running and still
    /// delivers its completion.
    func stopTracking() {
        wantsTracking = false
        guard isTrackingActive else { return }
        isTrackingActive = false
        trackingManager.stopUpdatingLocation()
    }

    private func startTrackingIfAuthorized() {
        guard wantsTracking, !isTrackingActive else { return }
        switch trackingManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            isTrackingActive = true
            trackingManager.startUpdatingLocation()
        default:
            break
        }
    }

    /// Bounces the continuous tracking session so CoreLocation delivers a
    /// current fix instead of replaying whatever it last cached under
    /// `distanceFilter = 5`. Intended for the moment right after a simulated
    /// fix has been withdrawn: nothing here makes GPS itself faster, it only
    /// stops the app's own session from adding delay on top of that.
    ///
    /// No-op unless the session is actually running — i.e. tracking is
    /// wanted (map on screen) and authorization is already granted. Never
    /// requests authorization itself: `startTrackingIfAuthorized()` is the
    /// only path that starts the session, and it already refuses to run
    /// without it. Only touches `trackingManager`, so an in-flight
    /// `locate(_:)` on the separate one-shot manager is never disturbed, and
    /// `isTrackingActive` / `wantsTracking` are left exactly as they were —
    /// this restarts the same session, it does not stop or start wanting one.
    ///
    /// Deliberately does not also call `requestLocation()` on
    /// `trackingManager`: that call self-terminates the session after one fix
    /// (or a timeout), which would silently end the continuous updates this
    /// method is supposed to be refreshing, not replacing.
    func refreshTracking() {
        guard isTrackingActive else { return }
        trackingManager.stopUpdatingLocation()
        trackingManager.startUpdatingLocation()
    }

    // MARK: - One-shot lookup (Locate Me)

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

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Authorization is app-wide, so both managers get this callback; each
        // only handles its own job.
        if manager === trackingManager {
            // Covers the case where the map appeared before permission existed
            // and Locate Me has just been granted it.
            startTrackingIfAuthorized()
            return
        }

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
        if manager === trackingManager {
            guard let coordinate = locations.last?.coordinate else { return }
            DispatchQueue.main.async { self.currentCoordinate = coordinate }
            return
        }

        guard let coordinate = locations.last?.coordinate else {
            finish(.failure(.unavailable))
            return
        }
        finish(.success(coordinate))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A tracking-session failure (no fix indoors, transient error) is not
        // worth surfacing: the session stays registered and recovers on its own.
        guard manager !== trackingManager else { return }
        finish(.failure(.unavailable))
    }
}
