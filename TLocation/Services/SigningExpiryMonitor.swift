//
//  SigningExpiryMonitor.swift
//  TLocation
//

import Foundation

/// What the app knows about when its own signature expires: the last value read
/// from the device, when that read happened, and when it is worth reading again.
///
/// The value is read from `misagent`, the service that serves the provisioning
/// profiles iOS validates against, so it tracks SideStore refreshes. See
/// ``AppSigningInfo`` for why the app bundle is not read instead.
///
/// The reading is persisted, because it cannot be taken on demand: it needs a
/// pairing file and a live tunnel, neither of which exists at cold launch. So the
/// UI is driven entirely from the cache, the cache is refreshed opportunistically
/// whenever a read is actually possible, and — the invariant this whole type
/// exists to hold — **a read that fails changes nothing**. A device that cannot
/// be reached leaves yesterday's answer exactly where it was; it can never turn
/// into "expired".
final class SigningExpiryMonitor: ObservableObject {
    /// One answer from the device, and the moment it was given.
    struct Reading: Equatable {
        /// `nil` means the device answered but carries no provisioning profile
        /// for this app: *unknown*, which never warns. Distinct from `reading`
        /// itself being `nil`, which means the device has never answered at all.
        let expirationDate: Date?
        let checkedAt: Date
    }

    static let shared = SigningExpiryMonitor()

    /// How old a reading may be and still be allowed to raise the launch warning.
    ///
    /// An expiry only ever moves *later* — a refresh renews it, and nothing
    /// shortens it — so a stale reading can only ever cry wolf, never miss a real
    /// lapse. Six hours is therefore a bound on how long a refresh the user has
    /// already performed can keep nagging them, while still letting a reading
    /// taken earlier the same day drive the warning, rather than demanding the
    /// tunnel be up at the exact instant the app launches.
    static let trustWindow: TimeInterval = 6 * 60 * 60

    /// Floor between two device reads. The value changes once a week at most, so
    /// anything shorter is pure traffic on an endpoint shared with the simulation.
    private static let refreshInterval: TimeInterval = 30 * 60

    /// The cache. Published so both the Settings row and the launch warning are
    /// driven by it and nothing else. Main thread only.
    @Published private(set) var reading: Reading?

    /// Guards against two overlapping reads. Main thread only, like `reading`.
    private var isReading = false

    private init() {
        reading = Self.persistedReading()
    }

    /// True when there is a reading *and* it is recent enough to act on. The
    /// launch warning requires this; the Settings row does not, because it shows
    /// when the reading was taken and lets the user judge for themselves.
    var isTrustworthy: Bool {
        guard let reading else { return false }
        return Date().timeIntervalSince(reading.checkedAt) <= Self.trustWindow
    }

    // MARK: - Refreshing

    /// Reads the expiry from the device, if a read is possible and due.
    ///
    /// Every guard below is a reason to do nothing at all, never a reason to
    /// invent a value. Call it as often as is convenient — on appear, on becoming
    /// active, whenever the tunnel connects; it is cheap when it declines.
    ///
    /// **Queue.** The FFI work runs on the serial `LocationSimulationCommandQueue`,
    /// the same queue every location-simulation command uses, and never on the
    /// main thread. That is not incidental:
    ///
    /// * The read borrows `JITEnableContext`'s tunnel, and `withTunnelHandles`
    ///   will call `ensureTunnel()` — i.e. `tunnel_create_rppairing` against
    ///   `<targetIP>:49152`, the single-occupancy endpoint (errno 48, "address
    ///   already in use") that `simulate_location` also handshakes against. That
    ///   is precisely the collision `startTunnelAfterPendingLocationCommands` and
    ///   `TLocationApp`'s deferred rebuild already serialise on this queue, so a
    ///   third caller joins them rather than inventing a queue of its own that
    ///   could race them both.
    /// * Being serial, it also means one read at a time and never a read
    ///   overlapping a resend.
    ///
    /// The cost is that a simulation command issued while a read is in flight
    /// waits for it — a couple of RSD round trips, the same tax the deferred
    /// tunnel rebuild already pays. The `LocationSimulationSession` gate below
    /// keeps that to the case where a simulation starts *during* the read; when
    /// one is already running the read is simply skipped, and the next call takes
    /// it. Nothing here is urgent enough to make a simulation wait for it.
    func refreshIfPossible(reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.refreshIfPossible(reason: reason) }
            return
        }

        guard !isReading else { return }

        if let reading, Date().timeIntervalSince(reading.checkedAt) < Self.refreshInterval {
            return
        }

        // Deliberately does not *build* a tunnel. Reading an expiry is not worth
        // a handshake the user did not ask for, and `ensureTunnel()` inside the
        // read would do exactly that. Riding an already-connected tunnel keeps
        // this feature incapable of causing a connection.
        guard TunnelManager.shared.isConnected else { return }

        // Same two checks, and the same reasoning, as
        // `TLocationApp.attemptDeferredTunnelReconnect`: `isOpen` is a live
        // session, `isMaintained` is a resend loop whose last rebuild failed and
        // which is about to try again.
        guard !LocationSimulationSession.isOpen, !LocationSimulationSession.isMaintained else { return }

        isReading = true
        LocationSimulationCommandQueue.shared.async { [weak self] in
            // Re-checked on the far side of the serial queue, where the state has
            // settled: a `simulate_location` that was mid-rebuild when the checks
            // above ran has returned by the time this block starts.
            let outcome: Reading? = (LocationSimulationSession.isOpen || LocationSimulationSession.isMaintained)
                ? nil
                : Self.readFromDevice(reason: reason)

            DispatchQueue.main.async {
                guard let self else { return }
                self.isReading = false
                // `nil` is "the device did not answer". The cache stays exactly
                // as it was — this is the invariant in the type comment.
                guard let outcome else { return }
                self.store(outcome)
            }
        }
    }

    /// The device read itself. Returns `nil` for *no answer* — a failure, which
    /// must leave the cache untouched — as opposed to a `Reading` whose
    /// `expirationDate` is `nil`, which is the device answering "no profile for
    /// this app".
    private static func readFromDevice(reason: String) -> Reading? {
        // Read from the bundle rather than hardcoded, so a rename or a fork does
        // not silently start matching nothing.
        guard let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty else {
            LogManager.shared.addWarningLog(
                "Signing expiry check skipped: this build reports no bundle identifier."
            )
            return nil
        }

        do {
            let profiles = try JITEnableContext.shared.fetchAllProvisioningProfiles()
            let expiry = AppSigningInfo.expirationDate(
                forBundleIdentifier: bundleIdentifier,
                in: profiles
            )

            if let expiry {
                LogManager.shared.addInfoLog(
                    "Signing expiry read from the device after \(reason): \(AppSigningInfo.formatted(expiry)) (\(profiles.count) profiles on device)."
                )
            } else {
                LogManager.shared.addInfoLog(
                    "Signing expiry read from the device after \(reason): none of the \(profiles.count) profiles on the device covers \(bundleIdentifier)."
                )
            }

            return Reading(expirationDate: expiry, checkedAt: Date())
        } catch {
            // A warning, not an error: no tunnel and no pairing file are the
            // normal state of this app at launch, and the readiness overlay
            // already says so far more usefully than an alert from here would.
            LogManager.shared.addWarningLog(
                "Could not read the signing expiry from the device after \(reason): \(error.localizedDescription)"
            )
            return nil
        }
    }

    // MARK: - Persistence

    /// A successful read is authoritative, including when it found nothing: the
    /// device is the source of truth, so "checked, no profile" replaces a
    /// previously known date rather than silently keeping it alive.
    private func store(_ newReading: Reading) {
        reading = newReading

        let defaults = UserDefaults.standard
        if let expirationDate = newReading.expirationDate {
            defaults.set(
                expirationDate.timeIntervalSince1970,
                forKey: UserDefaults.Keys.signingExpiryDate
            )
        } else {
            defaults.removeObject(forKey: UserDefaults.Keys.signingExpiryDate)
        }
        defaults.set(
            newReading.checkedAt.timeIntervalSince1970,
            forKey: UserDefaults.Keys.signingExpiryCheckedAt
        )
    }

    /// The timestamp is what records that a read ever happened, so its absence —
    /// not the date's — is what "never checked" means.
    private static func persistedReading() -> Reading? {
        let defaults = UserDefaults.standard
        guard let checkedAt = defaults.object(
            forKey: UserDefaults.Keys.signingExpiryCheckedAt
        ) as? Double else {
            return nil
        }

        let expiry = (defaults.object(forKey: UserDefaults.Keys.signingExpiryDate) as? Double)
            .map(Date.init(timeIntervalSince1970:))

        return Reading(
            expirationDate: expiry,
            checkedAt: Date(timeIntervalSince1970: checkedAt)
        )
    }
}
