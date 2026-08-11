//
//  IdeviceFFIBridge.swift
//  TLocation
//
//  Created by Stephen on 2026/3/30.
//

import Foundation
import idevice

private enum IdeviceBridge {
    static func makeError(
        domain: String = "TLocation",
        code: Int = -1,
        message: String
    ) -> NSError {
        NSError(
            domain: domain,
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    static func string(from cString: UnsafePointer<CChar>?) -> String? {
        guard let cString else { return nil }
        return String(validatingUTF8: cString)
    }

    /// Reads an FFI error for logging *without* freeing it, so the existing
    /// `idevice_error_free` call on each path stays exactly where it is and
    /// ownership is unchanged. Purely for diagnostics.
    static func detail(from ffiError: UnsafeMutablePointer<IdeviceFfiError>?) -> String {
        guard let ffiError else { return "libidevice reported no detail" }
        let message = string(from: ffiError.pointee.message) ?? "no message"
        return "libidevice code \(ffiError.pointee.code): \(message)"
    }

    static func consumeFFIError(
        _ ffiError: UnsafeMutablePointer<IdeviceFfiError>?,
        fallback: String,
        domain: String = "TLocation"
    ) -> NSError {
        guard let ffiError else {
            return makeError(domain: domain, message: fallback)
        }

        let code = Int(ffiError.pointee.code)
        let message = string(from: ffiError.pointee.message) ?? fallback
        idevice_error_free(ffiError)
        return makeError(domain: domain, code: code, message: message)
    }

    static func mappedFileData(atPath path: String, description: String) throws -> Data {
        let url = URL(fileURLWithPath: path)

        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty else {
                throw makeError(message: "\(description) is empty")
            }
            return data
        } catch let error as NSError {
            throw makeError(code: error.code, message: "Failed to read \(description): \(error.localizedDescription)")
        }
    }

    static func uint64Value(from plist: plist_t?, fieldName: String) throws -> UInt64 {
        guard let plist else {
            throw makeError(message: "\(fieldName) was not returned by lockdownd")
        }

        var value: UInt64 = 0
        plist_get_uint_val(plist, &value)

        guard value != 0 else {
            throw makeError(message: "Failed to decode \(fieldName)")
        }

        return value
    }

    static func withTunnelHandles<T>(
        for context: JITEnableContext,
        _ body: (OpaquePointer, OpaquePointer) throws -> T
    ) throws -> T {
        let handles = try activeTunnelHandles(for: context)
        return try body(handles.adapter, handles.handshake)
    }

    static func connectClient(
        fallback: String,
        missingClientMessage: String,
        domain: String = "TLocation",
        connect: (UnsafeMutablePointer<OpaquePointer?>) -> UnsafeMutablePointer<IdeviceFfiError>?
    ) throws -> OpaquePointer {
        var client: OpaquePointer?
        if let ffiError = connect(&client) {
            throw consumeFFIError(ffiError, fallback: fallback, domain: domain)
        }

        guard let client else {
            throw makeError(domain: domain, message: missingClientMessage)
        }

        return client
    }

    static func withConnectedClient<T>(
        fallback: String,
        missingClientMessage: String,
        domain: String = "TLocation",
        connect: (UnsafeMutablePointer<OpaquePointer?>) -> UnsafeMutablePointer<IdeviceFfiError>?,
        cleanup: (OpaquePointer) -> Void,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        let client = try connectClient(
            fallback: fallback,
            missingClientMessage: missingClientMessage,
            domain: domain,
            connect: connect
        )
        defer { cleanup(client) }
        return try body(client)
    }

    static func activeTunnelHandles(for context: JITEnableContext) throws -> (adapter: OpaquePointer, handshake: OpaquePointer) {
        try context.ensureTunnel()

        guard let adapterHandle = context.adapterHandle,
              let handshakeHandle = context.handshakeHandle else {
            throw makeError(message: "Tunnel is not connected")
        }

        return (adapterHandle, handshakeHandle)
    }
}

extension JITEnableContext {
    func getMountedDeviceCount() throws -> Int {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to image mounter",
                missingClientMessage: "Image mounter client was not created",
                connect: { image_mounter_connect_rsd(adapter, handshake, $0) },
                cleanup: { image_mounter_free($0) }
            ) { client in
                var devices: UnsafeMutablePointer<plist_t?>?
                var deviceCount = 0
                if let ffiError = image_mounter_copy_devices(client, &devices, &deviceCount) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to fetch mounted devices")
                }

                if let devices {
                    for index in 0..<deviceCount {
                        plist_free(devices[index])
                    }
                    idevice_data_free(
                        UnsafeMutableRawPointer(devices).assumingMemoryBound(to: UInt8.self),
                        UInt(deviceCount * MemoryLayout<plist_t?>.stride)
                    )
                }

                return deviceCount
            }
        }
    }

    func mountPersonalDDI(withImagePath imagePath: String, trustcachePath: String, manifestPath: String) throws {
        let imageData = try IdeviceBridge.mappedFileData(atPath: imagePath, description: "developer disk image")
        let trustcacheData = try IdeviceBridge.mappedFileData(atPath: trustcachePath, description: "developer disk image trust cache")
        let manifestData = try IdeviceBridge.mappedFileData(atPath: manifestPath, description: "developer disk image manifest")

        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            let uniqueChipID = try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to lockdownd",
                missingClientMessage: "Lockdownd client was not created",
                connect: { lockdownd_connect_rsd(adapter, handshake, $0) },
                cleanup: { lockdownd_client_free($0) }
            ) { lockdownClient in
                var uniqueChipIDPlist: plist_t?
                if let ffiError = lockdownd_get_value(lockdownClient, "UniqueChipID", nil, &uniqueChipIDPlist) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to query UniqueChipID")
                }

                defer {
                    if let uniqueChipIDPlist {
                        plist_free(uniqueChipIDPlist)
                    }
                }

                return try IdeviceBridge.uint64Value(from: uniqueChipIDPlist, fieldName: "UniqueChipID")
            }

            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to image mounter",
                missingClientMessage: "Image mounter client was not created",
                connect: { image_mounter_connect_rsd(adapter, handshake, $0) },
                cleanup: { image_mounter_free($0) }
            ) { imageMounterClient in
                let ffiError = imageData.withUnsafeBytes { imageBuffer -> UnsafeMutablePointer<IdeviceFfiError>? in
                    trustcacheData.withUnsafeBytes { trustcacheBuffer -> UnsafeMutablePointer<IdeviceFfiError>? in
                        manifestData.withUnsafeBytes { manifestBuffer -> UnsafeMutablePointer<IdeviceFfiError>? in
                            image_mounter_mount_personalized_with_callback_rsd(
                                imageMounterClient,
                                adapter,
                                handshake,
                                imageBuffer.bindMemory(to: UInt8.self).baseAddress,
                                imageData.count,
                                trustcacheBuffer.bindMemory(to: UInt8.self).baseAddress,
                                trustcacheData.count,
                                manifestBuffer.bindMemory(to: UInt8.self).baseAddress,
                                manifestData.count,
                                nil,
                                uniqueChipID,
                                progressCallback,
                                nil
                            )
                        }
                    }
                }

                if let ffiError {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to mount personalized DDI")
                }
            }
        }
    }
}

private enum LocationSimulationStatus {
    static let ok: Int32 = 0
    static let invalidIP: Int32 = 1
    static let pairingRead: Int32 = 2
    static let providerCreate: Int32 = 3
    static let remoteServer: Int32 = 9
    static let locationSimulation: Int32 = 10
    static let locationSet: Int32 = 11
    static let locationClear: Int32 = 12
}

private enum LocationSimulationState {
    static var adapter: OpaquePointer?
    static var handshake: OpaquePointer?
    static var remoteServer: OpaquePointer?
    static var locationSimulation: OpaquePointer?

    static func cleanup() {
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
        // Every teardown goes through here — the rebuild in `simulate_location`,
        // each failure path, and `clear_simulated_location` — so this is the one
        // place that has to retract the flag.
        LocationSimulationSession.set(open: false)
    }
}

/// Whether a location-simulation session is currently open on the device.
///
/// A lock-guarded mirror of `LocationSimulationState.locationSimulation != nil`,
/// maintained by the two places that change it (a successful
/// `location_simulation_new`, and `LocationSimulationState.cleanup()`), both of
/// which only ever run on `LocationSimulationCommandQueue`. The handles
/// themselves stay confined to that queue; this exposes a plain `Bool` so code
/// on any thread — notably the scene-phase handler in `TLocationApp`, which runs
/// on the main thread and cannot block — can ask the question without touching a
/// pointer.
///
/// It answers "is a session open", not "is the user simulating": those diverge
/// for exactly as long as it takes the resend loop to notice a session has died,
/// which is what `LocationSimulationView.handleResendResult(_:)` exists to close.
enum LocationSimulationSession {
    private static let lock = NSLock()
    private static var open = false

    static var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    fileprivate static func set(open newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        open = newValue
    }
}

enum LocationSimulationCommandQueue {
    static let shared = DispatchQueue(label: "vn.truongkma.tlocation.location-sim", qos: .userInitiated)
}

func simulate_location(_ deviceIP: String, _ latitude: Double, _ longitude: Double, _ pairingFile: String) -> Int32 {
    if let locationSimulation = LocationSimulationState.locationSimulation {
        if let ffiError = location_simulation_set(locationSimulation, latitude, longitude) {
            // Not an error yet: the code below rebuilds the session from
            // scratch and either succeeds or logs why it did not. Worth a line
            // regardless, because a session that keeps dying mid-simulation is
            // invisible otherwise — every rebuild looks like a fresh start.
            LogManager.shared.addWarningLog(
                "simulate_location: the open session rejected the update (\(IdeviceBridge.detail(from: ffiError))); rebuilding it"
            )
            idevice_error_free(ffiError)
            LocationSimulationState.cleanup()
        } else {
            return LocationSimulationStatus.ok
        }
    }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(49152).bigEndian

    let inetResult = deviceIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
    guard inetResult == 1 else {
        LogManager.shared.addErrorLog(
            "simulate_location failed (code \(LocationSimulationStatus.invalidIP)): “\(deviceIP)” is not a valid IPv4 address. Check the target device IP in Settings."
        )
        return LocationSimulationStatus.invalidIP
    }

    var pairingHandle: OpaquePointer?
    let pairingError = pairingFile.withCString { rp_pairing_file_read($0, &pairingHandle) }
    if let pairingError {
        LogManager.shared.addErrorLog(
            "simulate_location failed (code \(LocationSimulationStatus.pairingRead)): could not read the pairing file at \(pairingFile) — \(IdeviceBridge.detail(from: pairingError))"
        )
        idevice_error_free(pairingError)
        return LocationSimulationStatus.pairingRead
    }

    guard let pairingHandle else {
        LogManager.shared.addErrorLog(
            "simulate_location failed (code \(LocationSimulationStatus.pairingRead)): reading the pairing file at \(pairingFile) reported success but returned no handle"
        )
        return LocationSimulationStatus.pairingRead
    }

    defer { rp_pairing_file_free(pairingHandle) }

    let providerError = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            tunnel_create_rppairing(
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.stride),
                "TLocationSimulation",
                pairingHandle,
                nil,
                nil,
                &LocationSimulationState.adapter,
                &LocationSimulationState.handshake
            )
        }
    }

    if let providerError {
        LogManager.shared.addErrorLog(
            "simulate_location failed (code \(LocationSimulationStatus.providerCreate)): could not open the tunnel to \(deviceIP):49152 — \(IdeviceBridge.detail(from: providerError)). Check that LocalDevVPN is connected."
        )
        idevice_error_free(providerError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.providerCreate
    }

    let remoteServerError = remote_server_connect_rsd(
        LocationSimulationState.adapter,
        LocationSimulationState.handshake,
        &LocationSimulationState.remoteServer
    )
    if let remoteServerError {
        LogManager.shared.addErrorLog(
            "simulate_location failed (code \(LocationSimulationStatus.remoteServer)): could not connect to the remote service on \(deviceIP):49152 — \(IdeviceBridge.detail(from: remoteServerError))"
        )
        idevice_error_free(remoteServerError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.remoteServer
    }

    let locationSimulationError = location_simulation_new(
        LocationSimulationState.remoteServer,
        &LocationSimulationState.locationSimulation
    )
    if let locationSimulationError {
        LogManager.shared.addErrorLog(
            "simulate_location failed (code \(LocationSimulationStatus.locationSimulation)): the device would not start a location-simulation session — \(IdeviceBridge.detail(from: locationSimulationError)). This usually means the Developer Disk Image is not mounted."
        )
        idevice_error_free(locationSimulationError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.locationSimulation
    }

    LocationSimulationState.remoteServer = nil

    // The session handle now exists. Published here rather than after the
    // `location_simulation_set` below because from this point on there is
    // something to tear down: if the set fails, `cleanup()` retracts the flag on
    // its way out, so the two can never disagree.
    LocationSimulationSession.set(open: true)

    let locationSetError = location_simulation_set(
        LocationSimulationState.locationSimulation,
        latitude,
        longitude
    )
    if let locationSetError {
        // The coordinate is deliberately never written to the log. Which call
        // failed and why is what diagnosis needs; *where* the user chose to
        // appear is their business, and a log is a record that outlives the
        // moment. Same reasoning on every other line below.
        LogManager.shared.addErrorLog(
            "simulate_location failed (code \(LocationSimulationStatus.locationSet)): the device rejected the coordinate — \(IdeviceBridge.detail(from: locationSetError))"
        )
        idevice_error_free(locationSetError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.locationSet
    }

    // Only the freshly built session is logged. The early return above — the
    // path the 4-second resend loop takes on every tick — deliberately stays
    // silent, so this line marks a user-initiated simulation (or a rebuild
    // after the session died) and cannot flood the log.
    LogManager.shared.addInfoLog(
        "simulate_location: the device accepted the coordinate on a new session"
    )

    return LocationSimulationStatus.ok
}

/// How long the connection stack is held open after a successful
/// `location_simulation_clear` before it is torn down.
///
/// `location_simulation_clear` is documented in `idevice.h` only as "Clears the
/// location set … an IdeviceFfiError on error, null on success" — nothing
/// promises the device has *acted* on the clear by the time it returns, and
/// `location_simulation_free`/`remote_server_free`/`rsd_handshake_free`/
/// `adapter_free` document no ordering requirement beyond "the handle must be
/// valid or NULL". Freeing the handle and collapsing the tunnel microseconds
/// later was therefore able to abort the clear in flight while the call still
/// reported success — matching the observed symptom of a successful return with
/// the device still simulating, intermittently.
///
/// 300 ms is roughly two orders of magnitude more than a round trip over the
/// local RSD tunnel (single-digit milliseconds), which is ample headroom for a
/// race that only lost occasionally, while staying under the ~400 ms at which a
/// button tap stops feeling immediate. It is spent on the serial
/// `LocationSimulationCommandQueue`, never on the main thread.
private let locationClearSettleInterval: TimeInterval = 0.3

func clear_simulated_location() -> Int32 {
    guard let locationSimulation = LocationSimulationState.locationSimulation else {
        LogManager.shared.addErrorLog(
            "clear_simulated_location failed (code \(LocationSimulationStatus.locationClear)): there is no open location-simulation session to clear"
        )
        return LocationSimulationStatus.locationClear
    }

    if let ffiError = location_simulation_clear(locationSimulation) {
        LogManager.shared.addErrorLog(
            "clear_simulated_location failed (code \(LocationSimulationStatus.locationClear)): the device rejected the clear — \(IdeviceBridge.detail(from: ffiError))"
        )
        idevice_error_free(ffiError)
        // A rejected clear means the session is of no further use, so it is torn
        // down immediately: a non-zero return still leaves nothing allocated.
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.locationClear
    }

    // See `locationClearSettleInterval`: give the device the connection it needs
    // to actually process the clear before the stack that carries it is freed.
    Thread.sleep(forTimeInterval: locationClearSettleInterval)
    LocationSimulationState.cleanup()

    LogManager.shared.addInfoLog(
        "clear_simulated_location: the device accepted the clear; session closed after a \(Int(locationClearSettleInterval * 1000)) ms settle"
    )

    return LocationSimulationStatus.ok
}
