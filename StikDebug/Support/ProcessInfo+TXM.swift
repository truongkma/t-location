//
//  ProcessInfo+TXM.swift
//  StikDebug
//

import Foundation

public extension ProcessInfo {
    var hasTXMClassic: Bool {
        ProcessInfo.processInfo.isiOSAppOnMac ? false : ProcessInfo.detectLocalTXM()
    }

    var hasTXM: Bool {
        if isTXMOverridden {
            return true
        }

        return ProcessInfo.hasTXMSupport(
            isIOS266OrNewer: ProcessInfo.isIOS266OrNewer,
            hasTXMClassic: hasTXMClassic,
            hardwareIdentifier: hardwareIdentifier()
        )
    }

    var isTXMOverridden: Bool {
        UserDefaults.standard.bool(forKey: UserDefaults.Keys.txmOverride)
    }

    internal static func hasTXMSupport(
        isIOS266OrNewer: Bool,
        hasTXMClassic: Bool,
        hardwareIdentifier: String
    ) -> Bool {
        if isIOS266OrNewer, !hasTXMClassic {
            let firstTXM = 14.2
            let iPadTXM = 14.5

            if let ver = ProcessInfo.processInfo.deviceVersion(from: hardwareIdentifier) {
                if hardwareIdentifier.hasPrefix("iPad") {
                    return ver >= iPadTXM
                } else {
                    return ver >= firstTXM
                }
            }

            return false
        }

        return hasTXMClassic
    }

    func deviceVersion(from identifier: String) -> Double? {
        let iPhonePattern = #"iPhone(\d+),(\d+)"#
        let iPadPattern = #"iPad(\d+),(\d+)"#

        let extractVersion: (_ pattern: String) -> Double? = { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: identifier,
                    range: NSRange(identifier.startIndex..., in: identifier)
                  ),
                  let majorRange = Range(match.range(at: 1), in: identifier),
                  let minorRange = Range(match.range(at: 2), in: identifier),
                  let major = Double(identifier[majorRange]),
                  let minor = Double(identifier[minorRange])
            else {
                return nil
            }

            let divisor = pow(10.0, Double(String(Int(minor)).count))
            return major + (minor / divisor)
        }

        return extractVersion(iPhonePattern) ?? extractVersion(iPadPattern)
    }

    private static func detectLocalTXM() -> Bool {
        if let boot = FileManager.default.filePath(atPath: "/System/Volumes/Preboot", withLength: 36),
           let file = FileManager.default.filePath(atPath: "\(boot)/boot", withLength: 96) {
            return access("\(file)/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4", F_OK) == 0
        }

        return FileManager.default.filePath(atPath: "/private/preboot", withLength: 96).map {
            access("\($0)/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4", F_OK) == 0
        } ?? false
    }

    private static var isIOS266OrNewer: Bool {
        if #available(iOS 26.6, *) {
            return true
        }

        return false
    }

    private func hardwareIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)

        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}
