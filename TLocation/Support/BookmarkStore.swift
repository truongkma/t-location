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

    // MARK: Matching a coordinate to a saved bookmark

    /// How close an already-saved bookmark has to be for the map callout to
    /// call the dropped pin "saved".
    ///
    /// Deliberately much looser than `coordinateEpsilon` (~1.1 m), and
    /// deliberately measured in metres rather than degrees so it means the same
    /// thing at any latitude. Two things push the pin off a saved point by more
    /// than a metre through no fault of the user:
    ///
    /// - the opt-in natural GPS drift adds a random 3–5 m offset to every
    ///   resend, so while a simulation is running iOS reports a position that
    ///   wanders inside a ~5 m disc, and "Locate Me" hands that wandering
    ///   position straight back to the pin;
    /// - a real GPS fix is only good to a few metres anyway.
    ///
    /// At 1.1 m the callout would call such a pin unsaved and offer to save a
    /// near-duplicate a few metres from the original. 12 m clears the 5 m drift
    /// with room to spare while still being far smaller than the distance
    /// between two places a user would want saved separately.
    ///
    /// This is a *display* tolerance only. `merge` keeps `coordinateEpsilon`
    /// untouched: import/sync de-duplication must stay conservative, since
    /// merging two genuinely different bookmarks 10 m apart would lose data.
    static let displayMatchRadiusMeters: CLLocationDistance = 12

    /// The saved bookmark closest to `coordinate`, or `nil` if none is within
    /// `radiusMeters`. Nearest-wins, so an area with several saved points names
    /// the one the pin is actually on.
    static func bookmark(
        nearest coordinate: CLLocationCoordinate2D,
        in bookmarks: [LocationBookmark],
        within radiusMeters: CLLocationDistance = displayMatchRadiusMeters
    ) -> LocationBookmark? {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return bookmarks
            .map { ($0, CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: target)) }
            .filter { $0.1 <= radiusMeters }
            .min { $0.1 < $1.1 }?
            .0
    }

    // MARK: Persistence

    static func load(from defaults: UserDefaults = .standard) -> [LocationBookmark] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([LocationBookmark].self, from: data) else { return [] }
        return decoded
    }

    /// The one write path every mutation goes through — adding on the map,
    /// deleting, renaming, importing — which is why mirroring into the linked
    /// sync file hangs off this call rather than off each call site.
    ///
    /// The mirror is fire-and-forget and cannot fail loudly here: `UserDefaults`
    /// is the source of truth, and a sync file that is missing or offline must
    /// never cost the user a bookmark. `BookmarkSyncFile.status` carries the
    /// problem to Settings instead.
    static func save(_ bookmarks: [LocationBookmark], to defaults: UserDefaults = .standard) {
        persistLocally(bookmarks, to: defaults)
        if defaults === UserDefaults.standard {
            BookmarkSyncFile.shared.mirror(bookmarks)
        }
    }

    /// Writes to `UserDefaults` and nothing else. `BookmarkSyncFile` uses this
    /// when it has just read the linked file and is about to write the merged
    /// list back itself, so going through `save` would only queue a duplicate
    /// write of bytes already in flight.
    static func persistLocally(_ bookmarks: [LocationBookmark], to defaults: UserDefaults = .standard) {
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

    /// Name offered when creating a file to link as the sync file. This one
    /// file is written over for as long as the link lasts, so a date in its
    /// name would only ever be misleading.
    static let syncFileName = "TLocation-Bookmarks-Sync"

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
