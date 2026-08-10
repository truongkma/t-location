//
//  BookmarkSyncFile.swift
//  TLocation
//

import Foundation

/// A JSON file the user nominates — typically one kept in iCloud Drive — that
/// TLocation keeps in step with the saved bookmarks, so they survive deleting
/// the app and can be picked up on another device.
///
/// iCloud/CloudKit is deliberately not used. It needs the
/// `com.apple.developer.icloud-services` entitlement, and TLocation ships as an
/// unsigned IPA re-signed by SideStore with the end user's *free* Apple ID,
/// which cannot carry that entitlement. A file chosen through the document
/// picker needs no entitlement at all, and once the user puts it in iCloud
/// Drive it gives the same practical result.
///
/// `UserDefaults` stays the source of truth throughout. This type is a mirror:
/// a write that fails — file moved, deleted, or still in the cloud — leaves the
/// locally saved bookmarks completely untouched and surfaces the problem in
/// `status` instead.
final class BookmarkSyncFile: ObservableObject {
    static let shared = BookmarkSyncFile()

    // MARK: - Types

    /// What Settings shows about the link. `failure` is the last thing that went
    /// wrong reaching the file; it is cleared by the next success, so it always
    /// describes the current state rather than accumulating history.
    struct Status: Equatable {
        var fileName: String?
        var lastSyncedAt: Date?
        var failure: String?

        var isLinked: Bool { fileName != nil }
    }

    /// Result of a reconcile (link or Sync Now). Counts use the same rules as
    /// the one-shot import, so the two report the same way.
    struct SyncOutcome {
        var fileName: String
        var added: Int
        var skipped: Int
    }

    enum SyncError: LocalizedError {
        case notLinked
        case unreachable
        case invalidContents

        var errorDescription: String? {
            switch self {
            case .notLinked:
                return String(localized: "No sync file is linked.")
            case .unreachable:
                return String(localized: "The sync file could not be opened. It may have been moved or deleted, or not downloaded from iCloud yet.")
            case .invalidContents:
                return String(localized: "The sync file is not a valid TLocation bookmarks file.")
            }
        }
    }

    // MARK: - State

    /// Shown in place of a file name in the vanishingly unlikely case that a
    /// link exists without a remembered name — better than a blank row.
    private static var unnamedFilePlaceholder: String { String(localized: "Sync file") }

    @Published private(set) var status: Status

    private let defaults: UserDefaults
    /// Serialises every access to the linked file and keeps it off the main
    /// thread. A coordinated write to an iCloud Drive file can block for as long
    /// as the coordinator needs, which must never happen on a UI event.
    private let queue = DispatchQueue(label: "vn.truongkma.tlocation.bookmark-sync", qos: .utility)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedTimestamp = defaults.object(forKey: UserDefaults.Keys.bookmarkSyncLastSyncedAt) as? Double
        status = Status(
            // Driven by the presence of the URL bookmark, not the name: the
            // bookmark is what makes the link real, and Settings must show a
            // linked file even if the remembered name has somehow gone.
            fileName: defaults.data(forKey: UserDefaults.Keys.bookmarkSyncFileBookmark) == nil
                ? nil
                : (defaults.string(forKey: UserDefaults.Keys.bookmarkSyncFileName) ?? Self.unnamedFilePlaceholder),
            lastSyncedAt: storedTimestamp.map { Date(timeIntervalSince1970: $0) },
            failure: nil
        )
    }

    /// Thread-safe: read straight from `UserDefaults` rather than from the
    /// published snapshot, because `BookmarkStore.save` can ask from any thread.
    var isLinked: Bool {
        defaults.data(forKey: UserDefaults.Keys.bookmarkSyncFileBookmark) != nil
    }

    // MARK: - Mutation mirroring

    /// Fire-and-forget write of the current list into the linked file, called by
    /// `BookmarkStore.save` so that every mutation path — adding on the map,
    /// deleting, renaming, importing — is covered by one hook rather than by a
    /// call at each site. Does nothing when no file is linked.
    func mirror(_ bookmarks: [LocationBookmark]) {
        guard isLinked else { return }
        queue.async { [weak self] in
            self?.performWrite(bookmarks)
        }
    }

    // MARK: - Linking

    /// Links `url` and reconciles it with the saved list in one step: whatever
    /// the file already holds is merged in, then the combined list is written
    /// back. Linking therefore never discards bookmarks from either side.
    ///
    /// The link is only recorded once the file has been read and understood, so
    /// picking the wrong file leaves the previous link (or no link) in place.
    @discardableResult
    func link(to url: URL) async throws -> SyncOutcome {
        try await onQueue {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            // `.withSecurityScope` is macOS-only; on iOS the security scope is
            // embedded implicitly as long as the bookmark is created while the
            // picker's scope is open, which is exactly where we are.
            let bookmarkData: Data
            do {
                bookmarkData = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            } catch {
                throw SyncError.unreachable
            }

            let remote = try self.readBookmarks(at: url, treatingMissingFileAsEmpty: true)
            let outcome = try self.reconcile(with: remote, at: url)

            // Committed last, so a file that could not be read or written back
            // leaves no half-configured link behind for the next launch to trip
            // over.
            self.defaults.set(bookmarkData, forKey: UserDefaults.Keys.bookmarkSyncFileBookmark)
            self.defaults.set(url.lastPathComponent, forKey: UserDefaults.Keys.bookmarkSyncFileName)
            return outcome
        }
    }

    /// Forgets the link. The user's file is left exactly where it is — unlinking
    /// is not a delete.
    func unlink() {
        defaults.removeObject(forKey: UserDefaults.Keys.bookmarkSyncFileBookmark)
        defaults.removeObject(forKey: UserDefaults.Keys.bookmarkSyncFileName)
        defaults.removeObject(forKey: UserDefaults.Keys.bookmarkSyncLastSyncedAt)
        publish(Status())
    }

    // MARK: - Pulling

    /// Reads the linked file, merges it into the saved list using the same rules
    /// as the one-shot import, and writes the combined list back so both sides
    /// end up holding the same set.
    @discardableResult
    func pull() async throws -> SyncOutcome {
        try await onQueue {
            do {
                return try self.withLinkedFile { url in
                    let remote = try self.readBookmarks(at: url, treatingMissingFileAsEmpty: false)
                    return try self.reconcile(with: remote, at: url)
                }
            } catch {
                // Recorded as well as rethrown: the caller shows a transient
                // message, but the section also has to keep showing that the
                // file is unreachable once that message has faded.
                self.record(failure: error)
                throw error
            }
        }
    }

    /// Cheap reachability check for the Settings sheet: confirms the stored
    /// bookmark still resolves to a file that exists, without reading it. Runs
    /// off the main thread and reports through `status`.
    func refresh() {
        guard isLinked else {
            if status != Status() { publish(Status()) }
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let name = try self.withLinkedFile { url -> String in
                    guard (try? url.checkResourceIsReachable()) == true else { throw SyncError.unreachable }
                    return url.lastPathComponent
                }
                self.recordReachable(fileName: name)
            } catch {
                self.record(failure: error)
            }
        }
    }

    // MARK: - Work performed on `queue`

    /// Merges `remote` into what is saved locally, persists the result, and
    /// writes it back out to `url`. `BookmarkStore.persistLocally` is used
    /// rather than `save` so this does not bounce straight back through
    /// `mirror` for a second, redundant write of bytes we are already writing.
    private func reconcile(with remote: [LocationBookmark], at url: URL) throws -> SyncOutcome {
        let merge = BookmarkStore.merge(remote, into: BookmarkStore.load())
        BookmarkStore.persistLocally(merge.bookmarks)

        try writeData(try BookmarkStore.exportData(merge.bookmarks), to: url)
        recordSuccess(fileName: url.lastPathComponent)

        return SyncOutcome(fileName: url.lastPathComponent, added: merge.added, skipped: merge.skipped)
    }

    private func performWrite(_ bookmarks: [LocationBookmark]) {
        do {
            let data = try BookmarkStore.exportData(bookmarks)
            let name = try withLinkedFile { url -> String in
                try writeData(data, to: url)
                return url.lastPathComponent
            }
            recordSuccess(fileName: name)
        } catch {
            record(failure: error)
        }
    }

    /// Resolves the stored URL bookmark, opens its security scope for the
    /// duration of `body`, and closes it again afterwards.
    ///
    /// A stale bookmark — what you get once the user moves or renames the file —
    /// still resolves to the right place, so fresh bookmark data is minted on
    /// the spot instead of letting the next launch fail outright.
    private func withLinkedFile<T>(_ body: (URL) throws -> T) throws -> T {
        guard let data = defaults.data(forKey: UserDefaults.Keys.bookmarkSyncFileBookmark) else {
            throw SyncError.notLinked
        }

        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: [.withoutImplicitStartAccessing],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw SyncError.unreachable
        }

        // `false` here means the URL simply is not security scoped, which is
        // legitimate; it is not a failure to access.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        if isStale, let refreshed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(refreshed, forKey: UserDefaults.Keys.bookmarkSyncFileBookmark)
            defaults.set(url.lastPathComponent, forKey: UserDefaults.Keys.bookmarkSyncFileName)
        }

        return try body(url)
    }

    /// A brand-new file the user just created through the save sheet can be
    /// zero bytes; that is an empty bookmark list, not a broken file. A missing
    /// file is only tolerated while linking, where the picker may have handed
    /// back a location the provider has not materialised yet.
    private func readBookmarks(at url: URL, treatingMissingFileAsEmpty: Bool) throws -> [LocationBookmark] {
        let data: Data
        do {
            data = try readData(at: url)
        } catch {
            if treatingMissingFileAsEmpty { return [] }
            throw SyncError.unreachable
        }

        guard !data.isEmpty else { return [] }
        do {
            return try BookmarkStore.decode(data)
        } catch {
            throw SyncError.invalidContents
        }
    }

    /// Coordinated so an iCloud Drive file is downloaded and settled before it
    /// is read, rather than yielding a placeholder or a half-written file.
    private func readData(at url: URL) throws -> Data {
        var coordinatorError: NSError?
        var outcome: Result<Data, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readURL in
            outcome = Result { try Data(contentsOf: readURL) }
        }
        if let coordinatorError { throw coordinatorError }
        guard let outcome else { throw SyncError.unreachable }
        return try outcome.get()
    }

    /// Coordinated and atomic: the bytes land via a temporary file and a rename,
    /// so a reader — including the iCloud Drive uploader — never sees a
    /// half-written bookmark list.
    private func writeData(_ data: Data, to url: URL) throws {
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { writeURL in
            do {
                try data.write(to: writeURL, options: [.atomic])
            } catch {
                writeError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }

    /// Hops onto the serial queue and back, so callers in SwiftUI can `await`
    /// file work without it ever running on the main thread.
    private func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    // MARK: - Status bookkeeping

    private func recordSuccess(fileName: String) {
        let now = Date()
        defaults.set(fileName, forKey: UserDefaults.Keys.bookmarkSyncFileName)
        defaults.set(now.timeIntervalSince1970, forKey: UserDefaults.Keys.bookmarkSyncLastSyncedAt)
        publish(Status(fileName: fileName, lastSyncedAt: now, failure: nil))
    }

    private func recordReachable(fileName: String) {
        let storedTimestamp = defaults.object(forKey: UserDefaults.Keys.bookmarkSyncLastSyncedAt) as? Double
        publish(Status(
            fileName: fileName,
            lastSyncedAt: storedTimestamp.map { Date(timeIntervalSince1970: $0) },
            failure: nil
        ))
    }

    /// Keeps the link and the last-known file name: the user needs to see *which*
    /// file has gone missing, and needs the link to still be there so a Sync Now
    /// works again once the file comes back.
    private func record(failure error: Error) {
        LogManager.shared.addErrorLog("Bookmark sync file: \(error.localizedDescription)")

        guard isLinked else {
            publish(Status())
            return
        }
        let storedTimestamp = defaults.object(forKey: UserDefaults.Keys.bookmarkSyncLastSyncedAt) as? Double
        publish(Status(
            fileName: defaults.string(forKey: UserDefaults.Keys.bookmarkSyncFileName) ?? Self.unnamedFilePlaceholder,
            lastSyncedAt: storedTimestamp.map { Date(timeIntervalSince1970: $0) },
            failure: error.localizedDescription
        ))
    }

    private func publish(_ newStatus: Status) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.status != newStatus else { return }
            self.status = newStatus
        }
    }
}
