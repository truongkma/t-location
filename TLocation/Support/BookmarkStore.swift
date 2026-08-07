//
//  BookmarkStore.swift
//  TLocation
//

import CoreLocation
import Foundation

// MARK: - Bookmark Model

/// A saved location. The stored property names are part of the on-disk format:
/// they are what `BookmarkStore` writes into `UserDefaults` and what an exported
/// JSON file contains, so renaming any of them would orphan existing bookmarks.
struct LocationBookmark: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Store

/// The single owner of bookmark persistence. Both the map and Settings go
/// through this, so an import performed in one is visible in the other after a
/// reload.
///
/// Storage is deliberately unchanged from the original inline implementation in
/// `LocationSimulationView`: the same `UserDefaults` key holding a plain
/// `JSONEncoder`-encoded `[LocationBookmark]`. A user upgrading from a previous
/// build reads back exactly what the previous build wrote.
enum BookmarkStore {
    static let storageKey = "locationBookmarks"

    /// Two coordinates within this many degrees of each other count as the same
    /// place when de-duplicating an import (~1.1 m of latitude). Doubles that
    /// have made a round trip through JSON are never bit-identical, so an exact
    /// `==` would let re-importing the same file duplicate every entry.
    static let coordinateEpsilon: CLLocationDegrees = 0.00001

    // MARK: Persistence

    static func load(from defaults: UserDefaults = .standard) -> [LocationBookmark] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([LocationBookmark].self, from: data) else { return [] }
        return decoded
    }

    static func save(_ bookmarks: [LocationBookmark], to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(bookmarks) {
            defaults.set(data, forKey: storageKey)
        }
    }

    // MARK: Export / import

    /// Pretty-printed so an exported file stays readable (and diffable) if the
    /// user opens it. Keys are sorted for a stable byte-for-byte export.
    static func exportData(_ bookmarks: [LocationBookmark]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(bookmarks)
    }

    static func decode(_ data: Data) throws -> [LocationBookmark] {
        try JSONDecoder().decode([LocationBookmark].self, from: data)
    }

    /// `TLocation-Bookmarks-YYYY-MM-DD`, without an extension — `.fileExporter`
    /// appends the one matching the content type. A fixed POSIX locale and
    /// calendar keep the name in ISO order regardless of device settings.
    static func exportFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return "TLocation-Bookmarks-\(formatter.string(from: date))"
    }

    struct MergeResult {
        var bookmarks: [LocationBookmark]
        var added: Int
        var skipped: Int
    }

    /// Adds `incoming` to `existing`, keeping everything already saved. An entry
    /// is skipped when its `id` is already present, or when it looks like the
    /// same place saved under the same name — which is what happens when the
    /// user exports on one install and imports into another, where the ids
    /// survive but a hand-merged file may repeat entries.
    static func merge(_ incoming: [LocationBookmark], into existing: [LocationBookmark]) -> MergeResult {
        var merged = existing
        var knownIDs = Set(existing.map(\.id))
        var added = 0
        var skipped = 0

        for candidate in incoming {
            if knownIDs.contains(candidate.id) || merged.contains(where: { isDuplicate($0, candidate) }) {
                skipped += 1
                continue
            }
            merged.append(candidate)
            knownIDs.insert(candidate.id)
            added += 1
        }

        return MergeResult(bookmarks: merged, added: added, skipped: skipped)
    }

    private static func isDuplicate(_ lhs: LocationBookmark, _ rhs: LocationBookmark) -> Bool {
        let leftName = lhs.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let rightName = rhs.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard leftName.compare(rightName, options: [.caseInsensitive]) == .orderedSame else { return false }
        return abs(lhs.latitude - rhs.latitude) <= coordinateEpsilon
            && abs(lhs.longitude - rhs.longitude) <= coordinateEpsilon
    }
}
