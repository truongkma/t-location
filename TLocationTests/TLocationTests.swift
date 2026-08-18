//
//  TLocationTests.swift
//  TLocationTests
//

import Foundation
import Testing
@testable import TLocation

struct TLocationTests {

    /// Placeholder smoke test. The unit test target is hosted by the app, so
    /// `Bundle.main` is the app bundle.
    @Test func hostAppBundleIdentifierIsExpected() async throws {
        #expect(Bundle.main.bundleIdentifier == "vn.truongkma.tlocation")
    }
}

/// Wraps a provisioning-profile plist the way a real `.mobileprovision` does: a
/// CMS/PKCS#7 container with the XML plist buried in the middle. The bytes either
/// side stand in for the signature blobs `AppSigningInfo.plist(fromProfile:)` has
/// to skip past.
private func makeProfile(applicationIdentifier: String?, expiry: Date?) throws -> Data {
    var plist: [String: Any] = [:]
    if let applicationIdentifier {
        plist["Entitlements"] = ["application-identifier": applicationIdentifier]
    }
    if let expiry {
        plist["ExpirationDate"] = expiry
    }

    let body = try PropertyListSerialization.data(
        fromPropertyList: plist,
        format: .xml,
        options: 0
    )

    var container = Data([0x30, 0x82, 0x01, 0x00])
    container.append(body)
    container.append(Data([0xDE, 0xAD, 0xBE, 0xEF]))
    return container
}

struct AppSigningInfoTests {
    private let bundleIdentifier = "vn.truongkma.tlocation"

    @Test func picksTheProfileMatchingThisAppsBundleIdentifier() throws {
        let mine = Date(timeIntervalSince1970: 1_800_000_000)
        let theirs = Date(timeIntervalSince1970: 1_900_000_000)

        let profiles = [
            try makeProfile(applicationIdentifier: "ABCDE12345.com.example.other", expiry: theirs),
            try makeProfile(applicationIdentifier: "ABCDE12345.\(bundleIdentifier)", expiry: mine)
        ]

        #expect(
            AppSigningInfo.expirationDate(forBundleIdentifier: bundleIdentifier, in: profiles) == mine
        )
    }

    /// A device keeps superseded copies of its own profiles, so the newest one —
    /// the one iOS actually validates against — has to win.
    @Test func prefersTheLatestExpiryWhenSeveralProfilesMatch() throws {
        let stale = Date(timeIntervalSince1970: 1_800_000_000)
        let current = Date(timeIntervalSince1970: 1_800_604_800)

        let profiles = [
            try makeProfile(applicationIdentifier: "ABCDE12345.\(bundleIdentifier)", expiry: stale),
            try makeProfile(applicationIdentifier: "ABCDE12345.\(bundleIdentifier)", expiry: current),
            try makeProfile(applicationIdentifier: "ABCDE12345.\(bundleIdentifier)", expiry: nil)
        ]

        #expect(
            AppSigningInfo.expirationDate(forBundleIdentifier: bundleIdentifier, in: profiles) == current
        )
    }

    /// The dot before the bundle identifier is load-bearing: without it a profile
    /// for a differently named app whose identifier merely *ends* with ours would
    /// be mistaken for this app's.
    @Test func doesNotMatchAnIdentifierThatMerelyEndsWithOurs() throws {
        let profiles = [
            try makeProfile(
                applicationIdentifier: "ABCDE12345.com.exampletlocation",
                expiry: Date(timeIntervalSince1970: 1_800_000_000)
            )
        ]

        #expect(
            AppSigningInfo.expirationDate(forBundleIdentifier: "tlocation", in: profiles) == nil
        )
    }

    /// No match is *unknown*, and unknown must stay `nil` all the way up — the
    /// UI turns it into "no profile on this device", never into "expired".
    @Test func reportsNilWhenNoProfileCoversThisApp() throws {
        let profiles = [
            try makeProfile(
                applicationIdentifier: "ABCDE12345.com.example.other",
                expiry: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            try makeProfile(applicationIdentifier: nil, expiry: Date()),
            Data([0x00, 0x01, 0x02])
        ]

        #expect(
            AppSigningInfo.expirationDate(forBundleIdentifier: bundleIdentifier, in: profiles) == nil
        )
    }

    @Test func expiringSoonCoversTheLastDayAndEverythingPast() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(!AppSigningInfo.isExpiringSoon(now.addingTimeInterval(3 * 86_400), now: now))
        #expect(AppSigningInfo.isExpiringSoon(now.addingTimeInterval(3_600), now: now))
        #expect(AppSigningInfo.isExpiringSoon(now.addingTimeInterval(-3_600), now: now))

        #expect(!AppSigningInfo.hasExpired(now.addingTimeInterval(3_600), now: now))
        #expect(AppSigningInfo.hasExpired(now.addingTimeInterval(-1), now: now))
    }
}

/// The point of the whole change, stated as a test: "don't show again for this
/// expiry" must stop meaning "don't show again, ever". It only can once the
/// expiry it is keyed to actually moves, which is what reading `misagent` instead
/// of the frozen app bundle buys.
struct ExpiryWarningSuppressionTests {
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "vn.truongkma.tlocation.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func suppressesOnlyTheExpiryItWasTickedFor() throws {
        let defaults = try makeDefaults()
        let thisWeek = Date(timeIntervalSince1970: 1_800_000_000)
        let afterARefresh = thisWeek.addingTimeInterval(7 * 86_400)

        #expect(!ExpiryWarningSuppression.isSuppressed(thisWeek, in: defaults))

        ExpiryWarningSuppression.suppress(thisWeek, in: defaults)

        #expect(ExpiryWarningSuppression.isSuppressed(thisWeek, in: defaults))
        // The refresh that renews the certificate must bring the warning back.
        #expect(!ExpiryWarningSuppression.isSuppressed(afterARefresh, in: defaults))
    }

    /// The date round-trips through `UserDefaults` as a `Double`, so sub-second
    /// noise must not count as a different expiry.
    @Test func toleratesSubSecondDifferences() throws {
        let defaults = try makeDefaults()
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)

        ExpiryWarningSuppression.suppress(expiry, in: defaults)

        #expect(ExpiryWarningSuppression.isSuppressed(expiry.addingTimeInterval(0.4), in: defaults))
        #expect(!ExpiryWarningSuppression.isSuppressed(expiry.addingTimeInterval(2), in: defaults))
    }
}
