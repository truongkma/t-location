//
//  ActiveSimulationStore.swift
//  TLocation
//
//  The one piece of simulation state that has to outlive the process.
//
//  A simulation does not run inside TLocation: `simulate_location` hands the
//  position to the device's DDI location-simulation service, which keeps
//  reporting it until something clears it. Force-quitting the app — or having iOS
//  kill it — therefore stops nothing, while `LocationSimulationState` in
//  `IdeviceFFIBridge` (plain in-memory statics) comes back empty. Without a record
//  on disk the relaunched app would believe nothing is running and disable the
//  very controls that stop it.
//
//  This is that record: a flag plus the last coordinate. It is a *statement of
//  what the device was last asked to do*, never an instruction — reading it back
//  restores UI state and nothing else. Nothing here, and nothing that reads it,
//  may re-send a position or clear one; clearing is always the user's decision.
//

import CoreLocation
import Foundation

enum ActiveSimulationStore {
    /// True from a successful simulate until the successful clear that ends it,
    /// across launches.
    static var isActive: Bool {
        UserDefaults.standard.bool(forKey: UserDefaults.Keys.simulationIsActive)
    }

    /// The coordinate the device was last asked to report, or `nil` if the record
    /// is absent or unusable. A `nil` here does not mean "not simulating" — check
    /// `isActive` for that; it means "simulating, position unknown", which can only
    /// happen for a record written by a build older than this one.
    static var coordinate: CLLocationCoordinate2D? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: UserDefaults.Keys.simulationLatitude) != nil,
              defaults.object(forKey: UserDefaults.Keys.simulationLongitude) != nil else {
            return nil
        }

        let coordinate = CLLocationCoordinate2D(
            latitude: defaults.double(forKey: UserDefaults.Keys.simulationLatitude),
            longitude: defaults.double(forKey: UserDefaults.Keys.simulationLongitude)
        )
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    /// Records a simulation the device has just accepted. Call only after the FFI
    /// has reported success, so the flag never claims more than actually happened.
    ///
    /// The coordinate is written before the flag: a reader that catches the two
    /// writes mid-flight then sees "not active" rather than "active, at the
    /// previous simulation's coordinate".
    static func markStarted(latitude: Double, longitude: Double) {
        let defaults = UserDefaults.standard
        defaults.set(latitude, forKey: UserDefaults.Keys.simulationLatitude)
        defaults.set(longitude, forKey: UserDefaults.Keys.simulationLongitude)
        defaults.set(true, forKey: UserDefaults.Keys.simulationIsActive)
    }

    /// Forgets the recorded simulation. Call only after a clear the device has
    /// accepted — dropping the record while the device is still simulating is
    /// exactly the state this file exists to prevent.
    ///
    /// The flag is removed first, mirroring `markStarted`'s ordering, so an
    /// interleaved reader can never see "active" with the coordinate already gone.
    static func markCleared() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: UserDefaults.Keys.simulationIsActive)
        defaults.removeObject(forKey: UserDefaults.Keys.simulationLatitude)
        defaults.removeObject(forKey: UserDefaults.Keys.simulationLongitude)
    }
}
