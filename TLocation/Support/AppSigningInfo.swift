//
//  AppSigningInfo.swift
//  TLocation
//

import Foundation

/// Reports when this build's code signature expires, by reading the provisioning
/// profile Xcode/SideStore embedded in the app bundle.
///
/// TLocation is normally sideloaded through SideStore. With a free Apple ID the
/// signing certificate only lasts 7 days, and once it lapses the app refuses to
/// launch and has to be reinstalled — so the app warns before that happens.
///
/// Every lookup here is best-effort and returns `nil` rather than throwing: an App
/// Store build, a TrollStore install, or any build without an embedded profile has
/// no expiry to report, and must simply show no warning.
enum AppSigningInfo {
    /// Remaining time at or below which the launch warning is shown.
    static let warningThreshold: TimeInterval = 24 * 60 * 60

    /// Parsed once per launch. The profile cannot change while the app is running —
    /// re-signing means a new install — so re-reading it on every view update would
    /// be pure waste, and this is read from SwiftUI view bodies.
    private static let cachedExpirationDate: Date? = readExpirationDate()

    /// Date this build's signature expires, or `nil` when there is no embedded
    /// provisioning profile or it could not be parsed.
    static var expirationDate: Date? { cachedExpirationDate }

    /// Seconds until the signature expires. Negative once it already has.
    /// `nil` whenever `expirationDate` is.
    static var timeRemaining: TimeInterval? {
        cachedExpirationDate.map { $0.timeIntervalSinceNow }
    }

    /// True only when an expiry is actually known *and* it is within a day (or past).
    /// An unsigned/unknown build is never "expiring soon".
    static var isExpiringSoon: Bool {
        guard let remaining = timeRemaining else { return false }
        return remaining <= warningThreshold
    }

    static var hasExpired: Bool {
        guard let remaining = timeRemaining else { return false }
        return remaining <= 0
    }

    // MARK: - Presentation helpers

    /// Localised short date, e.g. "12 Aug 2026".
    static var formattedExpirationDate: String? {
        cachedExpirationDate?.formatted(date: .abbreviated, time: .omitted)
    }

    /// Human phrase for a positive duration: "5 days", "18 hours", "45 minutes".
    /// Rounded down, so the app never claims more time than is left.
    static func durationPhrase(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        let days = Int(seconds / 86_400)
        if days >= 1 { return days == 1 ? "1 day" : "\(days) days" }
        let hours = Int(seconds / 3_600)
        if hours >= 1 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        let minutes = Int(seconds / 60)
        if minutes >= 1 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        return "less than a minute"
    }

    /// "5 days" / "18 hours" left, or "Expired" once past. `nil` when unknown.
    static var remainingPhrase: String? {
        guard let remaining = timeRemaining else { return nil }
        return remaining <= 0 ? "Expired" : durationPhrase(remaining)
    }

    // MARK: - Profile parsing

    /// A `.mobileprovision` is a CMS/PKCS#7 signed blob wrapping an XML plist.
    /// Rather than pull in a CMS decoder for one date field, this slices the plist
    /// straight out of the container: everything from the first `<?xml` through the
    /// end of the last `</plist>`. The signature is not verified, and does not need
    /// to be — this is the app reading its own bundle to decide whether to nag the
    /// user, not a security boundary.
    private static func readExpirationDate() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let container = try? Data(contentsOf: url) else {
            return nil
        }

        let opening = Data("<?xml".utf8)
        let closing = Data("</plist>".utf8)
        guard let start = container.range(of: opening)?.lowerBound,
              let end = container.range(of: closing, options: .backwards)?.upperBound,
              start < end else {
            return nil
        }

        let plistData = container.subdata(in: start..<end)
        guard let plist = try? PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            return nil
        }

        return plist["ExpirationDate"] as? Date
    }
}
