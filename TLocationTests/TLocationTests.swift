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
