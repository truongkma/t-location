//
//  AppSigningInfo.swift
//  TLocation
//

import Foundation

/// Turns provisioning-profile bytes into an expiry date, and an expiry date into
/// the words the UI shows.
///
/// TLocation is normally sideloaded through SideStore. With a free Apple ID the
/// signing certificate only lasts 7 days, and once it lapses the app refuses to
/// launch and has to be reinstalled — so the app warns before that happens.
///
/// This type is deliberately pure: bytes and dates in, dates and strings out. It
/// never decides *when* to look, and never touches the device. Where the profiles
/// come from — the `misagent` service, read through ``SigningExpiryMonitor`` — is
/// that type's business.
///
/// The bundle's own `embedded.mobileprovision` is **not** read here, and must not
/// be. That file is written at install time and is never rewritten when SideStore
/// refreshes the app: a refresh renews the profile at the system level only
/// (SideStore PR #846 removed the install step from refresh). Reading it reports
/// the expiry of whichever certificate was current when the app was last
/// *installed*, which after the first weekly refresh is always in the past — a
/// red "expired" row and a warning card on every launch, on a perfectly healthy
/// signature. `misagent` reports the profiles iOS actually validates against, so
/// it moves when a refresh moves it, and it is the only source used.
enum AppSigningInfo {
    /// Remaining time at or below which the launch warning is shown.
    static let warningThreshold: TimeInterval = 24 * 60 * 60

    // MARK: - Choosing this app's profile

    /// Latest expiry among the profiles that cover `bundleIdentifier`, or `nil`
    /// when none of them do.
    ///
    /// A device keeps every profile that was ever installed on it, including
    /// superseded copies of this app's own from previous refreshes, so the newest
    /// expiry wins: the older ones are still present but are not what iOS
    /// validates against.
    ///
    /// `nil` means *unknown*, never *expired*. It is what an App Store or
    /// TrollStore install looks like — no profile names this app — and the
    /// caller must never turn it into a warning.
    static func expirationDate(forBundleIdentifier bundleIdentifier: String, in profiles: [Data]) -> Date? {
        profiles.compactMap { profile -> Date? in
            guard let plist = plist(fromProfile: profile),
                  covers(bundleIdentifier: bundleIdentifier, plist: plist) else {
                return nil
            }
            return plist["ExpirationDate"] as? Date
        }.max()
    }

    /// Whether a profile's entitlements name this app.
    ///
    /// `application-identifier` is the team-prefixed form —
    /// `ABCDE12345.vn.truongkma.tlocation` — so the app's own identifier is
    /// exactly the tail of it. The leading dot is part of the match on purpose:
    /// without it a profile for `com.example.nottlocation` would be claimed by
    /// `tlocation`.
    private static func covers(bundleIdentifier: String, plist: [String: Any]) -> Bool {
        guard !bundleIdentifier.isEmpty,
              let entitlements = plist["Entitlements"] as? [String: Any],
              let applicationIdentifier = entitlements["application-identifier"] as? String else {
            return false
        }
        return applicationIdentifier.hasSuffix(".\(bundleIdentifier)")
    }

    // MARK: - Profile parsing

    /// A `.mobileprovision` is a CMS/PKCS#7 signed blob wrapping an XML plist.
    /// Rather than pull in a CMS decoder for two fields, this slices the plist
    /// straight out of the container: everything from the first `<?xml` through
    /// the end of the last `</plist>`. The signature is not verified, and does not
    /// need to be — this is the app deciding whether to nag the user, not a
    /// security boundary.
    ///
    /// Returns `nil` for anything that does not parse. A device carries profiles
    /// belonging to other apps and other tools, and one unreadable profile must
    /// never cost the caller the rest of the list.
    static func plist(fromProfile container: Data) -> [String: Any]? {
        let opening = Data("<?xml".utf8)
        let closing = Data("</plist>".utf8)
        guard let start = container.range(of: opening)?.lowerBound,
              let end = container.range(of: closing, options: .backwards)?.upperBound,
              start < end else {
            return nil
        }

        let plistData = container.subdata(in: start..<end)
        return try? PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) as? [String: Any]
    }

    // MARK: - Presentation helpers

    static func hasExpired(_ expiry: Date, now: Date = Date()) -> Bool {
        expiry.timeIntervalSince(now) <= 0
    }

    /// True inside the last day, and once past it. Only ever asked about a date
    /// that is actually known — an unknown expiry is not "expiring soon".
    static func isExpiringSoon(_ expiry: Date, now: Date = Date()) -> Bool {
        expiry.timeIntervalSince(now) <= warningThreshold
    }

    /// Localised short date, e.g. "12 Aug 2026".
    static func formatted(_ expiry: Date) -> String {
        expiry.formatted(date: .abbreviated, time: .omitted)
    }

    /// Human phrase for a positive duration: "5 days", "18 hours", "45 minutes".
    /// Rounded down, so the app never claims more time than is left.
    ///
    /// Each branch is a whole localised string carrying its own count, chosen by
    /// the String Catalog's plural variations — never a number glued onto a
    /// separately translated unit word.
    static func durationPhrase(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        let days = Int(seconds / 86_400)
        if days >= 1 { return String(localized: "\(days) days") }
        let hours = Int(seconds / 3_600)
        if hours >= 1 { return String(localized: "\(hours) hours") }
        let minutes = Int(seconds / 60)
        if minutes >= 1 { return String(localized: "\(minutes) minutes") }
        return String(localized: "less than a minute")
    }

    /// "5 days" / "18 hours" left, or "Expired" once past.
    static func remainingPhrase(until expiry: Date, now: Date = Date()) -> String {
        let remaining = expiry.timeIntervalSince(now)
        return remaining <= 0 ? String(localized: "Expired") : durationPhrase(remaining)
    }
}

/// The "don't show again for this expiry" checkbox on the launch warning.
///
/// Keyed to the expiry date itself rather than stored as a plain flag, so that
/// refreshing in SideStore — which mints a new certificate and a new expiry —
/// brings the warning back next week instead of silencing it forever.
///
/// That was the intent from the start and it never worked, because the expiry it
/// was keyed to came from the app bundle and so never changed: ticking the box
/// disabled the warning permanently. It only becomes meaningful now that the
/// expiry is read from the device and actually moves. Lifted out of the view so
/// that behaviour can be tested rather than asserted.
enum ExpiryWarningSuppression {
    /// Dates are compared with a one-second tolerance because they make the round
    /// trip through `UserDefaults` as a `Double`.
    private static let tolerance: TimeInterval = 1

    static func suppress(_ expiry: Date, in defaults: UserDefaults = .standard) {
        defaults.set(expiry.timeIntervalSince1970, forKey: UserDefaults.Keys.suppressedExpiryWarning)
    }

    static func isSuppressed(_ expiry: Date, in defaults: UserDefaults = .standard) -> Bool {
        guard let suppressed = defaults.object(
            forKey: UserDefaults.Keys.suppressedExpiryWarning
        ) as? Double else {
            return false
        }
        return abs(suppressed - expiry.timeIntervalSince1970) < tolerance
    }
}
