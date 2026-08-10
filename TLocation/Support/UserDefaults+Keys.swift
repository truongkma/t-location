import Foundation

extension UserDefaults {
    enum Keys {
        static let targetDeviceIP = "TunnelDeviceIP"
        /// `timeIntervalSince1970` of the signing expiry the user chose to stop being
        /// warned about. Keyed to the date rather than stored as a plain flag so that
        /// refreshing in SideStore — which mints a new certificate and a new expiry —
        /// brings the warning back next week instead of silencing it forever.
        static let suppressedExpiryWarning = "suppressedExpiryWarning"

        /// Security-scoped URL bookmark for the JSON file the user linked as a
        /// bookmark sync file. See `BookmarkSyncFile`.
        static let bookmarkSyncFileBookmark = "bookmarkSyncFileBookmark"
        /// Last known display name of that file. Stored separately from the URL
        /// bookmark so Settings can still name the file in an error message on a
        /// launch where the bookmark no longer resolves.
        static let bookmarkSyncFileName = "bookmarkSyncFileName"
        /// `timeIntervalSince1970` of the last successful read from or write to
        /// the sync file. Absent until the first one succeeds.
        static let bookmarkSyncLastSyncedAt = "bookmarkSyncLastSyncedAt"

        /// `AppLanguage.rawValue` for the language override chosen in Settings.
        /// Absent (or "system") means follow the device language. See
        /// `LanguageSettings`.
        static let appLanguage = "appLanguage"
    }
}
