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
    }
}

enum LocationSimulationCommandQueue {
    static let shared = DispatchQueue(label: "vn.truongkma.tlocation.location-sim", qos: .userInitiated)
}

/// Brings up everything a location-simulation call needs — tunnel adapter and RSD
/// handshake built from the pairing file, remote server, location-simulation
/// handle — and parks the handles in `LocationSimulationState`.
///
/// Shared by `simulate_location` and `clear_simulated_location`. Clearing needs it
/// just as much as simulating does: a simulation lives in the device's DDI
/// location-simulation service and outlives this process, so after a force-quit
/// there is no session left to reuse and "no session in memory" must not be
/// allowed to mean "cannot clear".
///
/// Returns `LocationSimulationStatus.ok` on success, leaving
/// `LocationSimulationState.locationSimulation` non-nil. On every failure path the
/// partially built state is torn down before returning, so no handle is leaked and
/// a non-zero result always means there is nothing left to clean up.
private func establishLocationSimulation(deviceIP: String, pairingFile: String) -> Int32 {
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(49152).bigEndian

    let inetResult = deviceIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
    guard inetResult == 1 else {
        return LocationSimulationStatus.invalidIP
    }

    var pairingHandle: OpaquePointer?
    let pairingError = pairingFile.withCString { rp_pairing_file_read($0, &pairingHandle) }
    if let pairingError {
        idevice_error_free(pairingError)
        return LocationSimulationStatus.pairingRead
    }

    guard let pairingHandle else {
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
        idevice_error_free(remoteServerError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.remoteServer
    }

    let locationSimulationError = location_simulation_new(
        LocationSimulationState.remoteServer,
        &LocationSimulationState.locationSimulation
    )
    if let locationSimulationError {
        idevice_error_free(locationSimulationError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.locationSimulation
    }

    // `location_simulation_new` takes ownership of the remote server, so the
    // pointer is dropped here rather than freed by `cleanup()` later.
    LocationSimulationState.remoteServer = nil

    return LocationSimulationStatus.ok
}

func simulate_location(_ deviceIP: String, _ latitude: Double, _ longitude: Double, _ pairingFile: String) -> Int32 {
    if let locationSimulation = LocationSimulationState.locationSimulation {
        if let ffiError = location_simulation_set(locationSimulation, latitude, longitude) {
            idevice_error_free(ffiError)
            LocationSimulationState.cleanup()
        } else {
            return LocationSimulationStatus.ok
        }
    }

    let setupCode = establishLocationSimulation(deviceIP: deviceIP, pairingFile: pairingFile)
    guard setupCode == LocationSimulationStatus.ok else {
        return setupCode
    }

    let locationSetError = location_simulation_set(
        LocationSimulationState.locationSimulation,
        latitude,
        longitude
    )
    if let locationSetError {
        idevice_error_free(locationSetError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.locationSet
    }

    return LocationSimulationStatus.ok
}

/// Clears the simulated position on the device.
///
/// Only ever called from an explicit user action (the map's Stop button, Return to
/// Real Location, the confirmed `tlocation://clear-location` URL, and the "Stop
/// Simulating Location" shortcut). Nothing in the app may call this on its own —
/// silently dropping someone back to their real position is worse than any bug
/// this function fixes.
///
/// A missing in-memory session is *not* an error. The simulation runs in the
/// device's DDI location-simulation service, so it survives TLocation being
/// force-quit or killed while `LocationSimulationState` does not: on the next
/// launch iOS is still reporting the simulated position and this is the only thing
/// that can stop it. So when there is no session, one is established first — the
/// same setup `simulate_location` performs — and the clear is issued over it.
///
/// The device IP and pairing-file path are read here rather than taken as
/// parameters, so every existing caller keeps working unchanged; both come from
/// the same places the rest of the app reads them from.
///
/// Failure codes stay distinguishable: a connection that could not be established
/// reports the setup's own code (1, 2, 3, 9 or 10), while 12 means the connection
/// was fine and the clear itself was rejected. Clearing when nothing is simulated
/// is not a rejection — the service accepts it — so it reports success, which is
/// what a user who just wants their real location back expects.
func clear_simulated_location() -> Int32 {
    if LocationSimulationState.locationSimulation == nil {
        let pairingFile = PairingFileStore.prepareURL().path
        // Without a pairing file no tunnel can be built at all. Report that
        // rather than sitting in a connection attempt that cannot succeed.
        guard FileManager.default.fileExists(atPath: pairingFile) else {
            return LocationSimulationStatus.pairingRead
        }

        let setupCode = establishLocationSimulation(
            deviceIP: DeviceConnectionContext.targetIPAddress,
            pairingFile: pairingFile
        )
        guard setupCode == LocationSimulationStatus.ok else {
            return setupCode
        }
    }

    guard let locationSimulation = LocationSimulationState.locationSimulation else {
        return LocationSimulationStatus.locationSimulation
    }

    let ffiError = location_simulation_clear(locationSimulation)
    LocationSimulationState.cleanup()

    if let ffiError {
        idevice_error_free(ffiError)
        return LocationSimulationStatus.locationClear
    }

    return LocationSimulationStatus.ok
}
